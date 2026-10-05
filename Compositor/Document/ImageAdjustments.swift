import AppKit

/// 把图像画进一块 RGBA 缓冲区（预乘 alpha，alpha 在最后），交给一个 C kernel 就地修改，
/// 再返回结果。
nonisolated enum ImageAdjustmentPixels {
    static func run(_ image: CGImage, _ body: (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        body(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// 随调整一起存储的 sRGB 颜色，每通道 0–1。
nonisolated struct AdjustmentColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(_ color: PaletteColor) { self.init(red: Double(color.red), green: Double(color.green), blue: Double(color.blue)) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var clamped: Self {
        Self(red: ImageAdjustmentPixels.clamp(red, 0...1, 0), green: ImageAdjustmentPixels.clamp(green, 0...1, 0),
             blue: ImageAdjustmentPixels.clamp(blue, 0...1, 0))
    }
}

/// Photoshop 的曝光：`exposure`（档）缩放线性光，`offset` 平移它，随后由伽马校正弯折结果。
/// 同一条曲线作用于所有通道；alpha 保持不变。
nonisolated struct ExposureSettings: Codable, Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -20...20
    static let offsetRange: ClosedRange<Double> = -0.5...0.5
    static let gammaRange: ClosedRange<Double> = 0.01...9.99
    /// 曝光档数，−20…20。
    var exposure: Double = 0
    /// 在线性光上叠加，−0.5…0.5：负值加深阴影，正值提亮阴影。
    var offset: Double = 0
    /// 伽马校正，0.01…9.99；大于 1 时提亮中间调。
    var gamma: Double = 1
    var isValid: Bool { Self.exposureRange.contains(exposure) && Self.offsetRange.contains(offset) && Self.gammaRange.contains(gamma) }
    var normalized: Self {
        Self(exposure: ImageAdjustmentPixels.clamp(exposure, Self.exposureRange, 0),
             offset: ImageAdjustmentPixels.clamp(offset, Self.offsetRange, 0),
             gamma: ImageAdjustmentPixels.clamp(gamma, Self.gammaRange, 1))
    }
    /// 每个输入字节对应的各通道输出（0–1），先解码为线性光再编码回去。
    var table: [Float] {
        let scale = pow(2, exposure)
        return (0...255).map { index in
            let encoded = Double(index) / 255
            var linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            linear = pow(max(0, linear * scale + offset), 1 / gamma)
            let output = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return Float(min(1, max(0, output)))
        }
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let tables = Array([[Float]](repeating: table, count: 3).joined())
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, _ in
            levels_apply(pixels, width * height, tables)
        }
    }
}

/// 渐变映射：每个像素的明度在 `shadows` 与 `highlights` 之间取一个颜色（反转时两端互换）；
/// alpha 保持不变。
nonisolated struct GradientMapSettings: Codable, Equatable, Sendable {
    var shadows = AdjustmentColor(red: 0, green: 0, blue: 0)
    var highlights = AdjustmentColor(red: 1, green: 1, blue: 1)
    var reversed = false
    var isValid: Bool { shadows.isValid && highlights.isValid }
    var normalized: Self {
        var result = self
        result.shadows = shadows.clamped
        result.highlights = highlights.clamped
        return result
    }
    /// 最暗与最亮色调对应的颜色，按实际应用的顺序排列。
    var ends: (dark: AdjustmentColor, light: AdjustmentColor) { reversed ? (highlights, shadows) : (shadows, highlights) }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let (dark, light) = ends
        // 拆成显式标注类型的若干步：写成单个表达式时类型检查会超时（Xcode 26.1）。
        func channel(_ from: Double, _ to: Double, _ t: Double) -> UInt8 {
            let value: Double = from + (to - from) * t
            let scaled: Double = (value * 255).rounded()
            return UInt8(min(255.0, max(0.0, scaled)))
        }
        var table = [UInt8]()
        table.reserveCapacity(256 * 3)
        for index in 0...255 {
            let t: Double = Double(index) / 255
            table.append(channel(dark.red, light.red, t))
            table.append(channel(dark.green, light.green, t))
            table.append(channel(dark.blue, light.blue, t))
        }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_gradient_map(pixels, width, height, stride, table)
        }
    }
}

