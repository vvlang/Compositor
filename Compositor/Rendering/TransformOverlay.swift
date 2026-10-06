import AppKit

struct TransformOverlayGeometry: Equatable {
    let handles: [CGPoint]
    let rotationHandle: CGPoint
    /// 变形没有单一旋转角度，因此隐藏旋转手柄。
    let showsRotation: Bool

    init(transform: LayerTransform, viewport: CanvasViewport, documentSize: CGSize) {
        handles = LayerTransform.handles.map { viewport.viewPoint(from: transform.point($0), documentSize: documentSize) }
        rotationHandle = CGPoint(x: handles[1].x + sin(transform.radians) * 28,
                                 y: handles[1].y - cos(transform.radians) * 28)
        showsRotation = true
    }

    /// 变形的手柄：四个角点（文档像素）以及各边的中点。
    init(corners: [CGPoint], viewport: CanvasViewport, documentSize: CGSize) {
        let view = corners.map { viewport.viewPoint(from: $0, documentSize: documentSize) }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        handles = [view[0], middle(view[0], view[1]), view[1], middle(view[1], view[2]),
                   view[2], middle(view[2], view[3]), view[3], middle(view[3], view[0])]
        rotationHandle = handles[1]
        showsRotation = false
    }

    func hit(_ point: CGPoint) -> TransformDrag.Mode? {
        func near(_ other: CGPoint) -> Bool { hypot(point.x - other.x, point.y - other.y) <= 10 }
        if showsRotation, near(rotationHandle) { return .rotate }
        if let index = handles.firstIndex(where: near) { return .resize(index) }
        for (start, end, handle) in [(0, 2, 1), (2, 4, 3), (4, 6, 5), (6, 0, 7)] {
            let a = handles[start], b = handles[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            if (0...1).contains(t), hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= 10 {
                return .resize(handle)
            }
        }
        return nil
    }

    func resizeCursor(for index: Int) -> NSCursor {
        let angle = atan2(handles[2].y - handles[0].y, handles[2].x - handles[0].x)
        let offsets: [CGFloat] = [.pi / 4, .pi / 2, 3 * .pi / 4, 0, .pi / 4, .pi / 2, 3 * .pi / 4, 0]
        let direction = (Int(((angle + offsets[index]) / (.pi / 4)).rounded()) % 4 + 4) % 4
        let positions: [NSCursor.FrameResizePosition] = [.right, .bottomRight, .bottom, .topRight]
        return .frameResize(position: positions[direction], directions: [.inward, .outward])
    }
}

/// 独立的 overlay 层，这样选中图层时不必重绘图像像素。
final class TransformOverlay: NSView {
    let session: EditorSession
    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var geometry: TransformOverlayGeometry? {
        guard session.tool == .move, session.showsTransformControls || session.transformEdit?.persistent == true,
              let document = session.document else { return nil }
        // 选中了多个图层，或选中了文件夹：一个包围它们的框。
        if session.transformEdit?.group != nil || (session.transformEdit == nil && session.transformsAsGroup) {
            if let corners = session.transformEdit?.corners {
                return TransformOverlayGeometry(corners: corners, viewport: session.viewport, documentSize: document.size)
            }
            guard let box = session.transformEdit?.draft ?? session.groupTransformBox else { return nil }
            return TransformOverlayGeometry(transform: box, viewport: session.viewport, documentSize: document.size)
        }
        guard let layer = session.activeLayer, layer.asset != nil, !layer.isGroup, document.effectiveVisibleIDs.contains(layer.id) else { return nil }
        if let edit = session.transformEdit, edit.layerID == layer.id, let corners = edit.corners {
            return TransformOverlayGeometry(corners: corners, viewport: session.viewport, documentSize: document.size)
        }
        return TransformOverlayGeometry(transform: session.editedTransform(for: layer),
                                        viewport: session.viewport, documentSize: document.size)
    }

    /// 视图坐标系下待定的渐变线两端点。
    var gradientLine: (start: CGPoint, end: CGPoint)? {
        guard let edit = session.gradientEdit, edit.hasLine, let document = session.document else { return nil }
        return (session.viewport.viewPoint(from: edit.start, documentSize: document.size),
                session.viewport.viewPoint(from: edit.end, documentSize: document.size))
    }

    var antsPhase: CGFloat = 0

