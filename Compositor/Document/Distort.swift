import AppKit
import CoreImage

/// 自由变形（按住 Cmd 拖动变换手柄）：四个角点各自独立移动。
/// 图层变换为仿射变换，因此变形可实时预览，并在 Apply 时把像素（以及蒙版）
/// 重采样到新形状——正如 Photoshop 对像素图层的处理——最终留下一个普通轴对齐的图层，覆盖形状的外接矩形。
nonisolated enum DistortWarp {
    /// 变换的角点，按手柄顺序：左上、右上、右下、左下。
    static func corners(of transform: LayerTransform) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
    }

    /// 四个有限且具备面积的角点。凸形按透视变换；其余情形——某角点被拖过相邻角点从而使形状折回——
    /// 则按两个三角形分别变换（参见 `warp`）。
    static func isUsable(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else { return false }
        // 两侧都需有面积，否则其中一侧将无内容可绘制。
        return abs(area(corners[0], corners[1], corners[2])) > 0.01 && abs(area(corners[0], corners[2], corners[3])) > 0.01
    }

    private static func area(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// 透视变换可处理的形状：凸形，且缠绕方向一致（镜像形状也计入）。
    static func isConvex(_ corners: [CGPoint]) -> Bool {
        guard isUsable(corners) else { return false }
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 0.01 else { return false }
            if sign == 0 { sign = cross < 0 ? -1 : 1 } else if (cross < 0) != (sign < 0) { return false }
        }
        return true
    }

    /// 将三个源点映射到三个目标点的仿射变换。
    private static func affine(from source: (CGPoint, CGPoint, CGPoint), to target: (CGPoint, CGPoint, CGPoint)) -> CGAffineTransform? {
        let u = CGPoint(x: source.1.x - source.0.x, y: source.1.y - source.0.y)
        let v = CGPoint(x: source.2.x - source.0.x, y: source.2.y - source.0.y)
        let uu = CGPoint(x: target.1.x - target.0.x, y: target.1.y - target.0.y)
        let vv = CGPoint(x: target.2.x - target.0.x, y: target.2.y - target.0.y)
        let det = u.x * v.y - v.x * u.y
        guard abs(det) > 1e-9 else { return nil }
        let a = (uu.x * v.y - vv.x * u.y) / det, c = (vv.x * u.x - uu.x * v.x) / det
        let b = (uu.y * v.y - vv.y * u.y) / det, d = (vv.y * u.x - uu.y * v.x) / det
        return CGAffineTransform(a: a, b: b, c: c, d: d,
                                 tx: target.0.x - (a * source.0.x + c * source.0.y),
                                 ty: target.0.y - (b * source.0.x + d * source.0.y))
    }

    /// 将单位正方形（角点按 `corners(of:)` 顺序）透视映射到 `c`。
    static func homography(_ c: [CGPoint]) -> (CGPoint) -> CGPoint {
        let sx = c[0].x - c[1].x + c[2].x - c[3].x, sy = c[0].y - c[1].y + c[2].y - c[3].y
        var g: CGFloat = 0, h: CGFloat = 0
        if abs(sx) > 1e-9 || abs(sy) > 1e-9 {
            let dx1 = c[1].x - c[2].x, dx2 = c[3].x - c[2].x, dy1 = c[1].y - c[2].y, dy2 = c[3].y - c[2].y
            let den = dx1 * dy2 - dx2 * dy1
            if abs(den) > 1e-12 {
                g = (sx * dy2 - dx2 * sy) / den
                h = (dx1 * sy - sx * dy1) / den
            }
        }
        let a = c[1].x - c[0].x + g * c[1].x, b = c[3].x - c[0].x + h * c[3].x, x0 = c[0].x
        let d = c[1].y - c[0].y + g * c[1].y, e = c[3].y - c[0].y + h * c[3].y, y0 = c[0].y
        return { p in
            let w = g * p.x + h * p.y + 1
            return CGPoint(x: (a * p.x + b * p.y + x0) / w, y: (d * p.x + e * p.y + y0) / w)
        }
    }

    /// 图像自身像素各角点所对应的位置：翻转图层的像素呈镜像显示，因此像素去到形状的对侧角点。
    static func imageCorners(_ corners: [CGPoint], flipX: Bool, flipY: Bool)
        -> (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        func corner(_ x: Int, _ y: Int) -> CGPoint {
            let u = flipX ? 1 - x : x, v = flipY ? 1 - y : y
            return corners[[0, 1, 3, 2][v * 2 + u]]
        }
        return (corner(0, 0), corner(1, 0), corner(1, 1), corner(0, 1))
    }

    /// `image` 经 `transform` 显示，并被重采样使其角点落在 `corners` 上。
    /// 返回覆盖形状整像素外接矩形的变形像素及其轴对齐变换。`limit` 限制预览时最长边的像素数。
    static func warp(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], isMask: Bool,
                     limit: CGFloat? = nil) throws -> (image: CGImage, transform: LayerTransform) {
        guard isUsable(corners) else { throw ProjectError.invalid }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = floor(xs.min()!), minY = floor(ys.min()!)
        let bounds = CGRect(x: minX, y: minY, width: ceil(xs.max()!) - minX, height: ceil(ys.max()!) - minY)
        guard bounds.width >= 1, bounds.height >= 1, bounds.width <= DocumentLimits.maxSideExtent, bounds.height <= DocumentLimits.maxSideExtent,
              bounds.width * bounds.height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let placed = LayerTransform(origin: bounds.origin, size: bounds.size, sampling: transform.sampling)
        // 均匀的 1 × 1 蒙版已能覆盖任意形状。
        if isMask, image.width == 1, image.height == 1 { return (image, placed) }
        let factor = limit.map { min(1, $0 / max(bounds.width, bounds.height)) } ?? 1
        let width = max(1, Int((bounds.width * factor).rounded(.up)))
        let height = max(1, Int((bounds.height * factor).rounded(.up)))
        let target = imageCorners(corners, flipX: transform.flipX, flipY: transform.flipY)
        // 折回形状（某角点被拖过相邻角点）没有能直接将图像映射到它的透视变换，
        // 因此将两侧各自作为三角形分别变换，沿形状对角线相接。
        if !isConvex(corners) {
            return (try warpFolded(image, target: target, bounds: bounds, factor: factor,
                                   width: width, height: height, isMask: isMask), placed)
        }
        // Core Image 从输出底部向上度量 y 坐标。
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(x: (point.x - bounds.minX) * factor, y: (bounds.maxY - point.y) * factor)
        }
        let warped = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(target.topLeft), "inputTopRight": vector(target.topRight),
            "inputBottomRight": vector(target.bottomRight), "inputBottomLeft": vector(target.bottomLeft),
        ])
        return (try PixelAdjust.render(warped, width: width, height: height, isMask: isMask), placed)
    }

    /// 将图像按两个三角形绘制到形状中：对角线两侧各自由其仿射变换带到位。
    /// 可处理透视变换无法应对的折回与凹陷形状。
    private static func warpFolded(_ image: CGImage, target: (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint),
                                   bounds: CGRect, factor: CGFloat, width: Int, height: Int, isMask: Bool) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: isMask)
        let source = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let corners = (topLeft: CGPoint(x: source.minX, y: source.minY), topRight: CGPoint(x: source.maxX, y: source.minY),
                       bottomRight: CGPoint(x: source.maxX, y: source.maxY), bottomLeft: CGPoint(x: source.minX, y: source.maxY))
        func placed(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - bounds.minX) * factor, y: (point.y - bounds.minY) * factor)
        }
        let halves = [((corners.topLeft, corners.topRight, corners.bottomRight), (target.topLeft, target.topRight, target.bottomRight)),
                      ((corners.topLeft, corners.bottomRight, corners.bottomLeft), (target.topLeft, target.bottomRight, target.bottomLeft))]
        for (from, to) in halves {
            let destination = (placed(to.0), placed(to.1), placed(to.2))
            guard let map = affine(from: from, to: destination) else { continue }
            context.saveGState()
            // 共享对角线两侧为硬边，确保两半恰好相接而不发生双重混合。
            context.setShouldAntialias(false)
            let triangle = CGMutablePath()
            triangle.addLines(between: [destination.0, destination.1, destination.2])
            triangle.closeSubpath()
            context.addPath(triangle)
            context.clip()
            context.concatenate(map)
            context.setShouldAntialias(true)
            BrushRaster.draw(image, in: source, mask: isMask, context: context)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// 全分辨率的变形结果裁剪至可见像素。变形形状很少填满其外接矩形——画笔笔触更不会——
    /// 因此图层（及其变换手柄）应紧贴实际存在的区域。`crop` 以变形后的像素为单位，供裁剪蒙版与之匹配。
    static func warpTrimmed(_ image: CGImage, transform: LayerTransform, corners: [CGPoint])
        throws -> (image: CGImage, transform: LayerTransform, crop: CGRect) {
        let warped = try warp(image, transform: transform, corners: corners, isMask: false)
        let full = CGRect(x: 0, y: 0, width: warped.image.width, height: warped.image.height)
        let context = try BrushRaster.context(width: warped.image.width, height: warped.image.height, mask: false)
        BrushRaster.draw(warped.image, in: full, mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), warped.image.width, warped.image.height, context.bytesPerRow, &edges)
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        // 无可见内容或无可裁剪区域：保持变形结果不变。
        guard crop.width >= 1, crop.height >= 1, crop != full, let cropped = warped.image.cropping(to: crop) else {
            return (warped.image, warped.transform, full)
        }
        var placed = warped.transform
        placed.origin = CGPoint(x: placed.origin.x + crop.minX, y: placed.origin.y + crop.minY)
        placed.size = crop.size
        return (cropped, placed, crop)
    }

    /// 当应用于 `transform` 角点到 `corners` 的透视变换同样作用于 `placement` 时，
    /// 其角点（按手柄顺序）的落点——即与图层分离放置的链接蒙版如何随图层一起变形。
    static func carried(_ placement: LayerTransform, by transform: LayerTransform, to corners: [CGPoint]) -> [CGPoint] {
        let toUnit = CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: transform.size.width, y: transform.size.height))
            .concatenating(CGAffineTransform(rotationAngle: transform.radians))
            .concatenating(CGAffineTransform(translationX: transform.center.x, y: transform.center.y)).inverted()
        let map = homography(corners)
        return self.corners(of: placement).map { map($0.applying(toUnit)) }
    }

    /// 与 `warp` 同样变形的蒙版，但形状之外为 `background`（其像素外的色调）而非黑色——
    /// 供与图层分离放置、显示范围超出自身边界的蒙版使用。
    static func warpMask(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], background: CGFloat,
                         limit: CGFloat? = nil) throws -> (image: CGImage, transform: LayerTransform) {
        let warped = try warp(image, transform: transform, corners: corners, isMask: true, limit: limit)
        guard background > 0, warped.image !== image else { return warped }
        let width = warped.image.width, height = warped.image.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: background, alpha: 1)
        context.fill(full)
        let sx = CGFloat(width) / warped.transform.size.width, sy = CGFloat(height) / warped.transform.size.height
        let shape = CGMutablePath()
        shape.addLines(between: corners.map { CGPoint(x: ($0.x - warped.transform.origin.x) * sx, y: ($0.y - warped.transform.origin.y) * sy) })
        shape.closeSubpath()
        context.addPath(shape)
        context.clip()
        BrushRaster.draw(warped.image, in: full, mask: true, context: context)
        guard let result = context.makeImage() else { throw ExportError.render }
        return (result, warped.transform)
    }

    /// 将绘制在原始像素之上（按 `pixelToDocument` 放置）的轮廓带入变形后的形状，使变换中的选区始终匹配其像素。
    static func mapPath(_ path: CGPath, pixelToDocument: CGAffineTransform, pixelSize: CGSize,
                        transform: LayerTransform, corners: [CGPoint]) -> CGPath? {
        guard isConvex(corners), pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let toPixels = pixelToDocument.inverted()
        let map = homography(corners)
        func carry(_ point: CGPoint) -> CGPoint {
            let pixel = point.applying(toPixels)
            var u = pixel.x / pixelSize.width, v = pixel.y / pixelSize.height
            if transform.flipX { u = 1 - u }
            if transform.flipY { v = 1 - v }
            return map(CGPoint(x: u, y: v))
        }
        let result = CGMutablePath()
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: result.move(to: carry(element.points[0]))
            case .addLineToPoint: result.addLine(to: carry(element.points[0]))
            case .addQuadCurveToPoint: result.addQuadCurve(to: carry(element.points[1]), control: carry(element.points[0]))
            case .addCurveToPoint:
                result.addCurve(to: carry(element.points[2]), control1: carry(element.points[0]), control2: carry(element.points[1]))
            case .closeSubpath: result.closeSubpath()
            @unknown default: break
            }
        }
        return result
    }
}

