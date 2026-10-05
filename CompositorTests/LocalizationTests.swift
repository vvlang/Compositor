import Foundation
import Testing
@testable import Compositor

/// 目录本身能不能被查到，是最容易被忽略的一类失败：键只要差一个字符，
/// `String(localized:)` 就静默地返回英文，界面上看不出任何异常。
///
/// 两条约定值得单独说明：
/// 1. 插值必须传 String。塞 `String.LocalizationValue` 会走编译器标记为废弃的路径，
///    得到一个「未本地化的调试描述」而不是查表结果。
/// 2. `%@` 是数据占位符，**参数本身不会被翻译**。所以调用方要先自己把参数本地化，
///    再插进来 —— 真实代码里传的正是 `kind.localizedName` 这类值。
@MainActor
struct LocalizationTests {
    /// 纯字面量。
    @Test func plainLiteralResolves() {
        #expect(L10n.string("Gaussian Blur") == "高斯模糊")
        #expect(L10n.string("Opacity") == "不透明度")
    }

    /// 运行时用 rawValue 查表（枚举的 localizedName 走的正是这条路）。
    @Test func enumRawValueResolves() {
        #expect(FilterKind.gaussianBlur.localizedName == "高斯模糊")
        #expect(LayerBlendMode.multiply.localizedName == "正片叠底")
        #expect(AdjustmentKind.colorBalance.localizedName == "色彩平衡")
    }

    /// 带插值的键。目录里的占位符必须和运行时查找的字面量一致（%@）：
    /// xcstringstool 提取出来的是 %arg，而 xcstringstool compile 不会把键里的
    /// %arg 转成 %@。不统一的话这里会红，而且界面上只是默默显示英文。
    @Test func interpolatedKeysResolve() {
        #expect(L10n.string("Undo \(LayerEffectKind.stroke.localizedName)") == "撤销描边")
        #expect(L10n.string("Link mask: \(plainLayerName)") == "链接蒙版：Layer 1")
        #expect(L10n.string("\(EditorSession.SelectionAmountOperation.expand.localizedName) Selection") == "扩展选区")
        #expect(L10n.string("Edit \(FilterKind.gaussianBlur.localizedName) Adjustment") == "编辑「高斯模糊」调整")
        #expect(L10n.string("Add \(LayerEffectKind.shadow.localizedName)") == "添加投影")
    }

    /// 目录里每一个键都必须真的有中文译文。查表失败时 `String(localized:)` 不会报错，
    /// 只是原样返回英文——所以「值等于键」是漏翻最可靠的信号。
    ///
    /// 这里直接读编译产物，而不是问 Bundle.main：测试进程按自己的语言解析，
    /// 用中文键去问它只会得到「查不到」的假象。
    @Test func everyCatalogKeyIsActuallyTranslated() {
        let table = zhHansTable()
        #expect(!table.isEmpty, "读不到编译后的 zh-Hans 目录")
        let untranslated = table
            .filter { $0.key.contains("%@") }     // 带占位符的键最容易悄悄漏掉
            .filter { $0.value == $0.key }
            .filter { !verbatimKeys.contains($0.key) }  // 纯格式串和单位本来就一样
            .map(\.key)
        #expect(untranslated.isEmpty, "这些键的译文和原文相同：\(untranslated)")
    }

    /// 译文与原文相同是合理的：它们是尺寸/单位模板或算法名，不是文案。
    private let verbatimKeys: Set<String> = [
        "%@", "%@ × %@ px", "%@ × %@ px · sRGB", "%@%%", "%@°  %@",
    ]

    private func zhHansTable() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                       subdirectory: nil, localization: "zh-Hans"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return dict
    }

    /// 目录里带 %@ 的键，运行时必须真的查得到，而不是返回键本身。
    @Test func placeholderKeysAreReachable() {
        for key in ["Undo %@", "Link mask: %@", "%@ Selection", "%@ color", "Edit %@ Adjustment"] {
            #expect(Bundle.main.localizedString(forKey: key, value: nil, table: nil) != key,
                    "目录里查不到 \(key)，插值键会静默退回英文")
        }
    }

    /// 快捷键的 id 是 "\(group):\(title)"，写进 UserDefaults。译文不能影响它。
    @Test func shortcutIdentityStaysEnglish() {
        #expect(ShortcutDefinition.all.first { $0.title == "Undo" }?.id == "Menus:Undo")
        #expect(ShortcutDefinition.all.allSatisfy { !$0.title.containsCJK })
        #expect(ShortcutDefinition.all.allSatisfy { !$0.group.containsCJK })
    }

    /// 枚举的 rawValue 是写进 .comp manifest 的存档值，翻译一个字工程就打不开。
    @Test func persistedRawValuesStayEnglish() {
        #expect(FilterKind.gaussianBlur.rawValue == "Gaussian Blur")
        #expect(LayerBlendMode.colorBurn.rawValue == "Color Burn")
        #expect(AdjustmentKind.hsv.rawValue == "Hue/Saturation")
        #expect(ShapeKind.rectangle.rawValue == "Rectangle")
        #expect(GridAppearance.Preset.lightGray.rawValue == "Light Gray")
    }

    private var plainLayerName: String { "Layer 1" }
}

private extension String {
    var containsCJK: Bool { unicodeScalars.contains { $0.value >= 0x2E80 && $0.value <= 0x9FFF } }
}