    // MARK: 蚂蚁线的细节层级
    //
    // 细节丰富的画作上，魔棒轮廓可能有几十万个边，每一步像素一个。若每个时钟周期都完整描边，
    // 缩小后它们会挤进几个屏幕像素，一次重绘可能耗时数秒——这曾经让 App 卡死。
    // 因此在 1:1 以下，复杂轮廓改用按屏幕分辨率描出的版本绘制：它在后台构建，
    // 并按 2 的幂次缩放档位缓存，这样边数永远不会超过屏幕可显示的像素数。

    /// 路径元素数不超过该值的轮廓一律完整绘制；选框与套索因此始终精确。
    private static let fullDetailLimit = 20_000
    private var antsSource: CGPath?
    private var antsSourceIsComplex = false
    /// 以文档坐标表示的屏幕分辨率轮廓，以及描出它时所用的缩放档位。
    private var antsLevel: (path: CGPath, step: CGFloat)?
    private var antsPendingStep: CGFloat?
    private var antsTask: Task<Void, Never>?

    /// 蚂蚁线描边的对象：选区本身；或在复杂轮廓且缩小时，改用其屏幕分辨率版本。
    /// 首版简化轮廓仍在描摹期间为 nil。
    private func antsOutline(for path: CGPath) -> CGPath? {
        if antsSource !== path {
            antsSource = path
            antsTask?.cancel()
            antsTask = nil
            antsLevel = nil
            antsPendingStep = nil
            var elements = 0
            path.applyWithBlock { _ in elements += 1 }
            antsSourceIsComplex = elements > Self.fullDetailLimit
        }
        let scale = session.viewport.pointsPerPixel * (window?.backingScaleFactor ?? 2)
        guard antsSourceIsComplex, scale < 1, let document = session.document else { return path }
        // 每个文档像素对应的屏幕像素数，向上取整到 2 的幂，这样缩放时不必每帧重新描摹。
        let step = min(1, pow(2, ceil(log2(max(scale, 1 / 4096)))))
        if antsLevel?.step != step, antsPendingStep != step {
            antsPendingStep = step
            antsTask?.cancel()
            let canvas = CGRect(origin: .zero, size: document.size)
            antsTask = Task { [weak self] in
                let traced = await Task.detached(priority: .userInitiated) { Self.traceOutline(path, canvas: canvas, step: step) }.value
                guard let self, !Task.isCancelled, self.antsSource === path, self.antsPendingStep == step else { return }
                self.antsPendingStep = nil
                if let traced { self.antsLevel = (traced, step) }
                self.needsDisplay = true
            }
        }
        // 在新档位描出之前，先沿用上一次的：短时间内可能略粗或略细，但绝不会卡顿。
        return antsLevel?.path
    }

    /// 把 `path` 填充进一张足够精细、填充起来很快的蒙版，平均到每文档像素 `step` 个屏幕像素，
    /// 再沿这些像素的边缘描出轮廓。只要有覆盖就算数，因此细窄的部分仍会保留轮廓而不至消失。
    private nonisolated static func traceOutline(_ path: CGPath, canvas: CGRect, step: CGFloat) -> CGPath? {
        let region = path.boundingBoxOfPath.intersection(canvas).integral
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        // 填充的代价大致等同于每个输出像素要穿过的边数，因此蒙版以不低于一半的分辨率填充，
        // 且最多约 40 百万像素。
        let fill = min(1, max(step, (40_000_000 / (region.width * region.height)).squareRoot()))
        func mask(_ width: Int, _ height: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        let fillWidth = max(1, Int((region.width * fill).rounded(.up))), fillHeight = max(1, Int((region.height * fill).rounded(.up)))
        guard let filled = mask(fillWidth, fillHeight) else { return nil }
        // 原点在左上角，因此蒙版的一行就是文档的一行，与描摹器的预期一致。
        filled.translateBy(x: 0, y: CGFloat(fillHeight))
        filled.scaleBy(x: fill, y: -fill)
        filled.translateBy(x: -region.minX, y: -region.minY)
        filled.addPath(path)
        filled.setFillColor(gray: 1, alpha: 1)
        filled.fillPath(using: .winding)
        guard let image = filled.makeImage() else { return nil }
        let width = max(1, Int((region.width * step).rounded(.up))), height = max(1, Int((region.height * step).rounded(.up)))
        guard let small = mask(width, height) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = small.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let line = bytes + row * small.bytesPerRow
            for column in 0..<width where line[column] > 0 { pixels[row * width + column] = 255 }
        }
        guard let traced = try? MagicWand.outline(of: pixels, width: width, height: height) else { return nil }
        var toDocument = CGAffineTransform(translationX: region.minX, y: region.minY).scaledBy(x: 1 / step, y: 1 / step)
        return traced.copy(using: &toDocument)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLayoutGrid()
        drawGuides()
        if session.tool == .crop { drawCrop() }
        else if let line = gradientLine { drawGradientLine(line) }
        else { drawTransformHandles() }
        drawSelection()
        drawLassoDraft()
        drawSnapGuides()
    }

