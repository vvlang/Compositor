import CoreGraphics
import Foundation

/// 把图层绘制为「未变更图像 + 替换瓦片」的形式——即绘制图层的栅格快照，或进行中的画笔笔触——
/// 使其与 `LayerRenderer` 将像素作为一张完整图像绘制时的结果一致。
///
/// 单独绘制每个瓦片时会在没有相邻像素的情况下重采样（产生接缝），且无法使用 sharp halvings；
/// 此前实时笔触会把整个图层切换到 Nearest，导致绘画开始与结束时像素发生位移。
/// 取而代之，将瓦片区域重建为 pieces：按图层网格的方形、与每次 halving 对齐、
/// 周围带一圈像素边缘、以全分辨率重绘，并以与图像相同的 halving 缩小，仅在方块内绘制。
/// 边缘覆盖 halving 与 Core Graphics 最终重采样所能触及的所有范围，使 piece 的像素与整张图像一致；
/// 其余部分由未变更图像填充。剪裁为硬边，使各部分恰好相接而无缝隙或重叠。
nonisolated enum TiledLayerRenderer {
    nonisolated struct Piece: @unchecked Sendable {
        /// 本 piece 所绘制的网格像素区域。
        let interior: CGRect
        /// 其图像所保存的网格像素：内部区域加上边缘。
        let region: CGRect
        let image: CGImage
        func offsetBy(_ offset: CGPoint) -> Piece {
            Piece(interior: interior.offsetBy(dx: offset.x, dy: offset.y), region: region.offsetBy(dx: offset.x, dy: offset.y), image: image)
        }
    }

    /// 变化区域之外、其缩小重采样后的像素仍可能触及的网格像素数，并留有余量。
    static func support(level: Int) -> CGFloat { level == 0 ? 8 : CGFloat(16 << level) }
    /// piece 方块的边长：已提交的快照用大块（构建次数少，且只需构建一次），实时笔触用小块
    /// （每次鼠标移动需要重建的量很小）。两者都是各次 halving 的整数倍。
    static let committedCell: CGFloat = 1024
    static let strokeCell: CGFloat = 256

    /// 单个图层的网格如何映射到（已变换的）绘制上下文中。
    struct Frame {
        let bounds: CGRect
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        let level: Int
        let device: CGFloat
        let sampling: LayerSampling
        /// 上下文的剪裁区域能显示的网格像素范围。
        let visible: CGRect
        func mapped(_ rect: CGRect) -> CGRect {
            CGRect(x: bounds.minX + rect.minX / pixelWidth * bounds.width,
                   y: bounds.maxY - rect.maxY / pixelHeight * bounds.height,
                   width: rect.width / pixelWidth * bounds.width,
                   height: rect.height / pixelHeight * bounds.height)
        }
    }

    // MARK: Drawing

    /// 已提交的栅格快照（已绘制的图层）。
    static func drawRaster(_ raster: RasterSnapshot, transform: LayerTransform, center: CGPoint, scale: CGFloat,
                           opacity: Double, blendMode: LayerBlendMode, mask: CGImage?, in context: CGContext) {
        withFrame(pixelWidth: raster.width, pixelHeight: raster.height, transform: transform, center: center, scale: scale,
                  opacity: opacity, blendMode: blendMode, in: context) { frame in
            if let mask { clipToMask(mask, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height), frame: frame, context: context) }
            drawCommitted(raster, at: .zero, holes: [], frame: frame, in: context)
        }
    }

    /// 进行中的分块编辑（`patches`，位于 `width` × `height` 的网格中），叠加在图层原有的像素
    /// `image` 或 `raster`（位于 `sourceRect`）之上，按图层完成后的样子绘制。
    static func drawStroke(width: Int, height: Int, sourceRect: CGRect, patches: [BrushPatch], image: CGImage?, raster: RasterSnapshot?,
                           transform: LayerTransform, center: CGPoint, scale: CGFloat, opacity: Double, blendMode: LayerBlendMode,
                           mask: CGImage?, in context: CGContext) {
        withFrame(pixelWidth: width, pixelHeight: height, transform: transform, center: center, scale: scale,
                  opacity: opacity, blendMode: blendMode, in: context) { frame in
            let origin = CGPoint(x: sourceRect.minX + (raster?.alignment.x ?? 0), y: sourceRect.minY + (raster?.alignment.y ?? 0))
            let squares = interiors(near: patches.map(\.rect), margin: support(level: frame.level), size: strokeCell,
                                    step: CGFloat(1 << frame.level), origin: origin, visible: frame.visible)
            let painted = patches.reduce(CGRect(x: 0, y: 0, width: width, height: height)) { $0.union($1.rect) }
            let pieces = squares.compactMap { square in
                piece(interior: square, level: frame.level, origin: origin, bounds: painted) { context, region in
                    if let raster {
                        raster.draw(in: CGRect(origin: sourceRect.origin, size: CGSize(width: raster.width, height: raster.height)), context: context)
                    } else if let image {
                        drawCropped(image, at: sourceRect, within: region, in: context)
                    }
                    for patch in patches where patch.rect.intersects(region) {
                        BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: context)
                    }
                }
            }
            context.saveGState()
            if let mask { clipToMask(mask, in: sourceRect, frame: frame, context: context) }
            drawReplacing(pieces.map(\.interior), frame: frame, in: context, unchanged: {
                if let raster {
                    drawCommitted(raster, at: sourceRect.origin, holes: [], frame: frame, in: context)
                } else if let image {
                    drawBase(image, at: sourceRect, holes: [], frame: frame, in: context)
                }
            }, replace: { draw(pieces[$0], holes: [], frame: frame, in: context) })
            context.restoreGState()
            // 画出图层旧边界之外的部分是「显露」而非「遮罩」。
            if mask != nil {
                for piece in pieces where !sourceRect.contains(piece.interior) {
                    draw(piece, holes: [sourceRect], frame: frame, in: context)
                }
            }
        }
    }

    /// 绘制图层蒙版（覆盖度 `patches` 位于 `width` × `height` 网格中，叠加在 `sourceRect` 处的
    /// `oldMask` 上）：把图层像素 `image` 或 `raster`（同样在 `sourceRect` 处）透过提交后的新蒙版绘制 ——
    /// 笔触瓦片能显示之处用新蒙版的 piece，其余位置沿用旧蒙版。
    static func drawMaskStroke(width: Int, height: Int, sourceRect: CGRect, patches: [BrushPatch], oldMask: ImportedImage?,
                               image: CGImage?, raster: RasterSnapshot?, transform: LayerTransform, center: CGPoint, scale: CGFloat,
                               opacity: Double, blendMode: LayerBlendMode, in context: CGContext) {
        withFrame(pixelWidth: width, pixelHeight: height, transform: transform, center: center, scale: scale,
                  opacity: opacity, blendMode: blendMode, in: context) { frame in
            // piece 按蒙版图像自身的网格与层级做 halving，与旧蒙版的处理方式一致。
            let level = frame.sampling == .nearest ? 0
                : DownsampleCache.level(for: frame.mapped(sourceRect).width * frame.device / max(1, sourceRect.width))
            let found = interiors(near: patches.map(\.rect), margin: support(level: level), size: strokeCell,
                                  step: CGFloat(1 << level), origin: sourceRect.origin, visible: frame.visible)
            let pieces = found.compactMap { interior in
                piece(interior: interior, level: level, origin: sourceRect.origin, bounds: sourceRect, mask: true) { context, region in
                    // 超出旧蒙版的部分按蒙版编辑的惯例予以显露。
                    context.setFillColor(gray: 1, alpha: 1)
                    context.fill(region)
                    if let old = oldMask?.raster {
                        old.draw(in: sourceRect, context: context)
                    } else if let old = oldMask?.image {
                        drawCropped(old, at: sourceRect, within: region, mask: true, in: context)
                    }
                    for patch in patches where patch.rect.intersects(region) {
                        BrushRaster.draw(patch.image, in: patch.rect, mask: true, context: context)
                    }
                }
            }
            func drawLayer() {
                if let raster { drawCommitted(raster, at: sourceRect.origin, holes: [], frame: frame, in: context) }
                else if let image { drawBase(image, at: sourceRect, holes: [], frame: frame, in: context) }
            }
            drawReplacing(pieces.map(\.interior), frame: frame, in: context, unchanged: {
                context.saveGState()
                if let old = oldMask?.image { clipToMask(old, in: sourceRect, frame: frame, context: context) }
                drawLayer()
                context.restoreGState()
            }, replace: { index in
                context.saveGState()
                clip(to: pieces[index].interior, excluding: [], frame: frame, in: context)
                context.clip(to: frame.mapped(pieces[index].region), mask: pieces[index].image)
                drawLayer()
                context.restoreGState()
            })
        }
    }

    /// 除了 `interiors` 之外都绘制 `unchanged`，在第 i 个 interior 内部绘制 `replace(i)`。Core Graphics 的硬边剪裁
    /// 会覆盖它们触及的每一个像素，因此两个相邻剪裁会各自绘制被其公共边切开的那些像素——在不透明像素上看不出来，
    /// 但在图层或其蒙版半透明处会露出一条线。落在设备像素边上的剪裁才会精确切开，因此各 piece 对齐设备的边界
    /// 是分开组装的：在一个透明图层里，先清空每个 interior 再绘制其替代内容，最后一次性合成。
    private static func drawReplacing(_ interiors: [CGRect], frame: Frame, in context: CGContext,
                                      unchanged: () -> Void, replace: (Int) -> Void) {
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let visible = context.boundingBoxOfClipPath
        guard let first = interiors.first else { unchanged(); return }
        let union = interiors.dropFirst().reduce(first) { $0.union($1) }
        let device = frame.mapped(union).applying(toDevice)
            .intersection(visible.applying(toDevice).insetBy(dx: -2, dy: -2)).integral
        guard !device.isNull, !device.isEmpty else { unchanged(); return }
        let toUser = toDevice.inverted()

        context.saveGState()
        context.setShouldAntialias(false)
        let outline = CGPath(rect: visible.insetBy(dx: -64, dy: -64), transform: nil)
        context.addPath(outline.subtracting(CGPath(rect: device.insetBy(dx: -0.001, dy: -0.001), transform: [toUser]), using: .winding))
        context.clip()
        unchanged()
        context.restoreGState()

        context.saveGState()
        context.setShouldAntialias(false)
        context.addPath(CGPath(rect: device.insetBy(dx: 0.001, dy: 0.001), transform: [toUser]))
        context.clip()
        // 内部按全强度绘制，之后再与图层的不透明度和混合模式合成。
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.setBlendMode(.normal)
        unchanged()
        for index in interiors.indices {
            context.saveGState()
            clip(to: interiors[index], excluding: [], frame: frame, in: context)
            context.setBlendMode(.clear)
            context.fill(frame.mapped(interiors[index]))
            context.restoreGState()
            replace(index)
        }
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func withFrame(pixelWidth: Int, pixelHeight: Int, transform: LayerTransform, center: CGPoint, scale: CGFloat,
                                  opacity: Double, blendMode: LayerBlendMode, in context: CGContext, _ body: (Frame) -> Void) {
        let width = transform.size.width * scale, height = transform.size.height * scale
        guard width > 0, height > 0, pixelWidth > 0, pixelHeight > 0 else { return }
        let device = LayerRenderer.deviceScale(of: context)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: width * device / CGFloat(pixelWidth))
        context.saveGState()
        context.setAlpha(opacity)
        context.setBlendMode(blendMode.cgMode)
        context.interpolationQuality = LayerRenderer.interpolation(transform.sampling,
            finalFactor: width * device / CGFloat(pixelWidth) * CGFloat(1 << level), upright: transform.radians == 0)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        let bounds = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let clip = context.boundingBoxOfClipPath
        let sx = CGFloat(pixelWidth) / width, sy = CGFloat(pixelHeight) / height
        let visible = CGRect(x: (clip.minX - bounds.minX) * sx, y: (bounds.maxY - clip.maxY) * sy,
                             width: clip.width * sx, height: clip.height * sy)
        body(Frame(bounds: bounds, pixelWidth: CGFloat(pixelWidth), pixelHeight: CGFloat(pixelHeight), level: level,
                   device: device, sampling: transform.sampling, visible: visible))
        context.restoreGState()
    }

    /// 已提交的栅格数据，置于 frame 网格的 `offset` 处；`holes` 是留给覆盖其上 piece 的空位。
    private static func drawCommitted(_ raster: RasterSnapshot, at offset: CGPoint, holes: [CGRect], frame: Frame, in context: CGContext) {
        let pieces = TiledPieceCache.shared.pieces(for: raster, level: frame.level).map { $0.offsetBy(offset) }
        if let base = raster.base {
            drawBase(base, at: raster.baseRect.offsetBy(dx: offset.x, dy: offset.y), holes: pieces.map(\.interior) + holes,
                     frame: frame, in: context)
        }
        let visible = frame.visible.insetBy(dx: -2, dy: -2)
        for piece in pieces where piece.interior.intersects(visible) {
            draw(piece, holes: holes, frame: frame, in: context)
        }
    }

    /// 未变更的图像（置于 `rect` 处），按 frame 的 halving 缩小后绘制；`holes` 区域除外。
    private static func drawBase(_ image: CGImage, at rect: CGRect, holes: [CGRect], frame: Frame, in context: CGContext) {
        let reduced = DownsampleCache.shared.image(image, level: frame.level)
        let step = CGFloat(1 << reduced.level)
        let covered = CGRect(x: rect.minX, y: rect.minY,
                             width: CGFloat(reduced.image.width) * step * rect.width / CGFloat(max(1, image.width)),
                             height: CGFloat(reduced.image.height) * step * rect.height / CGFloat(max(1, image.height)))
        context.saveGState()
        // 图像自身的边缘照常做抗锯齿；只有 piece 的方块被挖空。
        clip(to: covered.insetBy(dx: -step - 8, dy: -step - 8), excluding: holes, frame: frame, in: context)
        context.setShouldAntialias(frame.sampling != .nearest)
        context.draw(reduced.image, in: frame.mapped(covered))
        context.restoreGState()
    }

    private static func draw(_ piece: Piece, holes: [CGRect], frame: Frame, in context: CGContext) {
        context.saveGState()
        clip(to: piece.interior, excluding: holes, frame: frame, in: context)
        context.setShouldAntialias(frame.sampling != .nearest)
        context.draw(piece.image, in: frame.mapped(piece.region))
        context.restoreGState()
    }

    /// Clips to `area` less `holes` (grid pixels) with hard edges, so neighbouring draws meet exactly.
    private static func clip(to area: CGRect, excluding holes: [CGRect], frame: Frame, in context: CGContext) {
        context.setShouldAntialias(false)
        let outline = CGPath(rect: snapped(frame.mapped(area), in: context), transform: nil)
        let cut = CGMutablePath()
        for hole in holes where hole.intersects(area) { cut.addRect(snapped(frame.mapped(hole), in: context)) }
        context.addPath(cut.isEmpty ? outline : outline.subtracting(cut, using: .winding))
        context.clip()
    }

    /// A clip edge on a fraction of a screen pixel leaves that pixel to be rounded one way here and the other way in
    /// the neighbouring piece, which shows as a hairline across translucent pixels. Rounding each edge to whole
    /// screen pixels first makes two pieces that share an edge round it the same way and meet exactly. Skipped for a
    /// rotated layer, whose pieces don't lie along the screen's pixels at all.
    private static func snapped(_ rect: CGRect, in context: CGContext) -> CGRect {
        let toDevice = context.userSpaceToDeviceSpaceTransform
        guard abs(toDevice.b) < 1e-9, abs(toDevice.c) < 1e-9, toDevice.a != 0, toDevice.d != 0 else { return rect }
        let device = rect.applying(toDevice)
        let snapped = CGRect(x: device.minX.rounded(), y: device.minY.rounded(),
                             width: max(0, device.maxX.rounded() - device.minX.rounded()),
                             height: max(0, device.maxY.rounded() - device.minY.rounded()))
        return snapped.applying(toDevice.inverted())
    }

    private static func clipToMask(_ mask: CGImage, in rect: CGRect, frame: Frame, context: CGContext) {
        let target = frame.mapped(rect)
        let reduced = LayerRenderer.reduced(mask, width: target.width, device: frame.device, sampling: frame.sampling)
        context.clip(to: LayerRenderer.coverage(of: reduced, in: target), mask: reduced.image)
    }

    // MARK: Pieces（piece）

    /// 绘制 `interior` 的一个 piece：`compose` 在向外扩展了支撑范围的 interior 上绘制全分辨率的网格像素
    /// （绘制上下文的原点即网格原点），随后再缩小到 `level`。
    /// `bounds`（网格像素）是所有含像素的范围——图层的网格，以及绘制到其之外的任何内容。
    /// 边缘留白被限制在其内：越过该边界就没有可合成的内容，而重采样一个边缘为空的 piece 会把这份空
    /// 带到图层边缘上，整图直接绘制时则绝不会这样。
    static func piece(interior: CGRect, level: Int, origin: CGPoint, bounds: CGRect? = nil, mask: Bool = false,
                      compose: (CGContext, CGRect) -> Void) -> Piece? {
        let margin = support(level: level)
        var region = aligned(interior.insetBy(dx: -margin, dy: -margin), step: CGFloat(1 << level), origin: origin)
        if let bounds {
            let limit = aligned(bounds, step: CGFloat(1 << level), origin: origin)
            region = region.intersection(limit)
            guard !region.isNull, !region.isEmpty else { return nil }
        }
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, width * height <= 64_000_000,
              let context = try? BrushRaster.context(width: width, height: height, mask: mask) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.translateBy(x: -region.minX, y: -region.minY)
        compose(context, region)
        context.restoreGState()
        guard var image = context.makeImage() else { return nil }
        for _ in 0..<level {
            guard let half = DownsampleCache.halve(image) else { return nil }
            image = half
        }
        let kept = bounds == nil ? interior : interior.intersection(region)
        guard !kept.isNull, !kept.isEmpty else { return nil }
        return Piece(interior: kept, region: region, image: image)
    }

    /// 各 piece 的 interior：在每个以 `origin` 为起点、边长 `size` 的方块内，取距 `rects` 中任一矩形在
    /// `margin` 范围内的部分，并对齐到 `step` 网格。piece 之间保持不相交，且只出现在变化可能显现之处
    /// ——除非有东西画在图层边缘附近，否则会避开这些边缘。范围不超过 `visible` 所显示的部分。
    static func interiors(near rects: [CGRect], margin: CGFloat, size: CGFloat, step: CGFloat, origin: CGPoint, visible: CGRect?) -> [CGRect] {
        var parts: [SIMD2<Int>: CGRect] = [:]
        for rect in rects {
            let grown = rect.insetBy(dx: -margin, dy: -margin)
            if let visible, !grown.intersects(visible) { continue }
            let x0 = Int(floor((grown.minX - origin.x) / size)), x1 = Int(ceil((grown.maxX - origin.x) / size))
            let y0 = Int(floor((grown.minY - origin.y) / size)), y1 = Int(ceil((grown.maxY - origin.y) / size))
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let square = CGRect(x: origin.x + CGFloat(x) * size, y: origin.y + CGFloat(y) * size, width: size, height: size)
                    let part = grown.intersection(square)
                    guard !part.isNull, !part.isEmpty else { continue }
                    let key = SIMD2(x, y)
                    parts[key] = parts[key].map { $0.union(part) } ?? part
                }
            }
        }
        // Squares sit on the step grid, so growing a part to it never leaves its square.
        return parts.values.map { aligned($0, step: step, origin: origin) }
            .filter { interior in visible.map { interior.intersects($0) } ?? true }
    }

    /// `rect` grown outward to whole multiples of `step` measured from `origin`.
    static func aligned(_ rect: CGRect, step: CGFloat, origin: CGPoint) -> CGRect {
        let minX = origin.x + floor((rect.minX - origin.x) / step) * step
        let minY = origin.y + floor((rect.minY - origin.y) / step) * step
        let maxX = origin.x + ceil((rect.maxX - origin.x) / step) * step
        let maxY = origin.y + ceil((rect.maxY - origin.y) / step) * step
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `image`（置于 `rect` 处）落在 `region` 内的部分：与网格 1:1 时按原样裁切，否则（比如一整块
    /// 1 × 1 的纯色蒙版）拉伸后绘制到 `rect` 上。
    private static func drawCropped(_ image: CGImage, at rect: CGRect, within region: CGRect, mask: Bool = false, in context: CGContext) {
        guard CGFloat(image.width) == rect.width, CGFloat(image.height) == rect.height else {
            BrushRaster.draw(image, in: rect, mask: mask, context: context)
            return
        }
        let local = region.offsetBy(dx: -rect.minX, dy: -rect.minY)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !local.isNull, !local.isEmpty, let crop = image.cropping(to: local) else { return }
        BrushRaster.draw(crop, in: local.offsetBy(dx: rect.minX, dy: rect.minY), mask: mask, context: context)
    }
}

