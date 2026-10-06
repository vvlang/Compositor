# Compositor（合成器）

> 🌐 **English**：[README.md](README.md) ｜ 简体中文（当前文件）

Adobe Photoshop 价格太贵，而 GIMP 这类工具的界面又不够熟悉，让我无法保持创作节奏。这正是我开发 Compositor 的原因。

我的目标是打造一款**完全免费且开源的全功能图像编辑器**。我过去常用 Photoshop 完成合成与后期处理工作，因此 Compositor 完全围绕这套工作流构建——专注于提供打造像素级完美成图所需的工具。

因为它是开源项目，你可以下载 Xcode 工程源码，按需增删或修改任意功能，让它完美贴合你的工作流。

## 安装

### 下载

前往 [robbietilton.com/compositor](https://robbietilton.com/compositor) 获取 Compositor，或直接从 [GitHub Releases](https://github.com/robbietilton/Compositor/releases/latest) 下载最新版本。

### Homebrew

```sh
brew install --cask robbietilton-compositor
```

### 本仓库构建的 DMG：如何绕过 Gatekeeper

> 如果你用的是**上游官方发布版**，跳过这一节——它有 Developer ID 签名并已公证，开箱即用。

本仓库提供的 `dist/Compositor-<version>.dmg` 是用 `scripts/package-adhoc-dmg.sh` 构建的，
**没有 Apple 开发者证书**（ad-hoc 签名，也未经公证）。因此 Gatekeeper 会拦截它，
双击打开会提示：

> 「无法验证开发者」／「Compositor 已损坏，无法打开」

这是**预期行为，不是文件损坏**——签名是完整的，只是没有 Apple 背书。
macOS 对未签名的下载内容一律拦截，无法通过双击绕过。三种解法，任选其一：

**方法一：右键 → 打开（推荐，最省事）**

在 Finder 里 **右键点击 `Compositor.app` → 打开** → 弹窗里再点一次「打开」。
这条路径只对这一次生效，之后正常双击即可。

**方法二：清除隔离属性（批量分发时用这个）**

隔离属性是浏览器下载时打上的标记，清掉它 Gatekeeper 就不会再拦：

```sh
# 把 APP_PATH 换成实际路径
xattr -dr com.apple.quarantine /Applications/Compositor.app
```

较新的 macOS 还会额外打上 `com.apple.provenance` 属性。可以一并删掉：

```sh
xattr -dr com.apple.provenance /Applications/Compositor.app
```

> 该属性在部分系统上受保护，若报 `Operation not permitted` 属正常现象——
> 删掉 `com.apple.quarantine` 通常已经足够。

**方法三：系统设置里放行（一次性，对所有未签名应用生效）**

「系统设置 › 隐私与安全性」→ 往下滚到「安全性」→ 点「仍要打开」。

> 如果这一项是灰的，说明你还没先尝试过打开它——Gatekeeper 会在你尝试打开之后才把按钮放出来。

**自己重新构建的话**，用仓库里的脚本即可，它已经把 ad-hoc 重签一并做好了：

```sh
bash scripts/package-adhoc-dmg.sh
```

> 补充：`scripts/release.sh`（上游原版）需要 Developer ID 证书与公证凭据，
> 没有证书时用不了，别在这条路上浪费时间。

## 功能特性

### 图层
- 图层与文件夹，支持不透明度调整，沿用 Photoshop 全套混合模式（按原顺序排列）——文件夹的不透明度会影响其内部所有图层
- 图层蒙版：可在画布任意位置（包括图层像素之外）进行绘制、填充、反相、模糊和羽化；可链接或解链接以便单独变换蒙版
- 剪贴蒙版与文件夹蒙版
- 调整图层：色相/饱和度、色阶、曲线、曝光、渐变映射、颗粒、黑白色调、色彩平衡、反相、高斯模糊、动态模糊、噪点
- 图层效果：描边、投影、颜色叠加、内阴影、外发光、内发光（GPU 渲染，可随时编辑）
- 向下合并、合并图层、合并组（⌘E）
- 复制、内联重命名、拖拽重排与嵌套；按住 Option 拖拽复制；图层面板支持右键菜单
- 复制粘贴整个图层和文件夹（⌘C/⌘V，且无选区时），可在同一工程或不同工程之间使用，也可直接在工程间拖拽

### 变换
- 非破坏性的移动、缩放、旋转与翻转——无论你把它缩小到多小，图像始终保留完整分辨率
- 自由变形（⌘+拖拽控制点），按住 Shift 锁定单一轴向
- 可同时变换多个图层或整个文件夹
- 吸附到画布、图层边缘与中心，支持参考线
- 位置、尺寸、缩放、角度支持精确数值输入，可用方向键微调
- 水平/垂直翻转图层和翻转画布

### 选区
- 矩形/椭圆选框、自由/多边形套索，以及魔棒工具——魔棒按颜色选择，Object（对象）工具追踪你点击的任意内容（Tab 切换）
- 选择主体，以及对任意选区进行扩展、收缩、羽化
- 选区的添加/减去、移动轮廓，或者移动与复制选区内的像素
- 将图层的像素或蒙版作为选区载入
- 内容识别填充（也可用于延伸图像边缘）

### 绘画与修饰
- 画笔工具支持大小、硬度、不透明度与平滑度，可切换绘制/擦除模式（B 与 E），按住 Shift 画直线
- 污点修复画笔（内容识别）
- 仿制图章，支持对齐/非对齐模式，可从单层或所有图层取样
- 模糊工具，可作用于像素或蒙版
- 渐变工具与形状工具（矩形、圆角矩形、椭圆、线条），保持可编辑而非栅格化
- 文字工具（T）：在可拖拽、可调整大小的段落框内多行编辑；工具栏可设置字体、字号、颜色、对齐与间距；可变换文字并将文字作为剪贴蒙版
- 吸管与完整拾色器

### 调整与滤镜
- Camera Raw 滤镜：光线、颜色、曲线、色彩混色器、调色、细节、光学、几何——面板位于画布旁
- 色阶（含自动）、曲线、色相/饱和度、曝光、渐变映射、颗粒、黑白色调、色彩平衡、反相
- 高斯模糊与动态模糊，可越过图层边缘向外延伸
- 添加噪点、暗角、泛光/辉光、色调对比、镜头校正、移除背景
- 实时预览，存在选区时仅作用于选区内

### 画布与文件
- 多项目标签页
- 标尺（⌘R）、从标尺拖出参考线、可调间距与细分次数的网格，以及对参考线、网格、图层与文档边界的吸附功能
- 裁剪支持吸附，包含 3:4、9:16 等比例，按住 Option 启用对称裁剪；存在选区时从选区开始裁剪
- 画布大小、图像大小、裁切
- 缩小视图时使用高质量下采样，放大时显示像素网格
- 导入 JPEG、PNG、HEIC、TIFF、SVG、相机 RAW（需先经过 Raw Develop 处理）、Photoshop PSD 和 PSB（8 位 RGB，不支持 CMYK）。Photoshop 的文件夹、蒙版、混合模式、矩形/椭圆填充图形，以及简单的水平文字保持可编辑；其他矢量与垂直文字会转为像素。导入前会显示转换报告
- 大文档处理：内存预算会随 Mac 配置自动调整，过大的 Photoshop 文件打开时会将各图层裁剪到画布范围
- JPEG 导出带实时预览（⇧⌥⌘S）；拷贝合并
- 保存过程中可继续操作
- 全程采用 Photoshop 风格的快捷键，可在「编辑 > 键盘快捷键」中重新映射
- 拖动数字标签可平滑调整数值，如同 Photoshop
- 自动更新，已签名并公证

### 与 AI 代理协作
- AI 代理和脚本可直接构建和编辑工程：`.comp` 文件本质上是一个包含 PNG 图层和清单的文件夹，已打开的工程在你写入文件时会实时更新。详见[编写 Compositor 工程](docs/writing-comp-files.zh-CN.md)

## 系统要求

- Apple Silicon Mac，macOS 26.0 或更高版本
- Xcode 26 或更高版本（从源码构建时需要）

## 构建

打开 `Compositor.xcodeproj` 并运行 **Compositor** scheme。

## Simplified Chinese Localization

> 🌐 [简体中文](README.md#简体中文本地化--simplified-chinese-localization) ｜ English (current file)

This repository is a Simplified Chinese localization of upstream
[robbietilton/Compositor](https://github.com/robbietilton/Compositor). It layers a complete
Chinese interface on top of the upstream English release. **Application logic, the file
format, and all `.comp` / manifest reading and writing are unchanged** — every modification
is confined to the display layer and the translation resources.

### Interface strings

All interface strings live in a single file, **`Compositor/Localizable.xcstrings`** (an Xcode
String Catalog), holding 926 zh-Hans translations. The source keeps the English originals and
looks them up through one entry point in `L10n.swift`:

```swift
L10n.string("Brush")     // AppKit: NSMenuItem / toolTip / NSTextField
L10n.text("Brush")       // SwiftUI: Text
```

The default language follows the system. You can switch back to English per-app under
System Settings › General › Language & Region › Applications.

### The one hard rule

> **English strings must never reach a place where they are compared or persisted.**

This rule shapes the entire change set. Translation happens only on **display paths**. Any
string involved in an equality check, used as a dictionary key, or written to a `.comp`, a
manifest, or `UserDefaults` stays English. Violating it does not crash — it fails
**silently**, which is the hardest kind of bug to track down.

The persisted identifiers include: blend mode `blendMode`, adjustment type `adjustment.kind`,
curves/levels channels, `transform.sampling`, the HSV range (which doubles as a JSON
dictionary key), and text alignment.

### What to look at first when merging upstream

A few places deliberately separate the *display value* from the *identity value*, which
keeps future merges from upstream relatively painless. They are **pure refactors with no
behavior change**, and the localization itself does not depend on them — upstream is free
to decline them:

| Location | Before | After |
|---|---|---|
| `UI/BlendModePicker.swift` | `NSMenuItem(title: rawValue)`, then reverse-lookup the enum by `title` | identity moves to `representedObject`; the title uses `localizedName` |
| `UI/KeyboardShortcuts.swift` | `id = "\(group):\(title)"`, and `group` is also compared in logic | `id` and comparisons stay English; new `displayTitle` / `displayGroup` for display |
| `Document/DocumentHistory.swift` | `beginEdit(_ name: String)` | parameter becomes `String.LocalizationValue`; undo names resolve on read |
| `ContentView.swift` | a ~2,700-character nested ternary for the status hint | rewritten as a `switch`, each branch localized |

### Helper scripts

```sh
python3 scripts/gen-xcstrings.py      # rescan the source, regenerate the catalog skeleton
bash    scripts/audit-localization.sh # verify catalog keys still match the source
bash    scripts/package-adhoc-dmg.sh   # build an ad-hoc signed DMG (no certificate, no notarization)
```

### Commit history

The work is split into topic-scoped commits so upstream can cherry-pick what it wants, or
revert a group wholesale:

```
b187379  prepare for localization without changing behavior   ← pure refactor, upstream-friendly
b6250d3  route display sites through the catalog
ba82f1d  localize the interface in Simplified Chinese         ← the bulk of the work
dc2ddca  catch the strings the first pass missed
15786f8  translate documentation to Simplified Chinese
```

Comment translation is **not on `main`** — it lives on the `l10n-comments` branch. It
rewrites the comments in 10 core files, and those are precisely the ones that collide
with upstream hardest (`EditorCanvas.swift` alone accounts for 677 changed lines) while
contributing nothing at runtime. Keeping it on the trunk multiplies the conflict surface
of every upstream sync. Merge `l10n-comments` back in when you want the full version;
otherwise never think about it again.

### Syncing a new upstream release

```sh
git fetch upstream
git checkout -b sync/1.5.0 upstream/main
git rebase sync/1.5.0 main

# After resolving conflicts, always run these two — when upstream adds English copy that
# has no matching key in the catalog, SwiftUI silently falls back to the English literal
# and raises no error. Only the audit script can find it:
python3 scripts/gen-xcstrings.py       # rescan the source, add the new keys
bash    scripts/audit-localization.sh   # list whatever is still untranslated

xcodebuild -project Compositor.xcodeproj -scheme Compositor \
           -destination 'platform=macOS' test
```

`rerere` is enabled: conflict resolutions you have already worked out are recorded and
replayed automatically when upstream makes a similar change. The `upstream` remote is
configured **fetch-only** (its push URL is `DISABLED://`), so pushing upstream by mistake
is structurally impossible — only `origin` accepts pushes.

## 发布

`scripts/release.sh` 会构建 Release 版本，使用 Developer ID 签名，经 `notarytool` 公证并装订，最后打包为 `dist/Compositor-<version>.dmg`。

它需要以下依赖（均保存在仓库之外）：

- 登录钥匙串中的 **Developer ID Application** 证书
- 通过 `xcrun notarytool store-credentials "compositor-notary" …` 保存的公证凭据
- [`create-dmg`](https://github.com/create-dmg/create-dmg)（`brew install create-dmg`）

## 许可证

MIT —— 详见 [LICENSE](LICENSE)。