/// 画布最近一次的变形预览，变形与图层未变化时复用。
/// 最近一次为变形而变形的 effects 图像，角点可继续移动而无需重做。
struct DistortEffectsCache {
    let corners: [CGPoint]
    let image: CGImage
    let result: (image: CGImage, transform: LayerTransform)?
}

struct DistortPreviewCache {
    let corners: [CGPoint]
    let draft: LayerTransform
    let image: CGImage
    let mask: CGImage?
    let result: (image: CGImage, mask: CGImage?, transform: LayerTransform)?
}

extension EditorSession {
    /// 在变换手柄上 Cmd + 拖动：角点开始自由移动。每次变形都会重采样像素，
    /// 因此编辑需等待 Apply 而非在鼠标抬起时立即应用。
    func beginDistort() {
        guard let edit = transformEdit, edit.corners == nil, edit.draft.isValid else { return }
        transformEdit = TransformEdit(layerID: edit.layerID, draft: edit.draft, persistent: true, floating: edit.floating,
                                      corners: DistortWarp.corners(of: edit.draft), mask: edit.mask, group: edit.group)
    }

    /// 移动变形角点；扭曲或塌陷的形状会被忽略。
    func previewCorners(_ corners: [CGPoint]) {
        guard transformEdit?.corners != nil, DistortWarp.isUsable(corners) else { return }
        transformEdit?.corners = corners
    }

