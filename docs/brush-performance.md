# 画笔渲染与 4K 基准测试

画笔现在用一个 Metal compute kernel，沿平滑后的指针路径扫描一段连续的圆形笔尖。每个被改动的 256 × 256 tile 每帧只处理一次。永久覆盖和临时的笔尾使用各自独立的缓冲区，因此替换笔尾时不会留下旧的像素。柔边覆盖通过沿行走距离积分涂色沉积量来累积，相当于笔尖直径 2.5% 间距上的 source-over 叠加。这能让笔画的交叉和拐角被自然平滑地融合，且与点击事件数量无关。厚度设置决定整笔笔画的累计上限。硬边笔尖保留其抗锯齿轮廓；软件降级路径使用 2.5% 软笔 / 1.5% 硬笔的间距。

松开鼠标时同步安装不可变的 `RasterSnapshot` 并写入撤销记录。快照共享未改动的 tile，并用空间索引扁平化其替换列表。边界由一块小型优化过的 C routine 在改动的 tile 里查找，不再用未优化的 Swift 去扫描整张文档的像素。画布与之后的笔画直接读取 tile 数据。仅当导出或图像处理需要字节流时，才惰性创建连续的 CGImage。蒙版走的是同一种交接路径，包括新扩展区域内的白色覆盖。

Metal 流水线由系统编译器一次性编译，在选中画笔时被热启动。这不依赖 Xcode 的可选 Metal toolchain。Pixel kernel 在 Debug 构建中仍是优化过的；Swift 代码则保持其 Debug 默认的优化设置。

## 2026 年 9 月 12 日实测

4000 × 4000 画布，800 px 画笔，硬度 0%，不透明度 100%。每笔 120 次指针更新，每次 40 文档像素，原生 1000 × 1000 NSWindow，适应窗口大小显示。耗时包含模型更新与 `CanvasView.synchronizeDisplay()` / `displayIfNeeded()`。鼠标松开包含 flush、提交、历史记录与随后的重绘。这些是同步的 CPU 时长，不是输入到屏幕的延迟，也不是与 Photoshop 的对比。

| Debug，空画布层 | Before | After |
| --- | ---: | ---: |
| 中位指针更新 | 6.54 ms | 2.64 ms |
| 第 95 百分位更新 | 11.98 ms | 3.70 ms |
| 鼠标松开，第一笔 | 1058 ms | 8.71 ms |
| 鼠标松开，第二笔 | 1002 ms | 8.14 ms |

在已存在的不透明 4K 图层上，新版 800 px 画笔测得中位 2.80 ms / p95 5.38 ms，鼠标松开 5.2–6.2 ms。40 px 画笔测得中位 0.36–0.47 ms，鼠标松开 1.3–4.8 ms。耗时随硬件、视图、图层栈与系统负载变化；本文不暗示分辨率无关的固定帧率。

Release 也构建并跑通了基准测试。其 800 px 空图层中位 2.81 ms，鼠标松开 9.6–11.0 ms（原本 Release 的鼠标松开为 87–111 ms）。不透明图层的中位 4.35 ms，鼠标松开 7.4–15.9 ms；这种差异说明应该给出实测区间，而不是承诺固定帧率。

最终 Debug 单元测试跑通 **171 tests in 25 suites**。本变更的日志为 `/tmp/compositor-brush-final-tests.log`、`/tmp/compositor-brush-new-debug.log`、`/tmp/compositor-brush-new-release.log`、`/tmp/compositor-brush-baseline-debug.log`。

## 复现

把性能测试单独跑，避免其他 main-actor 测试与基准测试争资源。`TEST_RUNNER_` 会把环境变量转发进 Xcode 测试宿主。

```sh
TEST_RUNNER_BRUSH_BENCHMARK=1 xcodebuild \
  -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
  -derivedDataPath /tmp/CompositorBrush -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  -parallel-testing-enabled NO \
  -only-testing:CompositorTests/BrushPerformanceTests test
```

基准测试会输出 `BRUSH BENCH` 日志行，并把 `/tmp/compositor-brush-benchmark.png` 导出用于可视化检查。它既覆盖空图层也覆盖不透明图层，导出的示例中包含了两次基准测试的记录。

功能覆盖范围包括 800 px 的连续柔边覆盖、tile 边界、曲线与笔尾替换、不透明度、选区、变换后的图层、紧接着的后续笔画、蒙版绘制与扩展、不可变快照、显示与导出一致性、撤销/重做、存储与重新打开、以及软件降级路径。已验证快照在提交、显示或下一笔过程中都不会被实体化。

## 自相交修正

最初连续笔尖的实现是取每个像素处最大的羽化衰减。它消除了堆叠时的条纹，但两条羽化边相遇时会形成一道锐折痕。柔笔现在改为沿每段曲线积分光学密度，再把累计密度转换为覆盖。永久密度存放在浮点 tile 缓冲区里；临时笔尾仍是独立的，替换时不会重复计数。硬笔保持其实心轮廓。原有的不透明度上限与立即提交快照的逻辑不变。

交叉测试把组合的笔画与 source-over 覆盖作对比，验证不透明度上限、重复 flush、软件降级路径，以及在 12、120、520 px 笔尖上稀疏/密集采样输出一致性。520 px / 4K 的对应示例会在 `TEST_RUNNER_BRUSH_BENCHMARK=1` 下由 `BrushIntersectionTests/exportCrossingExample` 导出到 `/tmp/compositor-brush-crossing.png`。

经此修正，800 px / 4K 的 Debug 基准在空图层和不透明图层上测得中位更新 3.08–3.12 ms、鼠标松开 6.3–9.7 ms。日志：`/tmp/compositor-intersection-bench.log`。

修正后的完整 Debug 测试套件跑通 **175 tests in 26 suites**（`/tmp/compositor-intersection-full.log`）。
