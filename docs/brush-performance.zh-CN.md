# 画笔渲染与 4K 基准测试

> 🌐 **English**：[docs/brush-performance.md](docs/brush-performance.md) ｜ 简体中文（当前文件）

画笔现在通过 Metal compute kernel 沿沿平滑后的指针路径扫描连续的圆形笔尖。每个发生变化的 256 × 256 切片在每次更新中被处理一次。永久覆盖层和临时笔尾使用独立的缓冲区，因此替换笔尾不会留下旧的像素。柔和覆盖通过对沿行进的颜料沉积进行积分累积，等价于直径间距 2.5% 的 source-over 笔尖。这能让自相交与笔尖平滑混合，并且与指针事件数量无关。不透明度设置会限制整个累积笔触。硬质笔尖保留其抗锯齿轮廓；软件回退使用 2.5% 柔和 / 1.5% 硬质笔尖间距。

鼠标抬起时会安装一个不可变的 `RasterSnapshot` 并同步记录撤销条目。快照共享未发生变化的切片并通过空间索引化索引来展开替换列表。范围在发生变化的切片中通过一个小型且经过优化的 C 例程查找，而不是在未优化的 Swift 中扫描每个文档像素。画布与随后的笔触直接读取这些切片。当导出或图像处理操作需要字节时，会惰性创建一个连续的 CGImage。蒙版使用相同的快照交接，包括在新增扩展区域中的白色覆盖。

Metal 管线由系统编译器编译一次，并在选择画笔时进行预热。这并不需要 Xcode 自带的可选 Metal 工具链。像素 kernel 在 Debug 配置下保持优化；Swift 代码保留其常规的 Debug 优化设置。

## 2026 年 9 月 12 日测得数据

4000 × 4000 文档，800 px 画笔，0% 硬度，100% 不透明度。两组笔触各 120 个指针更新，每次更新移动 40 个文档像素，运行在 fit 缩放下的原生 1000 × 1000 NSWindow 中。时间包含模型更新与 `CanvasView.synchronizeDisplay()` / `displayIfNeeded()`。鼠标抬起包含刷新、提交、历史记录与随后的显示。这些是同步的 CPU 时序，不是输入到显示的端到端测量，也不是 Photoshop 基准测试。

| Debug，空白绘画图层 | 改动前 | 改动后 |
| --- | ---: | ---: |
| 中位数指针更新 | 6.54 ms | 2.64 ms |
| 95 百分位更新 | 11.98 ms | 99 ms |
| 鼠标抬起，第一笔 | 1058 ms | 8.71 ms |
| 鼠标抬起，第二笔 | 1002 ms | 8.14 ms |

在已有的不透明 4K 图层上，新 800 px 画笔测得中位数 2.80 ms / 95 百分位 5.38 ms，鼠标抬起为 5.2–6.2 ms。40 px 画笔的中位数为 0.36–0.47 ms，鼠标抬起为 1.3–4.8 ms。计时因硬件、视口、图层堆栈与系统负载而异；不能假定一个与分辨率无关的固定帧率。

Release 配置同样构建并通过基准测试。其 800 px 空白图层中位数为 2.81 ms，鼠标抬起为 9.6–11.0 ms（原始 Release 鼠标抬起为 87–111 ms）。不透明图层的运行测得中位数 4.35 ms，鼠标抬起为 7.4–15.9 ms；这种差异进一步说明应使用测量区间而非承诺固定帧率。

最终 Debug 单元测试运行通过了 **171 个测试 / 25 个套件**。本次修改的日志位于 `/tmp/compositor-brush-final-tests.log`、`/tmp/compositor-brush-new-debug.log`、`/tmp/compositor-brush-new-release.log` 与 `/tmp/compositor-brush-baseline-debug.log`。

## 复现

单独运行性能测试，避免其他 main-actor 测试与基准竞争。`TEST_RUNNER_` 前缀将环境变量转发到 Xcode 测试宿主。

```sh
TEST_RUNNER_BRUSH_BENCHMARK=1 xcodebuild \
  -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
  -derivedDataPath /tmp/CompositorBrush -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  -parallel-testing-enabled NO \
  -only-testing:CompositorTests/BrushPerformanceTests test
```

基准测试会输出 `BRUSH BENCH` 日志行，并将 `/tmp/compositor-brush-benchmark.png` 导出用于可视化检查。它会同时在空白图层和不透明图层上运行。导出的示例包含两轮基准测试。

功能覆盖包括：800 px 连续柔和覆盖、切片边界、曲线/笔尾替换、不透明度、选区、变换后的图层、紧接其后的笔触、蒙版绘制/扩展、不可变快照、显示/导出的一致性、撤销/重做、保存/重新打开，以及软件回退。验证快照不会在提交、显示或下一次笔触过程中物化。

## 自相交修正

最初的连续笔尖实现取每个像素的最大衰减。这消除了笔尖纹路，但两段柔和边缘的交汇点会形成一道尖锐的折痕。柔和笔尖现在沿每个曲线段积分光密度，然后将累积密度转换为覆盖度。永久密度存储在浮点切片缓冲区中；临时笔尾保持独立，并被替换，绝不会被重复计算。硬质笔尖保留其实心轮廓。现有的不透明度上限与即时快照提交逻辑保持不变。

交叉测试将合并后的笔触与 source-over 覆盖进行比较，验证不透明度上限、重复刷新、软件回退，以及稀疏/密集采样下 12、120、520 px 笔尖的等价输出。对应的 520 px / 4K 示例通过 `BrushIntersectionTests/exportCrossingExample` 并设置 `TEST_RUNNER_BRUSH_BENCHMARK=1` 导出到 `/tmp/compositor-brush-crossing.png`。

经过修正后，800 px / 4K Debug 基准测得空白图层与不透明图层的中位数更新为 3.08–3.12 ms，鼠标抬起为 6.3–9.7 ms。日志：`/tmp/compositor-intersection-bench.log`。

修正后的完整 Debug 套件通过了 **175 个测试 / 26 个套件**（`/tmp/compositor-intersection-full.log`）。