import AppKit
import Foundation
import SwiftUI

/// 界面上所有面向用户的文字都从这里取，以便一处约定、全局一致。
///
/// 译文放在 String Catalog（`Localizable.xcstrings`）里，键就是源码中的英文字面量，
/// 所以键永远不需要在这里重复书写——`rawValue`、字面量、插值模板都能直接当键用。
///
/// 关键约定：**被持久化或被比较的字符串永远不要经过这里。** 磁盘上的 `rawValue`、
/// UserDefaults 的键、以及 `switch` / `==` 的判据，一律保持英文原样；只有显示路径才调用 `L10n`。
nonisolated enum L10n {
    /// 返回已本地化的 `String`，供 AppKit（`NSMenuItem`、`toolTip`、`NSTextField`、浮动面板标题）
    /// 以及任何需要 `String` 而非 `LocalizedStringKey` 的场合使用。
    nonisolated static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value)
    }

    /// 返回已本地化的 `Text`，按 verbatim 渲染，不再二次查表。供 `Text`、`.help(...)` 使用。
    nonisolated static func text(_ value: String.LocalizationValue) -> Text {
        Text(verbatim: String(localized: value))
    }

    /// 按 key 取词，key 与 `rawValue` 相同时用这个（绝大多数枚举都属于这一类）。
    nonisolated static func name(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

import AppKit

extension LayerBlendMode {
    /// 菜单标题。`rawValue` 是写进 `.comp` manifest 的存档值，永远保持英文。
    var localizedName: String { L10n.name(rawValue) }
}

extension FilterKind {
    var localizedName: String { L10n.name(rawValue) }
}

extension BackgroundQuality {
    var localizedName: String { L10n.name(rawValue) }
}

extension DitherStyle {
    var localizedName: String { L10n.name(rawValue) }
}

extension DitherColors {
    var localizedName: String { L10n.name(rawValue) }
}

extension DitherPixelShape {
    var localizedName: String { L10n.name(rawValue) }
}

extension BrushToolMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension BlurToolMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension SpotHealingMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension SelectionMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension LassoKind {
    var localizedName: String { L10n.name(rawValue) }
}

extension WandMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension EditorSession.SelectionAmountOperation {
    var localizedName: String { L10n.name(rawValue) }
}

extension TrimBasedOn {
    var localizedName: String { L10n.name(rawValue) }
}

extension LevelsSample {
    var localizedName: String { L10n.name(rawValue) }
}

extension LevelsAuto {
    var localizedName: String { L10n.name(rawValue) }
}

extension LayerEffectKind {
    var localizedName: String { L10n.name(rawValue) }
}

extension AdjustmentKind {
    var localizedName: String { L10n.name(rawValue) }
}

extension ShapeKind {
    var localizedName: String { L10n.name(rawValue) }
}

extension LayerSampling {
    var localizedName: String { L10n.name(rawValue) }
}

extension LevelsChannel {
    var localizedName: String { L10n.name(rawValue) }
}

extension ColorRange {
    var localizedName: String { L10n.name(rawValue) }
}

extension TextAlignment {
    var localizedName: String { L10n.name(rawValue) }
}

extension GradientShape {
    var localizedName: String { L10n.name(rawValue) }
}

extension GradientStyle {
    var localizedName: String { L10n.name(rawValue) }
}

extension CanvasUnit {
    var localizedName: String { L10n.name(rawValue) }
}

extension GridAppearance.Preset {
    var localizedName: String { L10n.name(rawValue) }
}

extension GridAppearance.Style {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawWhiteBalance {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawGlowStyle {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawVignetteStyle {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawCurvePage {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawPointChannel {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawMixerPage {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawMixerTab {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawGradePage {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawUprightMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawProjection {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawProcessVersion {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawScopeMode {
    var localizedName: String { L10n.name(rawValue) }
}

extension CameraRawMixerSettings {
    /// 八个色彩家族名按色相顺序排布，`names` 与 `centers` 是一一对应的定长表，
    /// 所以下标就是身份；只有显示时才取词。
    static func localizedName(at index: Int) -> String { L10n.name(names[index]) }
}

/// `rawValue` 是 Int，标题另存在一个数组里，所以这里要按 case 取词。
extension WandSampleSize {
    var localizedName: String {
        switch self {
        case .point: L10n.string("Point Sample")
        case .threeByThree: L10n.string("3 by 3 Average")
        case .fiveByFive: L10n.string("5 by 5 Average")
        }
    }
}

extension HueSampleMode {
    var localizedName: String { L10n.name(rawValue) }

    /// 吸管提示语，出现在色相/饱和度的取样模式里。
    var localizedHelp: String {
        switch self {
        case .replace: L10n.string("Click the image to center this range on that color")
        case .add: L10n.string("Click the image to widen this range to include that color")
        case .remove: L10n.string("Click the image to narrow this range to exclude that color")
        }
    }
}
