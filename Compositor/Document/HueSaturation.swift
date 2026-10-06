import AppKit
import CoreImage

/// 六个颜色区间加上 Master，与 Photoshop 的 Cmd+U 一致。
nonisolated enum ColorRange: String, CaseIterable, Sendable, Hashable, Codable {
    case master = "Master", reds = "Reds", yellows = "Yellows", greens = "Greens"
    case cyans = "Cyans", blues = "Blues", magentas = "Magentas"

    /// Photoshop 的初始色相带：falloff start、range start、range end、falloff end。
    var defaultBand: HueBand {
        switch self {
        case .master: HueBand(falloffStart: 0, rangeStart: 0, rangeEnd: 360, falloffEnd: 360)
        case .reds: HueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45)
        case .yellows: HueBand(falloffStart: 15, rangeStart: 45, rangeEnd: 75, falloffEnd: 105)
        case .greens: HueBand(falloffStart: 75, rangeStart: 105, rangeEnd: 135, falloffEnd: 165)
        case .cyans: HueBand(falloffStart: 135, rangeStart: 165, rangeEnd: 195, falloffEnd: 225)
        case .blues: HueBand(falloffStart: 195, rangeStart: 225, rangeEnd: 255, falloffEnd: 285)
        case .magentas: HueBand(falloffStart: 255, rangeStart: 285, rangeEnd: 315, falloffEnd: 345)
        }
    }
    static let colorRanges = ColorRange.allCases.filter { $0 != .master }
}

/// 以度数表示的色相带，在 360 处回绕：`rangeStart` 与 `rangeEnd` 之间为满强度，
/// 在 `falloffStart` 与 `falloffEnd` 处淡出为 0。
nonisolated struct HueBand: Equatable, Sendable, Codable {
    var falloffStart: Double
    var rangeStart: Double
    var rangeEnd: Double
    var falloffEnd: Double

    /// 从 `from` 正向到 `to` 的度数，范围始终 0…360。
    static func forward(_ from: Double, _ to: Double) -> Double {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        return delta < 0 ? delta + 360 : delta
    }

    /// 此色带对某个色相的强度：区间内为 1，经每个 falloff shoulder 线性爬升，区间外为 0。
    /// 通过正向测量处理环绕。
    func weight(of hue: Double) -> Double {
        let span = Self.forward(falloffStart, falloffEnd)
        guard span > 0 else { return 1 } // Master 覆盖所有色相。
        let position = Self.forward(falloffStart, hue)
        guard position <= span else { return 0 }
        let rampIn = Self.forward(falloffStart, rangeStart)
        let plateauEnd = Self.forward(falloffStart, rangeEnd)
        if position < rampIn { return rampIn > 0 ? position / rampIn : 1 }
        if position <= plateauEnd { return 1 }
        let rampOut = span - plateauEnd
        return rampOut > 0 ? (span - position) / rampOut : 1
    }

    var handles: [Double] { [falloffStart, rangeStart, rangeEnd, falloffEnd] }

    /// 居中于某色相的色带，保留此色带的中心宽度与 shoulder 宽度。
    func centered(on hue: Double) -> HueBand {
        let core = Self.forward(rangeStart, rangeEnd)
        let leading = Self.forward(falloffStart, rangeStart)
        let trailing = Self.forward(rangeEnd, falloffEnd)
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        let start = wrap(hue - core / 2)
        return HueBand(falloffStart: wrap(start - leading), rangeStart: start,
                       rangeEnd: wrap(start + core), falloffEnd: wrap(start + core + trailing))
    }

    /// 加宽色带使此色相完全位于其中，移动较近的那条边。
    mutating func include(_ hue: Double) {
        guard weight(of: hue) < 1 else { return }
        let shoulderIn = Self.forward(falloffStart, rangeStart)
        let shoulderOut = Self.forward(rangeEnd, falloffEnd)
        let beforeStart = Self.forward(hue, rangeStart)
        let afterEnd = Self.forward(rangeEnd, hue)
        if beforeStart <= afterEnd {
            rangeStart = hue
            falloffStart = hue - shoulderIn
        } else {
            rangeEnd = hue
            falloffEnd = hue + shoulderOut
        }
        normalize()
    }

    /// 收窄色带使此色相完全位于其外，包含 shoulder。
    mutating func exclude(_ hue: Double) {
        guard weight(of: hue) > 0 else { return }
        let shoulderIn = Self.forward(falloffStart, rangeStart)
        let shoulderOut = Self.forward(rangeEnd, falloffEnd)
        let fromStart = Self.forward(falloffStart, hue)
        let toEnd = Self.forward(hue, falloffEnd)
        if fromStart <= toEnd {
            falloffStart = hue + 1
            rangeStart = hue + 1 + shoulderIn
        } else {
            falloffEnd = hue - 1
            rangeEnd = hue - 1 - shoulderOut
        }
        normalize()
    }

    /// 保持四个手柄都在 0…360 区间，色带不超过一整圈。
    private mutating func normalize() {
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        falloffStart = wrap(falloffStart); rangeStart = wrap(rangeStart)
        rangeEnd = wrap(rangeEnd); falloffEnd = wrap(falloffEnd)
        if Self.forward(falloffStart, falloffEnd) > 350 {
            falloffEnd = wrap(falloffStart + 350)
        }
    }

    /// 移动一个手柄，保持四个手柄的顺序，色带不超过一整圈。
    mutating func setHandle(_ index: Int, to degrees: Double) {
        var updated = self
        let value = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch index {
        case 0: updated.falloffStart = value
        case 1: updated.rangeStart = value
        case 2: updated.rangeEnd = value
        default: updated.falloffEnd = value
        }
        let span = Self.forward(updated.falloffStart, updated.falloffEnd)
        let toStart = Self.forward(updated.falloffStart, updated.rangeStart)
        let toEnd = Self.forward(updated.falloffStart, updated.rangeEnd)
        guard span > 1, span <= 350, toStart <= toEnd, toEnd <= span else { return }
        self = updated
    }
}

