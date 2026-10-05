import AppKit
import SwiftUI

/// 「关于 Compositor」面板。
///
/// 上游原本没有这个面板：SwiftUI 不会自动生成 About 窗口，所以应用里一直没有地方
/// 放作者、版本这类元信息。加入本地化之后这里多了一项职责——把翻译者署名显式写出来，
/// 免得别人把汉化版当成官方版本。
///
/// 署名与版本都从 `Info.plist` 读，不在代码里写死：改版本号只要改构建设置，
/// 改翻译者只要改 `Config/Info.plist` 里的 `CompositorTranslator`。
@MainActor
enum AboutPanel {
    /// 没有登记翻译者时不显示这一行，避免留下一个空标签。
    private static var translator: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: TranslatorKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let TranslatorKey = "CompositorTranslator"

    static func show() {
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = body
        alert.addButton(withTitle: L10n.string("OK"))
        // 单个按钮的提示窗口关掉后不该再闪回编辑器，因此不让它自动激活。
        alert.window.level = .floating
        alert.runModal()
    }

    private static var appName: String {
        L10n.string("Compositor")
    }

    private static var body: String {
        var lines = [versionLine]
        if let translator { lines.append(L10n.string("Simplified Chinese translation by \(translator)")) }
        lines.append(L10n.string("Original version by Robbie Tilton, released under the MIT License."))
        return lines.joined(separator: "\n\n")
    }

    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return L10n.string("Version \(version) (\(build))")
        case let (version?, nil): return L10n.string("Version \(version)")
        default: return ""
        }
    }
}
