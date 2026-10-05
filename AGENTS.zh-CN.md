# 给 AI 代理的笔记

> 🌐 **English**：[AGENTS.md](AGENTS.md) ｜ 简体中文（当前文件）

Compositor 是一款 macOS 图像编辑器，专注于合成与照片后期处理工作流，使用 Swift 编写（SwiftUI 与 AppKit 混合，底层涉及部分 C 代码用于像素处理）。

## 设计或编辑 Compositor 工程

如果你被要求创建或修改 `.comp` 工程中的图像，你并不需要查看应用的源码。请阅读 [docs/writing-comp-files.zh-CN.md](docs/writing-comp-files.zh-CN.md)：其中涵盖了文件格式、让工程能够被加载的规则，以及如何在工程打开时安全地写入文件，以便用户能够实时观察画布的更新。

## 修改应用本身

- **构建**：打开 `Compositor.xcodeproj` 并运行 **Compositor** scheme，或执行 `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build`。
- **测试**：`CompositorTests` target（`xcodebuild ... test -only-testing:CompositorTests`）。CI 会在每次推送时自动运行这些测试。
- **匹配现有代码风格**：包括命名约定、注释风格与注释密度。
- **使用美式拼写**："color" 而非 "colour"，适用于代码、注释与 UI 文案。
- 工程文件格式详见 [docs/project-format.zh-CN.md](docs/project-format.zh-CN.md)。任何对保存内容的改动都需要在该文件以及 `ProjectManifest.current` 中同步更新格式版本号。