    /// 变形将 `layer` 带到何处：编辑下的变换以及该变换移到的角点——对组而言，每个图层按与框相同的透视变换。
    /// 进行中的变形将 `layer` 带往的框与角点（若确有移动）。
    func distortShape(for layer: ImageLayer) -> (transform: LayerTransform, corners: [CGPoint])? {
        guard let edit = transformEdit, !edit.mask, let shape = edit.corners else { return nil }
        return distortTarget(for: layer, edit: edit, shape: shape)
    }

    private func distortTarget(for layer: ImageLayer, edit: TransformEdit, shape: [CGPoint]) -> (transform: LayerTransform, corners: [CGPoint])? {
        guard let group = edit.group else { return edit.layerID == layer.id ? (edit.draft, shape) : nil }
        guard let original = group.originals[layer.id] else { return nil }
        let transform = original.following(from: group.box, to: edit.draft)
        let corners = DistortWarp.carried(transform, by: edit.draft, to: shape)
        return DistortWarp.isUsable(corners) ? (transform, corners) : nil
    }

    /// 变形到挂起变形中的图层（预览尺寸），供画布绘制。
    /// 图层的 effects 被变形到正在形成的形状中——这样在角点拖动期间描边和阴影保持显示，
    /// 而非等到 Apply 才出现。`image` 为已包含 effects 的图层（参见 `LayerEffectsRenderer`），其中已包含其蒙版。
    func distortedEffects(for layer: ImageLayer, effects image: CGImage, inset: CGFloat) -> (image: CGImage, transform: LayerTransform)? {
        guard let edit = transformEdit, !edit.mask, let shape = edit.corners,
              let target = distortTarget(for: layer, edit: edit, shape: shape) else { return nil }
        return distortedEffects(for: layer, effects: image, inset: inset, target: target)
    }