/// 黑白，与 Photoshop 的做法一致：不是简单去饱和，而是决定每个色系转成灰度后有多亮。
/// 红色 40%、黄色 60% 这组默认值，正是默认转换能把肤色和树叶分开的原因——
/// 而单纯用明度会把它们压成一片。
nonisolated struct BlackWhiteSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -200...300
    /// Photoshop 的默认值。
    var reds: Double = 40
    var yellows: Double = 60
    var greens: Double = 40
    var cyans: Double = 60
    var blues: Double = 20
    var magentas: Double = 80
    /// 为结果着色并保留明暗关系，可做旧照或蓝晒效果。
    var tint = false
    var tintHue: Double = 40
    var tintSaturation: Double = 20
    var isValid: Bool {
        [reds, yellows, greens, cyans, blues, magentas].allSatisfy { $0.isFinite && Self.range.contains($0) }
            && tintHue.isFinite && (0...360).contains(tintHue)
            && tintSaturation.isFinite && (0...100).contains(tintSaturation)
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        // C routine 中的顺序：红、黄、绿、青、蓝、洋红。
        let weights = [reds, yellows, greens, cyans, blues, magentas].map { Float($0 / 100) }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_black_white(pixels, width, height, stride, weights,
                               tint ? 1 : 0, tintHue, tintSaturation / 100)
        }
    }
}

/// 色彩平衡：把颜色朝每组对立色的一端推移，并分别为阴影、中间调和高光处理。
/// 「保留明度」会在之后把每个像素的明度还原，因此偏暖的色调不会顺带把画面提亮。
nonisolated struct ColorBalanceSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -100...100
    var shadowCyanRed: Double = 0
    var shadowMagentaGreen: Double = 0
    var shadowYellowBlue: Double = 0
    var midCyanRed: Double = 0
    var midMagentaGreen: Double = 0
    var midYellowBlue: Double = 0
    var highlightCyanRed: Double = 0
    var highlightMagentaGreen: Double = 0
    var highlightYellowBlue: Double = 0
    var preserveLuminosity = true
    private var all: [Double] {
        [shadowCyanRed, shadowMagentaGreen, shadowYellowBlue,
         midCyanRed, midMagentaGreen, midYellowBlue,
         highlightCyanRed, highlightMagentaGreen, highlightYellowBlue]
    }
    var isValid: Bool { all.allSatisfy { $0.isFinite && Self.range.contains($0) } }
    var isIdentity: Bool { all.allSatisfy { $0 == 0 } }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        guard !isIdentity else { return image }
        let shadows = [shadowCyanRed, shadowMagentaGreen, shadowYellowBlue].map { Float($0 / 100) }
        let midtones = [midCyanRed, midMagentaGreen, midYellowBlue].map { Float($0 / 100) }
        let highlights = [highlightCyanRed, highlightMagentaGreen, highlightYellowBlue].map { Float($0 / 100) }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_color_balance(pixels, width, height, stride, shadows, midtones, highlights,
                                 preserveLuminosity ? 1 : 0)
        }
    }
}

/// 胶片颗粒：作用于明度的噪点，在中间调最强。其图案由 `seed` 固定在文档空间中，
/// 因此画布平移或局部重绘时颗粒不会跟着动。
nonisolated struct GrainSettings: Codable, Equatable, Sendable {
    static let amountRange: ClosedRange<Double> = 0...100
    static let sizeRange: ClosedRange<Double> = 0.5...20
    static let roughnessRange: ClosedRange<Double> = 0...100
    /// 强度，0–100。
    var amount: Double = 25
    /// 颗粒尺度（文档像素），0.5–20。
    var size: Double = 1.5
    /// 0–100：加入多少更小的不规则细节，让主要颗粒显得更粗糙。
    var roughness: Double = 50
    var seed: UInt32 = 0
    var isValid: Bool { Self.amountRange.contains(amount) && Self.sizeRange.contains(size) && Self.roughnessRange.contains(roughness) }
    var normalized: Self {
        var result = self
        result.amount = ImageAdjustmentPixels.clamp(amount, Self.amountRange, 25)
        result.size = ImageAdjustmentPixels.clamp(size, Self.sizeRange, 1.5)
        result.roughness = ImageAdjustmentPixels.clamp(roughness, Self.roughnessRange, 50)
        return result
    }
    /// `origin` 与 `unitsPerPixel` 决定图像像素在文档空间中的位置（1:1 的整张图层即原点为零、
    /// 每像素一个单位）；给定 `seed` 时会替换掉已存的图案。
    func apply(_ image: CGImage, origin: CGPoint = .zero, unitsPerPixel: CGFloat = 1, seed: UInt32? = nil) throws -> CGImage {
        guard isValid, unitsPerPixel.isFinite, unitsPerPixel > 0 else { throw ProjectError.invalid }
        guard amount > 0 else { return image }
        let pattern = seed ?? self.seed
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_grain(pixels, width, height, stride, amount, size, roughness, pattern,
                         Double(origin.x), Double(origin.y), Double(unitsPerPixel))
        }
    }
}
