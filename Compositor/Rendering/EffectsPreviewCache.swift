import AppKit

/// 仅用于画布预览。全分辨率导出仍走 LayerEffectsRenderer.render 及其 worker。
/// 单个 worker、被取代请求的取消机制，以及固定的像素预算，共同把拖动滑块的耗时挡在 UI 线程之外。
@MainActor
final class EffectsPreviewCache {
    nonisolated private final class Request: @unchecked Sendable {
        let id = UUID()
        let image: CGImage
        let mask: CGImage?
        let maskSource: CGImage?
        let placement: LayerTransform?
        let transform: LayerTransform
        let effects: LayerEffects
        let sideLimit: Int
        private let lock = NSLock()
        private var cancelled = false
        init(image: CGImage, mask: CGImage?, maskSource: CGImage?, placement: LayerTransform?, transform: LayerTransform, effects: LayerEffects, sideLimit: Int) {
            self.image = image; self.mask = mask; self.maskSource = maskSource
            self.placement = placement; self.transform = transform; self.effects = effects; self.sideLimit = sideLimit
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func matches(_ other: Request) -> Bool {
            // 效果是在图层像素空间里渲染的；移动、缩放或旋转图层只会改变缓存图像的绘制位置。
            // 独立放置的蒙版是例外：任一变换改变时，它的覆盖图都必须重新采样。
            let sameMaskGeometry = maskSource == nil && other.maskSource == nil
                || (placement == nil && other.placement == nil)
                || (placement == other.placement && transform == other.transform)
            return image === other.image && maskSource === other.maskSource && sameMaskGeometry
                && effects == other.effects && sideLimit == other.sideLimit
        }
    }
    nonisolated private struct Result: @unchecked Sendable {
        let image: CGImage
        let inset: CGFloat
        /// 仅在种子结果上设置：该图像在文档中的位置。当图层自身的包围盒既被裁剪又被变形时，
        /// 单靠 inset 无法表达这一点。
        var placement: LayerTransform? = nil
    }
    private struct Entry {
        let request: Request
        var result: Result?
    }
    nonisolated private static let worker = DispatchQueue(label: "com.compositor.effects-preview", qos: .userInitiated)
    private var entries: [UUID: Entry] = [:]
    /// 每个图层保留若干个最近完成的预览，最新的排在最后。撤销与重做会把图层之前的像素恢复回来，
    /// 此时对应的效果从这里取用，而不是在重新渲染期间先消失一下。
    private var recent: [UUID: [Entry]] = [:]
    private static let recentPerLayer = 3
    /// 从别处传入的结果——应用变形时一并变形过的效果——在 worker 渲染出图层新像素之前一直显示，
    /// 这样效果不会消失一帧。
    private var seeds: [UUID: Result] = [:]
    private var sideLimit = 1536

    /// 为图层在 `placement` 处显示 `image`，直到新的预览就绪。
    func seed(_ id: UUID, image: CGImage, placement: LayerTransform) {
        // 正在渲染的内容对应的是被它替换的那些像素；若晚一步落地，这个种子就会被丢弃。
        entries.removeValue(forKey: id)?.request.cancel()
        seeds[id] = Result(image: image, inset: 0, placement: placement)
    }

    /// 绘制中图层的效果，来自笔触到目前为止的像素。以笔触的修订号作为键：下一个结果还在渲染时，
    /// 上一个结果继续留在屏幕上，因此效果不会在笔画中途消失。
    /// 某图层已经渲染好的内容，不触发任何新请求。
    func rendered(_ id: UUID) -> (image: CGImage, inset: CGFloat, placement: LayerTransform?)? {
        (entries[id]?.result ?? seeds[id]).map { ($0.image, $0.inset, $0.placement) }
    }

    func prepare(layers: [ImageLayer]) {
        let ids = Set(layers.filter { $0.effects?.visible.isEmpty == false }.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id)?.request.cancel() }
        for id in Array(seeds.keys) where !ids.contains(id) { seeds.removeValue(forKey: id) }
        for id in Array(recent.keys) where !ids.contains(id) { recent.removeValue(forKey: id) }
        // 所有带效果的图层共享约 64 MiB 的输出预算。不要在一个重绘周期内逐出可见图层：
        // 那样当可见图层增多时，被逐出的预览会被反复重建。
        sideLimit = min(1536, max(32, Int(sqrt(Double(16_777_216) / Double(max(1, ids.count))))))
    }

