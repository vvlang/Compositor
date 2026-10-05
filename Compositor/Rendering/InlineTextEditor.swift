import AppKit

/// 画布上的原生文本系统：选区、marked text / IME、剪贴板以及局部撤销都由 NSTextView 处理。
/// 其逻辑边界为图层像素；缩放由其所属视图提供。
/// 其字形清晰可见：画布在底层把文本绘制为图层自身的像素，正如 Photoshop 的做法，
/// 因此键入的文本在任何缩放下都与提交后所见一致。
/// 文本选区以半透明方式绘制，无论是否处于焦点状态。
private final class SeeThroughSelectionLayout: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        color.withAlphaComponent(min(color.alphaComponent, 0.45)).setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }
}

final class CanvasTextView: NSTextView {
    weak var editor: InlineTextEditor?
    private let textUndo = UndoManager()
    /// 当字体菜单夺取焦点时设置，以防折叠的插入符替换原本已选中的字符。
    var holdsSelection = false
    override var undoManager: UndoManager? { textUndo }
    // 撤销与重做会指向窗口，而窗口的历史栈并非此处所有，因此文本自行处理：
    // ⌘Z 一次性撤销自文本框打开以来键入的全部内容，如同 Figma 的行为。
    @objc func undo(_ sender: Any?) { if textUndo.canUndo { textUndo.undo() } }
    @objc func redo(_ sender: Any?) { if textUndo.canRedo { textUndo.redo() } }
    override func resignFirstResponder() -> Bool {
        // 字体菜单夺取焦点时可能令高亮消失。字母保持选中状态，这样字体设置便会作用于它们。
        let range = selectedRange()
        let resigned = super.resignFirstResponder()
        if range.length > 0 {
            holdsSelection = true
            editor?.keepSelection(range)
        }
        return resigned
    }
    override func mouseDown(with event: NSEvent) {
        holdsSelection = false
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let event = ShortcutSettings.shared.textEvent(event) else { return }
        if event.keyCode == 53 { editor?.canvas?.session.cancelText(); return }
        // Option 与方向键组合可调整间距，仿 Photoshop 的行为：左右调整字距（tracking），上下调整行距（leading）。
        // 按住 Shift 时每步放大十倍。
        if event.modifierFlags.contains(.option), [123, 124, 125, 126].contains(event.keyCode),
           let session = editor?.canvas?.session {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: session.changeTextStyle { $0.tracking -= step }
            case 124: session.changeTextStyle { $0.tracking += step }
            // 上箭头收紧行距，下箭头拉开行距，以「自动」计算出的当前值为基准。
            case 126: session.changeTextStyle { $0.leading = max(1, $0.lineHeight - step) }
            default: session.changeTextStyle { $0.leading = $0.lineHeight + step }
            }
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            _ = editor?.canvas?.session.finishText()
            return
        }
        holdsSelection = false
        super.keyDown(with: event)
        // 文本视图在键入时隐藏指针；画布上保持指针可见，以便知道下一次将点击的位置。
        NSCursor.setHiddenUntilMouseMoves(false)
    }
    override func mouseExited(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(false) }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    // 编辑器为整个文本框设置光标——文本之上为 I 形，边缘之上为缩放箭头。
    override func resetCursorRects() {}
}