/// Committed rasters' pieces, built once per snapshot and level (snapshots never change); the least recently
/// used are dropped beyond a pixel budget.
nonisolated final class TiledPieceCache: @unchecked Sendable {
    static let shared = TiledPieceCache()
    static let pixelBudget = 150_000_000
    private struct Key: Hashable {
        let raster: ObjectIdentifier
        let level: Int
    }
    private struct Entry {
        let raster: RasterSnapshot
        let pieces: [TiledLayerRenderer.Piece]
        var lastUse: UInt64
        let pixels: Int
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private let lock = NSLock()

    func pieces(for raster: RasterSnapshot, level: Int) -> [TiledLayerRenderer.Piece] {
        let key = Key(raster: ObjectIdentifier(raster), level: level)
        lock.lock()
        clock += 1
        if let entry = entries[key], entry.raster === raster {
            entries[key]?.lastUse = clock
            lock.unlock()
            return entry.pieces
        }
        lock.unlock()
        let origin = raster.alignment
        let full = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        let squares = TiledLayerRenderer.interiors(near: raster.patches.map(\.rect), margin: TiledLayerRenderer.support(level: level),
                                                   size: TiledLayerRenderer.committedCell, step: CGFloat(1 << level), origin: origin, visible: nil)
        let pieces = squares.compactMap { square in
            TiledLayerRenderer.piece(interior: square, level: level, origin: origin, bounds: full) { context, _ in raster.draw(in: full, context: context) }
        }
        let pixels = pieces.reduce(0) { $0 + $1.image.width * $1.image.height }
        lock.lock()
        entries[key] = Entry(raster: raster, pieces: pieces, lastUse: clock, pixels: pixels)
        var total = entries.values.reduce(0) { $0 + $1.pixels }
        while total > Self.pixelBudget,
              let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= oldest.value.pixels
            entries.removeValue(forKey: oldest.key)
        }
        lock.unlock()
        return pieces
    }
}
