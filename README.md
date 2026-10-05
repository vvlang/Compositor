# Compositor

> 🌐 **English**：[README.zh-CN.md](README.zh-CN.md) ｜ 简体中文（当前文件）

Adobe Photoshop 太贵，而 GIMP 那类工具的体验又不够贴近 Photoshop，让我的创作流总是被打断。正因如此，我建了 Compositor。

目标是做一个完全免费开源的全功能图像编辑器。我过去一直用 Photoshop 做合成与后期，所以 Compositor 是围绕这条工作流来设计的——一切工具都为能做出像素级精确的成片服务。

因为它是开源的，你可以下载 Xcode 工程，按自己的需要增删或修改任何功能。

## 安装

### 下载
从 [robbietilton.com/compositor](https://robbietilton.com/compositor) 获取 Compositor，或直接从 [GitHub Releases](https://github.com/robbietilton/Compositor/releases/latest) 下载最新发布版。

### Homebrew

```sh
brew install --cask robbietilton-compositor
```

## 功能

### 图层
- 图层与文件夹，各自带不透明度，并按 Photoshop 的全套混合模式顺序排列——文件夹的不透明度会作用于其内部所有内容
- 图层蒙版：可涂抹、填充、反相、模糊、羽化，且范围超出图层本身的像素；可链接/解除链接，从而单独变换蒙版
- 剪贴蒙版与文件夹蒙版
- 调整图层：色相/饱和度、色阶、曲线、曝光、渐变映射、颗粒、黑白、色彩平衡、反相、高斯模糊、动感模糊、降噪
- 图层样式：描边、投影、颜色叠加、内阴影、外发光、内发光——全部在 GPU 上实时渲染，可随时修改
- 向下合并、合并图层、合并组 (⌘E)
- 复制、内联重命名、拖拽重排与嵌套；启用链接或拖拽即复制；图层面板支持右键菜单
- 整图层与文件夹的复制粘贴 (⌘C/⌘V 且无选区)，可在同一工程内或跨工程之间复制，也可直接拖拽

### 变换
- 非破坏性的移动、缩放、旋转与翻转——图片永远保持原始分辨率
- 自由变形 (⌘-拖动手柄)，按住 Shift 锁定区间内一项
- 多图层或整个文件夹可一起变换
- 吸附到画布、图层边与中心，配合参考线使用
- 位置、尺寸、缩放、角度的精确数值，按方向键步进
- 水平/垂直翻转图层、水平/垂直翻转画布

### 选区
- 矩形与椭圆选框、自由与多边形套索，以及魔棒工具——魔棒按颜色选取，对象选择跟踪你点击的任何对象（Tab 在两模式间切换）
- 选择主体，以及扩展、收缩、羽化选区
- 选区相加与相减、移动轮廓、移动或复制选区内的像素
- 将图层像素或蒙版载入选区
- 内容识别填充，也可用于把图像延伸超出原边界

### 绘画与修饰
- 画笔带尺寸、硬度、高度与平滑，绘制或擦除模式 (B/E)，按住 Shift 画直线
- 污点修复画笔（内容识别）
- 仿制图章，可对齐或不对齐，可从一个图层或全部图层取样
- 模糊工具，可作用于像素或蒙版
- 渐变工具与形状工具（矩形、圆角矩形、椭圆、直线），保持可编辑而非栅格化
- 文字工具 (T)：在可拖动、可调整大小的段落框中内联多行编辑；字体、尺寸、颜色、对齐与字距在工具栏内；可变换文字并用作剪贴蒙版
- 吸管与完整的颜色选择器

### 调整与滤镜
- Camera Raw 滤镜：光线、颜色、曲线、颜色混合、调色、细节、光学、几何，置于画布侧边的面板中
- 色阶（带自动）、曲线、色相/饱和度、曝光、渐变映射、颗粒、黑白、色彩平衡、反相
- 高斯模糊、动感模糊，可超出图层边缘
- 添加杂色、晕影、辉光、色调对比、镜头校正、移除背景
- 实时预览，有选区时仅作用于选区

### 画布与文件
- 标签页式多工程
- 标尺 (⌘R)、从中拖出的参考线、可调间距与分段的布局网格，以及对参考线、网格、图层与画布边界的吸附
- 裁剪含吸附、预设比例（3:4、9:16 等），按住 Option 可对称裁剪；已有选区时从选区开始裁剪
- 画布大小、图像大小、裁掉边缘
- 缩小时的高质量降采样，缩放至足够大时显示像素网格
- 支持 JPEG、PNG、HEIC、TIFF、SVG、相机 RAW（需先执行显影），以及 Photoshop PSD 与 PSB（8-bit RGB，不支持 CMYK）的导入。Photoshop 的文件夹、蒙版、混合模式、填充矩形/椭圆、简单水平文字保持可编辑；其他矢量与垂直文字会栅格化为像素。开始导入前会显示转换报告
- 大文档：内存预算会按你的 Mac 自动调整；太大的 Photoshop 文件无法打开时，其图层会被裁剪到画布范围
- JPEG 导出含实时预览 (⇧⌥⌘S)；合并拷贝
- 工程存储中仍可继续编辑
- 全程仿照 Photoshop 的快捷键风格，可在 Edit > Keyboard Shortcuts 中重新映射
- 像 Photoshop 那样，可以拖动数值旁边的标签来刮擦调整
- 自动更新，已签名并公证

### 与 AI agent 协作
- AI agent 与脚本可以直接构造、修改工程：`.comp` 是一个装满 PNG 图层与清单的文件夹，已打开的工程会在被写入时实时刷新。参见 [Writing Compositor projects](docs/writing-comp-files.md)

## Requirements

- macOS 26.0 或更新版本，运行于 Apple Silicon Mac
- Xcode 26 或更新版本（用于从源码构建）

## 构建

用 Xcode 打开 `Compositor.xcodeproj`，运行 **Compositor** scheme 即可。

## 简体中文本地化 / Simplified Chinese Localization

> 🌐 [English](#simplified-chinese-localization) ｜ 简体中文（当前文件）

本仓库是上游 [robbietilton/Compositor](https://github.com/robbietilton/Compositor) 的简体中文本地化分支，
在上游英文版之上叠加了一套完整的界面汉化。**应用逻辑、文件格式、工程文件（`.comp`）与 manifest 的读写完全未改动**，
所有变更都局限在「显示层」与「翻译资源」。

### 界面文案

界面文案集中在单一文件 **`Compositor/Localizable.xcstrings`**（Xcode String Catalog），共 926 条 zh-Hans 译文。
源码里保留英文原文，通过 `L10n.swift` 的统一入口取词：

```swift
L10n.string("Brush")     // AppKit：NSMenuItem / toolTip / NSTextField
L10n.text("Brush")       // SwiftUI：Text
```

默认语言跟随系统，可在「系统设置 › 通用 › 语言与地区 › 应用程序」里为 Compositor 单独切换回英文。

### 一条硬性原则

> **英文字符串绝不能流进「被比较」或「被持久化」的位置。**

这条原则决定了整个改动的形态。翻译只发生在**显示路径**上；凡是参与相等比较、作为字典键、
或写入 `.comp` / manifest / `UserDefaults` 的字符串，一律保持英文原样。违反它不会崩溃，
而是**静默失效**——功能悄悄坏掉，最难排查。

典型的持久化位置包括：混合模式 `blendMode`、调整类型 `adjustment.kind`、
曲线/色阶通道、`transform.sampling`、HSV 范围（同时用作 JSON 字典键）、文字对齐方式。

### 上游合并时最需要留意的几处

为了让日后合并上游尽量少冲突，下面几处把「显示值」与「身份值」主动拆开了。
它们是**纯重构、行为不变**，即使上游不接受这些改动，汉化本身也不依赖它们：

| 位置 | 原来的写法 | 改后 |
|---|---|---|
| `UI/BlendModePicker.swift` | `NSMenuItem(title: rawValue)`，再靠 `title` 反查枚举 | 身份走 `representedObject`，标题走 `localizedName` |
| `UI/KeyboardShortcuts.swift` | `id = "\(group):\(title)"`，`group` 还参与逻辑比较 | `id` 与比较保持英文，新增 `displayTitle` / `displayGroup` 供显示 |
| `Document/DocumentHistory.swift` | `beginEdit(_ name: String)` | 形参改为 `String.LocalizationValue`，撤销名在读取时才解析 |
| `ContentView.swift` | 约 2,700 字符的嵌套三元状态提示 | 改写为 `switch`，逐分支本地化 |

### 辅助脚本

```sh
python3 scripts/gen-xcstrings.py    # 扫描源码，重新生成 xcstrings 骨架
bash    scripts/audit-localization.sh  # 校验键与源码是否对得上
bash    scripts/package-adhoc-dmg.sh   # 打 ad-hoc 签名的 DMG（无需证书与公证）
```

### 提交历史

改动按主题分成若干独立提交，便于上游按需取用或整体 `revert`：

```
b187379  prepare for localization without changing behavior   ← 纯重构，上游友好
b6250d3  route display sites through the catalog
ba82f1d  localize the interface in Simplified Chinese         ← 主体
dc2ddca  catch the strings the first pass missed
15786f8  translate documentation to Simplified Chinese
7cc5742 … 6093a21  translate comments (part 1–5 of 5)          ← 可独立丢弃
b79ae1b  build: add ad-hoc DMG packaging script
```

其中**注释汉化那 5 个提交**只改注释、不动任何代码。若上游不希望维护这份翻译，
可以只取前 6 个提交；反过来，若想整体撤掉注释汉化，`git revert 7cc5742^..6093a21` 即可。

## 发布

`scripts/release.sh` 会构建 Release 版本、用 Developer ID 签名、做公证并打固，最终输出 `dist/Compositor-<version>.dmg`。

它需要以下资源（全部保存在仓库外）：

- 一份 **Developer ID Application** 证书，保存在登录钥匙串里
- 通过 `xcrun notarytool store-credentials "compositor-notary" …` 保存的公证凭据
- [`create-dmg`](https://github.com/create-dmg/create-dmg)（`brew install create-dmg`）

## License

MIT —— 见 [LICENSE](LICENSE)。