final class InlineTextEditor: NSView, NSTextViewDelegate {
    weak var canvas: CanvasView?
    let textView = CanvasTextView(frame: .zero)
    fileprivate var draftID: UUID?
    private var shownStyle: LayerTextStyle?
    /// NSTextView 已接受但尚未落实的样式，颜色与字体 run 已相应移动以匹配。
    private var pendingStyle: LayerTextStyle?
    private var synchronizing = false
    private var logicalSize = CGSize(width: 360, height: 160)
    private var handleSize: CGFloat = 6
    private(set) var shownTransform: LayerTransform?
    private struct Geometry: Equatable {
        let transform: LayerTransform
        let logicalSize: CGSize
        let anchor: CGPoint
        let scale: CGFloat
    }
    private var shownGeometry: Geometry?
    private var measuredStyle: LayerTextStyle?
    private var measuredSize: CGSize = .zero
    private var resize: (handle: Int, draft: TextDraft, transform: LayerTransform, start: CGPoint)?
    /// 编辑器当前实际显示的变换。点文本随键入而增长，因此不一定是草稿自身的变换，
    /// 调整大小必须从屏幕上所见开始，否则文本会跳动。
    override var isFlipped: Bool { true }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        textView.editor = self
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // 选区透出至画布在其下方绘制的文本——即使在另一窗口（颜色拾取器预览所选字符）取得焦点时也是如此，
        // 否则 AppKit 会将其涂成实心灰色。
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45)]
        textView.textContainer?.replaceLayoutManager(SeeThroughSelectionLayout())
        textView.setAccessibilityLabel(L10n.string("Canvas text"))
        // 二者从一开始就由 layer 支撑。若交给 AppKit，文本表面的 layer 会先放入画布自身的 layer 树，
        // 一帧后才被移入本视图；而对于翻转的 layer，其镜像效果正依赖那次放置，
        // 因此这次移动会表现为一次跳动。
        wantsLayer = true
        textView.wantsLayer = true
        textView.layer?.anchorPoint = .zero
        addSubview(textView)
        clipsToBounds = false
        // 放置完成后再显示，避免翻转的 layer 在未镜像的位置出现一帧。
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func synchronize(_ draft: TextDraft) {
        guard let canvas, let document = canvas.session.document else { return }
        let fresh = draftID != draft.id
        draftID = draft.id
        let style = draft.style
        let layer = document.layers.first { $0.id == draft.layerID }
        // 点文本没有文本框：其大小即为已键入内容的体积，并随键入而增长。
        if let boxSize = style.boxSize {
            logicalSize = boxSize
        } else {
            if measuredStyle != style {
                measuredSize = EditorSession.textBoxSize(style)
                measuredStyle = style
            }
            logicalSize = measuredSize
        }
        var transform = draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        // 已落在图层上的点文本同样随键入增长，保持图层原本所给的缩放。
        if style.boxSize == nil, draft.transform != nil, let asset = layer?.asset, asset.image.width > 0 {
            let factor = transform.size.width / CGFloat(asset.image.width)
            // 旋转的图层绕其中心旋转，因此放大图层会让角点偏离，文本随之漂移。
            // 将左上角放回原位——提交后也保持在此位置。
            let anchor = transform.point(.zero)
            transform.size = CGSize(width: logicalSize.width * factor, height: logicalSize.height * factor)
            let moved = transform.point(.zero)
            transform.origin.x += anchor.x - moved.x
            transform.origin.y += anchor.y - moved.y
        }
        shownTransform = transform
        let scale = canvas.session.viewport.pointsPerPixel
        let anchor = canvas.session.viewport.viewPoint(from: transform.point(.zero), documentSize: document.size)
        let geometry = Geometry(transform: transform, logicalSize: logicalSize, anchor: anchor, scale: scale)
        if fresh || shownGeometry != geometry {
            // AppKit 的 frame 旋转同时参与绘制与事件坐标转换。
            frameRotation = 0
            frame = CGRect(origin: canvas.session.viewport.viewPoint(from: transform.point(.zero), documentSize: document.size),
                           size: CGSize(width: transform.size.width * scale, height: transform.size.height * scale))
            bounds = CGRect(origin: .zero, size: logicalSize)
            // 画布已翻转，正向的 frame 旋转让编辑器在屏幕上顺时针转动，与图层自身的旋转度量方向一致。
            // 取负会让编辑器与所编辑的文本方向相反。
            frameRotation = transform.rotation
            // 旋转已翻转的 NSView 可能改变其逻辑原点。固定住图层的左上角。
            let actual = convert(CGPoint.zero, to: canvas)
            setFrameOrigin(CGPoint(x: frame.origin.x + anchor.x - actual.x, y: frame.origin.y + anchor.y - actual.y))
            let padding = LayerTextStyle.padding
            let textFrame = bounds.insetBy(dx: padding, dy: padding)
            if textView.frame != textFrame { textView.frame = textFrame }
            // 镜像属于文本表面，让缩放手柄保持其逻辑顺序。
            mirror = (transform.flipX, transform.flipY)
            applyMirror()
            handleSize = max(2, 6 / max(0.01, scale * transform.size.width / logicalSize.width))
            shownGeometry = geometry
            needsDisplay = true
        }
        if shownStyle != style {
            synchronizing = true
            let live = textView.selectedRange()
            let kept = canvas.session.textDraft?.selection ?? live
            let selection = textView.holdsSelection && kept.length > 0 ? kept : live
            if textView.string != style.content { textView.string = style.content }
            var attributes = EditorSession.textAttributes(style)
            attributes[.foregroundColor] = NSColor.clear
            if !textView.hasMarkedText() {
                textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
                for run in style.fontRuns ?? [] where EditorSession.containsTextRun(run.location, run.length, in: textView.string.utf16.count) {
                    let font = NSFont(name: run.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
                    textView.textStorage?.addAttribute(.font, value: font, range: NSRange(location: run.location, length: run.length))
                }
                textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count),
                    length: min(selection.length, max(0, textView.string.utf16.count - selection.location))))
            }
            let caret = selection.length > 0 ? selection.location : max(0, selection.location - 1)
            let face = style.fontName(at: caret)
            attributes[.font] = NSFont(name: face, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
            textView.typingAttributes = attributes
            shownStyle = style
            updateInsertionPointColor(style)
            synchronizing = false
            needsDisplay = true
        }
        if isHidden { isHidden = false }
        if fresh {
            textView.undoManager?.removeAllActions()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canvas?.session.textDraft?.id == draft.id else { return }
                if self.window?.firstResponder is NSText, self.window?.firstResponder !== self.textView { return }
                self.window?.makeFirstResponder(self.textView)
                // 打开已有文本时把光标置于文本末尾，便于继续追加，除非此前已有点击放置过光标。
                if draft.layerID != nil, self.textView.selectedRange() == NSRange(location: 0, length: 0) {
                    self.textView.setSelectedRange(NSRange(location: self.textView.string.utf16.count, length: 0))
                }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !synchronizing, let session = canvas?.session, var draft = session.textDraft else { return }
        if let pendingStyle, pendingStyle.content == textView.string {
            draft.style.colorRuns = pendingStyle.colorRuns
            draft.style.fontRuns = pendingStyle.fontRuns
        }
        pendingStyle = nil
        draft.style.content = textView.string
        // 文本 NSTextView 在未说明改动方式的情况下无法逐字符保留颜色与字体。
        if !draft.style.isValid { draft.style.colorRuns = nil; draft.style.fontRuns = nil }
        draft.selection = textView.selectedRange()
        shownStyle = draft.style
        session.textDraft = draft
        // NSTextView 自行绘制变更后的字形。刷新文本框的溢出标记，
        // 但不要在每次按键时重置文本容器的几何信息。
        needsDisplay = true
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let length = replacementString?.utf16.count ?? 0
        guard textView.string.utf16.count - affectedCharRange.length + length <= 100_000 else { return false }
        if !synchronizing, let draft = canvas?.session.textDraft,
           draft.style.colorRuns != nil || draft.style.fontRuns != nil {
            var style = pendingStyle ?? draft.style
            guard NSMaxRange(affectedCharRange) <= style.content.utf16.count else { return true }
            style.replaceCharacters(in: affectedCharRange, withLength: length)
            style.content = (style.content as NSString).replacingCharacters(in: affectedCharRange, with: replacementString ?? "")
            pendingStyle = style
        }
        return true
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !synchronizing, let session = canvas?.session, session.textDraft?.id == draftID else { return }
        let selection = textView.selectedRange()
        if textView.holdsSelection, selection.length == 0, (session.textDraft?.selection.length ?? 0) > 0 { return }
        textView.holdsSelection = false
        if session.textDraft?.selection != selection { session.textDraft?.selection = selection }
        if let style = session.textDraft?.style { updateInsertionPointColor(style) }
    }
    /// 恢复焦点切换时被清掉的选区，使字体菜单仍能作用于这些字符。
    func keepSelection(_ range: NSRange) {
        guard range.length > 0, let session = canvas?.session, session.textDraft?.id == draftID else { return }
        if session.textDraft?.selection != range { session.textDraft?.selection = range }
    }
    private func updateInsertionPointColor(_ style: LayerTextStyle) {
        let location = textView.selectedRange().location
        let color = style.color(at: location > 0 ? location - 1 : 0)
        textView.insertionPointColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private var handleTracking: NSTrackingArea?
    /// 为翻转图层镜像文本表面，围绕表面中点进行。图层变换绕其 anchor point 旋转，
    /// 而 AppKit 在布局该视图时会设置该点（以及 layer 的 position），
    /// 因此每次布局后都要重新执行，并在绘制前再执行一次。
    private var mirror: (x: Bool, y: Bool) = (false, false)
    private func applyMirror() {
        guard let layer = textView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard mirror.x || mirror.y else {
            if !layer.affineTransform().isIdentity { layer.setAffineTransform(.identity) }
            return
        }
        // 手动放置：在 AppKit 完成本视图布局之前，文本表面的 layer 仍处于画布坐标系中，
        // 围绕位于别处的 layer 做镜像会在第一帧出现一次跳动。
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: .zero, size: textView.bounds.size)
        layer.position = textView.frame.origin
        let shift = CGPoint(x: mirror.x ? textView.bounds.width : 0, y: mirror.y ? textView.bounds.height : 0)
        layer.setAffineTransform(CGAffineTransform(translationX: shift.x, y: shift.y)
            .scaledBy(x: mirror.x ? -1 : 1, y: mirror.y ? -1 : 1))
    }
    override func layout() {
        super.layout()
        applyMirror()
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        // 将文本表面的 layer 接入本视图的 layer 树会清除其变换，且这一步发生在其他一切之后：
        // 缺少此调用，翻转 layer 的首帧会以未镜像的状态绘制。
        applyMirror()
    }

    /// 光标遵循与鼠标相同的判定：边缘与角点之上为缩放箭头，文本之上为 I 形。
    /// 光标矩形在此无济于事——文本框可能旋转，而 AppKit 不会将光标矩形映射经过视图的旋转——因此本视图自行监听指针。
    private var cursorTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow,
                                                         .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area)
        cursorTracking = area
    }
    override func mouseEntered(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { showCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(false) }
    private func showCursor(at point: CGPoint) {
        guard bounds.insetBy(dx: -edgeReach, dy: -edgeReach).contains(point) else {
            NSCursor.setHiddenUntilMouseMoves(false)
            NSCursor.arrow.set()
            return
        }
        guard resize == nil, canvas?.session.colorPicker == nil else { return }
        guard let index = handle(at: point) else { NSCursor.iBeam.set(); return }
        handleCursor(index).set()
    }

    /// 文本框打开期间的每一次鼠标移动，无论指针位于何处。一旦文本表面取得鼠标，tracking area 就停止上报，
    /// 导致光标停留在上一次所设的状态。文本框内为 I 形或缩放箭头；画布其余部分为 Type 工具的 I 形；
    /// 离开画布时为箭头，仅在离开瞬间设置一次，避免工具栏自身控件的光标被覆盖。
    private var moveMonitor: Any?
    private var pointerOnCanvas = true
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor); self.moveMonitor = nil }
        guard window != nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, self.window === event.window else { return event }
            self.pointerMoved(event)
            return event
        }
    }
    deinit {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
    }
    func pointerMoved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -edgeReach, dy: -edgeReach).contains(point) {
            pointerOnCanvas = true
            showCursor(at: point)
        } else if let canvas, canvas.bounds.contains(canvas.convert(event.locationInWindow, from: nil)) {
            pointerOnCanvas = true
            guard resize == nil, canvas.session.colorPicker == nil else { return }
            NSCursor.iBeam.set()
        } else if pointerOnCanvas {
            pointerOnCanvas = false
            NSCursor.setHiddenUntilMouseMoves(false)
            NSCursor.arrow.set()
        }
    }

    /// 缩放手柄对应的边缘或角点的箭头，随文本框一起旋转。
    private func handleCursor(_ index: Int) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .topLeft, .top, .topRight, .right]
        let rotation = canvas?.session.textDraft?.transform?.rotation ?? 0
        let turns = (Int((rotation / 45).rounded()) % 8 + 8) % 8
        let ordered: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right]
        let position = ordered[(ordered.firstIndex(of: positions[index])! + turns) % 4]
        return .frameResize(position: position, directions: [.inward, .outward])
    }

    /// 距离一条边多远的区域算作该边，以文本框自身单位计量。设有上限以保证小文本框仍留有可键入的中间区域。
    /// Move 工具的框在距边 10 个屏幕点内即捕获；此处手柄绘制宽度 6 点，
    /// 因此同等捕获范围为一个手柄的 10/6。
    private var edgeReach: CGFloat { min(handleSize * 10 / 6, min(bounds.width, bounds.height) / 3) }

    /// 某点所对应的边缘或角点，按手柄顺序：沿每条边有一条捕获带，正如 Move 工具的框，
    /// 而非仅限于手柄方块。其余位置返回 nil，表示处于文本区域。
    private func handle(at point: CGPoint) -> Int? {
        let reach = edgeReach
        let left = point.x <= reach, right = point.x >= bounds.width - reach
        let top = point.y <= reach, bottom = point.y >= bounds.height - reach
        guard point.x >= -reach, point.x <= bounds.width + reach,
              point.y >= -reach, point.y <= bounds.height + reach else { return nil }
        switch (left, right, top, bottom) {
        case (true, _, true, _): return 0
        case (_, true, true, _): return 2
        case (_, true, _, true): return 4
        case (true, _, _, true): return 6
        case (_, _, true, _): return 1
        case (_, true, _, _): return 3
        case (_, _, _, true): return 5
        case (true, _, _, _): return 7
        default: return nil
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if canvas?.session.colorPicker != nil { return nil }
        let local = convert(point, from: superview)
        if handle(at: local) != nil { return self }
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let box = NSBezierPath(rect: bounds.insetBy(dx: handleSize / 12, dy: handleSize / 12))
        box.lineWidth = handleSize / 6
        box.stroke()
        for unit in LayerTransform.handles {
            let rect = CGRect(x: unit.x * bounds.width - handleSize / 2, y: unit.y * bounds.height - handleSize / 2,
                              width: handleSize, height: handleSize)
            NSColor.white.setFill(); rect.fill()
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: rect).stroke()
        }
        // 装不下的文本以绘制在右下角手柄中的加号标记，仿 Photoshop 的做法。
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) < layout.numberOfGlyphs {
                let unit = LayerTransform.handles[4]
                let center = CGPoint(x: unit.x * bounds.width, y: unit.y * bounds.height)
                let arm = handleSize * 0.42
                let plus = NSBezierPath()
                plus.move(to: CGPoint(x: center.x - arm, y: center.y)); plus.line(to: CGPoint(x: center.x + arm, y: center.y))
                plus.move(to: CGPoint(x: center.x, y: center.y - arm)); plus.line(to: CGPoint(x: center.x, y: center.y + arm))
                plus.lineWidth = handleSize / 6
                NSColor.black.setStroke()
                plus.stroke()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let canvas, let document = canvas.session.document, let draft = canvas.session.textDraft,
              let handle = handle(at: convert(event.locationInWindow, from: nil)) else { return }
        let transform = shownTransform ?? draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        let pixel = canvas.session.viewport.documentPoint(from: canvas.convert(event.locationInWindow, from: nil), documentSize: document.size)
        // 拖动手柄将点文本转换为当前大小的文本框，文本随即被框住并换行，而非按比例缩放文本。
        // 缩放与旋转沿用图层原本的值。
        var fixed = draft
        if fixed.style.boxSize == nil {
            fixed.style.boxSize = logicalSize
            fixed.transform = transform
            fixed.origin = transform.origin
            canvas.session.textDraft = fixed
        }
        resize = (handle, fixed, transform, pixel)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let resize, let canvas, let document = canvas.session.document else { return }
        let point = canvas.session.viewport.documentPoint(from: canvas.convert(event.locationInWindow, from: nil), documentSize: document.size)
        let old = resize.transform
        let dx = point.x - resize.start.x, dy = point.y - resize.start.y
        let localX = dx * cos(old.radians) + dy * sin(old.radians)
        let localY = -dx * sin(old.radians) + dy * cos(old.radians)
        let unit = LayerTransform.handles[resize.handle]
        var left: CGFloat = 0, top: CGFloat = 0, right = old.size.width, bottom = old.size.height
        let source = resize.draft.style.boxSize ?? logicalSize
        let minW = 16 * old.size.width / source.width, minH = 16 * old.size.height / source.height
        if unit.x == 0 { left = min(localX, right - minW) }
        if unit.x == 1 { right = max(left + minW, right + localX) }
        if unit.y == 0 { top = min(localY, bottom - minH) }
        if unit.y == 1 { bottom = max(top + minH, bottom + localY) }
        var draft = resize.draft
        draft.style.boxSize = CGSize(width: ((right - left) * source.width / old.size.width).rounded(),
                                     height: ((bottom - top) * source.height / old.size.height).rounded())
        guard draft.style.boxIsValid else { return }
        var transform = old
        transform.size = CGSize(width: draft.style.boxSize!.width * old.size.width / source.width,
                                height: draft.style.boxSize!.height * old.size.height / source.height)
        let anchor = old.point(CGPoint(x: left / old.size.width, y: top / old.size.height))
        let current = transform.point(.zero)
        transform.origin.x += anchor.x - current.x
        transform.origin.y += anchor.y - current.y
        guard transform.isValid else { return }
        draft.origin = transform.origin
        draft.transform = transform
        canvas.session.textDraft = draft
        canvas.synchronizeDisplay()
    }
    override func mouseUp(with event: NSEvent) { resize = nil; window?.makeFirstResponder(textView) }
}