/// Hue/Saturation 面板打开时，所选中的吸管。
nonisolated enum HueSampleMode: String, CaseIterable, Sendable {
    case replace = "Sample", add = "Add", remove = "Remove"
    /// 三者都是吸管；Add 与 Remove 配有小角标。
    var symbol: String { "eyedropper" }
    var badge: String? {
        switch self {
        case .replace: nil
        case .add: "plus.circle.fill"
        case .remove: "minus.circle.fill"
        }
    }
    var help: String {
        switch self {
        case .replace: "Click the image to center this range on that color"
        case .add: "Click the image to widen this range to include that color"
        case .remove: "Click the image to narrow this range to exclude that color"
        }
    }
}

/// 正在进行的定向调整拖动。
struct HueTargetDrag {
    let range: ColorRange
    let hue: Double
    let saturation: Double
}

nonisolated struct RangeAdjustment: Equatable, Sendable, Codable {
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
}

/// Hue 取值 −180…180（着色时 0…360），Saturation −100…100（着色时 0…100），
/// Lightness −100…100。每个颜色区间各自保留值；Master 作用于全部。
nonisolated struct HueSaturationSettings: Equatable, Sendable, Codable {
    /// 滑块和色相条所编辑的颜色区间。
    var range: ColorRange = .master
    var colorize = false
    /// 改为将所选区间作用于其色带*之外*的所有色相。
    var invertRange = false
    var adjustments: [ColorRange: RangeAdjustment] = [:]
    var bands: [ColorRange: HueBand] = Dictionary(uniqueKeysWithValues: ColorRange.allCases.map { ($0, $0.defaultBand) })

    init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0, colorize: Bool = false,
         range: ColorRange = .master) {
        self.range = range
        self.colorize = colorize
        adjustments[range] = RangeAdjustment(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// 滑块读写所选颜色区间。
    var hue: Double {
        get { adjustments[range]?.hue ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].hue = newValue }
    }
    var saturation: Double {
        get { adjustments[range]?.saturation ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].saturation = newValue }
    }
    var lightness: Double {
        get { adjustments[range]?.lightness ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].lightness = newValue }
    }
    var band: HueBand {
        get { bands[range] ?? range.defaultBand }
        set { bands[range] = newValue }
    }

    /// Photoshop 打开 Colorize 时的起始值。
    static let colorizeStart = HueSaturationSettings(hue: 0, saturation: 25, lightness: 0, colorize: true)
    var isIdentity: Bool { !colorize && adjustments.values.allSatisfy { $0 == RangeAdjustment() } }

    /// 某颜色区间对某色相的作用强度：Master 对所有色相生效，其他色相则经由其色带作用。
    func weight(of colorRange: ColorRange, hue: Double) -> Double {
        guard colorRange != .master else { return 1 }
        let weight = (bands[colorRange] ?? colorRange.defaultBand).weight(of: hue)
        return invertRange && colorRange == range ? 1 - weight : weight
    }
}

