# 给 AI agent 的笔记

Compositor 是一个面向合成与照片后期的 macOS 图像编辑器，使用 Swift（SwiftUI 与 AppKit，部分像素相关代码用 C）实现。

## 设计或修改 Compositor 工程

如果任务是在 `.comp` 工程里增删或改动图像，你并不需要看 App 源代码。读 [docs/writing-comp-files.md](docs/writing-comp-files.md)：里面讲清文件格式、让工程能打开的规则，以及如何在工程打开时安全写入，从而让人能看到画布实时更新。

## 改动 App 本身

- 构建：用 Xcode 打开 `Compositor.xcodeproj` 并运行 **Compositor** scheme，或执行 `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build`。
- 测试：跑 `CompositorTests` 这个 target（`xcodebuild ... test -only-testing:CompositorTests`）。CI 在每次 push 时都会执行。
- 模仿周围代码的命名、注释密度与风格。
- 代码、注释和界面统一使用美式拼写（color，不出现 "colour"）。
- 工程文件格式在 [docs/project-format.md](docs/project-format.md) 里说明。凡是改了保存内容的地方，都要在那里以及 `ProjectManifest.current` 中把格式版本号 +1。