extension CanvasView {
    func synchronizeInlineText() {
        guard let draft = session.textDraft else {
            if inlineTextEditor != nil {
                let hadFocus = window?.firstResponder === inlineTextEditor?.textView
                inlineTextEditor?.removeFromSuperview()
                inlineTextEditor = nil
                needsDisplay = true
                if hadFocus { window?.makeFirstResponder(self) }
            }
            return
        }
        if inlineTextEditor?.draftID != draft.id { needsDisplay = true }
        if inlineTextEditor == nil {
            let editor = InlineTextEditor(canvas: self)
            inlineTextEditor = editor
            addSubview(editor)
            needsDisplay = true
        }
        inlineTextEditor?.synchronize(draft)
    }

    func beginTextGesture(at point: CGPoint, event: NSEvent) {
        guard let document = session.document, session.finishText() else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let visible = document.effectiveVisibleIDs
        if let layer = document.layers.reversed().first(where: { visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(pixel) }) {
            session.selectLayer(layer.id)
            session.editActiveText()
            synchronizeInlineText()
            inlineTextEditor?.textView.mouseDown(with: event)
        } else {
            textBoxAnchor = pixel
            textBoxRect = CGRect(origin: pixel, size: .zero)
        }
        needsDisplay = true
    }

    func dragTextGesture(to point: CGPoint) {
        guard let anchor = textBoxAnchor, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        textBoxRect = DragBox.rect(from: anchor, to: pixel, square: false, fromCenter: false)
        needsDisplay = true
    }

    func finishTextGesture() {
        guard let rect = textBoxRect else { return }
        textBoxAnchor = nil; textBoxRect = nil
        if rect.width < 4 && rect.height < 4 { session.beginText(at: rect.origin, newLayer: true) }
        else { session.beginText(in: rect) }
        synchronizeInlineText()
        needsDisplay = true
    }

    func drawTextBoxDraft() {
        guard let rect = textBoxRect, let document = session.document else { return }
        let origin = session.viewport.viewPoint(from: rect.origin, documentSize: document.size)
        let scale = session.viewport.pointsPerPixel
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: CGRect(origin: origin, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
        path.lineWidth = 1
        path.stroke()
    }
}
