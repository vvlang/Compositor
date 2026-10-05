import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.consumeFocusRequest(session.canvasFocusRequest)
        _ = session.showsTransformControls // 在这里观察，这样 ⌘H 能立刻重绘变换框
        _ = session.showsGrid
        _ = session.layoutGrid
        _ = session.gridAppearance
        _ = session.showsGuides
        _ = session.guideDrag
        _ = session.document?.guides
        view.synchronizeDisplay()
        view.window?.isDocumentEdited = session.isModified
    }
}

final class CanvasView: NSView {
    var inlineTextEditor: InlineTextEditor?
    /// 正在输入的文字，按图层最终保存的样子渲染，仅在样式变化时重建。
    private var draftTextCache: (style: LayerTextStyle, image: CGImage)?
    /// 为正在编辑的文字渲染的效果，以及渲染时所依据的输入。
    private var draftEffects: (image: CGImage, effects: LayerEffects, transform: LayerTransform, rendered: CGImage, inset: CGFloat)?
    /// `draftEffects` 是为哪个图层和哪段文字准备的，以便编辑提交后可以临时顶上去。
    private var draftEffectsSource: (layerID: UUID, style: LayerTextStyle)?
    /// 正在输入的文字（以像素形式），编辑器在此处显示它（见 `InlineTextEditor`）。
    private var draftText: (image: CGImage, transform: LayerTransform)? {
        guard let draft = session.textDraft, let transform = inlineTextEditor?.shownTransform else { draftTextCache = nil; return nil }
        if draftTextCache?.style != draft.style {
            guard let image = try? EditorSession.textImage(draft.style) else { draftTextCache = nil; return nil }
            draftTextCache = (draft.style, image)
        }
        return draftTextCache.map { ($0.image, transform) }
    }
    var textBoxAnchor: CGPoint?
    var textBoxRect: CGRect?
    private var lastFocusRequest = 0
    func consumeFocusRequest(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            // 正在编辑的文字重新接收按键（例如从颜色选择器切回后），以便输入和 ⌘Return 仍能送达它。
            if self.session.textDraft == nil { window.makeFirstResponder(self) }
            else if let editor = self.inlineTextEditor { window.makeFirstResponder(editor.textView) }
        }
    }
    private let sampleRing = SampleRingOverlay()
    private let lines = CanvasLinesOverlay()
    private var samplingOriginal = PaletteColor.black
    let session: EditorSession
    private var spaceHeld = false
    private var panPhysicalKey: UInt16?
    private var brushPointer: CGPoint?
    /// 正在被绘制到 surface 上的图层，供 SeparableBlend 使用——它先正常绘制图层，之后再做混合。
    private var normalBlendLayerID: UUID?
    private func blendMode(of layer: ImageLayer) -> LayerBlendMode {
        layer.id == normalBlendLayerID ? .normal : session.displayedBlendMode(for: layer)
    }
    private let brushCursor = BrushCursorOverlay()
    private var lastDragPoint: CGPoint?
    /// 中键拖动上一次所在的位置（见 `otherMouseDown`）。
    private var middlePanPoint: CGPoint?
    /// Shift 在进行中的笔触上最后一次按下的位置（如果按下时已按住 Shift，则是笔触起点）：
    /// Shift 持续按住时，笔触被约束在这条直线上。
    private var brushAxisAnchor: CGPoint?
    /// 该直线沿哪条轴延伸，由 Shift 按下后笔触最初的移动方向决定。
    private var brushAxisHorizontal: Bool?
    /// 笔触上一次的位置，这样在笔触中段按下 Shift 时会从该处锁定，而不是从笔触起点。
    private var brushLastPixel: CGPoint?
    private var transformDrag: TransformDrag? {
        didSet { if transformDrag == nil { releaseDragCursor() } }
    }
    private var dragCursor: NSCursor?
    private weak var cursorLockWindow: NSWindow?
    private var cropDrag: CropDrag? {
        didSet { if cropDrag == nil { releaseDragCursor() } }
    }
    private var guideDragging = false {
        didSet { if !guideDragging { releaseDragCursor() } }
    }
    private let transformOverlay: TransformOverlay
    private var displayedState: DisplayState?
    private var displayedTool: NavigationTool?
    private var displayedPicking = false
    private var displayedTargeting = false
    private var optionHeld = false
    private var palettePicking: Bool { session.tool == .eyedropper || (optionHeld && (session.tool == .brush || session.tool == .spotHealing || session.tool == .gradient) && session.brushStroke == nil && gradientDrag == nil) }
    private var picking: Bool {
        palettePicking || (session.colorPicker != nil && !session.pickingForDialog) || session.hueSampleMode != nil || session.levels?.sampleMode != nil
            || session.colorRange != nil
            || session.filterEdit?.samplesWhiteBalance == true || session.filterEdit?.samplesPointColor == true
            || session.filterEdit?.samplesDefringe == true
            || session.filterEdit?.drawingCameraRawGeometryGuide == true
    }
    /// 目标调整拖动在视图坐标中的起始点。
    private var hueTargetStart: CGPoint?
    private var samplingColor = false
    private enum GradientHandle { case start, end }
    private var gradientDrag: GradientHandle?
    private var antsTimer: Timer?
    private var modifierMonitor: Any?
    private var sampleClickMonitor: Any?
    private var cursorUpdateMonitor: Any?
    /// 直接从事件流中取得的取样点击，这样它的拖动与松开也会顺延到此处。
    private var sampleClickActive = false
    private var keyMonitor: Any?
    /// 选区轮廓拖动在文档坐标中的起始点。
    private var selectionDragStart: CGPoint?
    /// 选中像素的 Cmd-拖动在文档坐标中的起始点。
    private var pixelDragStart: CGPoint?
    private var duplicatesTransformOnDrag = false
    /// 进行中的裁剪拖动的吸附信息，在拖动开始时构建（拖动过程中缩放不会改变）。
    private var cropSnap: CropSnap?
    /// 以屏幕点计，裁剪边距图层边或画布边多近时开始吸附。
    static let cropSnapDistance: CGFloat = 8
    /// Shift 是否能将 Marquee 草稿约束为正方形。按下时已按住 Shift（用于选择 Add 模式）期间为 false；
    /// 放开后即进入待命状态，再次按下 Shift 即可将形状约束为正方形。
    private var marqueeConstrainArmed = true
    /// Marquee 草稿的最新拖动点，这样 Shift 状态变化时无需鼠标移动也能重新塑形。
    private var marqueeDragPixel: CGPoint?
    /// Marquee 被拖到画布边缘或越过边缘时，将视图朝指针方向平移。
    private var marqueeAutoscroll: Timer?
    private var marqueeAutoscrollPoint: CGPoint?
    /// 箭头带剪刀：在此处 Cmd-拖动会剪切并移动选中的像素。
    /// 不可见的光标，用于工具自己在画布上绘制指针的情况。
    static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    static let movePixelsCursor: NSCursor = {
        let base = NSCursor.arrow
        let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Move pixels")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let glyph = CGRect(x: base.hotSpot.x + 9, y: base.hotSpot.y + 12, width: 11, height: 11)
            for step in 0..<12 {
                let angle = CGFloat(step) * .pi / 6
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.2, dy: sin(angle) * 1.2), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            black.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }()
    /// 指针箭头（作为矢量路径），箭尖在原点（y 朝下），尺寸接近系统箭头。
    private static let arrowPath: NSBezierPath = {
        let arrow = NSBezierPath()
        for (index, point) in [(0, 0), (0, 16.5), (3.9, 12.8), (6.6, 19), (9.2, 17.9), (6.6, 11.8), (11.8, 11.8)].enumerated() {
            let point = NSPoint(x: point.0, y: point.1)
            if index == 0 { arrow.move(to: point) } else { arrow.line(to: point) }
        }
        arrow.close()
        arrow.lineJoinStyle = .round
        arrow.lineWidth = 2.2 // 在填充下方描边，因此约显示 1 pt 的描边
        return arrow
    }()
    /// 由后往前绘制的形状，按系统光标的样式描边（每条路径的线宽即为描边宽度，在填充下方描边），带柔和阴影。坐标 y 朝下。
    private static func outlinedCursor(size: NSSize, hotSpot: NSPoint,
                                       _ shapes: [(path: NSBezierPath, fill: NSColor, outline: NSColor)]) -> NSCursor {
        let image = NSImage(size: size, flipped: true) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            for shape in shapes {
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                shape.outline.setStroke()
                shape.path.stroke()
                NSGraphicsContext.restoreGraphicsState()
                shape.fill.setFill()
                shape.path.fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }
    /// 由后往前绘制的箭头，每个箭头从 hot spot 出发向右下偏移。
    private static func arrowCursor(_ arrows: [(offset: CGFloat, fill: NSColor, outline: NSColor)]) -> NSCursor {
        let tip = NSPoint(x: 4, y: 3)
        return outlinedCursor(size: NSSize(width: 28, height: 32), hotSpot: tip, arrows.map { arrow in
            let path = arrowPath.copy() as! NSBezierPath
            path.transform(using: AffineTransform(translationByX: tip.x + arrow.offset, byY: tip.y + arrow.offset))
            return (path, arrow.fill, arrow.outline)
        })
    }
    /// Photoshop 的复制指针：黑色箭头叠加在后方偏移的白色箭头上。出现在拖动复制的场合——
    /// Option-拖动图层、Cmd-Option-拖动选中像素。
    static let duplicateCursor = arrowCursor([(offset: 5, fill: .white, outline: .black), (offset: 0, fill: .black, outline: .white)])
    /// 变换控制点上方的白色箭头，拖动时表示可扭曲（按住 Cmd，或已处于扭曲状态）。
    static let distortCursor = arrowCursor([(offset: 0, fill: .white, outline: .black)])
    /// Photoshop 的移动指针：箭头右下角带一个小四向箭头。在变换控制点之外的任何按压会拖动图层的位置显示它。
    static let moveCursor: NSCursor = {
        let base = NSCursor.arrow
        // 头部保持窄而分开，这样四个箭头在徽标尺寸下仍清晰可辨。
        let badge = fourArrowPath(center: NSPoint(x: base.hotSpot.x + 14.5, y: base.hotSpot.y + 17.5),
                                  reach: 6.5, shaft: 0.75, head: 2, headLength: 2.5)
        badge.lineWidth = 1.6 // 在填充下方描边，因此约显示 0.8 pt 的白色描边
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            NSColor.white.setStroke()
            badge.stroke()
            NSColor.black.setFill()
            badge.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }()

    /// 围绕 `center` 的四个箭头（y 朝下）：每个箭头沿杆身从中心延伸 `reach` 的距离，杆身半宽为 `shaft`，
    /// 末端为两侧各 `head` 宽、长 `headLength` 的箭头头部。
    private static func fourArrowPath(center: NSPoint, reach: CGFloat, shaft: CGFloat, head: CGFloat, headLength: CGFloat) -> NSBezierPath {
        // 顶部的箭头，从其左侧的杆身绕到箭头尖端，再到其右侧的杆身；每次旋转 90 度
        //（`(x, y) → (−y, x)`）就顺时针描出其余三个箭头。
        let arm: [(CGFloat, CGFloat)] = [(-shaft, -reach + headLength), (-head, -reach + headLength), (0, -reach),
                                         (head, -reach + headLength), (shaft, -reach + headLength), (shaft, -shaft)]
        let path = NSBezierPath()
        for turn in 0..<4 {
            for var point in arm {
                for _ in 0..<turn { point = (-point.1, point.0) }
                let location = NSPoint(x: center.x + point.0, y: center.y + point.1)
                if path.isEmpty { path.move(to: location) } else { path.line(to: location) }
            }
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
    /// 箭头带一个小虚线框：在此处拖动会移动选区轮廓。
    static let moveSelectionCursor = selectionBadged(.arrow, boxAt: CGPoint(x: 9.5, y: 13.5))
    /// 指形手光标带虚线框：Cmd-点击缩略图将其作为选区载入。
    static let loadSelectionCursor = selectionBadged(.pointingHand, boxAt: CGPoint(x: 11.5, y: 14.5))

    /// 给系统光标添加一个小虚线选区框，偏移位置相对于其 hot spot。
    static func selectionBadged(_ base: NSCursor, boxAt offset: CGPoint) -> NSCursor {
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let box = NSBezierPath(rect: NSRect(x: base.hotSpot.x + offset.x, y: base.hotSpot.y + offset.y, width: 8, height: 6))
            NSColor.white.setStroke()
            box.lineWidth = 2.5
            box.stroke()
            NSColor.black.setStroke()
            box.lineWidth = 1
            box.setLineDash([2, 1.5], count: 2, phase: 0)
            box.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: base.hotSpot)
    }
    /// 十字准星所指明的选区工具：工具栏中的图标，缩小显示，位于十字准星的右下方。
    enum SelectionIcon: CaseIterable { case freehandLasso, polygonalLasso, rectangleMarquee, ellipseMarquee, objectSelection }

    /// 十字准星带工具图标，并在图标旁附 "+"（添加）或 "−"（减去）标记，与 Photoshop 一致。
    static let selectionCursors: [SelectionIcon: [SelectionMode: NSCursor]] = Dictionary(uniqueKeysWithValues:
        SelectionIcon.allCases.map { icon in
            (icon, Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { ($0, selectionCursor(icon, mode: $0)) }))
        })

    private static func selectionCursor(_ icon: SelectionIcon, mode: SelectionMode) -> NSCursor {
        let base = NSCursor.crosshair
        let hotSpot = base.hotSpot
        let image = NSImage(size: NSSize(width: 44, height: 36), flipped: true) { _ in
            base.image.draw(in: NSRect(origin: .zero, size: base.image.size), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            let box = NSRect(x: hotSpot.x + 7, y: hotSpot.y + 7, width: 12, height: 12)
            drawSelectionIcon(icon, in: box)
            if mode != .replace {
                let center = CGPoint(x: box.maxX + 5, y: box.midY)
                let badge = NSBezierPath()
                // 与系统十字准星一样使用白边黑色描边和圆头。
                badge.move(to: CGPoint(x: center.x - 3, y: center.y))
                badge.line(to: CGPoint(x: center.x + 3, y: center.y))
                if mode == .add {
                    badge.move(to: CGPoint(x: center.x, y: center.y - 3))
                    badge.line(to: CGPoint(x: center.x, y: center.y + 3))
                }
                badge.lineCapStyle = .round
                NSColor.white.setStroke()
                badge.lineWidth = 3.2
                badge.stroke()
                NSColor.black.setStroke()
                badge.lineWidth = 1.2
                badge.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    /// 光标尺寸下工具栏图标的样式：黑色细线加白色描边，因此在任何图像上都清晰可读。
    private static func drawSelectionIcon(_ icon: SelectionIcon, in box: NSRect) {
        if icon == .polygonalLasso {
            // 沿用工具栏自己的绘制（见 `PolygonalLassoToolIcon`），使用其 18 单位的网格。
            let unit = box.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
            let path = NSBezierPath()
            for (corners, closed) in [([point(1.2, 7.0), point(4.0, 2.4), point(11.8, 1.8), point(16.8, 5.2), point(15.6, 10.4), point(7.0, 11.6)], true),
                                      ([point(8.9, 10.9), point(13.3, 10.5), point(11.6, 14.5)], true),
                                      ([point(11.6, 14.5), point(12.9, 17.3)], false)] {
                path.move(to: corners[0])
                for corner in corners.dropFirst() { path.line(to: corner) }
                if closed { path.close() }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 1.4 * unit + 2
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.4 * unit
            path.stroke()
            return
        }
        if icon == .objectSelection {
            let unit = box.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
            let corners = NSBezierPath()
            for part in [[point(2, 6), point(2, 2), point(6, 2)], [point(12, 2), point(16, 2), point(16, 6)],
                         [point(16, 12), point(16, 16), point(12, 16)], [point(6, 16), point(2, 16), point(2, 12)]] {
                corners.move(to: part[0]); corners.line(to: part[1]); corners.line(to: part[2])
            }
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            NSColor.white.setStroke()
            corners.lineWidth = 1.6 * unit + 2
            corners.stroke()
            NSColor.black.setStroke()
            corners.lineWidth = 1.6 * unit
            corners.stroke()
            let cursor = NSBezierPath()
            for (index, p) in [point(7, 5), point(7, 14), point(9.6, 11.7), point(11.3, 15.3),
                               point(13.2, 14.4), point(11.5, 10.9), point(14.5, 10.9)].enumerated() {
                index == 0 ? cursor.move(to: p) : cursor.line(to: p)
            }
            cursor.close()
            cursor.lineJoinStyle = .round
            NSColor.white.setStroke()
            cursor.lineWidth = 2
            cursor.stroke()
            NSColor.black.setFill()
            cursor.fill()
            return
        }
        let name = icon == .freehandLasso ? "lasso" : icon == .ellipseMarquee ? "circle.dashed" : "rectangle.dashed"
        let size = NSImage.SymbolConfiguration(pointSize: box.height, weight: .semibold)
        guard let white = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [.white]))),
              let black = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(size.applying(.init(paletteColors: [.black]))) else { return }
        // 符号保持其自身形状，适配到框内。
        let scale = min(box.width / black.size.width, box.height / black.size.height)
        let rect = NSRect(x: box.midX - black.size.width * scale / 2, y: box.midY - black.size.height * scale / 2,
                          width: black.size.width * scale, height: black.size.height * scale)
        for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7)] {
            white.draw(in: rect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        black.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    /// 魔棒，其星花位于 hot spot，并与其他选区工具一样带有 "+" / "−" 标记。
    static let wandCursors: [SelectionMode: NSCursor] = Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { mode in
        let hotSpot = NSPoint(x: 7, y: 7)
        let image = NSImage(size: NSSize(width: 34, height: 34), flipped: true) { _ in
            let stick = NSBezierPath()
            stick.move(to: CGPoint(x: hotSpot.x + 6, y: hotSpot.y + 6))
            stick.line(to: CGPoint(x: hotSpot.x + 20, y: hotSpot.y + 20))
            let marks = NSBezierPath()
            for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
                marks.move(to: CGPoint(x: hotSpot.x + dx * 2.5, y: hotSpot.y + dy * 2.5))
                marks.line(to: CGPoint(x: hotSpot.x + dx * 6, y: hotSpot.y + dy * 6))
            }
            if mode != .replace {
                let center = CGPoint(x: hotSpot.x + 17, y: hotSpot.y + 5)
                marks.move(to: CGPoint(x: center.x - 3, y: center.y))
                marks.line(to: CGPoint(x: center.x + 3, y: center.y))
                if mode == .add {
                    marks.move(to: CGPoint(x: center.x, y: center.y - 3))
                    marks.line(to: CGPoint(x: center.x, y: center.y + 3))
                }
            }
            for path in [stick, marks] { path.lineCapStyle = .round }
            // 先画白色描边，这样任一形状的描边都不会覆盖另一形状的黑色线条。
            NSColor.white.setStroke()
            stick.lineWidth = 5
            stick.stroke()
            marks.lineWidth = 3.2
            marks.stroke()
            NSColor.black.setStroke()
            stick.lineWidth = 2.4
            stick.stroke()
            marks.lineWidth = 1.2
            marks.stroke()
            return true
        }
        return (mode, NSCursor(image: image, hotSpot: hotSpot))
    })
    private var displayedCropRect: CGRect?
    private var displayedTransformGeometry: TransformOverlayGeometry?
    private var hoverTrackingArea: NSTrackingArea?
    private static let rotationCursor: NSCursor = {
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Rotate")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            // 先扩大白色轮廓，再在其上绘制黑色符号。
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            black.draw(in: glyph)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    private static let eyedropperCursor = makeEyedropperCursor(badge: nil)
    /// Color Range 的取色器：按住 Shift（添加）或 Option（去除）时显示，或已选择 + 或 − 模式时显示。
    private static let eyedropperAddCursor = makeEyedropperCursor(badge: "plus")
    private static let eyedropperRemoveCursor = makeEyedropperCursor(badge: "minus")
    private static func makeEyedropperCursor(badge: String?) -> NSCursor {
        let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Sample color")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let mark = badge.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .black).applying(.init(paletteColors: [.black])))
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            black.draw(in: glyph)
            // 标记位于右下角，远离滴管尖端：白底黑边圆盘上绘有黑色 + 或 −，因此在任何图像上都清晰可读。
            if let mark {
                let spot = CGRect(x: 12.5, y: 0.5, width: 11, height: 11)
                let disc = NSBezierPath(ovalIn: spot)
                NSColor.white.setFill(); disc.fill()
                NSColor.black.setStroke(); disc.lineWidth = 1; disc.stroke()
                let size = mark.size
                mark.draw(in: CGRect(x: spot.midX - size.width / 2, y: spot.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
        // 滴管尖端位于字形左下角。
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 21))
    }
    /// 当 Color Range 面板获得焦点时，任何重建本视图光标矩形的事件（新选区重绘、面板在点击后重新拿回焦点）
    /// 都会让箭头停留到指针移动为止。处理完之后将取色器放回原位。
    private func keepColorRangeCursor(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.session.colorRange != nil, self.pointerOverCanvas else { return }
            self.pickCursor.set()
        }
    }
    /// 指针位于画布自身之上，而非悬浮于其上的面板之上。
    private var pointerOverCanvas: Bool {
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
    }
    /// 当前应显示的取色器：Color Range 的取色器会指明点击是添加还是去除。
    private var pickCursor: NSCursor {
        switch session.colorRange?.effectiveMode {
        case .add: Self.eyedropperAddCursor
        case .remove: Self.eyedropperRemoveCursor
        default: Self.eyedropperCursor
        }
    }

    /// 缩放工具的光标：放大镜带加号，按住 Option 时变为减号。
    private static func zoomCursor(out: Bool) -> NSCursor {
        let symbol = NSImage(systemSymbolName: out ? "minus.magnifyingglass" : "plus.magnifyingglass",
                             accessibilityDescription: out ? "Zoom out" : "Zoom in")!
        let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let glyph = CGRect(x: 2, y: 2, width: 20, height: 20)
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                white.draw(in: glyph.offsetBy(dx: cos(angle) * 1.25, dy: sin(angle) * 1.25))
            }
            // 透镜填充为白色，因此光标在任何图像上都清晰可读。根据符号测量：透镜位于字形 41% 横、40% 纵处，
            // 内半径约为字形的 27%。
            let center = CGPoint(x: glyph.minX + glyph.width * 0.41, y: glyph.maxY - glyph.height * 0.40)
            let radius = glyph.width * 0.29
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            black.draw(in: glyph)
            return true
        }
        // 透镜中心，靠近字形左上角。
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
    private static let zoomInCursor = zoomCursor(out: false)
    private static let zoomOutCursor = zoomCursor(out: true)
    /// 缩放工具的按压：左右拖动会从起点开始平滑缩放；若按压后未移动，则在松开时缩放一级。
    private var zoomDrag: (start: CGPoint, zoom: CGFloat, moved: Bool)?

    private struct DisplayState: Equatable {
        struct Layer: Equatable {
            let id: UUID
            let transform: LayerTransform
            let imageID: ObjectIdentifier?
            let maskID: ObjectIdentifier?
            let maskSourceID: UUID?
            /// 将图层移入或移出带蒙版的文件夹，会改变其裁剪方式。
            let parentID: UUID?
            let visible: Bool
            let opacity: Double
            let blendMode: LayerBlendMode
            let adjustment: LayerAdjustment?
            let effects: LayerEffects?
            /// 蒙版与图层分离放置时的显示位置。
            let maskPlacement: LayerTransform?
        }
        let brushRevision: Int
        let pixelGrid: Bool
        let documentID: UUID?
        let size: CGSize?
        let renderBounds: CGRect?
        let viewport: CanvasViewport
        let layers: [Layer]
        /// 文件夹没有像素，因此其蒙版在 `layers` 之外单独追踪。
        struct FolderMask: Equatable {
            let id: UUID
            let maskID: ObjectIdentifier?
            let transform: LayerTransform
        }
        let folderMasks: [FolderMask]
        /// 正在输入的文字，画布将其绘制为像素。
        let textStyle: LayerTextStyle?
        let textTransform: LayerTransform?
        /// 单独显示的蒙版，可能是合成时不会绘制的那个（已禁用，或属于文件夹）。
        let maskAlone: ObjectIdentifier?
    }

    @discardableResult
    func synchronizeDisplay() -> Bool {
        // 笔触结束：其 surface 中持有的内容会临时顶替，直到图层自身的效果基于笔触留下的像素被重建完成，
        // 以免笔触末尾出现闪烁。
        if session.brushStroke == nil, let surface = strokeSurface {
            if let built = surface.image, let placement = surface.placement {
                session.effectsPreviews.seed(surface.layerID, image: built, placement: placement)
            }
            strokeSurface = nil
        }
        synchronizeInlineText()
        if session.tool != .type, textBoxRect != nil { textBoxAnchor = nil; textBoxRect = nil; needsDisplay = true }
        // 通过图像标识检测栅格替换，无需比较像素数据。
        let document = session.document
        let documentPresenceChanged = (displayedState?.documentID != nil) != (document != nil)
        // 文件夹不含像素，因此不列入下方；它们的不透明度通过内部的图层传递到画布，
        // 这才是需要监听变化的部分。
        let opacities = document?.effectiveOpacities ?? [:]
        // 一次性算出：每个查询都要遍历整个图层层级，在数百图层的情况下，
        // 每次事件都为每个图层重新计算代价过高。
        let visible = document?.effectiveVisibleIDs ?? []
        let state = DisplayState(brushRevision: session.brushRevision, pixelGrid: session.showsPixelGrid, documentID: document?.id, size: document?.size, renderBounds: renderBounds, viewport: session.viewport,
            layers: (document.map { $0.layers.contains(where: { $0.maskSourceID != nil }) ? $0.layers : $0.renderLayers } ?? []).filter { $0.asset != nil || $0.adjustment != nil }.map {
                DisplayState.Layer(id: $0.id, transform: session.displayedTransform(for: $0),
                                   imageID: $0.asset.map { ObjectIdentifier($0.image) }, maskID: $0.mask?.enabledImage.map { ObjectIdentifier($0) }, maskSourceID: $0.maskSourceID, parentID: $0.parentID, visible: visible.contains($0.id), opacity: opacities[$0.id] ?? $0.opacity, blendMode: session.displayedBlendMode(for: $0), adjustment: $0.adjustment, effects: $0.effects,
                                   maskPlacement: session.displayedMaskPlacement(for: $0))
            },
            folderMasks: (document?.layers ?? []).filter { $0.isGroup && $0.mask != nil }.map {
                DisplayState.FolderMask(id: $0.id, maskID: $0.mask?.enabledImage.map { ObjectIdentifier($0) },
                                        transform: session.displayedTransform(for: $0))
            }, textStyle: session.textDraft?.style, textTransform: session.textDraft == nil ? nil : inlineTextEditor?.shownTransform,
            maskAlone: session.maskAloneLayer?.mask.map { ObjectIdentifier($0.asset.image) })
        var changed = false
        if displayedState != state {
            if let previous = displayedState, previous.documentID == state.documentID,
               previous.size == state.size, previous.viewport == state.viewport,
               previous.renderBounds == state.renderBounds, previous.layers == state.layers,
               previous.folderMasks == state.folderMasks,
               let stroke = session.brushStroke, let document,
               let dirty = stroke.dirtyDocumentRect {
                let origin = session.viewport.viewPoint(from: dirty.origin, documentSize: document.size)
                let scale = session.viewport.pointsPerPixel
                setNeedsDisplay(CGRect(origin: origin, size: CGSize(width: dirty.width * scale, height: dirty.height * scale)).insetBy(dx: -2, dy: -2))
            } else { needsDisplay = true }
            displayedState = state
            changed = true
        }
        if documentPresenceChanged {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if displayedTool != session.tool {
            displayedTool = session.tool
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if displayedPicking != picking || displayedTargeting != session.hueTargeting {
            displayedPicking = picking
            displayedTargeting = session.hueTargeting
            samplingColor = false
            sampleRing.isHidden = true
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            // 光标矩形仅在指针进入时才生效，因此在取样开始或结束时，
            // 在此处更新已有文档的光标。空白画布则保持表单自身的光标不动。
            if session.document != nil, let window,
               bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                if picking { pickCursor.set() } else { restoreToolCursor() }
            }
            // Color Range 面板在打开稍后才出现并获得焦点。
            if session.colorRange != nil { keepColorRangeCursor(); keepColorRangeCursor(after: 0.15) }
        }
        if displayedCropRect != transformOverlay.cropViewRect {
            displayedCropRect = transformOverlay.cropViewRect
            window?.invalidateCursorRects(for: self)
        }
        if displayedTransformGeometry != transformOverlay.geometry {
            displayedTransformGeometry = transformOverlay.geometry
            window?.invalidateCursorRects(for: self)
        }
        updateBrushCursor()
        updateAntsTimer()
        // 仅出于轻量级控制点叠加层的目的观察选区。
        _ = session.activeLayerID
        _ = session.cropRect
        transformOverlay.needsDisplay = true
        redrawRulers()
        return changed
    }

    private func redrawRulers() {
        func find(_ view: NSView) {
            if view is CanvasRulerNSView { view.needsDisplay = true }
            view.subviews.forEach(find)
        }
        window?.contentView.map(find)
    }

    init(session: EditorSession) {
        self.session = session
        transformOverlay = TransformOverlay(session: session)
        super.init(frame: .zero)
        session.refreshCanvasPreview = { [weak self] in
            self?.synchronizeDisplay()
            self?.displayIfNeeded()
        }
        addSubview(lines)
        addSubview(transformOverlay)
        addSubview(brushCursor)
        addSubview(sampleRing)
        // 每个叠加层都绘制到各自的 layer 上。没有 layer 的话，重绘一个透明叠加层（每次裁剪或变换拖动、
        // 蚂蚁线跳动或光标移动）都会让 AppKit 重新绘制下面的画布——也就是整个棋盘格和图层合成结果。
        // 这三者都使用 layer 以保持叠加顺序。
        for overlay in [lines, transformOverlay, brushCursor, sampleRing] as [NSView] { overlay.wantsLayer = true }
        lines.autoresizingMask = [.width, .height]
        lines.drawLines = { [weak self] dirtyRect in self?.drawLines(in: dirtyRect) }
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.string("Canvas"))
        setAccessibilityIdentifier("editorCanvas")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        transformOverlay.frame = bounds
        brushCursor.frame = bounds
        syncGeometry()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncGeometry()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let sampleClickMonitor { NSEvent.removeMonitor(sampleClickMonitor); self.sampleClickMonitor = nil }
        if let cursorUpdateMonitor { NSEvent.removeMonitor(cursorUpdateMonitor); self.cursorUpdateMonitor = nil }
        guard window != nil else { return }
        // 为打开的面板（颜色选择器、色阶、滤镜）对画布进行取样时，在窗口看到点击事件之前先在此处处理：
        // 点击会让本窗口成为 key window，面板会失去焦点并伴随阴影淡出，直到松开鼠标焦点才回来。
        // 当 Color Range 面板获得焦点时，AppKit 在 Shift 或 Option 变化后发送的 cursor-update 事件
        // 会到达一个返回箭头光标的视图。在画布上时，应在此处改为回应取色器。
        cursorUpdateMonitor = NSEvent.addLocalMonitorForEvents(matching: .cursorUpdate) { [weak self] event in
            guard let self, self.session.colorRange != nil, self.pointerOverCanvas else { return event }
            self.pickCursor.set()
            return nil
        }
        sampleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                guard self.picking, !window.isKeyWindow, NSApp.keyWindow is NSPanel,
                      let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: self) else { return event }
                self.sampleClickActive = true
                self.mouseDown(with: event)
            case .leftMouseDragged:
                guard self.sampleClickActive else { return event }
                self.mouseDragged(with: event)
            default:
                guard self.sampleClickActive else { return event }
                self.sampleClickActive = false
                self.mouseUp(with: event)
            }
            return nil
        }
        optionHeld = NSEvent.modifierFlags.contains(.option)
        // 新建标签页会挂载一个新画布。等 SwiftUI 完成安装后恢复键盘焦点，
        // 同时不要抢占新弹出对话框的焦点。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.document != nil, let window = self.window,
                  window.attachedSheet == nil, !self.session.showsNewDocument,
                  !self.session.showsImporter, self.session.colorPicker == nil else { return }
            window.makeFirstResponder(self)
        }
        // 修饰键的变化只会传给第一响应者；在全局监听它们，
        // 这样即使其他控件持有键盘焦点，套索标记也会更新。
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.optionHeld = event.modifierFlags.contains(.option)
            // Color Range：Shift 添加、Option 去除，按住时分别显示在取色器及其面板上。
            if let edit = self.session.colorRange {
                let flags = event.modifierFlags
                let held: HueSampleMode? = flags.contains(.option) ? .remove : flags.contains(.shift) ? .add : nil
                if edit.held != held {
                    edit.held = held
                    // 立刻设置一次，等 AppKit 处理完按键变化后再设置一次，以防期间有其他代码把光标改成箭头。
                    if self.pointerOverCanvas { self.pickCursor.set() }
                    self.keepColorRangeCursor()
                }
            }
            // Marquee 拖动过程中 Shift 按下或松开时立即重塑形状，不必等待鼠标移动。
            if let pixel = self.marqueeDragPixel, let kind = self.session.lassoDraft?.kind, kind == .rectangle || kind == .ellipse {
                self.dragMarqueeDraft(to: pixel, flags: event.modifierFlags)
            }
            // 裁剪拖动也同理：Option（对称）或 Control（不吸附）变化时立即响应。
            if let drag = self.cropDrag, self.session.tool == .crop, let document = self.session.document, let window = self.window {
                self.dragCrop(drag, to: self.convert(window.mouseLocationOutsideOfEventStream, from: nil),
                              flags: event.modifierFlags, documentSize: document.size)
            }
            self.synchronizeDisplay()
            self.updateBrushCursor()
            // 仅在指针位于画布上时才这样做：若指针在其他位置（图层面板、按住 Option 创建剪贴蒙版）
            // 时重建光标矩形，会夺走该视图的光标。
            // Color Range 打开期间不重建：其取色器已覆盖整个画布，且面板获得焦点时重建会让箭头短暂显示
            // 一下再切回取色器。
            if self.session.document != nil, self.session.colorRange == nil, let window = self.window,
               self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                self.window?.invalidateCursorRects(for: self)
            }
            self.session.updateHeldSelectionKeys(shift: event.modifierFlags.contains(.shift),
                                                 option: event.modifierFlags.contains(.option))
            if self.session.tool.isSelectionTool { self.refreshLassoCursor(event.modifierFlags) }
            if self.session.document != nil, self.session.tool == .move, let window = self.window {
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.visibleRect.contains(point) { self.updateTransformCursor(at: point, flags: event.modifierFlags) }
            }
            return event
        }
        // 全窗口生效的快捷键——在画布、图层面板、顶部控件、工具栏等任意焦点位置都能用，
        // 但在文本框中输入时除外。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let originalEvent = event
            guard let event = ShortcutSettings.shared.canvasEvent(event) else { return originalEvent }
            guard let self, let window = self.window, event.windowNumber == window.windowNumber,
                  !(window.firstResponder is NSText) else { return originalEvent }
            if self.handleKeyboardZoom(event) { return nil }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers else { return originalEvent }
            // Shift-+ / Shift-− 在任何工具中都会切换当前图层的混合模式。
            if event.modifierFlags.contains(.shift), key == "+" || key == "_" || event.keyCode == 24 || event.keyCode == 27 {
                self.session.cycleBlendMode(forward: key == "+" || event.keyCode == 24)
                return nil
            }
            // 笔刷尺寸（[ ]）与硬度（Shift-[ ]）；画布自身取得焦点时由其 keyDown 处理。
            guard (self.session.tool.isBrushTool), self.session.levels == nil, window.firstResponder !== self,
                  ["[", "]", "{", "}"].contains(key) else { return originalEvent }
            if key == "[" || key == "]" { self.session.changeBrushSize(increase: key == "]") }
            else { self.session.changeBrushHardness(increase: key == "}") }
            return nil
        }
    }

    /// 在 keyDown 时处理默认的缩放快捷键（包括按键重复），无需等待菜单命令。
    private func handleKeyboardZoom(_ event: NSEvent) -> Bool {
        guard session.document != nil, event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }

        let zoomInIsDefault = ShortcutDefinition.all.first(where: { $0.isMenu && $0.title == "Zoom In" })
            .map { ShortcutSettings.shared.chord($0) == $0.original } ?? true
        let zoomOutIsDefault = ShortcutDefinition.all.first(where: { $0.isMenu && $0.title == "Zoom Out" })
            .map { ShortcutSettings.shared.chord($0) == $0.original } ?? true

        // 在 Mac 键盘上，'+' 即 Shift+'='；数字小键盘有各自的键码。
        let isZoomIn = [24, 69].contains(event.keyCode)
        let isZoomOut = [27, 78].contains(event.keyCode) && !event.modifierFlags.contains(.shift)
        guard (isZoomIn && zoomInIsDefault) || (isZoomOut && zoomOutIsDefault) else { return false }

        session.zoomKeyboard(by: isZoomIn ? 1 : -1)
        synchronizeDisplay()
        return true
    }

    private var lassoCursor: NSCursor { lassoCursor(flags: NSEvent.modifierFlags) }

    /// 在选区上的 New 模式下显示移动光标；否则显示带标记的十字准星。
    /// 在选区上，Cmd 显示剪刀（剪切并移动像素），Cmd-Option 显示复制光标。
    /// 若事件提供了指针位置，`location` 即为视图坐标中的指针。
    private func lassoCursor(flags: NSEvent.ModifierFlags, at location: CGPoint? = nil) -> NSCursor {
        let mode = session.lassoCursorMode(shift: flags.contains(.shift), option: flags.contains(.option))
        if selectionDragStart != nil { return Self.moveSelectionCursor }
        if pixelDragStart != nil { return pixelDragCursor(duplicate: session.pixelMove?.duplicate == true) }
        if flags.contains(.command) || mode == .replace, let document = session.document,
           let point = location ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }),
           session.canMoveSelection(at: session.viewport.documentPoint(from: point, documentSize: document.size)) {
            return flags.contains(.command) ? pixelDragCursor(duplicate: flags.contains(.option)) : Self.moveSelectionCursor
        }
        if session.tool == .wand, session.wandMode == .wand { return Self.wandCursors[mode] ?? .crosshair }
        let icon: SelectionIcon = session.tool == .wand ? .objectSelection : session.tool == .marquee
            ? (session.marqueeKind == .ellipse ? .ellipseMarquee : .rectangleMarquee)
            : (session.lassoKind == .polygonal ? .polygonalLasso : .freehandLasso)
        return Self.selectionCursors[icon]?[mode] ?? .crosshair
    }

    /// Cmd-拖动选区会剪切并移动其像素（剪刀）；按住 Option 则复制它们。
    private func pixelDragCursor(duplicate: Bool) -> NSCursor { duplicate ? Self.duplicateCursor : Self.movePixelsCursor }

    /// 若指针位于画布上，立即重新设置套索光标。
    private func refreshLassoCursor(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard session.document != nil else { return }
        window?.invalidateCursorRects(for: self)
        guard session.tool.isSelectionTool, !spaceHeld, !picking, let window,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        lassoCursor(flags: flags).set()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncGeometry() }

    private func syncGeometry() {
        // 将可观察的变更延后到 SwiftUI 的 layout pass 之后执行。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scale = self.convertToBacking(CGSize(width: 1, height: 1)).width
            guard self.session.viewport.viewSize != self.bounds.size ||
                    self.session.viewport.backingScale != scale else { return }
            self.session.viewport.resize(to: self.bounds.size, backingScale: scale,
                                         documentSize: self.session.document?.size)
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 网格和正在拖动的文字框跟随其下方的像素。
        if lines.frame != bounds { lines.frame = bounds }
        lines.needsDisplay = true
        if drawOnGPU(dirtyRect) { return }
        NSColor(white: 0.105, alpha: 1).setFill()
        dirtyRect.fill()
        guard let document = session.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let pixels = renderBounds ?? CGRect(origin: .zero, size: document.size)
        let rect = CGRect(origin: session.viewport.viewPoint(from: pixels.origin, documentSize: document.size),
                          size: CGSize(width: pixels.width * session.viewport.pointsPerPixel,
                                       height: pixels.height * session.viewport.pointsPerPixel))
        guard rect.intersects(bounds), rect.intersects(dirtyRect) else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 14,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor(white: 0.26, alpha: 1).cgColor)
        context.fill(rect)
        context.restoreGState()
        context.saveGState()
        context.clip(to: rect.intersection(dirtyRect))
        context.setFillColor(NSColor(white: 0.30, alpha: 1).cgColor)
        context.fill(rect)
        // 工作量随可见视口而非文档尺寸变化。
        let tile: CGFloat = 10
        let visible = rect.intersection(bounds).intersection(dirtyRect)
        if !visible.isNull, !visible.isEmpty {
            let minX = Int(floor((visible.minX - rect.minX) / tile))
            let maxX = Int(ceil((visible.maxX - rect.minX) / tile))
            let minY = Int(floor((visible.minY - rect.minY) / tile))
            let maxY = Int(ceil((visible.maxY - rect.minY) / tile))
            context.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor)
            for row in minY..<maxY {
                for column in minX..<maxX where (row + column).isMultiple(of: 2) {
                    context.fill(CGRect(x: rect.minX + CGFloat(column) * tile,
                                        y: rect.minY + CGFloat(row) * tile, width: tile, height: tile))
                }
            }
        }
        if session.viewport.zoom >= Self.crispZoom, !visible.isNull, !visible.isEmpty {
            drawDocumentPixels(covering: visible, clippedTo: pixels, document: document, in: context)
        } else {
            // 将原生分辨率的素材绘制在与导航相同的文档/视图映射中。
            // AppKit 视图是翻转的；在本地翻转每张图像，使其顶部始终保持在上。
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawLayers(document, scale: session.viewport.pointsPerPixel,
                       center: { self.session.viewport.viewPoint(from: $0, documentSize: document.size) }, in: context)
            context.endTransparencyLayer()
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        context.setLineWidth(1 / session.viewport.backingScale)
        context.stroke(rect)
    }

    /// 从 200%（每个文档像素对应 2 个屏幕像素）起，画布显示硬边的文档像素，与 Photoshop 一致；像素网格从 800% 起显示。
    static let crispZoom: CGFloat = 2
    static let pixelGridZoom: CGFloat = 8

    /// 图层图像的副本，尺寸按其在 `context`（`drawnWidth` 以 context 单位计）中的最终大小调整，
    /// 取自共享的清晰缩减缓存。Core Graphics 每次绘制都会重采样整个源图像——一个 4000 px 的图层
    /// 每帧约耗 24 ms，即便只有一小块区域脏了也不例外——并且在大比例缩小时还会模糊。
    private func displayImage(_ image: CGImage, width drawnWidth: CGFloat, in context: CGContext) -> CGImage {
        DownsampleCache.shared.image(image, drawnAt: drawnWidth * LayerRenderer.deviceScale(of: context) / CGFloat(max(1, image.width)))
    }

    /// Option-点击后 Photoshop 显示的蒙版样式：覆盖整个画布的灰度图，白色显示、黑色隐藏，
    /// 并显示目前笔触已绘制到蒙版中的内容。超出蒙版像素范围的部分显示为蒙版的边缘色调。
    private func drawMaskAlone(_ mask: LayerMask, of layer: ImageLayer, document: CanvasDocument, scale: CGFloat,
                               center: (CGPoint) -> CGPoint, in context: CGContext) {
        let origin = center(.zero)
        context.setFillColor(gray: LayerMask.background(of: mask.asset.thumbnail), alpha: 1)
        context.fill(CGRect(x: origin.x, y: origin.y, width: document.size.width * scale, height: document.size.height * scale))
        if let stroke = session.brushStroke ?? session.gradientEdit?.raster, stroke.isMask, stroke.layer.id == layer.id {
            let placed = stroke.paintTransform
            LayerRenderer.drawBrushPreview(mask.asset.image, transform: placed, center: center(placed.center), scale: scale,
                opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches, pixelWidth: stroke.width,
                pixelHeight: stroke.height, paintingMask: false, sourceRect: stroke.sourceRect, in: context)
            return
        }
        // 拖动变换时蒙版的显示位置，与合成时一致。
        let placed = session.displayedMaskPlacement(for: layer) ?? session.displayedTransform(for: layer)
        LayerRenderer.draw(mask.asset.image, transform: placed, center: center(placed.center), scale: scale, in: context)
    }

    private func drawLayers(_ document: CanvasDocument, scale: CGFloat, center: @escaping (CGPoint) -> CGPoint, in context: CGContext, onSurface: Bool = false) {
        // 正在移动的像素或渐变：下方绘制的瓦片只有在被读取时才会跟随拖动（见 `PixelMove` 与 `GradientEdit`）。
        if let move = session.pixelMove {
            do { try move.applyOffset() } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.session.cancelPixelMove()
                    self?.session.brushError = message
                }
            }
        }
        if let gradient = session.gradientEdit {
            do { try gradient.applyFill() } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.session.cancelGradient()
                    self?.session.brushError = message
                }
            }
        }
        if let layer = session.maskAloneLayer, let mask = layer.mask {
            drawMaskAlone(mask, of: layer, document: document, scale: scale, center: center, in: context)
            return
        }
        handOffTextEffects(document)
        session.effectsPreviews.prepare(layers: document.layers)
        // Color Burn 与 Color Dodge 需要手动将其与下方的像素进行混合，这就需要一个 surface 来回读像素（见 `SeparableBlend`）。
        if !onSurface, document.layers.contains(where: { $0.adjustment != nil
            || SeparableBlend.needsSurface(session.displayedBlendMode(for: $0)) }) {
            let visible = document.effectiveVisibleIDs
            let padding = document.layers.filter { visible.contains($0.id) }
                .compactMap(\.adjustment).map(\.samplingMargin).max() ?? 0
            AdjustmentSurface.draw(in: context, padding: padding * scale) {
                self.drawLayers(document, scale: scale, center: center, in: $0, onSurface: true)
            }
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        func drawOwn(_ id: UUID, _ context: CGContext) {
            guard let layer = byID[id] else { return }
            // 正在编辑的文字按提交后的样子绘制，位置就在各图层之中。
            if layer.id == session.textDraft?.layerID {
                guard let shown = editedText(layer) else { return }
                LayerRenderer.draw(shown.image, transform: shown.transform, center: center(shown.transform.center), scale: scale,
                    opacity: layer.effectiveOpacity(in: byID), blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            // 图层所在的文件夹会按其不透明度一并作用于该图层及内部所有图层（见 `LayerOpacity`）。
            let opacity = layer.effectiveOpacity(in: byID)
            let mode = session.displayedBlendMode(for: layer)
            if SeparableBlend.needsSurface(mode), normalBlendLayerID != id {
                normalBlendLayerID = id
                defer { normalBlendLayerID = nil }
                if SeparableBlend.draw(mode, in: context, body: { drawOwn(id, $0) }) { return }
            }
            let stroke = session.brushStroke?.layer.id == layer.id ? session.brushStroke
                : session.gradientEdit?.raster.layer.id == layer.id ? session.gradientEdit?.raster
                : session.pixelMove?.raster.layer.id == layer.id ? session.pixelMove?.raster : nil
            // 空图层无内容可绘，除非滤镜（如 Vignette）正在其上预览像素。
            guard layer.asset != nil || stroke != nil || session.filterEdit?.previewImage(for: layer.id) != nil else { return }
            // 涂抹或液化进行中：图层按笔触到目前为止的形变，铺满整块画布。
            if let warp = session.warpStroke, warp.layer.id == layer.id, let image = warp.image {
                let canvas = LayerTransform(origin: .zero, size: document.size)
                let mask = layer.mask?.clipImage(placement: layer.maskTransform, over: canvas, width: warp.width, height: warp.height, limit: 2048)
                LayerRenderer.draw(image, transform: canvas, center: center(canvas.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: mask, in: context)
                return
            }
            // 待定的变形会把图层扭曲成新形状——它的图层样式也跟着一起扭曲，
            // 因此拖动角点时样式始终还在。
            // 只在拖动角点期间请求：这个请求会在预览缓存里顶替该图层的正常样式，
            // 若每次重绘都发一次，就会一直占着本该给下面那个正常样式的位置。
            if stroke == nil, layer.effects?.visible.isEmpty == false,
               let edit = session.transformEdit, !edit.mask, edit.corners != nil,
               let effects = session.effectsPreviews.preview(for: layer,
                    // 独立放置的蒙版，在图层绘制时被重采样到图层的网格中。
                    mask: layer.mask?.clipImage(placement: session.displayedMaskPlacement(for: layer), over: layer.transform,
                        width: layer.asset?.image.width ?? Int(layer.size.width.rounded()),
                        height: layer.asset?.image.height ?? Int(layer.size.height.rounded()), limit: 2048),
                    transform: layer.transform, maskPlacement: session.displayedMaskPlacement(for: layer),
                    completion: { [weak self] in self?.needsDisplay = true }),
               let warped = session.distortedEffects(for: layer, effects: effects.image, inset: effects.inset) {
                LayerRenderer.draw(warped.image, transform: warped.transform, center: center(warped.transform.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            if stroke == nil, let distorted = session.distortPreview(for: layer) {
                LayerRenderer.draw(distorted.image, transform: distorted.transform, center: center(distorted.transform.center),
                    scale: scale, opacity: opacity, blendMode: blendMode(of: layer),
                    mask: distorted.mask, in: context)
                return
            }
            // 蒙版笔触在蒙版自身的网格上绘制；图层本身保持不动。
            // 独立放置的蒙版在自身的网格上绘制，并在图层所在位置绘制图层；其他笔触的网格
            // 若超出图层，则在超出区域继续绘制笔触内容。
            let transform = (stroke?.isMask == true && stroke?.layer.mask?.placement != nil ? nil : stroke?.paintTransform)
                ?? session.displayedTransform(for: layer)
            // 与图层分离放置的蒙版，会被重采样到图层绘制所用的网格中（移动过程中最多 2048 像素，
            // 其他情况下约为绘制尺寸）。
            let mask: CGImage? = {
                guard let owned = layer.mask else { return nil }
                if let distorted = session.maskDistortPreview(for: layer) { return distorted }
                guard let placement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
                let owner = stroke?.layer ?? layer
                let base = stroke == nil ? transform : owner.transform
                let drawn = max(base.size.width, base.size.height) * scale * LayerRenderer.deviceScale(of: context)
                let steady = pow(2, ceil(log2(max(64, drawn))))
                return owned.clipImage(placement: placement, over: base,
                    width: owner.asset?.image.width ?? Int(base.size.width.rounded()),
                    height: owner.asset?.image.height ?? Int(base.size.height.rounded()),
                    limit: session.transformEdit != nil ? min(2048, steady) : steady)
            }()
            // 笔触或投影围绕图层像素绘制，画布会扩展到足以容纳它。
            if stroke == nil, layer.asset != nil,
               let effects = session.effectsPreviews.preview(for: layer, mask: mask, transform: transform,
                    maskPlacement: session.displayedMaskPlacement(for: layer), completion: { [weak self] in
                        self?.needsDisplay = true
                    }) {
                // 播种的预览会自带其所属位置；其他情况则为图层框加上其外边距。
                let grown = effects.placement ?? LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
                LayerRenderer.draw(effects.image, transform: grown, center: center(grown.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                return
            }
            if stroke == nil, let shaped = session.shapeTransformPreview(for: layer, transform: transform) {
                LayerRenderer.draw(shaped, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), mask: mask, in: context)
            } else if let stroke, !stroke.isMask {
                // 效果跟随绘制：一个保持全分辨率的 surface，仅在笔刷刚扫过的区域重做（见 `LayerEffectsSurface`）。
                // 它已持有湿润像素及其上的效果——颜色叠加和内阴影位于图层之上，
                // 再在其上绘制一遍绘制内容会盖住它们——因此本图层不再绘制其他内容。
                if let surface = strokeSurface(layer: layer, stroke: stroke, mask: mask), let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    LayerRenderer.draw(built, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                    return
                }
                if let effects = session.effectsPreviews.rendered(layer.id) {
                    let grown = effects.placement
                        ?? LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                    LayerRenderer.draw(effects.image, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                }
                // 像素预览与最终图层完全一致，使用图层自身的采样，
                // 这样笔触起止时不会出现位置偏移（见 `TiledLayerRenderer`）。
                let previous = stroke.layer.asset
                TiledLayerRenderer.drawStroke(width: stroke.width, height: stroke.height, sourceRect: stroke.sourceRect,
                    patches: stroke.patches, image: previous?.raster == nil ? previous?.image : nil, raster: previous?.raster,
                    transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            } else if let stroke, let placement = stroke.layer.mask?.placement {
                // 独立放置的蒙版在其自身网格上绘制：图层通过笔触留下的蒙版显示，
                // 该蒙版被重采样到图层的网格。
                let preview = stroke.placedMaskPreview(placement: stroke.paintTransform)
                // 开启图层样式后，会随蒙版变化一并重做，取自蒙版即将完成的状态。
                if let preview, let surface = placedMaskSurface(layer: layer, stroke: stroke, placement: placement, preview: preview),
                   let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    LayerRenderer.draw(built, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                    return
                }
                if let raster = stroke.layer.asset?.raster {
                    TiledLayerRenderer.drawRaster(raster, transform: transform, center: center(transform.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: preview, in: context)
                } else if let image = stroke.layer.asset?.image {
                    LayerRenderer.draw(image, transform: transform, center: center(transform.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: preview, in: context)
                }
            } else if let stroke {
                // 启用效果时，surface 会随蒙版变化而重做效果，使其在绘制过程中始终保持显示。
                if let surface = strokeSurface(layer: layer, stroke: stroke, mask: nil), let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    LayerRenderer.draw(built, transform: grown, center: center(grown.center), scale: scale,
                        opacity: opacity, blendMode: blendMode(of: layer), mask: nil, in: context)
                    return
                }
                // 绘制蒙版时，按提交后图层透过蒙版显示的效果进行预览，与上面一致。
                let previous = stroke.layer.asset
                TiledLayerRenderer.drawMaskStroke(width: stroke.width, height: stroke.height, sourceRect: stroke.sourceRect,
                    patches: stroke.patches, oldMask: stroke.layer.mask?.asset,
                    image: previous?.raster == nil ? previous?.image : nil, raster: previous?.raster,
                    transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer), in: context)
            } else if let asset = layer.asset, let raster = asset.raster, session.hueSaturation?.previewImage(for: layer.id) == nil && session.levels?.previewImage(for: layer.id) == nil && session.filterEdit?.previewImage(for: layer.id) == nil {
                TiledLayerRenderer.drawRaster(raster, transform: transform, center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            } else if let image = session.filterEdit?.previewImage(for: layer.id) ?? session.levels?.previewImage(for: layer.id) ?? session.hueSaturation?.previewImage(for: layer.id) ?? layer.asset?.image {
                // LayerRenderer 会自行选择图像及其蒙版的清晰缩减版本。
                LayerRenderer.draw(image, transform: transform,
                    center: center(transform.center), scale: scale,
                    opacity: opacity, blendMode: blendMode(of: layer),
                    mask: mask, in: context)
            }
        }
        // 正在拖出的形状预览其图层将放置的位置——位于当前图层之上——而非覆盖所有内容，
        // 这样上方的图层在形状创建后会按预期盖住它。
        func drawOwnWithDraft(_ id: UUID, _ context: CGContext) {
            drawOwn(id, context)
            guard id == session.activeLayerID else { return }
            drawShapeDraft(scale: scale, center: center, in: context)
            drawNewText(context)
        }
        // 新文字放在其图层将位于的位置：当前图层正上方，或在该图层未绘制时（文件夹、隐藏图层或无图层）置于最上层。
        var drewNewText = false
        func drawNewText(_ context: CGContext) {
            guard !drewNewText, session.textDraft?.layerID == nil, let text = draftText else { return }
            drewNewText = true
            LayerRenderer.draw(text.image, transform: text.transform, center: center(text.transform.center), scale: scale, in: context)
        }
        let live = LiveMaskRenderer(bounds: context.boundingBoxOfClipPath, source: { byID[$0]?.maskSourceID }, drawOwn: drawOwnWithDraft)
        live.adjustment = { byID[$0]?.adjustment }
        live.adjustmentOpacity = { byID[$0]?.effectiveOpacity(in: byID) ?? 1 }
        // 调整作用于 surface 的像素，每屏幕像素对应一次（见 `AdjustmentSurface`）。
        live.adjustmentScale = scale * LayerRenderer.deviceScale(of: context)
        live.resolution = LayerRenderer.deviceScale(of: context)
        let corner = center(.zero)
        live.adjustmentRegion = { rect in
            CGRect(x: (rect.minX - corner.x) / scale, y: (rect.minY - corner.y) / scale, width: rect.width / scale, height: rect.height / scale)
        }
        let area = context.boundingBoxOfClipPath
        live.adjustmentClip = { [weak self] id, ctx in
            guard let self, let layer = byID[id], layer.mask?.isEnabled == true else { return }
            // 笔触进行中时，蒙版仅以编辑的瓦片形式存在，因此调整按这些瓦片进行裁剪，
            // 与文件夹蒙版的处理方式相同——否则笔触要等到提交后才会显示。
            if let edit = self.liveMaskEdit(for: id),
               let clip = self.liveFolderMaskClip(edit, area: area, scale: scale, center: center, in: ctx) {
                clip(ctx)
                return
            }
            if let image = layer.mask?.enabledImage {
                FolderMaskClip(image: image, transform: layer.transform).apply(scale: scale, center: center(layer.transform.center), in: ctx)
            }
        }
        live.prepareStacks(document.renderLayers.map(\.id), parent: { byID[$0]?.parentID }, blend: { byID[$0].map { session.displayedBlendMode(for: $0) } ?? .normal })
        FolderMaskClip.draw(document.renderLayers.map(\.id), parent: { byID[$0]?.parentID }, clip: { id in
            guard let folder = byID[id], let mask = folder.mask, mask.isEnabled else { return nil }
            if let edit = liveMaskEdit(for: folder.id),
               let clip = liveFolderMaskClip(edit, area: area, scale: scale, center: center, in: context) {
                return clip
            }
            let transform = session.displayedTransform(for: folder)
            let clip = FolderMaskClip(image: displayImage(mask.asset.image, width: transform.size.width * scale, in: context), transform: transform)
            let origin = center(transform.center)
            return { clip.apply(scale: scale, center: origin, in: $0) }
        }, in: context) { live.drawComposite($0, in: context) }
        drawNewText(context)
    }

    /// 正在编辑的文字在图层间的显示方式：按提交后的样子，连同其周围的效果一起显示。
    /// 编辑期间效果保持显示，根据实时输入的文字重做；在新效果完成重做之前，
    /// 上一次的效果会临时顶在新文字之下，不会闪烁消失。
    private func editedText(_ layer: ImageLayer) -> (image: CGImage, transform: LayerTransform)? {
        guard let text = draftText else { return nil }
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else { return text }
        // 仅在文字像素、位置或效果发生变化时才重做。
        if draftEffects?.image !== text.image || draftEffects?.effects != effects || draftEffects?.transform != text.transform {
            let mask = layer.mask.flatMap { owned -> CGImage? in
                guard let placement = owned.placement else { return owned.enabledImage }
                return owned.clipImage(placement: placement, over: text.transform,
                                       width: text.image.width, height: text.image.height, limit: 2048)
            }
            draftEffects = session.effectsPreviews.renderNow(image: text.image, mask: mask, effects: effects)
                .map { (text.image, effects, text.transform, $0.image, $0.inset) }
            draftEffectsSource = session.textDraft.map { (layer.id, $0.style) }
        }
        guard let built = draftEffects else { return text }
        return (built.rendered, LayerEffectsRenderer.placed(text.transform, image: built.rendered, inset: built.inset))
    }

    /// 文字编辑刚结束：若图层此时持有的正是上次输入的文字，则编辑期间的效果先临时顶替，
    /// 直至从已提交的像素重建完成，避免效果消失一帧。
    private func handOffTextEffects(_ document: CanvasDocument) {
        guard session.textDraft == nil, let built = draftEffects, let source = draftEffectsSource else { return }
        if document.layers.first(where: { $0.id == source.layerID })?.liveText?.style == source.style {
            session.effectsPreviews.seed(source.layerID, image: built.rendered,
                placement: LayerEffectsRenderer.placed(built.transform, image: built.rendered, inset: built.inset))
        }
        draftEffects = nil
        draftEffectsSource = nil
    }

    /// 使用形状工具拖出的形状，按其最终创建时的颜色绘制。
    private func drawShapeDraft(scale: CGFloat, center: (CGPoint) -> CGPoint, in context: CGContext) {
        // 水平或竖直线段对应的框没有高度或宽度，因此在本检查中不算"空"。
        guard let draft = session.shapeDraft,
              draft.kind == .line ? (draft.rect.width > 0 || draft.rect.height > 0) : !draft.rect.isEmpty else { return }
        let middle = center(CGPoint(x: draft.rect.midX, y: draft.rect.midY))
        let rect = CGRect(x: middle.x - draft.rect.width * scale / 2, y: middle.y - draft.rect.height * scale / 2,
                          width: draft.rect.width * scale, height: draft.rect.height * scale)
        context.saveGState()
        context.setFillColor(session.foregroundColor.nsColor.cgColor)
        if draft.kind == .line {
            guard let ends = session.shapeLineEnds else { context.restoreGState(); return }
            let thickness = max(1, CGFloat(session.shapeLineWidth) * scale)
            context.setStrokeColor(session.foregroundColor.nsColor.cgColor)
            context.setLineWidth(thickness)
            context.setLineCap(.round)
            // 严格使用拖动中的两个端点，因此起点不会偏移。
            context.move(to: center(ends.start))
            context.addLine(to: center(ends.end))
            context.strokePath()
        } else {
            context.addPath(draft.kind.path(in: rect, cornerRadius: draft.cornerRadius * scale))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// 正在绘制图层的效果 surface，在笔触开始时创建，并随笔触进行而更新。
    private var strokeSurface: LayerEffectsSurface?
    /// GPU 在叠加层之下绘制画布的位置（见 `drawOnGPU`）。
    var gpuView: MetalCanvasView?
    /// 关闭时，每一帧都使用 Core Graphics 绘制。
    var allowsGPU = true
    private var snapshotting = false
    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        snapshotting = true
        defer { snapshotting = false }
        super.cacheDisplay(in: rect, to: bitmapImageRep)
    }
    private func strokeSurface(layer: ImageLayer, stroke: BrushStroke, mask: CGImage?) -> LayerEffectsSurface? {
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else { return nil }
        let grid = CGSize(width: stroke.width, height: stroke.height)
        if strokeSurface?.matches(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect) != true {
            strokeSurface = LayerEffectsSurface(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect)
        }
        guard let surface = strokeSurface else { return nil }
        if stroke.isMask {
            // 笔触留下的蒙版，覆盖网格的某个区域：在原蒙版之外的编辑会显示出来，提交后亦如此。
            let old = stroke.layer.mask?.asset.image, patches = stroke.patches, sourceRect = stroke.sourceRect, background = stroke.maskBackground
            surface.update(base: stroke.layer.asset?.image, patches: [], mask: nil, maskStroke: .init(patches: patches, toGrid: .identity) { region in
                guard let coverage = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: true) else { return nil }
                coverage.translateBy(x: -region.minX, y: -region.minY)
                coverage.setFillColor(gray: background, alpha: 1)
                coverage.fill(region)
                if let old { BrushRaster.draw(old, in: sourceRect, mask: true, context: coverage) }
                for patch in patches where patch.rect.intersects(region) {
                    BrushRaster.draw(patch.image, in: patch.rect, mask: true, context: coverage)
                }
                return coverage.makeImage()
            })
        } else {
            surface.update(base: stroke.layer.asset?.image, patches: stroke.patches, mask: mask)
        }
        return surface
    }

    /// 独立放置的蒙版正在绘制时的效果 surface。其笔触绘制于蒙版自身的网格；
    /// surface 保留在图层网格中，从 `preview`（即重采样到该网格的笔触蒙版）取蒙版。
    private func placedMaskSurface(layer: ImageLayer, stroke: BrushStroke, placement: LayerTransform, preview: CGImage) -> LayerEffectsSurface? {
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid, let base = stroke.layer.asset?.image else { return nil }
        let grid = CGSize(width: base.width, height: base.height)
        let full = CGRect(origin: .zero, size: grid)
        if strokeSurface?.matches(layerID: layer.id, effects: effects, grid: grid, sourceRect: full) != true {
            strokeSurface = LayerEffectsSurface(layerID: layer.id, effects: effects, grid: grid, sourceRect: full)
        }
        guard let surface = strokeSurface else { return nil }
        let toGrid = BrushRaster.pixelToDocument(stroke.paintTransform, width: stroke.width, height: stroke.height)
            .concatenating(BrushRaster.pixelToDocument(stroke.layer.transform, width: base.width, height: base.height).inverted())
        surface.update(base: base, patches: [], mask: nil, maskStroke: .init(patches: stroke.patches, toGrid: toGrid) { region in
            guard let coverage = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: true) else { return nil }
            coverage.translateBy(x: -region.minX, y: -region.minY)
            coverage.interpolationQuality = .medium
            coverage.saveGState()
            coverage.translateBy(x: 0, y: full.maxY)
            coverage.scaleBy(x: 1, y: -1)
            coverage.draw(preview, in: full)
            coverage.restoreGState()
            return coverage.makeImage()
        })
        return surface
    }

    /// 正在为该文件夹蒙版绘制的栅格编辑（若有）。
    private func liveMaskEdit(for id: UUID) -> BrushStroke? {
        [session.brushStroke, session.gradientEdit?.raster].compactMap { $0 }.first { $0.layer.id == id && $0.isMask }
    }

    /// 绘制文件夹蒙版时，蒙版仅以编辑的瓦片形式存在，因此内部图层的裁剪由这些瓦片渲染而来——
    /// 仅针对正在重绘的区域、按 context 的设备分辨率——与图层自身蒙版的预览方式相同。
    private func liveFolderMaskClip(_ edit: BrushStroke, area: CGRect, scale: CGFloat,
                                    center: (CGPoint) -> CGPoint, in context: CGContext) -> ((CGContext) -> Void)? {
        let rect = area.integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let device = context.convertToDeviceSpace(rect)
        let width = Int(abs(device.width).rounded(.up)), height = Int(abs(device.height).rounded(.up))
        guard width >= 1, height >= 1, width * height <= 64_000_000,
              let coverage = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        // 文件夹蒙版范围之外的区域被隐藏，与已提交的蒙版一致。
        coverage.setFillColor(gray: 0, alpha: 1)
        coverage.fill(CGRect(x: 0, y: 0, width: width, height: height))
        coverage.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        coverage.translateBy(x: -rect.minX, y: -rect.minY)
        var transform = edit.paintTransform
        transform.sampling = .nearest
        let base = edit.layer.mask?.asset
        LayerRenderer.drawBrushPreview(base.map { $0.raster == nil ? displayImage($0.image, width: transform.size.width * scale, in: coverage) : $0.image },
            transform: transform, center: center(transform.center), scale: scale, opacity: 1, blendMode: .normal, mask: nil,
            patches: edit.patches, pixelWidth: edit.width, pixelHeight: edit.height, paintingMask: false,
            sourceRect: edit.sourceRect, raster: base?.raster,
            rasterBase: base?.raster.flatMap { raster in raster.base.map { displayImage($0, width: transform.size.width * scale * raster.baseRect.width / CGFloat(max(1, raster.width)), in: coverage) } }, in: coverage)
        guard let image = coverage.makeImage() else { return nil }
        return { target in
            // CGImage 的行从上到下排列；在此翻转坐标空间中，图像裁剪则从下到上进行。
            target.translateBy(x: 0, y: rect.minY * 2 + rect.height)
            target.scaleBy(x: 1, y: -1)
            target.clip(to: rect, mask: image)
            target.scaleBy(x: 1, y: -1)
            target.translateBy(x: 0, y: -(rect.minY * 2 + rect.height))
        }
    }

    /// 仅按 1:1 合成可见的文档像素（与导出时的渲染一致），然后无平滑地放大，
    /// 使每个文档像素都呈现为清晰的方块，即便图层经过缩放或旋转亦如此。开销与屏幕显示内容成正比。
    private func drawDocumentPixels(covering view: CGRect, clippedTo pixels: CGRect, document: CanvasDocument, in context: CGContext) {
        let viewport = session.viewport
        let topLeft = viewport.documentPoint(from: view.origin, documentSize: document.size)
        let bottomRight = viewport.documentPoint(from: CGPoint(x: view.maxX, y: view.maxY), documentSize: document.size)
        let region = CGRect(x: floor(topLeft.x), y: floor(topLeft.y),
                            width: ceil(bottomRight.x) - floor(topLeft.x), height: ceil(bottomRight.y) - floor(topLeft.y))
            .intersection(pixels.integral)
        guard !region.isNull, region.width >= 1, region.height >= 1,
              let raster = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false) else { return }
        drawLayers(document, scale: 1, center: { CGPoint(x: $0.x - region.minX, y: $0.y - region.minY) }, in: raster)
        guard let image = raster.makeImage() else { return }
        let origin = viewport.viewPoint(from: region.origin, documentSize: document.size)
        let target = CGRect(origin: origin, size: CGSize(width: region.width * viewport.pointsPerPixel,
                                                         height: region.height * viewport.pointsPerPixel))
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    /// 线条叠加层绘制的内容：800% 起的像素网格，以及正在拖出的新文字框。
    private func drawLines(in dirtyRect: NSRect) {
        guard let document = session.document, let context = NSGraphicsContext.current?.cgContext else { return }
        if session.showsPixelGrid, session.viewport.zoom >= Self.pixelGridZoom {
            let pixels = renderBounds ?? CGRect(origin: .zero, size: document.size)
            let rect = CGRect(origin: session.viewport.viewPoint(from: pixels.origin, documentSize: document.size),
                              size: CGSize(width: pixels.width * session.viewport.pointsPerPixel,
                                           height: pixels.height * session.viewport.pointsPerPixel))
            let visible = rect.intersection(bounds).intersection(dirtyRect)
            if !visible.isNull, !visible.isEmpty { drawPixelGrid(in: visible, document: document, context: context) }
        }
        drawTextBoxDraft()
    }

    /// 一屏幕像素宽的线条，仅绘制在图像之上、对应文档像素边界处。
    private func drawPixelGrid(in view: CGRect, document: CanvasDocument, context: CGContext) {
        let viewport = session.viewport
        let canvas = CGRect(origin: viewport.viewPoint(from: .zero, documentSize: document.size),
                            size: CGSize(width: document.size.width * viewport.pointsPerPixel,
                                         height: document.size.height * viewport.pointsPerPixel))
        let area = view.intersection(canvas)
        guard !area.isNull, !area.isEmpty else { return }
        let first = viewport.documentPoint(from: area.origin, documentSize: document.size)
        let last = viewport.documentPoint(from: CGPoint(x: area.maxX, y: area.maxY), documentSize: document.size)
        let hairline = 1 / viewport.backingScale
        let path = CGMutablePath()
        for column in stride(from: Int(ceil(first.x)), through: Int(floor(last.x)), by: 1) {
            let x = viewport.viewPoint(from: CGPoint(x: CGFloat(column), y: 0), documentSize: document.size).x
            path.addRect(CGRect(x: x - hairline / 2, y: area.minY, width: hairline, height: area.height))
        }
        for row in stride(from: Int(ceil(first.y)), through: Int(floor(last.y)), by: 1) {
            let y = viewport.viewPoint(from: CGPoint(x: 0, y: CGFloat(row)), documentSize: document.size).y
            path.addRect(CGRect(x: area.minX, y: y - hairline / 2, width: area.width, height: hairline))
        }
        context.saveGState()
        context.addPath(path)
        context.setFillColor(NSColor(white: 0.55, alpha: 0.45).cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// 取样结束后恢复当前工具的光标，效果与光标矩形在进入画布时设置光标一致。
    private func restoreToolCursor() {
        if session.hueTargeting { NSCursor.resizeLeftRight.set() }
        else if session.tool.isSelectionTool, !spaceHeld { lassoCursor.set() }
        else if session.tool == .cloneStamp, session.cloneSource != nil, !optionHeld, !spaceHeld { Self.hiddenCursor.set() }
        else { toolCursor.set() }
    }

    /// 画布上当前工具的光标，前提是既不在取样也不在拖动。
    private var toolCursor: NSCursor {
        spaceHeld || session.tool == .hand ? .openHand
            // 移动工具的光标取决于指针位置（控制点、Option 复制等），因此在此按指针设置。
            : session.tool == .move ? window.map { transformCursor(at: convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? .arrow
            : session.tool == .type ? .iBeam
            : session.tool == .idle ? .arrow
            : session.tool == .zoom ? (optionHeld ? Self.zoomOutCursor : Self.zoomInCursor)
            : .crosshair
    }

    override func resetCursorRects() {
        guard session.document != nil else { return }
        if let dragCursor { addCursorRect(bounds, cursor: dragCursor); return }
        if picking {
            addCursorRect(bounds, cursor: pickCursor)
            keepColorRangeCursor()
            return
        }
        if session.hueTargeting { addCursorRect(bounds, cursor: .resizeLeftRight); return }
        if session.tool.isSelectionTool, !spaceHeld { addCursorRect(bounds, cursor: lassoCursor); return }
        // 仿制图章有源点时：笔刷圆圈、其预览以及源点十字准星代替光标。
        // 按住 Option 选取新源点时，恢复十字准星显示。
        if session.tool == .cloneStamp, session.cloneSource != nil, !optionHeld, !spaceHeld {
            addCursorRect(bounds, cursor: Self.hiddenCursor)
            return
        }
        addCursorRect(bounds, cursor: toolCursor)
        guard session.tool == .crop, !spaceHeld else { return }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for region in transformOverlay.cropResizeRegions.reversed() {
            let rect = region.rect.intersection(bounds)
            if !rect.isEmpty && !rect.isNull {
                addCursorRect(rect, cursor: .frameResize(position: positions[region.index], directions: [.inward, .outward]))
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard session.document != nil else { return }
        // 所有工具都会收到 mouse-leave 事件，使其光标不会跟随鼠标移出画布；
        // 仅光标依赖指针位置的工具才额外监听 mouseMoved。
        // 取色面板仍保持为 key window，因此即使本窗口非 key 也需继续追踪取样。
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, picking ? .activeAlways : .activeInKeyWindow, .inVisibleRect]
        if picking || session.tool == .move || session.tool.isBrushTool || session.tool.isSelectionTool {
            options.formUnion([.mouseMoved, .cursorUpdate])
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    private func updateBrushCursor() {
        let shows = session.tool.isBrushTool && !spaceHeld && !picking && middlePanPoint == nil
        let diameter = session.brushStroke?.settings.diameter ?? session.brushSettings.diameter
        // 仿制图章还会标出取样源位置；两次笔触之间，它在圆圈内预览
        // 一次点击会在那里盖下什么。
        var sample: CGPoint?
        var preview: CGImage?
        if shows, session.tool == .cloneStamp, let pointer = brushPointer, let document = session.document {
            let point = session.viewport.documentPoint(from: pointer, documentSize: document.size)
            if let source = session.cloneSamplePoint(for: point) {
                sample = session.viewport.viewPoint(from: source, documentSize: document.size)
            }
            if session.brushStroke == nil, !optionHeld, let offset = session.cloneStrokeOffset(at: point) {
                preview = clonePreview(center: CGPoint(x: point.x + offset.width, y: point.y + offset.height),
                                       diameter: diameter, document: document)
            }
        }
        brushCursor.update(point: shows ? brushPointer : nil, diameter: max(1, diameter * session.viewport.pointsPerPixel),
                           sample: sample, preview: preview, previewOpacity: session.brushSettings.opacity,
                           tip: preview == nil ? nil : cloneTip(diameter: diameter, hardness: session.brushSettings.hardness),
                           hardness: brushTipDrag?.hardnessShown == true ? session.brushSettings.hardness : nil)
    }

    private var cloneTipCache: (diameter: CGFloat, hardness: CGFloat, image: CGImage?)?

    /// 当前画笔尺寸与硬度下，一次点击所产生的覆盖度。由画笔引擎本身绘制，
    /// 因此预览的柔化程度与真实点击完全一致。只在这两个参数变化时才重建。
    private func cloneTip(diameter: CGFloat, hardness: CGFloat) -> CGImage? {
        if let cache = cloneTipCache, cache.diameter == diameter, cache.hardness == hardness { return cache.image }
        var image: CGImage?
        let side = max(1, Int(diameter.rounded(.up)))
        let size = CGSize(width: side, height: side)
        let settings = BrushSettings(diameter: diameter, hardness: hardness, red: 1, green: 1, blue: 1)
        if let stroke = try? BrushStroke(layer: ImageLayer(name: "Tip", blankSize: size), mask: false, settings: settings, canvas: size),
           (try? stroke.append(CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2))) != nil,
           (try? stroke.flush()) != nil,
           let painted = try? stroke.paintSnapshot(),
           let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            BrushRaster.draw(painted.asset.image, in: painted.bounds, mask: false, context: context)
            image = context.makeImage()
        }
        cloneTipCache = (diameter, hardness, image)
        return image
    }

    private struct ClonePreviewKey: Equatable {
        let center: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let revision: Int
        let undoCount: Int
        let allLayers: Bool
        let layerID: UUID?
    }
    private var clonePreviewCache: (key: ClonePreviewKey, image: CGImage?)?

    /// 一次仿制图章点击会拷进画笔圆圈的内容：`center`（文档像素）周围的源区域，
    /// 只按屏幕分辨率渲染这一小块，并在指针、缩放、画笔或文档变化之前一直复用。
    private func clonePreview(center: CGPoint, diameter: CGFloat, document: CanvasDocument) -> CGImage? {
        let scale = session.viewport.pointsPerPixel * session.viewport.backingScale
        let key = ClonePreviewKey(center: center, diameter: diameter, scale: scale, revision: session.brushRevision,
                                  undoCount: session.history.undoCount, allLayers: session.cloneSettings.sampleAllLayers,
                                  layerID: session.activeLayerID)
        if let cache = clonePreviewCache, cache.key == key { return cache.image }
        let side = min(1024, max(1, Int((diameter * scale).rounded(.up))))
        var image: CGImage?
        if diameter > 0, let context = try? BrushRaster.context(width: side, height: side, mask: false) {
            let perPixel = CGFloat(side) / diameter
            context.scaleBy(x: perPixel, y: perPixel)
            context.translateBy(x: diameter / 2 - center.x, y: diameter / 2 - center.y)
            context.interpolationQuality = .medium
            if session.cloneSettings.sampleAllLayers {
                session.drawLiveComposite(document, in: context)
            } else if let layer = session.activeLayer, let source = layer.asset?.image {
                let transform = session.displayedTransform(for: layer)
                LayerRenderer.draw(source, transform: transform, center: transform.center, in: context)
            }
            image = context.makeImage()
        }
        clonePreviewCache = (key, image)
        return image
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        session.filterEdit?.cameraRawReadout = nil
        brushPointer = nil
        updateBrushCursor()
        // 工具在画布上时会直接设置自己的光标，因此离开时要把箭头光标装回去。
        // 拖拽过程中则一直保持其光标，直到松开鼠标。
        if session.document != nil, NSEvent.pressedMouseButtons == 0 {
            NSCursor.setHiddenUntilMouseMoves(false)
            NSCursor.arrow.set()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard session.document != nil else { return }
        if session.filterEdit?.kind == .cameraRaw, let document = session.document {
            let point = convert(event.locationInWindow, from: nil)
            session.updateCameraRawReadout(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        }
        optionHeld = event.modifierFlags.contains(.option)
        if picking { pickCursor.set(); return }
        if session.tool.isSelectionTool {
            // App 处于后台期间按键状态可能已改变。
            session.updateHeldSelectionKeys(shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            lassoCursor(flags: event.modifierFlags, at: convert(event.locationInWindow, from: nil)).set()
            if session.lassoDraft?.kind == .polygonal, let document = session.document {
                session.moveLassoCursor(to: session.viewport.documentPoint(from: convert(event.locationInWindow, from: nil), documentSize: document.size))
                synchronizeDisplay()
            }
            return
        }
        // 取色器在指针位于别处（例如它自己的面板上）时关闭，留下了一个悬而未决的吸管。
        if [Self.eyedropperCursor, Self.eyedropperAddCursor, Self.eyedropperRemoveCursor].contains(NSCursor.current) { restoreToolCursor() }
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
        if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags) }
        else { super.mouseMoved(with: event) }
    }
    override func cursorUpdate(with event: NSEvent) {
        guard session.document != nil else { return }
        if picking { pickCursor.set() }
        else if session.tool.isSelectionTool, !spaceHeld { lassoCursor.set() }
        // 光标更新事件不携带修饰键标志（AppKit 只在按键变化后发一次），
        // 所以按当前实际按键状态来判断；若采信事件自带的标志，Option 的复制光标会立刻失效。
        else if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: NSEvent.modifierFlags) }
        else { super.cursorUpdate(with: event) }
    }
    private func updateTransformCursor(at point: CGPoint, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard session.document != nil else { return }
        transformCursor(at: point, flags: flags).set()
    }

    /// 移动工具在某个视图坐标处的光标。指针在拖拽会作用到的任何东西上并按住 Option 时，
    /// 显示复制光标，因为 Option-拖动会复制图层。参考线位于手柄之下、图层拖拽之上。
    private func transformCursor(at point: CGPoint, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> NSCursor {
        if let dragCursor { return dragCursor }
        guard !spaceHeld else { return .openHand }
        guard !session.isProjectBusy, !session.isImporting else { return .arrow }
        let duplicate = flags.contains(.option)
        if let geometry = transformOverlay.geometry, let hit = geometry.hit(point) {
            switch hit {
            case .resize(let index):
                // 变形中（按住 Cmd，或已变形）时角点可自由移动，白箭头即表示这一点。
                let distorting = session.transformEdit?.corners != nil || flags.contains(.command)
                return distorting ? Self.distortCursor : geometry.resizeCursor(for: index)
            case .rotate: return Self.rotationCursor
            case .move: return duplicate ? Self.duplicateCursor : Self.moveCursor
            case .distort: return Self.distortCursor
            }
        }
        if let guide = session.hitGuide(at: point) {
            return guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
        }
        guard pressMovesLayer(at: point, flags: flags) else { return .arrow }
        return duplicate ? Self.duplicateCursor : Self.moveCursor
    }

    /// 一次没落在变换手柄上的按下，是否会拖动图层（见 `transformPressLayer`）。
    private func pressMovesLayer(at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard let document = session.document else { return false }
        return transformPressLayer(at: session.viewport.documentPoint(from: point, documentSize: document.size), flags: flags) != nil
    }

    /// 一次没落在变换手柄上的按下会拖动哪个图层，以及它是否是从指针下选出来的。
    /// 与 Photoshop 一样，按住 Command 会反转「自动选择」：关闭时取指针下的图层，
    /// 开启时保持当前图层。默认是当前图层，除非自动选择在那里找到别的图层
    /// ——包括叠在某个同样覆盖该按下位置、且已被选中的背景之上的图层。
    /// 按在空白画布上仍会拖动当前图层：按下点不必落在图层边界之内。
    private func transformPressLayer(at pixel: CGPoint, flags: NSEvent.ModifierFlags) -> (id: UUID, picked: Bool)? {
        guard session.canEditLayers || session.transformEdit != nil, let document = session.document else { return nil }
        let underPointer = document.renderLayers.reversed().first { $0.asset != nil && $0.transform.contains(pixel) }?.id
        let active = session.activeLayer.flatMap { layer in
            layer.asset != nil && !layer.isGroup && document.effectiveVisibleIDs.contains(layer.id) ? layer : nil
        }
        let picks = session.transformEdit == nil
        let autoSelect = session.transformAutoSelect != flags.contains(.command)
        // Cmd-Shift-单击把指针下的图层加入选区，与「自动选择」的设置无关。
        if flags.contains(.command), flags.contains(.shift) || !session.transformAutoSelect, picks, let underPointer {
            return (underPointer, true)
        }
        // 选中了多个图层，或选中了文件夹：按在它们包围盒之内会拖动全部；按在盒外同样如此，
        // 除非自动选择在那里找到了某个图层。
        if session.transformsAsGroup, let id = session.activeLayerID {
            let box = session.transformEdit?.draft ?? session.groupTransformBox
            if box?.contains(pixel) == true || !(picks && autoSelect) || underPointer == nil { return (id, false) }
        }
        if let active, session.editedTransform(for: active).contains(pixel) {
            // `renderLayers` 是从底到顶排列的，因此下标越大绘制得越靠上。自动选择开启时优先取该图层；
            // 否则一张铺满画布的背景图层会包含每一次按下，坚持选它就会把叠在其上的前景图层挡住。
            if picks, autoSelect, let underPointer, underPointer != active.id,
               let top = document.renderLayers.lastIndex(where: { $0.id == underPointer }),
               let current = document.renderLayers.lastIndex(where: { $0.id == active.id }),
               top > current {
                return (underPointer, true)
            }
            return (active.id, false)
        }
        if picks, autoSelect, let underPointer { return (underPointer, true) }
        return active.map { ($0.id, false) }
    }
    /// 使用画笔工具时右键拖动：左右拖动以按下时的尺寸为基准缩放画笔，
    /// 按住 Shift 则改为调整硬度。画笔圆圈始终停在按下时的位置。
    private var brushTipDrag: (start: CGPoint, diameter: CGFloat, hardness: CGFloat, hardnessShown: Bool)?
    override func rightMouseDown(with event: NSEvent) {
        guard session.tool.isBrushTool, session.brushStroke == nil, session.warpStroke == nil, !spaceHeld else {
            super.rightMouseDown(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        brushTipDrag = (point, session.brushSettings.diameter, session.brushSettings.hardness, event.modifierFlags.contains(.shift))
        brushPointer = point
        updateBrushCursor()
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let drag = brushTipDrag else { super.rightMouseDragged(with: event); return }
        brushTipDrag?.hardnessShown = event.modifierFlags.contains(.shift)
        let dx = convert(event.locationInWindow, from: nil).x - drag.start.x
        if event.modifierFlags.contains(.shift) {
            // 整个量程分布在 200 个点上。
            session.brushSettings.hardness = min(1, max(0, drag.hardness + dx / 200))
            session.brushSettings.diameter = drag.diameter
        } else {
            // 圆圈边缘跟随指针：每移动一个点，半径就按一个屏幕像素增大。
            let perPixel = max(0.0001, session.viewport.pointsPerPixel)
            session.brushSettings.diameter = min(2000, max(1, (drag.diameter + 2 * dx / perPixel).rounded()))
            session.brushSettings.hardness = drag.hardness
        }
        brushPointer = drag.start
        updateBrushCursor()
    }
    override func rightMouseUp(with event: NSEvent) {
        guard brushTipDrag != nil else { super.rightMouseUp(with: event); return }
        brushTipDrag = nil
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
    }
    override func mouseDown(with event: NSEvent) {
        session.effectSelection = nil
        optionHeld = event.modifierFlags.contains(.option)
        window?.makeFirstResponder(self)
        guard session.document != nil, !session.isProjectBusy, !session.isImporting else { return }
        let point = convert(event.locationInWindow, from: nil)
        if session.filterEdit?.samplesWhiteBalance == true, !spaceHeld, let document = session.document {
            session.sampleCameraRawWhiteBalance(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel"))
            return
        }
        if session.filterEdit?.samplesPointColor == true, !spaceHeld, let document = session.document {
            session.sampleCameraRawPointColor(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel"))
            return
        }
        if session.filterEdit?.samplesDefringe == true, !spaceHeld, let document = session.document {
            session.sampleCameraRawDefringe(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("filterPanel"))
            return
        }
        if session.filterEdit?.drawingCameraRawGeometryGuide == true, !spaceHeld, let document = session.document {
            session.beginCameraRawGeometryGuide(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if (session.filterEdit?.targetsCameraRawCurve == true || session.filterEdit?.targetsCameraRawMixer == true),
           !spaceHeld, let document = session.document {
            session.beginCameraRawDrag(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if session.levels?.sampleMode != nil, !spaceHeld, let document = session.document {
            session.sampleLevels(at: session.viewport.documentPoint(from: point, documentSize: document.size))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("levelsPanel"))
            return
        }
        if session.levels != nil, !spaceHeld, session.tool != .hand, session.tool != .zoom { return }
        if session.colorRange != nil, !spaceHeld, let document = session.document {
            session.sampleColorRange(at: session.viewport.documentPoint(from: point, documentSize: document.size),
                                     shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("colorRangePanel"))
            keepColorRangeCursor()
            return
        }
        if picking, !spaceHeld {
            if session.colorPicker != nil || (palettePicking && session.hueSampleMode == nil) {
                samplingOriginal = session.colorPicker?.color ?? session.foregroundColor
                samplingColor = true
                sampleColor(at: point)
            } else if let document = session.document {
                session.sampleHueRange(at: session.viewport.documentPoint(from: point, documentSize: document.size))
                FloatingPanelController.refocus(NSUserInterfaceItemIdentifier("adjustmentPanel"))
            }
            return
        }
        if session.hueTargeting, !spaceHeld, let document = session.document {
            if session.beginHueTargeting(at: session.viewport.documentPoint(from: point, documentSize: document.size)) {
                hueTargetStart = point
                NSCursor.resizeLeftRight.set()
            }
            return
        }
        if spaceHeld || session.tool == .hand {
            lastDragPoint = point
            NSCursor.closedHand.set()
        } else if session.tool.isBrushTool, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            // 仿制图章下 Option-单击设置取样源位置（其他画笔则是吸取颜色）。
            if session.tool == .cloneStamp, event.modifierFlags.contains(.option) {
                session.setCloneSource(pixel)
                updateBrushCursor()
                window?.invalidateCursorRects(for: self)
                return
            }
            brushPointer = point
            // 与 Photoshop 一样，按住 Shift 会从上一笔结束处接着画一条直线。
            if event.modifierFlags.contains(.shift), let from = session.shiftLineStart() {
                session.beginBrush(at: from)
                session.continueBrush(at: pixel)
            } else {
                session.beginBrush(at: pixel)
            }
            brushAxisAnchor = event.modifierFlags.contains(.shift) ? pixel : nil
            brushAxisHorizontal = nil
            brushLastPixel = pixel
            synchronizeDisplay()
        } else if session.tool.isSelectionTool {
            lassoMouseDown(at: point, event: event)
            refreshLassoCursor()
        } else if session.tool == .gradient {
            beginGradientDrag(at: point)
        } else if session.tool == .type {
            beginTextGesture(at: point, event: event)
        } else if session.tool == .shape, let document = session.document {
            session.beginShape(at: snappedCorner(session.viewport.documentPoint(from: point, documentSize: document.size),
                                                 flags: event.modifierFlags))
        } else if session.tool == .crop {
            beginCropDrag(at: point)
        } else if session.tool == .move {
            // 双击可编辑文字即可直接编辑，无需先切到文字工具。
            if event.clickCount >= 2, beginLiveTextEdit(at: point) { return }
            if beginGuideDrag(at: point) { return }
            beginTransformDrag(at: point, modifiers: event.modifierFlags)
        } else if session.tool == .zoom {
            zoomDrag = (point, session.viewport.zoom, false)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard session.document != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if session.filterEdit?.drawingCameraRawGeometryGuide == true, session.filterEdit?.cameraRawGuideDraft != nil,
           let document = session.document {
            session.continueCameraRawGeometryGuide(to: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if session.filterEdit?.cameraRawDrag != nil, let document = session.document {
            session.dragCameraRaw(to: session.viewport.documentPoint(from: point, documentSize: document.size))
            return
        }
        if textBoxAnchor != nil { dragTextGesture(to: point); return }
        if var drag = zoomDrag {
            let dx = point.x - drag.start.x
            if abs(dx) >= 3 { drag.moved = true; zoomDrag = drag }
            // 向右放大，向左缩小：每拖 100 点翻一倍。
            if drag.moved { session.zoom(to: drag.zoom * pow(2, dx / 100), anchor: drag.start) }
            return
        }
        if samplingColor { sampleColor(at: point); return }
        if let start = hueTargetStart {
            session.dragHueTargeting(byViewDelta: point.x - start.x,
                                     adjustsHue: event.modifierFlags.contains(.command))
            NSCursor.resizeLeftRight.set()
            return
        }
        if let start = pixelDragStart, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
            // 按住 Shift 让像素保持在一条直线上，横向或纵向——取拖动中走得较远的那一维——
            // 与移动图层时的行为一致。
            if event.modifierFlags.contains(.shift) {
                if abs(offset.width) >= abs(offset.height) { offset.height = 0 } else { offset.width = 0 }
            }
            session.movePixels(by: offset)
            pixelDragCursor(duplicate: session.pixelMove?.duplicate == true).set()
            synchronizeDisplay()
            return
        }
        if selectionDragStart != nil {
            dragSelection(to: point, flags: event.modifierFlags)
            updateMarqueeAutoscroll(at: point)
            Self.moveSelectionCursor.set()
            synchronizeDisplay()
            return
        }
        if session.tool.isSelectionTool, lastDragPoint == nil, let draft = session.lassoDraft, let document = session.document {
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            switch draft.kind {
            case .freehand: session.extendLasso(to: pixel)
            case .polygonal: session.moveLassoCursor(to: pixel)
            case .rectangle, .ellipse:
                dragMarqueeDraft(to: pixel, flags: event.modifierFlags)
                updateMarqueeAutoscroll(at: point)
            }
            synchronizeDisplay()
            return
        }
        if session.shapeDraft != nil, lastDragPoint == nil, let document = session.document {
            // 与选框不同，Option 在这里没有别的用途，因此与 Photoshop 一样从中心起笔。
            session.dragShape(to: snappedCorner(session.viewport.documentPoint(from: point, documentSize: document.size),
                                                flags: event.modifierFlags),
                              square: event.modifierFlags.contains(.shift), fromCenter: event.modifierFlags.contains(.option))
            synchronizeDisplay()
            return
        }
        if let handle = gradientDrag, let edit = session.gradientEdit, let document = session.document {
            var pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            if event.modifierFlags.contains(.shift) {
                pixel = Self.snapped(pixel, around: handle == .start ? edit.end : edit.start)
            }
            session.moveGradient(start: handle == .start ? pixel : nil, end: handle == .end ? pixel : nil)
            synchronizeDisplay()
            return
        }
        brushPointer = point
        updateBrushCursor()
        if session.brushStroke != nil || session.warpStroke != nil, !session.isProjectBusy, let document = session.document {
            var pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            // 按住 Shift 无论从何处按下都保持笔触为水平或垂直直线；松开后继续自由绘制。
            // 方向由最初几个像素的移动决定，因此不会在一笔中途翻转。
            if event.modifierFlags.contains(.shift) {
                let anchor = brushAxisAnchor ?? brushLastPixel ?? pixel
                if brushAxisAnchor == nil { brushAxisAnchor = anchor; brushAxisHorizontal = nil }
                if brushAxisHorizontal == nil, hypot(pixel.x - anchor.x, pixel.y - anchor.y) >= 3 {
                    brushAxisHorizontal = abs(pixel.x - anchor.x) >= abs(pixel.y - anchor.y)
                }
                if let horizontal = brushAxisHorizontal {
                    pixel = horizontal ? CGPoint(x: pixel.x, y: anchor.y) : CGPoint(x: anchor.x, y: pixel.y)
                } else {
                    pixel = anchor
                }
            } else {
                brushAxisAnchor = nil
                brushAxisHorizontal = nil
            }
            brushLastPixel = pixel
            session.continueBrush(at: pixel)
            synchronizeDisplay()
            return
        }
        if guideDragging, let drag = session.guideDrag, let document = session.document {
            dragCursor?.set()
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            session.moveGuideDrag(to: Double(drag.axis == .vertical ? pixel.x : pixel.y))
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        if let drag = cropDrag, session.tool == .crop, !session.isProjectBusy, let document = session.document {
            dragCursor?.set()
            dragCrop(drag, to: point, flags: event.modifierFlags, documentSize: document.size)
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        if let drag = transformDrag, let document = session.document {
            dragCursor?.set()
            let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
            if duplicatesTransformOnDrag {
                duplicatesTransformOnDrag = false
                session.beginDuplicateTransform()
            }
            if let corners = drag.corners(to: pixel, shift: event.modifierFlags.contains(.shift)) {
                session.previewCorners(corners)
                needsDisplay = true
            } else {
                let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
                let moving = session.transformEdit?.group.map { Set($0.originals.keys) }
                    ?? Set([session.transformEdit?.layerID].compactMap { $0 })
                let tolerance = TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001)
                // 移动与缩放会吸附到画布和其他图层——以及被缩放图层正被拖动的那几条边——
                // 旋转则不吸附。按住 Control 可自由拖动。
                var target = pixel
                if case .resize = drag.mode, !event.modifierFlags.contains(.control) {
                    target = session.snappedResizePoint(pixel, drag: drag, proportional: session.locksTransformRatio != shift,
                                                        moving: moving, tolerance: tolerance) {
                        drag.updated(to: $0, lockRatio: session.locksTransformRatio, shift: shift, option: option)
                    }
                }
                // 拖动、缩放和旋转都落在整数像素与整数度上；手动输入的数值则保持精确。
                var draft = drag.updated(to: target, lockRatio: session.locksTransformRatio, shift: shift, option: option).rounded()
                if case .move = drag.mode, !event.modifierFlags.contains(.control) {
                    draft = session.snappedMove(draft, moving: moving, tolerance: tolerance)
                }
                session.previewTransform(draft)
            }
            synchronizeDisplay()
            dragCursor?.set()
            return
        }
        guard let last = lastDragPoint else { return }
        session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        lastDragPoint = point
        redrawRulers()
    }
    /// 任何工具下都可以用中键平移，无需去按空格或切换到抓手工具。它保有自己的拖动起点，
    /// 因此不会干扰左键正在进行的操作。
    private func panPoint(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, session.document != nil else { super.otherMouseDown(with: event); return }
        middlePanPoint = panPoint(of: event)
        if session.tool.isBrushTool { updateBrushCursor() }
        NSCursor.closedHand.set()
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard let last = middlePanPoint else { super.otherMouseDragged(with: event); return }
        let point = panPoint(of: event)
        session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        middlePanPoint = point
        redrawRulers()
    }
    override func otherMouseUp(with event: NSEvent) {
        guard middlePanPoint != nil else { super.otherMouseUp(with: event); return }
        middlePanPoint = nil
        // 闭合抓手光标是直接设置的，因此这里直接装回工具自己的光标，不必等到下一次移动。
        refreshLassoCursor(event.modifierFlags)
        if session.tool.isBrushTool { updateBrushCursor() }
        window?.invalidateCursorRects(for: self)
    }
    override func mouseUp(with event: NSEvent) {
        if session.filterEdit?.cameraRawGuideDraft != nil {
            session.commitCameraRawGeometryGuide()
        }
        session.filterEdit?.cameraRawDrag = nil
        if textBoxAnchor != nil { finishTextGesture(); return }
        stopMarqueeAutoscroll()
        if let drag = zoomDrag {
            zoomDrag = nil
            if !drag.moved {
                session.zoom(to: session.viewport.zoom * (event.modifierFlags.contains(.option) ? 0.5 : 2), anchor: drag.start)
            }
            return
        }
        session.snapGuides = ([], [])
        if guideDragging {
            session.finishGuideDrag(delete: isOverRuler(convert(event.locationInWindow, from: nil)))
            guideDragging = false
        }
        if samplingColor {
            samplingColor = false
            sampleRing.isHidden = true
            if session.colorPicker != nil { ColorPickerPanelController.refocus() }
            return
        }
        if session.brushStroke != nil || session.warpStroke != nil, !session.isProjectBusy {
            if let document = session.document {
                session.continueBrush(at: session.viewport.documentPoint(from: convert(event.locationInWindow, from: nil), documentSize: document.size))
            }
            session.finishBrushImmediately()
            synchronizeDisplay()
        }
        if gradientDrag != nil {
            gradientDrag = nil
            session.endGradientDrag()
        }
        if session.shapeDraft != nil {
            session.finishShape()
            synchronizeDisplay()
        }
        if hueTargetStart != nil {
            hueTargetStart = nil
            session.endHueTargeting()
        }
        if pixelDragStart != nil {
            pixelDragStart = nil
            Task { await session.finishPixelMove(); synchronizeDisplay(); refreshLassoCursor() }
        }
        if let start = selectionDragStart {
            selectionDragStart = nil
            let moved = session.selectionMoveOrigin != session.selection
            session.endSelectionMove()
            if !moved, session.tool == .wand, session.wandMode == .object {
                Task { await session.selectObject(at: start, mode: .replace); synchronizeDisplay(); refreshLassoCursor() }
            } else if !moved, session.tool == .wand {
                // 选区内的魔棒点击会从该像素重新开始选取。
                Task { await session.magicWand(at: start, mode: .replace); synchronizeDisplay(); refreshLassoCursor() }
            } else if !moved {
                // 不带拖动的单击会取消选择，与套索在其他地方的行为一致。
                session.deselect()
            }
            synchronizeDisplay()
            refreshLassoCursor()
        }
        if session.tool.isSelectionTool, let kind = session.lassoDraft?.kind, kind != .polygonal {
            session.finishLasso()
            synchronizeDisplay()
            refreshLassoCursor()
        }
        cropDrag = nil
        if transformDrag != nil {
            duplicatesTransformOnDrag = false
            transformDrag = nil
            if session.transformEdit?.persistent == false { session.commitTransform() }
        }
        lastDragPoint = nil
        // 拖动中途离开会保留拖动光标，因此在画布之外（例如图层面板上）松开的拖动，
        // 必须自行把箭头光标装回去。
        if session.document != nil {
            if !visibleRect.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
            window?.invalidateCursorRects(for: self)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        guard session.document != nil else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            session.zoom(to: session.viewport.zoom * exp(-event.scrollingDeltaY * 0.015),
                         anchor: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            session.viewport.translate(by: CGSize(width: event.scrollingDeltaX * multiplier,
                                                  height: event.scrollingDeltaY * multiplier))
            redrawRulers()
        }
    }
    override func magnify(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        session.zoom(to: session.viewport.zoom * (1 + event.magnification),
                     anchor: convert(event.locationInWindow, from: nil))
    }
    override func keyDown(with event: NSEvent) {
        let physicalKey = event.keyCode
        guard let event = ShortcutSettings.shared.canvasEvent(event) else { return }
        if handleKeyboardZoom(event) { return }
        if event.keyCode == 53, textBoxAnchor != nil { textBoxAnchor = nil; textBoxRect = nil; needsDisplay = true; return }
        if event.keyCode == 53, session.textDraft != nil { session.cancelText(); return }
        // 一次拖动会话会吞掉「Option 已松开」的那个 flagsChanged 事件，
        // 导致画布仍以为它被按住——连带让吸管顶替了画笔。每次按键都会重新读取该状态。
        optionHeld = event.modifierFlags.contains(.option)
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift {
            if session.canContentAwareFill { session.beginFilter(.contentAwareFill) }
            return
        }
        if let edit = session.levels {
            if event.keyCode == 53 { session.cancelLevels(); return }
            if [36, 76].contains(event.keyCode) { Task { await session.commitLevels() }; return }
            if event.charactersIgnoringModifiers?.lowercased() == "p", event.modifierFlags.contains(.option) {
                session.updateLevels(edit.settings, preview: !edit.preview); return
            }
            if event.keyCode != 49 { super.keyDown(with: event); return }
        }
        if session.brushStroke != nil || session.warpStroke != nil {
            if event.keyCode == 53 && !session.isProjectBusy { session.cancelBrush(); synchronizeDisplay() }
            return
        }
        if session.lassoDraft != nil, [53, 36, 76, 51, 117].contains(event.keyCode) {
            if event.keyCode == 53 { session.cancelLasso() }
            else if [36, 76].contains(event.keyCode) { session.finishLasso() }
            else { session.removeLastLassoPoint() }
            synchronizeDisplay()
            refreshLassoCursor()
        } else if session.shapeDraft != nil, event.keyCode == 53 {
            session.cancelShape()
            synchronizeDisplay()
        } else if session.gradientEdit != nil, event.keyCode == 53 {
            gradientDrag = nil
            session.cancelGradient()
        } else if session.gradientEdit != nil, [36, 76].contains(event.keyCode) {
            gradientDrag = nil
            Task { await session.commitGradient() }
        } else if session.tool == .crop, event.keyCode == 53 {
            cropDrag = nil
            session.cancelCrop()
        } else if session.tool == .crop, [36, 76].contains(event.keyCode) {
            cropDrag = nil
            Task { await session.commitCrop() }
        } else if event.keyCode == 53, session.guideDrag != nil {
            session.cancelGuideDrag()
            guideDragging = false
        } else if event.keyCode == 53, session.transformEdit != nil {
            transformDrag = nil
            session.cancelTransform()
        } else if [36, 76].contains(event.keyCode), session.transformEdit != nil {
            transformDrag = nil
            session.commitTransform()
        } else if session.selection?.isEmpty == false, session.lassoDraft == nil, [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.contains(.command), event.modifierFlags.intersection([.control, .option]).isEmpty {
            // 任何工具下 Cmd+方向键都会移动选中的像素；按住 Shift 为 10 像素。
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            Task { await session.nudgePixels(dx: dx, dy: dy); synchronizeDisplay() }
        } else if session.tool.isSelectionTool, session.lassoDraft == nil, session.selection?.isEmpty == false,
                  [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session.nudgeSelection(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                   dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if session.tool == .move, [123, 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session.nudgeLayer(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                               dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            session.deleteKeyPressed()
        } else if event.keyCode == 48, session.textDraft == nil, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            // Tab 切换当前工具的模式（矩形/椭圆、绘制/擦除等）。
            session.cycleToolMode()
            refreshLassoCursor()
            updateBrushCursor()
        } else if event.keyCode == 49 {
            panPhysicalKey = physicalKey
            spaceHeld = true
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": session.swapPaletteColors()
            case "d": session.resetPaletteColors()
            case "b": session.selectTool(.brush); session.brushMode = .paint
            case "e": session.selectTool(.brush); session.brushMode = .erase
            case "j": session.selectTool(.spotHealing)
            case "s": session.selectTool(.cloneStamp)
            case "t": session.selectTool(.type)
            case "g": session.selectTool(.gradient)
            case "u":
                if event.modifierFlags.contains(.shift), session.tool == .shape { session.toggleShapeKind() }
                else { session.selectTool(.shape) }
            case "i": session.selectTool(.eyedropper)
            // M 选择选框，沿用它上次设定的形状；形状在工具栏里切换。
            // 忽略按键重复事件，可避免一直按住时产生异常行为。
            case "m": if !event.isARepeat { session.pressMarqueeKey(); refreshLassoCursor() }
            case "w": if !event.isARepeat { session.pressWandKey(); refreshLassoCursor() }
            // L 以同样方式选择套索；自由/多边形在工具栏里切换。
            case "l": if !event.isARepeat { session.pressLassoKey(); refreshLassoCursor() }
            case let key? where Int(key) != nil && session.usesOpacityKeys:
                session.typeOpacityDigit(Int(key) ?? 0)
            case "[" where session.tool.isBrushTool: session.changeBrushSize(increase: false)
            case "]" where session.tool.isBrushTool: session.changeBrushSize(increase: true)
            // 按住 Shift 会把 [ 和 ] 变成 { 和 }。
            case "{" where session.tool.isBrushTool: session.changeBrushHardness(increase: false)
            case "}" where session.tool.isBrushTool: session.changeBrushHardness(increase: true)
            case "a": session.selectTool(.idle)
            case "r": session.selectTool(.blur)
            case "c": session.selectTool(.crop)
            case "v": session.selectTool(.move)
            case "h": session.selectTool(.hand)
            case "z": session.selectTool(.zoom)
            default: super.keyDown(with: event)
            }
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == panPhysicalKey || (panPhysicalKey == nil && event.keyCode == 49) {
            panPhysicalKey = nil
            spaceHeld = false
            updateBrushCursor()
            window?.invalidateCursorRects(for: self)
        } else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        if !session.isProjectBusy { session.cancelBrush() }
        brushPointer = nil
        updateBrushCursor()
        cropDrag = nil
        gradientDrag = nil
        session.cancelShape()
        if let kind = session.lassoDraft?.kind, kind != .polygonal { session.cancelLasso() }
        if selectionDragStart != nil { selectionDragStart = nil; session.endSelectionMove() }
        if pixelDragStart != nil { pixelDragStart = nil; session.cancelPixelMove() }
        if let drag = transformDrag {
            duplicatesTransformOnDrag = false
            session.previewTransform(drag.original)
            if session.transformEdit?.persistent == false { session.cancelTransform() }
            transformDrag = nil
        }
        spaceHeld = false
        lastDragPoint = nil
        return super.resignFirstResponder()
    }

    /// 视图朝位于 `point` 的指针每帧平移多少点：在画布内部较远处不动，
    /// 越接近边缘越快，从边缘前几个点开始加速，直到与指针越过边缘的距离成正比。
    private func marqueeAutoscrollDelta(at point: CGPoint) -> CGSize {
        let rect = visibleRect, margin: CGFloat = 12
        func speed(_ past: CGFloat) -> CGFloat { past <= 0 ? 0 : min(40, 2 + past * 0.4) }
        let left = speed(rect.minX + margin - point.x), right = speed(point.x - (rect.maxX - margin))
        let top = speed(rect.minY + margin - point.y), bottom = speed(point.y - (rect.maxY - margin))
        // 指针越过右边缘：文档向左滑动，把越界的内容带进视野。
        return CGSize(width: left - right, height: top - bottom)
    }
    private func updateMarqueeAutoscroll(at point: CGPoint) {
        marqueeAutoscrollPoint = point
        guard marqueeAutoscrollDelta(at: point) != .zero else { stopMarqueeAutoscroll(); return }
        guard marqueeAutoscroll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMarqueeAutoscroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        marqueeAutoscroll = timer
    }
    private func stepMarqueeAutoscroll() {
        let marquee = session.lassoDraft.map { $0.kind == .rectangle || $0.kind == .ellipse } == true
        guard let point = marqueeAutoscrollPoint, let document = session.document,
              marquee || selectionDragStart != nil else { stopMarqueeAutoscroll(); return }
        let delta = marqueeAutoscrollDelta(at: point)
        guard delta != .zero else { stopMarqueeAutoscroll(); return }
        session.viewport.translate(by: delta)
        // 指针没有移动，但它下方的文档移动了：包围盒的角点、以及被移动的选区都会跟随。
        if selectionDragStart != nil { dragSelection(to: point, flags: NSEvent.modifierFlags) }
        else { dragMarqueeDraft(to: session.viewport.documentPoint(from: point, documentSize: document.size), flags: NSEvent.modifierFlags) }
        synchronizeDisplay()
    }
    /// 移动被拖动的选区，使被抓取的那个像素落在 `point` 下方。按住 Shift 可把移动限制在
    /// 某一个轴上：取拖动中走得较远的那一维。
    private func dragSelection(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let start = selectionDragStart, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
        var horizontal = true, vertical = true
        if flags.contains(.shift) {
            if abs(offset.width) >= abs(offset.height) { offset.height = 0; vertical = false } else { offset.width = 0; horizontal = false }
        }
        // 与绘制选框时一样吸附到「显示 > 对齐到」的目标，除非按住 Control。
        if flags.contains(.control) { session.snapGuides = ([], []) }
        else {
            offset = session.snappedSelectionOffset(offset, tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001),
                                                    horizontal: horizontal, vertical: vertical)
        }
        session.moveSelection(by: offset)
    }
    private func stopMarqueeAutoscroll() {
        marqueeAutoscroll?.invalidate()
        marqueeAutoscroll = nil
        marqueeAutoscrollPoint = nil
    }

    /// 调整选框草稿的形状。Option 为减去模式（在按下时选定），因此不会从中心起笔。
    /// Shift 使选框为正方形——但如果拖动开始时就已按住 Shift，则它选择的是「组合」，
    /// 直到松开后重新按下才恢复正方形，与 Photoshop 相同。
    /// 位于 `pixel`（文档像素）的选框或形状角点；除非按住 Control，否则会吸附到「显示 > 对齐到」的目标。
    private func snappedCorner(_ pixel: CGPoint, flags: NSEvent.ModifierFlags) -> CGPoint {
        guard !flags.contains(.control) else { session.snapGuides = ([], []); return pixel }
        return session.snappedPoint(pixel, tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001))
    }

    private func dragMarqueeDraft(to pixel: CGPoint, flags: NSEvent.ModifierFlags) {
        if !flags.contains(.shift) { marqueeConstrainArmed = true }
        marqueeDragPixel = pixel
        session.dragMarquee(to: snappedCorner(pixel, flags: flags), square: marqueeConstrainArmed && flags.contains(.shift), fromCenter: false)
    }

    /// 自由套索按下即开始拖出轮廓。多边形套索每点击一次添加一个角点，
    /// 点击首个角点附近或双击即闭合。首次点击时按下的修饰键决定模式：
    /// Shift 为组合，Option 为减去。
    private func lassoMouseDown(at point: CGPoint, event: NSEvent) {
        guard let document = session.document else { return }
        // 按下时按住 Shift 表示「组合」；对选框而言，只有重新按下 Shift 才会变成正方形。
        marqueeConstrainArmed = !event.modifierFlags.contains(.shift)
        marqueeDragPixel = nil
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        guard let draft = session.lassoDraft, draft.kind == .polygonal else {
            // 选区内 Cmd-拖动会剪切并移动其中的像素（即 Photoshop 的临时移动工具）。
            if event.modifierFlags.contains(.command), session.canMoveSelection(at: pixel) {
                if session.beginPixelMove(duplicate: event.modifierFlags.contains(.option)) {
                    pixelDragStart = pixel
                    pixelDragCursor(duplicate: event.modifierFlags.contains(.option)).set()
                } else { NSSound.beep() }
                return
            }
            let mode = session.selectionMode(shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
            // 在「新建」模式下，于选区内拖动会移动轮廓，而不是绘制。
            if mode == .replace, session.canMoveSelection(at: pixel), session.beginSelectionMove() {
                selectionDragStart = pixel
                Self.moveSelectionCursor.set()
                return
            }
            if session.tool == .wand, session.wandMode == .object {
                Task { await session.selectObject(at: pixel, mode: mode); synchronizeDisplay(); refreshLassoCursor() }
                return
            }
            if session.tool == .wand {
                Task { await session.magicWand(at: pixel, mode: mode); synchronizeDisplay(); refreshLassoCursor() }
                return
            }
            session.beginLasso(at: session.tool == .marquee ? snappedCorner(pixel, flags: event.modifierFlags) : pixel, mode: mode)
            synchronizeDisplay()
            return
        }
        let first = session.viewport.viewPoint(from: draft.points[0], documentSize: document.size)
        if event.clickCount >= 2 || (draft.points.count >= 3 && hypot(point.x - first.x, point.y - first.y) <= 8) {
            session.finishLasso()
        } else {
            session.extendLasso(to: pixel)
        }
        synchronizeDisplay()
    }

    /// 只有存在可见选区时，蚂蚁线才会动。
    private func updateAntsTimer() {
        let active = session.selection?.isEmpty == false && window != nil
        if active, antsTimer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                // 若还有待处理的重绘，本帧跳过：宁可让缓慢的轮廓出现跳动，也不要无限排队重绘。
                guard let self, !self.transformOverlay.needsDisplay else { return }
                self.transformOverlay.antsPhase = (self.transformOverlay.antsPhase + 1).truncatingRemainder(dividingBy: 8)
                self.transformOverlay.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !active, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }

    /// 抓取一个已有的端点，或在指针处开始一条新线。
    private func beginGradientDrag(at point: CGPoint) {
        guard let document = session.document else { return }
        if let geometry = transformOverlay.gradientLine {
            if hypot(point.x - geometry.end.x, point.y - geometry.end.y) <= 10 { gradientDrag = .end; return }
            if hypot(point.x - geometry.start.x, point.y - geometry.start.y) <= 10 { gradientDrag = .start; return }
        }
        session.beginGradient(at: session.viewport.documentPoint(from: point, documentSize: document.size))
        gradientDrag = session.gradientEdit == nil ? nil : .end
        synchronizeDisplay()
    }

    /// 与 Photoshop 一样，按住 Shift 会把线约束在 45° 的步进上。
    private static func snapped(_ point: CGPoint, around anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    private func sampleColor(at point: CGPoint) {
        guard let document = session.document else { return }
        Self.eyedropperCursor.set()
        let documentPoint = session.viewport.documentPoint(from: point, documentSize: document.size)
        if session.colorPicker != nil { session.sampleIntoColorPicker(at: documentPoint) }
        else if session.canEditPalette, let color = session.sampleCompositeColor(at: documentPoint) {
            session.foregroundColor = color
        }
        sampleRing.frame = CGRect(x: point.x - 58, y: point.y - 58, width: 116, height: 116)
        sampleRing.original = samplingOriginal
        sampleRing.sampled = session.colorPicker?.color ?? session.foregroundColor
        sampleRing.isHidden = !session.showsSampleRing
        sampleRing.needsDisplay = true
    }

    private var renderBounds: CGRect? {
        guard let document = session.document else { return nil }
        let original = CGRect(origin: .zero, size: document.size)
        return session.tool == .crop ? original.union(session.cropRect ?? original) : original
    }

    private func beginCropDrag(at point: CGPoint) {
        guard let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let rect = session.visibleCropRect ?? CGRect(origin: pixel, size: .zero)
        let mode: CropDrag.Mode
        if let region = transformOverlay.cropResizeRegions.first(where: { $0.rect.contains(point) }) {
            mode = .resize(region.index)
        } else if session.cropRect?.contains(pixel) == true,
                  rect != CGRect(origin: .zero, size: document.size) { mode = .move }
        else { mode = .create; session.cropRect = nil }
        cropDrag = CropDrag(start: pixel, original: rect, mode: mode)
        let targets = session.cropSnapTargets()
        cropSnap = CropSnap(xs: targets.xs, ys: targets.ys, tolerance: Self.cropSnapDistance / max(session.viewport.pointsPerPixel, 0.0001))
        dragCursor = .current
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
    }

    /// 针对位于 `point`（视图坐标）的指针调整裁剪框：Option 保持裁剪框中心不动，
    /// 各边会吸附到附近的图层边缘与画布边缘，除非按住 Control。
    private func dragCrop(_ drag: CropDrag, to point: CGPoint, flags: NSEvent.ModifierFlags, documentSize: CGSize) {
        let pixel = session.viewport.documentPoint(from: point, documentSize: documentSize)
        let symmetric = flags.contains(.option)
        var next = drag.updated(to: pixel, ratio: session.cropRatio, symmetric: symmetric)
        if let cropSnap, session.snappingEnabled, !flags.contains(.control) {
            next = cropSnap.apply(next, drag: drag, point: pixel, ratio: session.cropRatio, symmetric: symmetric)
        }
        if CropGeometry.valid(next) { session.cropRect = next }
    }

    private func beginGuideDrag(at point: CGPoint) -> Bool {
        guard session.canEditGuides, let guide = session.hitGuide(at: point) else { return false }
        session.beginGuideMove(guide)
        guideDragging = true
        dragCursor = guide.axis == .vertical ? .resizeLeftRight : .resizeUpDown
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
        return true
    }

    /// 移动工具下双击：在指针下最上层的可编辑文字上打开文字编辑器。
    private func beginLiveTextEdit(at point: CGPoint) -> Bool {
        guard let document = session.document, session.canEditLayers else { return false }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let visible = document.effectiveVisibleIDs
        guard let layer = document.layers.reversed().first(where: {
            visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(pixel)
        }) else { return false }
        session.commitTransform()
        session.selectLayer(layer.id)
        session.editActiveText()
        synchronizeInlineText()
        return true
    }

    /// 在顶部或左侧的标尺条上松开，该区域位于画布之外。
    func isOverRuler(_ point: CGPoint) -> Bool {
        session.showsRulers && (point.x < 0 || point.y < 0)
    }

    func documentPosition(axis: CanvasGuide.Axis, at point: CGPoint) -> Double? {
        guard let document = session.document else { return nil }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        return Double(axis == .vertical ? pixel.x : pixel.y)
    }

    private func beginTransformDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard session.canEditLayers || session.transformEdit != nil, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        var mode = transformOverlay.geometry?.hit(point)
        if mode == nil, let target = transformPressLayer(at: pixel, flags: modifiers) {
            // Cmd-Shift-单击把指针下的图层加入选区（再按一次则移出）；单独 Cmd-单击则只选中该图层。
            if target.picked, modifiers.contains(.command), modifiers.contains(.shift) {
                session.extendSelection(with: target.id)
            } else if target.picked {
                session.selectLayer(target.id)
            }
            mode = .move
        }
        guard var mode else { return }
        if case .move = mode { duplicatesTransformOnDrag = modifiers.contains(.option) }
        else { duplicatesTransformOnDrag = false }
        // 先提交移动栏中输入框尚未敲定的数值：这次拖动本身就是一次独立的编辑。
        if session.transformEdit?.fromFields == true { session.commitTransform() }
        if session.transformEdit == nil { session.beginTransform(persistent: false) }
        // 与 Photoshop 一样，Cmd-拖动手柄即进入变形；一旦变形，手柄会持续执行变形。
        if case .resize(let index) = mode, modifiers.contains(.command) || session.transformEdit?.corners != nil {
            session.beginDistort()
            if session.transformEdit?.corners != nil { mode = .distort(index) }
        }
        guard let transform = session.transformEdit?.draft else { return }
        transformDrag = TransformDrag(original: transform, start: pixel, mode: mode, originalCorners: session.transformEdit?.corners)
        switch mode {
        case .resize(let index): dragCursor = transformOverlay.geometry?.resizeCursor(for: index) ?? .arrow
        case .rotate: dragCursor = Self.rotationCursor
        case .move: dragCursor = duplicatesTransformOnDrag ? Self.duplicateCursor : Self.moveCursor
        case .distort: dragCursor = Self.distortCursor
        }
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
        dragCursor?.set()
    }

    private func releaseDragCursor() {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, dragCursor != nil else { return }
        dragCursor = nil
        cursorLockWindow?.enableCursorRects()
        cursorLockWindow?.invalidateCursorRects(for: self)
        cursorLockWindow = nil
        if let window, session.tool == .move {
            updateTransformCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
}

// MARK: GPU 画布

extension CanvasView {
    /// 在 GPU 上绘制该帧（见 `GPUCanvasRenderer`），并报告是否成功。当画布上的某些内容必须改用
    /// Core Graphics 画布时——绘制、正在编辑的文字、变形、GPU 不支持的调整——Metal 视图会隐藏，
    /// 该帧照旧由 Core Graphics 绘制。
    func drawOnGPU(_ dirtyRect: NSRect) -> Bool {
        // 仅限屏幕显示：视图的快照（测试用的或打印用的）仍由 Core Graphics 绘制。
        guard allowsGPU, !snapshotting, !Self.gpuDisabled, window != nil, NSGraphicsContext.current?.isDrawingToScreen == true,
              let renderer = GPUCanvasRenderer.shared, let document = session.document else {
            return hideGPUView(dirtyRect)
        }
        let view = gpuView ?? makeGPUView()
        let scale = session.viewport.backingScale
        view.fit(scale: scale)
        guard let frame = gpuFrame(document, renderer: renderer, size: view.metalLayer.drawableSize) else {
            return hideGPUView(dirtyRect)
        }
        if view.isHidden { view.isHidden = false }
        renderer.present(frame, in: view.metalLayer)
        return true
    }

    /// 打开 `CompositorCPUCanvas` 可让每一帧都由 Core Graphics 绘制，以便两者对比。
    static let gpuDisabled = UserDefaults.standard.bool(forKey: "CompositorCPUCanvas")

    private func makeGPUView() -> MetalCanvasView {
        let view = MetalCanvasView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: subviews.first)
        gpuView = view
        return view
    }

    /// 重新露出 Core Graphics 画布。GPU 显示该帧期间它一直没有被绘制，因此局部重绘会让其余部分
    /// 停留在旧状态：GPU 的最后一帧会一直保留，直到整个视图都画完。
    private func hideGPUView(_ dirtyRect: NSRect) -> Bool {
        guard let view = gpuView, !view.isHidden else { return false }
        if dirtyRect.contains(bounds) {
            view.isHidden = true
            return false
        }
        DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        return true
    }

    /// GPU 会绘制的那一帧，横跨 `size` 个屏幕像素，用于与 Core Graphics 画布对比。
    func gpuFrame(size: CGSize) -> CIImage? {
        guard let renderer = GPUCanvasRenderer.shared, let document = session.document else { return nil }
        return gpuFrame(document, renderer: renderer, size: size)
    }

    /// 正在拖出的形状，由 `drawShapeDraft` 绘制到一块刚好容纳它的位图上，单位为帧像素。
    private func shapeDraftImage(placement: GPUPlacement) -> CIImage? {
        guard let draft = session.shapeDraft, let renderer = GPUCanvasRenderer.shared else { return nil }
        let reach = CGFloat(session.shapeLineWidth) * placement.scale + 4
        let box = draft.rect.applying(placement.mapping).insetBy(dx: -reach, dy: -reach).integral
        guard box.width >= 1, box.height >= 1, box.width * box.height <= DocumentLimits.maxSurfaceExtent,
              let context = try? BrushRaster.context(width: Int(box.width), height: Int(box.height), mask: false) else { return nil }
        context.translateBy(x: -box.minX, y: -box.minY)
        drawShapeDraft(scale: placement.scale, center: { $0.applying(placement.mapping) }, in: context)
        guard let image = context.makeImage(), let drawn = renderer.image(image, transient: true) else { return nil }
        return drawn.transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
    }

    /// 整个视图按 `draw(_:)` 的样子绘制——背景、文档的阴影与棋盘格、各图层以及文档边缘——
    /// 单位为屏幕像素，横跨 `size`。当必须由 Core Graphics 画布绘制时为 nil。
    private func gpuFrame(_ document: CanvasDocument, renderer: GPUCanvasRenderer, size: CGSize) -> CIImage? {
        let viewport = session.viewport
        let device = viewport.backingScale
        let pixels = renderBounds ?? CGRect(origin: .zero, size: document.size)
        let origin = viewport.documentRect(document.size).origin
        let perPixel = viewport.pointsPerPixel * device
        let mapping = CGAffineTransform(a: perPixel, b: 0, c: 0, d: perPixel, tx: origin.x * device, ty: origin.y * device)
        let full = CGRect(origin: .zero, size: size)
        let rect = pixels.applying(mapping)
        func gray(_ white: CGFloat, alpha: CGFloat = 1) -> CIImage {
            CIImage(color: CIColor(red: white, green: white, blue: white, alpha: alpha))
        }
        var frame = gray(0.105).cropped(to: full)
        guard rect.intersects(full) else { return frame }
        // 先画文档阴影，再画棋盘格：自其左上角起铺 10 点的方格。
        let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: 0, y: 3 * device)).applyingGaussianBlur(sigma: 7 * device)
        frame = shadow.composited(over: frame)
        let tile = 10 * device
        let squares = gray(0.35).cropped(to: CGRect(x: 0, y: 0, width: tile, height: tile))
            .composited(over: gray(0.30).cropped(to: CGRect(x: tile, y: 0, width: tile, height: tile)))
            .composited(over: gray(0.30).cropped(to: CGRect(x: 0, y: tile, width: tile, height: tile)))
            .composited(over: gray(0.35).cropped(to: CGRect(x: tile, y: tile, width: tile, height: tile)))
        let offset = NSAffineTransform()
        offset.translateX(by: rect.minX, yBy: rect.minY)
        let checkerboard = squares.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: offset]).cropped(to: rect)
        frame = checkerboard.composited(over: frame)
        // 从 200% 起，文档自身的像素一对一合成，并以清晰的方块放大。
        let crisp = viewport.zoom >= Self.crispZoom
        let placement = GPUPlacement(mapping: crisp ? .identity : mapping, scale: crisp ? 1 : perPixel, renderer: renderer)
        guard var layers = gpuLayers(document, placement: placement) else { return nil }
        if crisp { layers = layers.cropped(to: pixels).samplingNearest().transformed(by: mapping) }
        frame = layers.cropped(to: rect).composited(over: frame)
        // 文档边缘：以它为中心的一像素宽线条。
        let edge = gray(1, alpha: 0.13)
        for line in [CGRect(x: rect.minX - 0.5, y: rect.minY - 0.5, width: rect.width + 1, height: 1),
                     CGRect(x: rect.minX - 0.5, y: rect.maxY - 0.5, width: rect.width + 1, height: 1),
                     CGRect(x: rect.minX - 0.5, y: rect.minY + 0.5, width: 1, height: rect.height - 1),
                     CGRect(x: rect.maxX - 0.5, y: rect.minY + 0.5, width: 1, height: rect.height - 1)] {
            frame = edge.cropped(to: line).composited(over: frame)
        }
        return frame.cropped(to: full)
    }

    /// 各图层按 `drawLayers` 的方式合成在空白之上。当某图层必须由 Core Graphics 画布绘制时为 nil。
    private func gpuLayers(_ document: CanvasDocument, placement: GPUPlacement) -> CIImage? {
        handOffTextEffects(document)
        session.effectsPreviews.prepare(layers: document.layers)
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let ids = document.renderLayers.map(\.id)
        // 剪贴堆叠，结构与 `LiveMaskRenderer.prepareStacks` 找出的相同。
        var stacks: [UUID: [UUID]] = [:], stacked = Set<UUID>()
        for (index, base) in ids.enumerated() where byID[base]?.maskSourceID == nil && byID[base]?.adjustment == nil {
            var children: [UUID] = []
            for child in ids.dropFirst(index + 1) {
                guard byID[child]?.maskSourceID == base, byID[child]?.parentID == byID[base]?.parentID else { break }
                children.append(child)
            }
            guard !children.isEmpty else { continue }
            stacks[base] = children
            stacked.formUnion(children)
        }
        // 文件夹蒙版，各自放置一次。
        var folderMasks: [UUID: CIImage?] = [:]
        func folderMask(_ id: UUID) -> CIImage? {
            if let known = folderMasks[id] { return known }
            let placed: CIImage? = byID[id].flatMap { folder in
                guard let mask = folder.mask, mask.isEnabled else { return nil }
                if let edit = liveMaskEdit(for: id) { return paintedMask(edit) }
                return placement.place(mask.asset.image, transform: session.displayedTransform(for: folder), mask: true)
            }
            folderMasks[id] = placed
            return placed
        }
        func clippedByFolders(_ id: UUID, _ image: CIImage) -> CIImage {
            var result = image, folder = byID[id]?.parentID, depth = 0
            while let current = folder, depth < 64 {
                if let mask = folderMask(current) { result = GPUBlend.masked(result, by: mask) }
                folder = byID[current]?.parentID
                depth += 1
            }
            return result
        }
        var unsupported = false
        // 正在绘制的图层（或其蒙版——此时绘的是蒙版）在开始时的原始像素。
        func oldPixels(_ stroke: BrushStroke) -> CIImage? {
            let asset = stroke.isMask ? stroke.layer.mask?.asset : stroke.layer.asset
            if let raster = asset?.raster { return placement.renderer.image(raster) }
            return asset.flatMap { placement.renderer.image($0.image, mask: stroke.isMask) }
        }
        // 正在绘制的蒙版，以其笔触网格呈现：原值（并显露其外区域）叠加笔触的瓦片，
        // 拖动渐变时则是叠加在其上的渐变。
        func maskGrid(_ stroke: BrushStroke) -> CIImage? {
            guard let edit = session.gradientEdit, edit.raster === stroke else {
                return placement.renderer.image(stroke, base: oldPixels(stroke))
            }
            let gridRect = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
            var grid = CIImage(color: .white).cropped(to: gridRect)
            if let old = oldPixels(stroke) { grid = inGrid(old, stroke: stroke).composited(over: grid) }
            if edit.hasLine, let fill = edit.fill, let shading = gradient(fill, stroke: stroke) { grid = shading.composited(over: grid) }
            return grid.cropped(to: gridRect)
        }
        func paintedMask(_ stroke: BrushStroke) -> CIImage? {
            guard let grid = maskGrid(stroke) else { return nil }
            return placement.place(live: grid, width: stroke.width, height: stroke.height, transform: stroke.paintTransform)
        }
        // 覆盖图层原始像素的图像，按其所处位置放入笔触网格。
        func inGrid(_ image: CIImage, stroke: BrushStroke) -> CIImage {
            let source = stroke.sourceRect
            return image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: source.width / image.extent.width, y: source.height / image.extent.height)
                .concatenating(CGAffineTransform(translationX: source.minX, y: source.minY))).cropped(to: source)
        }
        // 绘制图层像素期间该图层的自有蒙版；当蒙版被独立放置时重采样进图层网格——
        // 与 `drawOwn` 的处理一致。
        func paintingMask(_ layer: ImageLayer, stroke: BrushStroke) -> CGImage? {
            guard let owned = layer.mask else { return nil }
            guard let maskPlacement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
            let base = stroke.layer.transform
            let drawn = max(base.size.width, base.size.height) * placement.scale
            let steady = pow(2, ceil(log2(max(64, drawn))))
            return owned.clipImage(placement: maskPlacement, over: base,
                width: stroke.layer.asset?.image.width ?? Int(base.size.width.rounded()),
                height: stroke.layer.asset?.image.height ?? Int(base.size.height.rounded()),
                limit: session.transformEdit != nil ? min(2048, steady) : steady)
        }
        // Option-单击蒙版缩略图：单独显示该蒙版，在整块画布上呈灰色（超出其像素处沿用边缘色调），
        // 其中铺入正在拖动的笔触或渐变——与 `drawMaskAlone` 在 Core Graphics 画布上的画法相同。
        if let layer = session.maskAloneLayer, let mask = layer.mask {
            let edge = LayerMask.background(of: mask.asset.thumbnail)
            let back = CIImage(color: CIColor(red: edge, green: edge, blue: edge))
                .cropped(to: CGRect(origin: .zero, size: document.size).applying(placement.mapping))
            let placed: CIImage?
            if let stroke = session.brushStroke ?? session.gradientEdit?.raster, stroke.isMask, stroke.layer.id == layer.id {
                placed = paintedMask(stroke)
            } else {
                placed = placement.place(mask.asset.image, transform: session.displayedMaskPlacement(for: layer)
                    ?? session.displayedTransform(for: layer), mask: true)
            }
            // 蒙版的数值存放在其红色通道中；显示时呈灰色。
            let gray = placed?.applyingFilter("CIColorMatrix", parameters: ["inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                                                                            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
            return gray.map { $0.composited(over: back) } ?? back
        }
        // 正在绘制或被赋予渐变的图层：其网格按笔触完成后的状态呈现（绘制蒙版时，则是原始像素
        // 透过即将完成的蒙版呈现），并通过其自有蒙版作用于原始像素所在的区域——画出该范围之外的部分可见。
        func painted(_ layer: ImageLayer, stroke: BrushStroke, opacity: Double) -> CIImage? {
            let gridRect = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
            let placedApart = stroke.isMask && stroke.layer.mask?.placement != nil
            // 独立放置的蒙版在自己的网格中绘制；图层则按其所在位置绘制。
            let transform = placedApart ? session.displayedTransform(for: layer) : stroke.paintTransform
            // 开启图层样式后，会随绘制过程重做（见 LayerEffectsSurface），取自笔触的瓦片
            // ——渐变与像素移动只会在有内容读取它们时才填充这些瓦片。
            if layer.effects?.visible.isEmpty == false {
                if let edit = session.gradientEdit, edit.raster === stroke { try? edit.applyFill() }
                if let move = session.pixelMove, move.raster === stroke { try? move.applyOffset() }
                let surface: LayerEffectsSurface?
                if placedApart, let maskPlacement = stroke.layer.mask?.placement {
                    surface = stroke.placedMaskPreview(placement: stroke.paintTransform).flatMap {
                        placedMaskSurface(layer: layer, stroke: stroke, placement: maskPlacement, preview: $0)
                    }
                } else {
                    surface = strokeSurface(layer: layer, stroke: stroke, mask: stroke.isMask ? nil : paintingMask(layer, stroke: stroke))
                }
                if let surface, let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    guard let image = placement.place(transient: built, transform: grown) else { return nil }
                    return GPUBlend.faded(image, opacity)
                }
            }
            // 绘制独立放置的蒙版：图层按其所在位置绘制，并透过笔触完成后的蒙版呈现，
            // 该蒙版已重采样进图层网格。
            if placedApart {
                let pixels: CIImage?
                if let raster = layer.asset?.raster { pixels = placement.place(raster, transform: transform) }
                else { pixels = layer.asset.flatMap { placement.place($0.image, transform: transform) } }
                guard var image = pixels else { return nil }
                if let preview = stroke.placedMaskPreview(placement: stroke.paintTransform) {
                    guard let mask = placement.place(transient: preview, transform: transform, mask: true) else { return nil }
                    image = GPUBlend.masked(image, by: mask)
                }
                return GPUBlend.faded(image, opacity)
            }
            var grid: CIImage
            if stroke.isMask {
                guard let mask = maskGrid(stroke) else { return nil }
                let pixels: CIImage?
                if let raster = layer.asset?.raster { pixels = placement.renderer.image(raster) }
                else { pixels = layer.asset.flatMap { placement.renderer.image($0.image) } }
                guard let pixels else { return nil }
                grid = GPUBlend.masked(inGrid(pixels, stroke: stroke), by: mask)
            } else if let edit = session.gradientEdit, edit.raster === stroke {
                // 拖动时在此绘制的渐变；其瓦片在提交时才填充一次。
                grid = oldPixels(stroke).map { inGrid($0, stroke: stroke) } ?? CIImage.empty()
                if edit.hasLine, let fill = edit.fill, let fillImage = gradient(fill, stroke: stroke) {
                    grid = fillImage.composited(over: grid)
                }
                grid = grid.cropped(to: gridRect)
            } else {
                guard let image = placement.renderer.image(stroke, base: oldPixels(stroke)) else { return nil }
                grid = image
            }
            // 图层的自有蒙版覆盖其原始像素所在的区域。
            if !stroke.isMask, let mask = paintingMask(layer, stroke: stroke), let placed = placement.renderer.image(mask, mask: true) {
                grid = GPUBlend.masked(grid, by: inGrid(placed, stroke: stroke).composited(over: CIImage(color: .white).cropped(to: gridRect)))
            }
            guard let image = placement.place(live: grid, width: stroke.width, height: stroke.height, transform: transform)
            else { return nil }
            return GPUBlend.faded(image, opacity)
        }
        // 笔触网格中的渐变填充：作用于画布与选区之上，透明度取该填充的设置。
        func gradient(_ fill: GradientEdit.Fill, stroke: BrushStroke) -> CIImage? {
            func color(_ value: CGColor) -> CIColor {
                // 蒙版的灰度就是其数值，按原样绘制进蒙版的灰度像素中；颜色则转换为 sRGB。
                let c = value.colorSpace?.model == .monochrome ? value.components ?? [0, 1]
                    : value.converted(to: placement.renderer.space, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
                return CIColor(red: c[0], green: c.count > 2 ? c[1] : c[0], blue: c.count > 2 ? c[2] : c[0], alpha: c.last ?? 1,
                               colorSpace: placement.renderer.space) ?? .black
            }
            guard fill.colors.count == 2 else { return nil }
            let shading: CIImage
            switch fill.shape {
            case .linear:
                shading = CIImage.empty().applyingFilter("CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: fill.start), "inputPoint1": CIVector(cgPoint: fill.end),
                    "inputColor0": color(fill.colors[0]), "inputColor1": color(fill.colors[1])])
            case .radial:
                shading = CIImage.empty().applyingFilter("CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: fill.start), "inputRadius0": 0,
                    "inputRadius1": hypot(fill.end.x - fill.start.x, fill.end.y - fill.start.y),
                    "inputColor0": color(fill.colors[0]), "inputColor1": color(fill.colors[1])])
            }
            let toGrid = stroke.pixelToDocument.inverted()
            var coverage = CIImage(color: .white).cropped(to: stroke.canvas)
            if let clip = stroke.selectionClip {
                guard let selection = clip.coverage.flatMap({ placement.renderer.image($0, mask: true) }) else { return nil }
                let placed = selection.transformed(by: CGAffineTransform(scaleX: clip.rect.width / selection.extent.width,
                                                                         y: clip.rect.height / selection.extent.height)
                    .concatenating(CGAffineTransform(translationX: clip.rect.minX, y: clip.rect.minY)))
                coverage = coverage.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.black,
                                                                                      kCIInputMaskImageKey: placed])
            }
            let shaded = GPUBlend.faded(GPUBlend.masked(shading, by: coverage), Double(fill.opacity))
            return shaded.transformed(by: toGrid)
        }
        // 单个图层的像素，按其位置放置、透过自有蒙版、并按其不透明度绘制——即 `drawOwn` 的内容。
        func own(_ layer: ImageLayer) -> CIImage? {
            let opacity = layer.effectiveOpacity(in: byID)
            // 正在编辑的文字，按提交后的样子绘制。
            if layer.id == session.textDraft?.layerID {
                guard let shown = editedText(layer) else { return nil }
                guard let image = placement.place(shown.image, transform: shown.transform) else { unsupported = true; return nil }
                return GPUBlend.faded(image, opacity)
            }
            // 涂抹或液化进行中：图层按笔触到目前为止的形变，铺满整块画布。
            if let warp = session.warpStroke, warp.layer.id == layer.id, warp.gpu != nil || warp.image != nil {
                let canvas = LayerTransform(origin: .zero, size: document.size)
                // 在 GPU 上直接就地从 dab 运行处绘制；否则按当前状态上传。
                let shown: CIImage?
                if let working = warp.gpu?.image {
                    shown = placement.place(live: working, width: warp.width, height: warp.height, transform: canvas)
                } else {
                    shown = warp.image.flatMap { placement.place(transient: $0, transform: canvas) }
                }
                guard var placed = shown else { unsupported = true; return nil }
                if let mask = layer.mask?.clipImage(placement: layer.maskTransform, over: canvas, width: warp.width, height: warp.height, limit: 2048) {
                    guard let placedMask = placement.place(mask, transform: canvas, mask: true) else { unsupported = true; return nil }
                    placed = GPUBlend.masked(placed, by: placedMask)
                }
                return GPUBlend.faded(placed, opacity)
            }
            let stroke = session.brushStroke?.layer.id == layer.id ? session.brushStroke
                : session.gradientEdit?.raster.layer.id == layer.id ? session.gradientEdit?.raster : nil
            if let stroke {
                guard let image = painted(layer, stroke: stroke, opacity: opacity) else { unsupported = true; return nil }
                return image
            }
            // 移动中的像素：把选区抠掉的图层（整层全抠，即复制），以及浮在其上的被提起像素。
            // 存在蒙版或图层样式时，取自移动后各瓦片的状态，画法与笔触相同。
            if let move = session.pixelMove, move.raster.layer.id == layer.id, !move.drawsOnGPU {
                try? move.applyOffset()
                guard let image = painted(layer, stroke: move.raster, opacity: opacity) else { unsupported = true; return nil }
                return image
            }
            if let move = session.pixelMove, move.raster.layer.id == layer.id {
                let stroke = move.raster
                guard let lifted = stroke.lifted, let target = stroke.liftedTarget(offset: move.offset),
                      let rest = move.duplicate ? stroke.original : stroke.holed,
                      let below = placement.place(rest, transform: stroke.transform(for: stroke.sourceRect)),
                      let above = placement.place(lifted.image, transform: stroke.transform(for: target)) else {
                    unsupported = true
                    return nil
                }
                return GPUBlend.faded(above.composited(over: below), opacity)
            }
            guard layer.asset != nil || session.filterEdit?.previewImage(for: layer.id) != nil else { return nil }
            // 变形进行中且带有图层样式：把样式一起扭曲到新形状中（与 Core Graphics 画布相同）。
            if layer.effects?.visible.isEmpty == false, let edit = session.transformEdit, !edit.mask, edit.corners != nil,
               let effects = session.effectsPreviews.preview(for: layer,
                    mask: layer.mask?.clipImage(placement: session.displayedMaskPlacement(for: layer), over: layer.transform,
                        width: layer.asset?.image.width ?? Int(layer.size.width.rounded()),
                        height: layer.asset?.image.height ?? Int(layer.size.height.rounded()), limit: 2048),
                    transform: layer.transform, maskPlacement: session.displayedMaskPlacement(for: layer),
                    completion: { [weak self] in self?.needsDisplay = true }),
               let warped = session.distortedEffects(for: layer, effects: effects.image, inset: effects.inset) {
                guard let image = placement.place(warped.image, transform: warped.transform) else { unsupported = true; return nil }
                return GPUBlend.faded(image, opacity)
            }
            // 不带图层样式时：在此以透视方式把图层纳入新形状；当蒙版覆盖图层自身的像素时，蒙版一同处理。
            // 形状发生翻折、或蒙版被独立放置时，则在 CPU 上完成变形并从那里绘制。
            if let target = session.distortShape(for: layer), let image = layer.asset?.image,
               layer.mask.map({ $0.placement == nil && $0.isLinked }) ?? true,
               var warped = placement.warp(image, transform: target.transform, corners: target.corners) {
                if let mask = layer.mask?.enabledImage {
                    guard let shape = placement.warp(mask, transform: target.transform, corners: target.corners, mask: true)
                    else { unsupported = true; return nil }
                    warped = GPUBlend.masked(warped, by: shape)
                }
                return GPUBlend.faded(warped, opacity)
            }
            if let distorted = session.distortPreview(for: layer) {
                guard var image = placement.place(distorted.image, transform: distorted.transform) else { unsupported = true; return nil }
                if let mask = distorted.mask.flatMap({ placement.place($0, transform: distorted.transform, mask: true) }) {
                    image = GPUBlend.masked(image, by: mask)
                }
                return GPUBlend.faded(image, opacity)
            }
            let transform = session.displayedTransform(for: layer)
            // 独立于图层放置的蒙版会重采样进图层网格，与 Core Graphics 画布的处理一致。
            let mask: CGImage? = {
                guard let owned = layer.mask else { return nil }
                if let distorted = session.maskDistortPreview(for: layer) { return distorted }
                guard let maskPlacement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
                let drawn = max(transform.size.width, transform.size.height) * placement.scale
                let steady = pow(2, ceil(log2(max(64, drawn))))
                return owned.clipImage(placement: maskPlacement, over: transform,
                    width: layer.asset?.image.width ?? Int(transform.size.width.rounded()),
                    height: layer.asset?.image.height ?? Int(transform.size.height.rounded()),
                    limit: session.transformEdit != nil ? min(2048, steady) : steady)
            }()
            if layer.asset != nil,
               let effects = session.effectsPreviews.preview(for: layer, mask: mask, transform: transform,
                    maskPlacement: session.displayedMaskPlacement(for: layer), completion: { [weak self] in
                        self?.needsDisplay = true
                    }) {
                let grown = effects.placement ?? LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
                guard let image = placement.place(effects.image, transform: grown) else { unsupported = true; return nil }
                return GPUBlend.faded(image, opacity)
            }
            let placed: CIImage?
            if let shaped = session.shapeTransformPreview(for: layer, transform: transform) {
                placed = placement.place(shaped, transform: transform)
            } else if let raster = layer.asset?.raster, session.hueSaturation?.previewImage(for: layer.id) == nil,
                      session.levels?.previewImage(for: layer.id) == nil, session.filterEdit?.previewImage(for: layer.id) == nil {
                placed = placement.place(raster, transform: transform)
            } else if let image = session.filterEdit?.previewImage(for: layer.id) ?? session.levels?.previewImage(for: layer.id)
                        ?? session.hueSaturation?.previewImage(for: layer.id) ?? layer.asset?.image {
                placed = placement.place(image, transform: transform)
            } else { return nil }
            guard var image = placed else { unsupported = true; return nil }
            if let mask {
                guard let placedMask = placement.place(mask, transform: transform, mask: true) else { unsupported = true; return nil }
                image = GPUBlend.masked(image, by: placedMask)
            }
            return GPUBlend.faded(image, opacity)
        }
        // 调整图层透过其自有蒙版及所属文件夹的各层蒙版，按其不透明度为下方内容重新着色。
        func adjusted(_ below: CIImage, by layer: ImageLayer, adjustment: LayerAdjustment, folders: Bool) -> CIImage? {
            guard var changed = GPUAdjustment.apply(adjustment, to: below, scale: placement.scale, mapping: placement.mapping)
            else { return nil }
            // 在混合模式下，调整后的颜色以全覆盖与其下方颜色混合，之后再把原始覆盖度还原回来
            // ——与 LiveMaskRenderer 的做法相同，这样柔边不会被加重。
            let mode = session.displayedBlendMode(for: layer)
            if mode != .normal {
                func opaque(_ image: CIImage) -> CIImage {
                    image.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                }
                changed = GPUBlend.blend(opaque(changed), over: opaque(below), mode: mode)
                    .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                         kCIInputMaskImageKey: below])
            }
            var coverage: CIImage?
            func multiply(_ mask: CIImage) {
                coverage = coverage.map {
                    $0.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.black,
                                                                          kCIInputMaskImageKey: mask])
                } ?? mask
            }
            if layer.mask?.isEnabled == true, let edit = liveMaskEdit(for: layer.id), let placed = paintedMask(edit) {
                multiply(placed)
            } else if let own = layer.mask?.enabledImage, let placed = placement.place(own, transform: layer.transform, mask: true) {
                multiply(placed)
            }
            if folders {
                var folder = layer.parentID, depth = 0
                while let current = folder, depth < 64 {
                    if let mask = folderMask(current) { multiply(mask) }
                    folder = byID[current]?.parentID
                    depth += 1
                }
            }
            let opacity = layer.effectiveOpacity(in: byID)
            if opacity < 1 {
                multiply(CIImage(color: CIColor(red: opacity, green: opacity, blue: opacity)))
            }
            guard let coverage else { return changed }
            return changed.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: below,
                                                                              kCIInputMaskImageKey: coverage])
        }
        // 通过取蒙版来源那一层的覆盖度显示的图层——该层本身也按其绘制方式、再透过它自己的来源呈现
        // ——与 LiveMaskRenderer 的画法相同。
        var visiting = Set<UUID>()
        func live(_ layer: ImageLayer) -> CIImage? {
            guard let image = own(layer) else { return nil }
            guard let sourceID = layer.maskSourceID else { return image }
            guard let source = byID[sourceID], !visiting.contains(sourceID), visiting.count < 256 else { return CIImage.empty() }
            visiting.insert(sourceID)
            defer { visiting.remove(sourceID) }
            guard let coverage = live(source) else { return unsupported ? nil : CIImage.empty() }
            return image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                             kCIInputMaskImageKey: coverage])
        }
        // 正在拖出的形状与新建的文字会出现在其图层将要所处的位置：当前图层正上方；
        // 若该处没有绘制，则新文字置于最上层（见 `drawLayers`）。
        var drewNewText = false
        func drafts(after id: UUID, over image: CIImage) -> CIImage {
            guard id == session.activeLayerID else { return image }
            var result = image
            if let shape = shapeDraftImage(placement: placement) { result = shape.composited(over: result) }
            if session.textDraft?.layerID == nil, let text = draftText, let placed = placement.place(text.image, transform: text.transform) {
                result = placed.composited(over: result)
                drewNewText = true
            }
            return result
        }
        var result = CIImage.empty()
        for id in ids where !stacked.contains(id) {
            guard let layer = byID[id] else { continue }
            let mode = session.displayedBlendMode(for: layer)
            if let adjustment = layer.adjustment {
                guard layer.maskSourceID == nil else { continue }
                guard let changed = adjusted(result, by: layer, adjustment: adjustment, folders: true) else { return nil }
                result = changed
                continue
            }
            if let children = stacks[id] {
                // 基图层的像素不透明，承载被剪贴到它的各图层；整个堆叠随后沿用基图层的覆盖度。
                guard let base = own(layer) else {
                    if unsupported { return nil }
                    continue
                }
                var group = base.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                group = drafts(after: id, over: group)
                for childID in children {
                    guard let child = byID[childID] else { continue }
                    if let adjustment = child.adjustment {
                        guard let changed = adjusted(group, by: child, adjustment: adjustment, folders: false) else { return nil }
                        group = changed
                    } else if let image = own(child) {
                        group = GPUBlend.blend(image, over: group, mode: session.displayedBlendMode(for: child))
                    } else if unsupported { return nil }
                    group = drafts(after: childID, over: group)
                }
                let stack = group.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                                       kCIInputMaskImageKey: base])
                result = GPUBlend.blend(clippedByFolders(id, stack), over: result, mode: mode)
                continue
            }
            // 透过另一图层覆盖度做蒙版的图层，且不在剪贴堆叠之内。
            if let image = live(layer) {
                result = GPUBlend.blend(clippedByFolders(id, image), over: result, mode: mode)
            } else if unsupported { return nil }
            result = drafts(after: id, over: result)
        }
        if !drewNewText, session.textDraft?.layerID == nil, let text = draftText,
           let placed = placement.place(text.image, transform: text.transform) {
            result = placed.composited(over: result)
        }
        return result
    }
}
