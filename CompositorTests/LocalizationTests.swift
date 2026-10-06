import Foundation
import Testing
@testable import Compositor

/// 目录本身能不能被查到，是最容易被忽略的一类失败：键只要差一个字符，
/// `String(localized:)` 就静默地返回英文，界面上看不出任何异常。
///
/// **这里所有断言都向 zh-Hans.lproj 直接要答案，一律不走 `L10n.string`。**
/// 后者的结果同时取决于进程语言：英文系统上它会正确地返回英文原文，于是测试变红，
/// 可目录其实没问题 —— CI 的 Verify 任务就是这么红的（en_US runner）。真正要验证的
/// 是「键和目录对得上」，那就该显式指定语言，而不是让系统语言替我们决定。
/// 代价是这些断言不再覆盖 `L10n.string` 这层封装；那层是 Apple 的代码，
/// 它的正确性不该由本地化分支的测试来担保。
@MainActor
struct LocalizationTests {
    /// 纯字面量。
    @Test func plainLiteralResolves() {
        #expect(zh("Gaussian Blur") == "高斯模糊")
        #expect(zh("Opacity") == "不透明度")
    }

    /// 运行时用 rawValue 查表（枚举的 localizedName 走的正是这条路）。
    @Test func enumRawValueResolves() {
        #expect(zh(FilterKind.gaussianBlur.rawValue) == "高斯模糊")
        #expect(zh(LayerBlendMode.multiply.rawValue) == "正片叠底")
        #expect(zh(AdjustmentKind.colorBalance.rawValue) == "色彩平衡")
    }

    /// 带插值的键。目录里的占位符必须和运行时查找的字面量一致（%@）：
    /// xcstringstool 提取出来的是 %arg，而 xcstringstool compile 不会把键里的
    /// %arg 转成 %@。不统一的话这里会红，而且界面上只是默默显示英文。
    ///
    /// 实参同样要经 `zhName()` 取，不能直接用 `kind.localizedName`：后者跟着进程语言走，
    /// 英文系统上会给出 "Stroke"，套进「撤销%@」自然拼不成「撤销描边」。真实代码里
    /// 传的是已本地化的名字，在中文进程下它正是 `zhName(rawValue)`。
    ///
    /// 这也正是运行时该有的行为：英文系统上 `L10n.string("Undo Stroke")` 显示
    /// "Undo Stroke"，本来就是对的——界面语言是英文，不该出现中文。
    @Test func interpolatedKeysResolve() {
        #expect(zh("Undo %@", zhName(LayerEffectKind.stroke.rawValue)) == "撤销描边")
        #expect(zh("Link mask: %@", plainLayerName) == "链接蒙版：Layer 1")
        #expect(zh("%@ Selection", zhName(EditorSession.SelectionAmountOperation.expand.rawValue)) == "扩展选区")
        #expect(zh("Edit %@ Adjustment", zhName(FilterKind.gaussianBlur.rawValue)) == "编辑「高斯模糊」调整")
        #expect(zh("Add %@", zhName(LayerEffectKind.shadow.rawValue)) == "添加投影")
    }

    /// 直接把 zh-Hans.lproj 当 Bundle 用，走的是和 `String(localized:)` 同一套
    /// Foundation 查表，只是把语言钉死成中文，因此与系统语言无关。
    private let zhHans = Bundle.main
        .path(forResource: "zh-Hans", ofType: "lproj")
        .flatMap { Bundle(path: $0) }

    /// zh-Hans 里有没有这条键。查表失败时 Foundation 会原样返回键，这是唯一的失败信号。
    private func has(_ key: String) -> Bool {
        guard let bundle = zhHans else { return false }
        return bundle.localizedString(forKey: key, value: "", table: nil) != key
    }

    /// 一条身份值（rawValue）对应的中文名。查不到就退回英文原样，
    /// 让下游的相等断言自己去发现它——不在这里悄悄吞掉。
    private func zhName(_ rawValue: String) -> String { zh(rawValue) ?? rawValue }

    /// 查一条 zh-Hans 译文并套用 `%@` 占位符。查不到一律返回 nil，好让断言自己说话。
    private func zh(_ key: String, _ args: CVarArg...) -> String? {
        let template = zhHans?.localizedString(forKey: key, value: "", table: nil)
        guard let template, template != key else { return nil }
        return String(format: template, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
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

    /// 目录里带 %@ 的键必须真的存在，而不是缺了之后被原样返回。
    @Test func placeholderKeysAreReachable() {
        for key in ["Undo %@", "Link mask: %@", "%@ Selection", "%@ color", "Edit %@ Adjustment"] {
            #expect(has(key), "目录里查不到 \(key)，插值键会静默退回英文")
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