    /// 覆盖在文档之上的布局网格，不参与打印：主格线用所选线型，网格分段为点线，两者都用所选颜色。
    private func drawLayoutGrid() {
        guard session.showsGrid, let document = session.document, let transform = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let grid = session.layoutGrid
        let appearance = session.gridAppearance
        let color = appearance.color.nsColor
        let size = document.size
        let scale = session.viewport.pointsPerPixel
        let hairline = 1 / max(session.viewport.backingScale, 1)
        let subdivisionGap = grid.step * scale
        context.saveGState()
        context.concatenate(transform)
        context.setLineWidth(hairline / max(scale, 0.0001))
        context.setStrokeColor(color.withAlphaComponent(appearance.subdivisionAlpha).cgColor)
        if subdivisionGap >= 4 {
            context.setLineDash(phase: 0, lengths: [1 / max(scale, 0.0001), 2 / max(scale, 0.0001)])
            let path = CGMutablePath()
            for x in grid.lines(along: size.width) where !grid.isMajor(x) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in grid.lines(along: size.height) where !grid.isMajor(y) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.addPath(path)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: appearance.style.dashes.map { $0 / max(scale, 0.0001) })
        context.setStrokeColor(color.withAlphaComponent(appearance.majorAlpha).cgColor)
        let majors = CGMutablePath()
        for x in grid.lines(along: size.width) where grid.isMajor(x) {
            majors.move(to: CGPoint(x: x, y: 0))
            majors.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in grid.lines(along: size.height) where grid.isMajor(y) {
            majors.move(to: CGPoint(x: 0, y: y))
            majors.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.addPath(majors)
        context.strokePath()
        context.restoreGState()
    }

    /// 用户参考线横跨整个视图，包括画布外的空白区。
    private func drawGuides() {
        guard session.showsGuides, let document = session.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let guides = session.displayedGuides
        guard !guides.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(EditorSession.guideColor)
        context.setLineWidth(1 / max(session.viewport.backingScale, 1))
        for guide in guides {
            if guide.axis == .vertical {
                let x = session.viewport.viewPoint(from: CGPoint(x: guide.position, y: 0), documentSize: document.size).x
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
            } else {
                let y = session.viewport.viewPoint(from: CGPoint(x: 0, y: guide.position), documentSize: document.size).y
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    /// 移动被吸附时，沿着对齐目标画一条贯穿整块画布的线。
    private func drawSnapGuides() {
        let guides = session.snapGuides
        guard !guides.xs.isEmpty || !guides.ys.isEmpty, let document = session.document,
              let transform = documentToView, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        for x in guides.xs {
            context.move(to: CGPoint(x: x, y: 0).applying(transform))
            context.addLine(to: CGPoint(x: x, y: document.size.height).applying(transform))
        }
        for y in guides.ys {
            context.move(to: CGPoint(x: 0, y: y).applying(transform))
            context.addLine(to: CGPoint(x: document.size.width, y: y).applying(transform))
        }
        context.strokePath()
        context.restoreGState()
    }

    private var documentToView: CGAffineTransform? {
        guard let document = session.document else { return nil }
        let origin = session.viewport.documentRect(document.size).origin
        let scale = session.viewport.pointsPerPixel
        return CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
    }

    /// 蚂蚁线：一条白线，上面覆盖一节会动的黑线。
    private func drawSelection() {
        guard let selection = session.displayedSelection, !selection.isEmpty, var transform = documentToView,
              let outline = antsOutline(for: selection.path),
              let path = outline.copy(using: &transform), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setLineWidth(1)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.strokePath()
        context.addPath(path)
        context.setLineDash(phase: antsPhase, lengths: [4, 4])
        context.setStrokeColor(NSColor.black.cgColor)
        context.strokePath()
        context.restoreGState()
    }


    private func drawLassoDraft() {
        guard let draft = session.lassoDraft, let transform = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }
        var points = draft.points.map { $0.applying(transform) }
        if draft.kind == .polygonal, let cursor = draft.cursor { points.append(cursor.applying(transform)) }
        guard let first = points.first else { return }
        context.saveGState()
        let path = CGMutablePath()
        if draft.kind == .ellipse, points.count == 4 {
            let xs = points.map(\.x), ys = points.map(\.y)
            path.addEllipse(in: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
        } else {
            path.addLines(between: points)
            if draft.kind == .rectangle { path.closeSubpath() }
        }
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if draft.kind == .polygonal {
            // 第一个角点：点击它即可闭合轮廓。
            let handle = CGRect(x: first.x - 4, y: first.y - 4, width: 8, height: 8)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(handle)
            context.setStrokeColor(NSColor.black.cgColor)
            context.stroke(handle)
        }
        context.restoreGState()
    }

    private func drawTransformHandles() {
        guard let geometry, let context = NSGraphicsContext.current?.cgContext else { return }
        let path = CGMutablePath()
        path.move(to: geometry.handles[0])
        for index in [2, 4, 6] { path.addLine(to: geometry.handles[index]) }
        path.closeSubpath()
        if geometry.showsRotation {
            path.move(to: geometry.handles[1])
            path.addLine(to: geometry.rotationHandle)
        }
        // 只画强调线：在其下方再加一条深色线，会在框周围读作一圈灰色光晕。
        context.addPath(path)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        for point in geometry.handles {
            let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            context.fill(rect)
            context.stroke(rect)
        }
        guard geometry.showsRotation else { return }
        let point = geometry.rotationHandle
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }

    var cropViewRect: CGRect? {
        guard let rect = session.visibleCropRect, let document = session.document else { return nil }
        return CGRect(origin: session.viewport.viewPoint(from: rect.origin, documentSize: document.size),
                      size: CGSize(width: rect.width * session.viewport.pointsPerPixel,
                                   height: rect.height * session.viewport.pointsPerPixel))
    }
    var cropHandles: [CGPoint] {
        guard let rect = cropViewRect else { return [] }
        return LayerTransform.handles.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
    }
    var cropResizeRegions: [(index: Int, rect: CGRect)] {
        guard let rect = cropViewRect else { return [] }
        let handles = cropHandles
        let radius: CGFloat = 10
        var regions = [0, 2, 4, 6].map { index in
            (index: index, rect: CGRect(x: handles[index].x - radius, y: handles[index].y - radius,
                                        width: radius * 2, height: radius * 2))
        }
        // 整条边都可以拖动，而不只是中间那些小方块。
        for index in [1, 5] {
            regions.append((index, CGRect(x: rect.minX + radius, y: handles[index].y - radius,
                width: max(0, rect.width - radius * 2), height: radius * 2)))
        }
        for index in [3, 7] {
            regions.append((index, CGRect(x: handles[index].x - radius, y: rect.minY + radius,
                width: radius * 2, height: max(0, rect.height - radius * 2))))
        }
        return regions
    }
    private func drawGradientLine(_ line: (start: CGPoint, end: CGPoint)) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if session.gradientSettings.shape == .radial {
            // 径向渐变到达末端颜色处的淡边。
            let radius = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            let rim = CGRect(x: line.start.x - radius, y: line.start.y - radius, width: radius * 2, height: radius * 2)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: rim)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: rim)
            context.setLineDash(phase: 0, lengths: [])
        }
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        for (point, color) in [(line.start, session.gradientColors(mask: false).first), (line.end, session.gradientColors(mask: false).last)] {
            let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
            // 透明的两端会透出棋盘格。
            let inner = rect.insetBy(dx: 2.5, dy: 2.5)
            context.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
            context.fillEllipse(in: inner)
            if let color { context.setFillColor(color); context.fillEllipse(in: inner) }
        }
        context.restoreGState()
    }

    private func drawCrop() {
        guard let rect = cropViewRect, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addRect(bounds)
        context.addRect(rect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        for index in 1...2 {
            let fraction = CGFloat(index) / 3
            context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        context.strokePath()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        for point in cropHandles {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(handle)
            context.stroke(handle)
        }
        context.restoreGState()
    }
}