    /// 同上，但目标已知的变形——commit，编辑结束后执行一次。
    func distortedEffects(for layer: ImageLayer, effects image: CGImage, inset: CGFloat,
                          target: (transform: LayerTransform, corners: [CGPoint])) -> (image: CGImage, transform: LayerTransform)? {
        // effects 图像为按其外扩边距放大后的图层框；其角点承受相同的透视变换。
        let grown = LayerEffectsRenderer.placed(target.transform, image: image, inset: inset)
        let carried = DistortWarp.carried(grown, by: target.transform, to: target.corners)
        if let cache = distortEffectsCache[layer.id], cache.corners == carried, cache.image === image { return cache.result }
        let result = (try? DistortWarp.warp(image, transform: grown, corners: carried, isMask: false, limit: 2048))
            .map { (image: $0.image, transform: $0.transform) }
        distortEffectsCache[layer.id] = DistortEffectsCache(corners: carried, image: image, result: result)
        return result
    }

    func distortPreview(for layer: ImageLayer) -> (image: CGImage, mask: CGImage?, transform: LayerTransform)? {
        guard let edit = transformEdit, !edit.mask, let shape = edit.corners, let image = layer.asset?.image,
              let target = distortTarget(for: layer, edit: edit, shape: shape) else { return nil }
        let transform = target.transform, corners = target.corners
        let mask = layer.mask?.enabledImage
        if let cache = distortPreviewCache[layer.id], cache.corners == corners, cache.draft == transform,
           cache.image === image, cache.mask === mask { return cache.result }
        var result: (image: CGImage, mask: CGImage?, transform: LayerTransform)?
        if let warped = try? DistortWarp.warp(image, transform: transform, corners: corners, isMask: false, limit: 2048) {
            let owned = layer.mask
            let warpedMask: CGImage?
            if owned?.placement == nil && owned?.isLinked != false {
                warpedMask = mask.flatMap { try? DistortWarp.warp($0, transform: transform, corners: corners, isMask: true, limit: 2048).image }
            } else if let owned, owned.isLinked, let placed = owned.placement,
                      case let placement = placed.following(from: layer.transform, to: transform),
                      case let carried = DistortWarp.carried(placement, by: transform, to: corners), DistortWarp.isConvex(carried),
                      let moved = try? DistortWarp.warpMask(owned.asset.image, transform: placement, corners: carried,
                                                            background: LayerMask.background(of: owned.asset.thumbnail), limit: 2048) {
                // 分离放置的链接蒙版在其自身外接矩形内承受相同的透视变换。
                warpedMask = LayerMask(asset: ImportedImage(image: moved.image, thumbnail: owned.asset.thumbnail, name: owned.asset.name),
                                       isEnabled: owned.isEnabled)
                    .clipImage(placement: moved.transform, over: warped.transform, width: warped.image.width, height: warped.image.height, limit: 2048)
            } else {
                // An unlinked mask stays where it is on the document.
                warpedMask = owned?.clipImage(placement: owned?.placement ?? layer.transform, over: warped.transform,
                                              width: warped.image.width, height: warped.image.height, limit: 2048)
            }
            result = (warped.image, warpedMask, warped.transform)
        }
        distortPreviewCache[layer.id] = DistortPreviewCache(corners: corners, draft: transform, image: image, mask: mask, result: result)
        return result
    }