nonisolated struct HueSaturationJob: @unchecked Sendable {
    let image: CGImage
    let settings: HueSaturationSettings
    let selection: SelectionClip?
    let pixelToDocument: CGAffineTransform
    /// 预览跳过图层面板的缩略图。
    var thumbnail = true
}

nonisolated struct AdjustedPixels: @unchecked Sendable {
    let image: CGImage
    let thumbnail: CGImage?
}

/// 根据设置构建颜色立方表并在 GPU 上应用。通过立方表操作可在大幅图像上保持拖动顺畅；
/// 单位（identity）设置不会走到这里。
nonisolated enum HueSaturationFilter {
    /// 每轴 33 个采样点——此类查找表的常见尺寸：构建迅速，足够平滑。
    static let dimension = 33

    static func run(_ job: HueSaturationJob) throws -> AdjustedPixels {
        let width = job.image.width, height = job.image.height
        // 在 CPU 多核上而非 Core Image：Hue/Saturation 图层每帧都在整个画布视图上运行，
        // 一来一回的 GPU 通信比查表本身还贵。查表在自身周围做 unpremultiply。
        let context = try BrushRaster.copy(job.image)
        guard let data = context.data else { throw ExportError.render }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let table = cube(job.settings)
        table.withUnsafeBytes { raw in
            let entries = raw.assumingMemoryBound(to: Float.self).baseAddress!
            BrushRaster.inBands(count: width * height) { start, length in
                cube_apply(pixels + start * 4, length, entries, Int32(dimension))
            }
        }
        guard var result = context.makeImage() else { throw ExportError.render }
        if let selection = job.selection {
            let original = try PixelAdjust.bitmap(width: width, height: height, mask: false)
            original.draw(job.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let originalImage = original.makeImage() else { throw ExportError.render }
            result = try PixelAdjust.blend(result, over: originalImage, through: selection,
                                           pixelToDocument: job.pixelToDocument, isMask: false)
        }
        return AdjustedPixels(image: result, thumbnail: job.thumbnail ? try PixelAdjust.thumbnail(of: result) : nil)
    }

    /// 每个色相对应的总位移量，每度采样一次。每套设置只构建一次，保持立方表廉价：
    /// 否则 ~36k 个立方表条目都要重新评估全部七个区间。
    typealias HueResponse = (shift: Double, saturation: Double, lightness: Double)

    static func hueResponse(_ settings: HueSaturationSettings) -> [HueResponse] {
        (0...360).map { degree in
            var response: HueResponse = (0, 0, 0)
            for (colorRange, adjustment) in settings.adjustments where adjustment != RangeAdjustment() {
                let weight = settings.weight(of: colorRange, hue: Double(degree))
                guard weight > 0 else { continue }
                response.shift += adjustment.hue * weight
                response.saturation += adjustment.saturation * weight
                response.lightness += adjustment.lightness * weight
            }
            return response
        }
    }

    /// 最近构建的几个表：Hue/Saturation 图层在每一帧画布上都用同一套设置重绘，
    /// 而构建一个表比应用它更耗时。
    private static let cubeLock = NSLock()
    nonisolated(unsafe) private static var cubes: [(settings: HueSaturationSettings, data: Data)] = []

    /// 查找表：每个立方表角点转换为 HSL、调整、再转换回去。
    static func cube(_ settings: HueSaturationSettings) -> Data {
        if let cached = cubeLock.withLock({ cubes.first { $0.settings == settings }?.data }) { return cached }
        let data = buildCube(settings)
        cubeLock.withLock {
            cubes.removeAll { $0.settings == settings }
            cubes.insert((settings, data), at: 0)
            if cubes.count > 8 { cubes.removeLast() }
        }
        return data
    }

    private static func buildCube(_ settings: HueSaturationSettings) -> Data {
        let response = hueResponse(settings)
        var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var index = 0
        let step = Double(dimension - 1)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let color = adjust(red: Double(red) / step, green: Double(green) / step, blue: Double(blue) / step,
                                       settings: settings, response: response)
                    values[index] = Float(color.red)
                    values[index + 1] = Float(color.green)
                    values[index + 2] = Float(color.blue)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func adjust(red: Double, green: Double, blue: Double, settings: HueSaturationSettings,
                       response: [HueResponse]? = nil) -> (red: Double, green: Double, blue: Double) {
        var (hue, saturation, lightness) = toHSL(red: red, green: green, blue: blue)
        var lightnessAmount = 0.0
        if settings.colorize {
            hue = settings.hue.truncatingRemainder(dividingBy: 360)
            saturation = min(1, max(0, settings.saturation / 100))
            lightnessAmount = settings.lightness / 100
        } else {
            // 每个区间都参与加权，按其对原始色相的作用强度。
            let table = response ?? hueResponse(settings)
            let sampled = table[min(table.count - 1, max(0, Int(hue.rounded())))]
            lightnessAmount = sampled.lightness / 100
            hue = (hue + sampled.shift).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            saturation = adjustedSaturation(saturation, by: sampled.saturation)
        }
        // Lightness 高于 0 时向白色拉，低于 0 时向黑色拉，至 ±100 时达到极端。
        let amount = min(1, max(-1, lightnessAmount))
        lightness = amount >= 0 ? lightness + (1 - lightness) * amount : lightness * (1 + amount)
        return toRGB(hue: hue, saturation: saturation, lightness: min(1, max(0, lightness)))
    }

    /// 色相条色样所对应的色相，供 "after" 色条使用。
    /// Photoshop 的 Saturation：低于 0 时按比例向灰色收敛（−100 即为灰色）；高于 0 时按剩余量做除法，
    /// 因此 +50 使饱和度翻倍，+100 把任意颜色推满。两侧都是乘性变换，因此中性灰始终保持中性。
    static func adjustedSaturation(_ saturation: Double, by amount: Double) -> Double {
        let amount = min(1, max(-1, amount / 100))
        guard amount > 0 else { return max(0, saturation * (1 + amount)) }
        return amount >= 1 ? (saturation > 0 ? 1 : 0) : min(1, saturation / (1 - amount))
    }

    static func shiftedHue(_ hue: Double, settings: HueSaturationSettings) -> Double {
        var shift = 0.0
        for (colorRange, adjustment) in settings.adjustments where adjustment.hue != 0 {
            shift += adjustment.hue * settings.weight(of: colorRange, hue: hue)
        }
        let shifted = (hue + shift).truncatingRemainder(dividingBy: 360)
        return shifted < 0 ? shifted + 360 : shifted
    }

    private static func toHSL(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if high == red { hue = (green - blue) / delta }
        else if high == green { hue = (blue - red) / delta + 2 }
        else { hue = (red - green) / delta + 4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }

    private static func toRGB(hue: Double, saturation: Double, lightness: Double)
        -> (red: Double, green: Double, blue: Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let (red, green, blue): (Double, Double, Double)
        switch Int(sector) {
        case 0: (red, green, blue) = (chroma, second, 0)
        case 1: (red, green, blue) = (second, chroma, 0)
        case 2: (red, green, blue) = (0, chroma, second)
        case 3: (red, green, blue) = (0, second, chroma)
        case 4: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        return (min(1, max(0, red + base)), min(1, max(0, green + base)), min(1, max(0, blue + base)))
    }
}

/// 一个打开的 Hue/Saturation 对话框。预览从原图的缩小副本渲染并直接绘制到画布上，
/// 拖动保持流畅，文档在点击 OK 之前不会被修改。
@Observable
final class HueSaturationEdit {
    let layerID: UUID
    let original: ImportedImage
    let selection: SelectionClip?
    let pixelToDocument: CGAffineTransform
    /// 缩小后的原图供预览使用，附其自身像素网格的映射。
    @ObservationIgnored let previewSource: CGImage
    @ObservationIgnored let previewPixelToDocument: CGAffineTransform
    var settings = HueSaturationSettings()
    var preview = true
    /// 对话框打开期间画布所显示的内容；nil 表示使用图层自身的像素。
    /// 不参与响应式追踪：画布重绘由 `brushRevision` 驱动。
    @ObservationIgnored private(set) var preparedPreview: CGImage?

    /// 预览最长边最多渲染这么多像素：常规情况下使用原图大小，使画布展示真实效果
    /// 而非拉伸放大的粗糙副本，Hue/Saturation 图层本就如此。
    static let previewLimit = 8000

    init(layerID: UUID, original: ImportedImage, selection: SelectionClip?, transform: LayerTransform) throws {
        self.layerID = layerID
        self.original = original
        self.selection = selection
        let width = original.image.width, height = original.image.height
        pixelToDocument = BrushRaster.pixelToDocument(transform, width: width, height: height)
        let factor = min(1, Double(Self.previewLimit) / Double(max(width, height)))
        if factor < 1 {
            let small = max(1, Int(Double(width) * factor)), tall = max(1, Int(Double(height) * factor))
            let context = try BrushRaster.context(width: small, height: tall, mask: false)
            context.interpolationQuality = .medium
            BrushRaster.draw(original.image, in: CGRect(x: 0, y: 0, width: small, height: tall), mask: false, context: context)
            guard let scaled = context.makeImage() else { throw ExportError.render }
            previewSource = scaled
            previewPixelToDocument = BrushRaster.pixelToDocument(transform, width: small, height: tall)
        } else {
            previewSource = original.image
            previewPixelToDocument = pixelToDocument
        }
    }

    func previewImage(for layer: UUID) -> CGImage? { layer == layerID ? preparedPreview : nil }
    func setPreview(_ image: CGImage?) { preparedPreview = image }
}

extension EditorSession {
    /// 颜色调整需要可见的图像图层（而非蒙版），若有选区则选区必须非空；
    /// 先应用挂起的渐变或变换。Vignette 也会绘制到空白图层上，在放上像素之前它没有内容。
    var canVignette: Bool {
        if canAdjustColors { return true }
        guard let layer = activeLayer, layer.asset == nil, layer.adjustment == nil, !layer.isGroup else { return false }
        return canAdjust(allowingEmpty: true)
    }
    var canAdjustColors: Bool { canAdjust(allowingEmpty: false) }
    private func canAdjust(allowingEmpty: Bool) -> Bool {
        _ = showsBusy
        // 正在编辑的文本由其编辑器绘制，而非图层本身，因此滤镜对它的预览会失真：先提交。
        guard levels == nil, filterEdit == nil, textDraft == nil, document != nil, let layer = activeLayer, !isProjectBusy, !isImporting, brushStroke == nil,
              pixelMove == nil, renamingLayerID == nil, !showsNewDocument, !showsImporter,
              selectedLayerIDs.count == 1, !layer.isGroup, !isMaskSelected, layer.asset != nil || allowingEmpty,
              document?.effectiveVisibleIDs.contains(layer.id) == true, selection?.isEmpty != true else { return false }
        return true
    }

    func beginHueSaturation() {
        guard hueSaturation == nil, canAdjustColors else { NSSound.beep(); return }
        commitTransform()
        if gradientEdit != nil { resolveGradient() }
        guard let document, let layer = activeLayer, let asset = layer.asset else { return }
        do {
            hueSaturation = try HueSaturationEdit(layerID: layer.id, original: asset,
                selection: try selection?.clip(canvas: document.size), transform: layer.transform)
        } catch { brushError = error.localizedDescription }
    }

    /// 来自缩小原图的实时预览。请求合并而不取消：已在进行的渲染会完成并显示，
    /// 然后渲染最新一次请求。取消反而会在拖动过程中使预览断流，因为滑块变化的到达速度
    /// 比一次渲染完成更快。
    func updateHueSaturation(_ settings: HueSaturationSettings, preview: Bool) {
        guard let edit = hueSaturation else { return }
        edit.settings = settings
        edit.preview = preview
        if previewAdjustmentEditing(preview: preview) { return }
        guard preview, !settings.isIdentity else {
            hueSaturationTask?.cancel()
            hueSaturationPending = nil
            edit.setPreview(nil)
            brushRevision += 1
            return
        }
        hueSaturationPending = HueSaturationJob(image: edit.previewSource, settings: settings,
                                                selection: edit.selection, pixelToDocument: edit.previewPixelToDocument,
                                                thumbnail: false)
        renderPendingPreview(edit)
    }

    private func renderPendingPreview(_ edit: HueSaturationEdit) {
        guard hueSaturation === edit, let job = hueSaturationPending, hueSaturationTask == nil else { return }
        hueSaturationPending = nil
        hueSaturationTask = Task { @MainActor [weak self] in
            let adjusted = await self?.adjustedPixels(job)
            guard let self else { return }
            self.hueSaturationTask = nil
            guard self.hueSaturation === edit else { return }
            if let adjusted {
                edit.setPreview(adjusted.image)
                self.brushRevision += 1
            }
            self.renderPendingPreview(edit)
        }
    }

    /// OK：以全分辨率渲染并记录一个 "Hue/Saturation" 撤销步骤。单位（identity）设置完全不会改动。
    func commitHueSaturation() async {
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = hueSaturation else { return }
        hueSampleMode = nil
        hueTargeting = false
        hueTargetDrag = nil
        hueSaturationPending = nil
        hueSaturationTask?.cancel()
        let settings = edit.settings
        // 预览在提交后的像素进入文档之前一直保留在屏幕上：
        // 先清掉会让画布有一帧显示原图。
        defer {
            hueSaturation = nil
            brushRevision += 1
        }
        guard !settings.isIdentity else { return }
        isProjectBusy = true
        defer { isProjectBusy = false }
        let job = HueSaturationJob(image: edit.original.image, settings: settings,
                                   selection: edit.selection, pixelToDocument: edit.pixelToDocument, thumbnail: true)
        guard let adjusted = await adjustedPixels(job),
              let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
              let current = document?.layers[index], current.asset?.image === edit.original.image else { return }
        beginEdit("Hue/Saturation")
        document?.layers[index] = ImageLayer(id: current.id,
            asset: ImportedImage(image: adjusted.image, thumbnail: adjusted.thumbnail ?? adjusted.image, name: current.name),
            name: current.name, isVisible: current.isVisible, transform: current.transform, parentID: current.parentID,
            isGroup: false, opacity: current.opacity, blendMode: current.blendMode, mask: current.mask, maskSourceID: current.maskSourceID)
        endEdit()
    }

    /// 文档某点对应的色相，取自可见合成图。近中性像素没有有意义的色相。
    func sampledHue(at point: CGPoint) -> Double? {
        guard let color = sampleCompositeColor(at: point) else { return nil }
        let hsb = PickerHSB(color)
        return hsb.saturation > 0.02 ? hsb.hue : nil
    }

    /// 吸管：重新居中、加宽或收窄所选区间的色带。
    func sampleHueRange(at point: CGPoint) {
        guard let edit = hueSaturation, let mode = hueSampleMode else { return }
        var settings = edit.settings
        guard settings.range != .master, !settings.colorize, let hue = sampledHue(at: point) else { NSSound.beep(); return }
        switch mode {
        case .replace: settings.band = settings.band.centered(on: hue)
        case .add: settings.band.include(hue)
        case .remove: settings.band.exclude(hue)
        }
        updateHueSaturation(settings, preview: edit.preview)
    }

    /// 定向调整：选中拥有采样颜色的区间并拖动其 saturation（按住 Command 则调整 hue）。
    func beginHueTargeting(at point: CGPoint) -> Bool {
        guard let edit = hueSaturation, hueTargeting, !edit.settings.colorize,
              let hue = sampledHue(at: point) else { NSSound.beep(); return false }
        var settings = edit.settings
        let range = ColorRange.colorRanges.max {
            settings.weight(of: $0, hue: hue) < settings.weight(of: $1, hue: hue)
        } ?? .reds
        settings.range = range
        let adjustment = settings.adjustments[range] ?? RangeAdjustment()
        hueTargetDrag = HueTargetDrag(range: range, hue: adjustment.hue, saturation: adjustment.saturation)
        updateHueSaturation(settings, preview: edit.preview)
        return true
    }

    /// 向右拖动抬高数值，向左降低；每个视图点对应一个单位。
    func dragHueTargeting(byViewDelta delta: CGFloat, adjustsHue: Bool) {
        guard let edit = hueSaturation, let drag = hueTargetDrag else { return }
        var settings = edit.settings
        if adjustsHue {
            settings.adjustments[drag.range, default: RangeAdjustment()].hue =
                min(180, max(-180, drag.hue + Double(delta) / 2))
        } else {
            settings.adjustments[drag.range, default: RangeAdjustment()].saturation =
                min(100, max(-100, drag.saturation + Double(delta) / 2))
        }
        updateHueSaturation(settings, preview: edit.preview)
    }

    func endHueTargeting() { hueTargetDrag = nil }

    func cancelHueSaturation() {
        if finishAdjustmentEditing(commit: false) { return }
        hueSampleMode = nil
        hueTargeting = false
        hueTargetDrag = nil
        guard hueSaturation != nil else { return }
        hueSaturationPending = nil
        hueSaturationTask?.cancel()
        hueSaturation = nil
        brushRevision += 1
    }

    private func adjustedPixels(_ job: HueSaturationJob) async -> AdjustedPixels? {
        do { return try await Task.detached(priority: .userInitiated) { try HueSaturationFilter.run(job) }.value }
        catch { brushError = error.localizedDescription; return nil }
    }
}
