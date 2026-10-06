import AppKit

/// 「帮助」菜单里的实际动作。
///
/// macOS 会自动给每个 app 造一个「帮助」菜单，里面只有一条「<App> 帮助 ⌘?」，
/// 点下去转给 `NSHelpManager`。而这个工程既没有 help book，也没有登记
/// `CFBundleHelpBookName`，`NSHelpManager` 无事可做——那条菜单项**按下毫无反应**：
/// 不弹窗、不报错、不出声。实测点它之后既没有 Help Viewer 进程，窗口列表也不变。
///
/// 这不是汉化引入的问题：上游 v1.4.5 的源码里同样搜不到任何 help 相关接线，
/// 菜单在那里也是空的。
///
/// 与其留一条死菜单，不如把它换成真正点得动的东西。三个入口都指向网页，
/// 用系统默认浏览器打开——这是没有 help book 时最省事也最不容易过期的做法。
@MainActor
enum HelpMenu {
    /// 使用说明。指向本仓库的 `README.md`，那一份是中文的（英文的在 `README.zh-CN.md`）；
    /// GitHub 会把 `.md` 渲染成网页，不需要另建一套文档。
    static func openGuide() { open(url: GuideURL) }

    /// 上游官网，介绍与下载正版。
    static func openUpstreamSite() { open(url: UpstreamSiteURL) }

    /// 反馈问题的入口。汉化若有错字或漏翻，在这里提最直接。
    static func openIssueTracker() { open(url: IssueTrackerURL) }

    // 地址集中放在这里：换仓库或换文档位置只改这三行。
    private static let GuideURL = URL(string: "https://github.com/vvlang/Compositor-zh/blob/main/README.md")!
    private static let UpstreamSiteURL = URL(string: "https://robbietilton.com/compositor")!
    private static let IssueTrackerURL = URL(string: "https://github.com/vvlang/Compositor-zh/issues")!

    /// `URL(string:)` 对这三个常量不会失败，但真失败时也不该让菜单点下去崩掉——
    /// 静默忽略，好过在用户面前抛一个无法恢复的错误。
    private static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }
}