    /// Apply 变形：每个被变形图层的像素与蒙版被重采样到其形状中，构成一个撤销步骤。
    func commitDistort(_ edit: TransformEdit, corners shape: [CGPoint]) {
        distortPreviewCache = [:]
        defer { distortEffectsCache = [:] }
        let ids = edit.group.map { Array($0.originals.keys) } ?? [edit.layerID]
        beginEdit(edit.group == nil ? "Distort" : "Distort Layers")
        for id in ids {
            guard let index = document?.layers.firstIndex(where: { $0.id == id }), let layer = document?.layers[index],
                  let target = distortTarget(for: layer, edit: edit, shape: shape) else { continue }
            // 本次变形所用的 effects 图像已就绪：保留显示直到后台为图层新像素渲染完成，
            // 否则 Apply 时它们会消失一帧。
            let warpedEffects = effectsPreviews.rendered(id)
                .flatMap { distortedEffects(for: layer, effects: $0.image, inset: $0.inset, target: target) }
            do { try distort(at: index, transform: target.transform, corners: target.corners) }
            catch { brushError = error.localizedDescription }
            // 放置在变形落点处：Apply 变形同时裁剪图层，周围的边距不再均匀，
            // 因此 inset 无法将其放回正确位置。
            if let warpedEffects { effectsPreviews.seed(id, image: warpedEffects.image, placement: warpedEffects.transform) }
        }
        endEdit()
    }

    /// `index` 处的图层，经 `transform` 显示，重采样使其角点落在 `corners` 上。
    private func distort(at index: Int, transform: LayerTransform, corners: [CGPoint]) throws {
        guard let layer = document?.layers[index], let image = layer.asset?.image else { return }
        let warped = try DistortWarp.warpTrimmed(image, transform: transform, corners: corners)
        let asset = ImportedImage(image: warped.image, thumbnail: try PixelAdjust.thumbnail(of: warped.image), name: layer.name)
        var mask = layer.mask
        if let original = layer.mask, original.placement == nil, original.isLinked {
            let warpedMask = try DistortWarp.warp(original.asset.image, transform: transform, corners: corners, isMask: true)
            // 均匀蒙版保持原样；其他蒙版随像素一同裁剪。
            let maskAsset: ImportedImage
            if warpedMask.image === original.asset.image {
                maskAsset = original.asset
            } else {
                guard let cropped = warpedMask.image.cropping(to: warped.crop) else { throw ExportError.render }
                maskAsset = try LayerMask.asset(from: cropped)
            }
            mask = original.replacing(maskAsset)
        } else if let original = layer.mask, original.isLinked, let placed = original.placement,
                  case let placement = placed.following(from: layer.transform, to: transform),
                  case let carried = DistortWarp.carried(placement, by: transform, to: corners), DistortWarp.isConvex(carried) {
            // A linked mask placed apart takes the same perspective over its own bounds.
            let moved = try DistortWarp.warpMask(original.asset.image, transform: placement, corners: carried,
                                                 background: LayerMask.background(of: original.asset.thumbnail))
            mask = LayerMask(asset: moved.image === original.asset.image ? original.asset : try LayerMask.asset(from: moved.image),
                             isEnabled: original.isEnabled, placement: moved.transform, isLinked: true)
        } else if let original = layer.mask {
            // 未链接的蒙版保持其在文档上的位置。
            mask?.placement = original.placement ?? layer.transform
        }
        document?.layers[index].asset = asset
        document?.layers[index].transform = warped.transform
        document?.layers[index].mask = mask
    }
}