    func preview(for layer: ImageLayer, mask: CGImage?, transform: LayerTransform, maskPlacement: LayerTransform?,
                 completion: @escaping @MainActor @Sendable () -> Void) -> (image: CGImage, inset: CGFloat, placement: LayerTransform?)? {
        guard let image = layer.asset?.image, let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else {
            entries.removeValue(forKey: layer.id)?.request.cancel()
            return nil
        }
        let request = Request(image: image, mask: mask, maskSource: layer.mask?.enabledImage,
                              placement: maskPlacement, transform: transform, effects: effects, sideLimit: sideLimit)
        if let entry = entries[layer.id], entry.request.matches(request) {
            return entry.result.map { ($0.image, $0.inset, $0.placement) }
        }
        let old = entries[layer.id]
        old?.request.cancel()
        if let known = recent[layer.id]?.last(where: { $0.request.matches(request) }), let result = known.result {
            entries[layer.id] = known
            seeds.removeValue(forKey: layer.id)
            return (result.image, result.inset, result.placement)
        }
        // 在同一批像素上做变换和改设置时，保持效果可见。
        // 对独立放置的蒙版，保留上一份预览，直到更新后的覆盖图在 worker 上渲染完成。
        // 隐藏多个效果中的一个只会改变哪些效果可见，而不会改变其下的像素；仍在显示的那些效果
        // 不该在其余效果重建期间消失——所以那几帧里让上一份预览顶上，宁可多一个效果，也不要一个都没有。
        // 在同一批像素上添加、移除或替换蒙版时同理：保持原样，直到新的效果就绪。
        let previous = old.flatMap { entry in
            entry.request.image === image ? entry.result : nil
        } ?? seeds[layer.id]
        entries[layer.id] = Entry(request: request, result: previous)
        let layerID = layer.id
        Self.worker.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard !request.isCancelled else { return }
            let result = autoreleasepool { try? Self.render(request) }
            guard !request.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.entries[layerID]?.request.id == request.id else { return }
                self.entries[layerID]?.result = result
                if let result {
                    self.seeds.removeValue(forKey: layerID)
                    var kept = (self.recent[layerID] ?? []).filter { !$0.request.matches(request) }
                    kept.append(Entry(request: request, result: result))
                    self.recent[layerID] = Array(kept.suffix(Self.recentPerLayer))
                }
                completion()
            }
        }
        return previous.map { ($0.image, $0.inset, $0.placement) }
    }

    /// 直接以预览尺寸渲染效果：正在输入的文字很小，效果不该比按键慢一拍。
    func renderNow(image: CGImage, mask: CGImage?, effects: LayerEffects) -> (image: CGImage, inset: CGFloat)? {
        let request = Request(image: image, mask: mask, maskSource: nil, placement: nil, transform: LayerTransform(origin: .zero, size: .zero),
                              effects: effects, sideLimit: sideLimit)
        return (try? Self.render(request)).map { ($0.image, $0.inset) }
    }

    nonisolated private static func render(_ request: Request) throws -> Result {
        let image = request.image
        let margin = LayerEffectsRenderer.margin(for: request.effects)
        // 描边与投影的外扩也要计入预算；即使是 500 px 的描边，尺寸也仍然有界。
        let factor = min(1, CGFloat(request.sideLimit - 8) / (CGFloat(max(image.width, image.height)) + 2 * margin))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        func resized(_ source: CGImage, mask: Bool) throws -> CGImage {
            let context = try BrushRaster.context(width: width, height: height, mask: mask)
            context.interpolationQuality = .high
            // 对灰度蒙版，直接绘制其存储的覆盖度数值。
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw ExportError.render }
            return result
        }
        let pixels = factor == 1 ? image : try resized(image, mask: false)
        let mask = try request.mask.map { factor == 1 ? $0 : try resized($0, mask: true) }
        var effects = request.effects
        effects.stroke?.size *= factor
        effects.shadow?.distance *= factor
        effects.shadow?.blur *= factor
        let rendered = try LayerEffectsRenderer.render(pixels, mask: mask, effects: effects)
        return Result(image: rendered.image, inset: rendered.inset)
    }
}
