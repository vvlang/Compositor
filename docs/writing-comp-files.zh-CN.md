# 编写 Compositor 工程（面向 AI 代理和脚本）

> 🌐 **English**：[docs/writing-comp-files.md](docs/writing-comp-files.md) ｜ 简体中文（当前文件）

Compositor 工程（`.comp` 文件）是一个由 PNG 图层图像与 `manifest.json` 组成的文件夹。任何能够写入文件的工具都可以构建或修改它，而 Compositor 会随着文件的更改实时更新已打开的画布。整个过程不需要插件或 API。

## 快速上手

1. 在 Compositor 1.3 或更高版本中打开一个工程（把新画布保存到任意位置，例如 `~/Desktop/demo.comp`），并保持它处于打开状态。
2. 让能够编辑你 Mac 上文件的 AI 代理（Claude Code、Codex 等）执行：

   > 读取 github.com/robbietilton/Compositor 仓库的 docs/writing-comp-files.zh-CN.md，然后在 ~/Desktop/demo.comp 中设计一个情绪化的夜景场景。分步进行，每次构建一到两个图层。

3. 观察画布。每次代理写入工程后，Compositor 通常在 0.5 秒内就会重新加载。

最终你得到的就是普通的图层：可以选取、调整不透明度与混合模式、在蒙版上绘画、保存。

## 工程包结构

```
Example.comp/
├── manifest.json
└── images/
    ├── 6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.png        图层的像素
    └── 6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.mask.png   图层蒙版（可选）
```

只含一个铺满画布图像层的 manifest 最小示例：

```json
{
  "format": "com.compositor.project",
  "version": 11,
  "colorSpace": "sRGB",
  "documentID": "0C5E7A91-3B2D-4F6A-8E1C-9D0B7A6F5E4D",
  "width": 1920,
  "height": 1080,
  "resolution": 72,
  "activeLayerID": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F",
  "layers": [
    {
      "id": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F",
      "name": "Background",
      "imageFile": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.png",
      "isVisible": true,
      "isGroup": false,
      "opacity": 1,
      "blendMode": "Normal",
      "transform": {
        "origin": [0, 0],
        "size": [1920, 1080],
        "rotation": 0,
        "flipX": false,
        "flipY": false,
        "sampling": "High quality"
      }
    }
  ]
}
```

- `layers` 数组按**从下到上**排列：最后一个图层绘制在最上面。
- 编辑已有工程时，请保留 `documentID` 不变。
- `transform` 以文档像素定位图层：`origin` 是图层的左上角，`size` 是其宽高，「scale\"rotation` 以度为单位，顺时针。图像会被拉伸到 `size`，因此图层可以小于画布（例如用 `origin` 摆放的剪切图层），也可以缩放。
- `sampling` 可为 `"High quality"`、`"Smooth"` 或 `"Nearest"`。
- `opacity` 取值范围为 0 到 1。

## 重要规则

违反以下任何一条规则，Compositor 都会**静默拒绝整个文件**：画布保持原样不做任何变化。如果更新没有发生，请先检查这些规则。

- **图像文件以图层 ID 命名**。一个 ID 为 `"6F1D…"` 的图层必须使用 `"imageFile": "6F1D….png"`，对应蒙版则使用 `"maskFile": "6F1D….mask.png"`，ID 必须与 manifest 中一致（大写）。每个 ID 在工程内必须唯一。
- **图像为 8 位 PNG**，存放在 `images/` 目录。图层图像为 RGBA；蒙版为 8 位灰度图（白色显示图层，黑色隐藏）。
- **混合模式的拼写必须精确**：Normal、Darken、Multiply、Color Burn、Linear Burn、Lighten、Screen、Color Dodge、Linear Dodge (Add)、Overlay、Soft Light、Hard Light、Vivid Light、Linear Light、Pin Light、Hard Mix、Difference、Exclusion、Subtract、Divide、Hue、Saturation、Color、Luminosity。
- **manifest 中列出的每个图层都必须有对应的图像文件**，且 manifest 必须是合法的 JSON。

## 工程已打开时安全地写入

Compositor 会在文件改动后立刻重新加载工程，因此永远不要把它写到一半：

1. 首先把所有新增或更改的 PNG 写入 `images/` 目录。
2. 然后将 manifest 写入包内的临时文件（例如 `.manifest.json.tmp`），再把它重命名覆盖原文件。重命名是原子操作，Compositor 看到的是完整的新版本或完整的旧版本，不会看到中间状态。

要修改一个已有图层，保留其 `id` 并覆盖对应的 PNG，然后重写 manifest。该图层就会在原位置原地更新。

当 manifest 中不再引用某些图像时，把它们删除即可。

Compositor 保存的工程还会包含一个 `QuickLook` 文件夹（`Preview.jpg`），用于在 Finder 的空格键预览中显示。当你修改工程时，请删除该文件夹，以免 Finder 显示过时的预览图；Compositor 在下次保存时会重新生成。

## 应用打开后会发生什么

- 在写入停止约 0.3 秒后会自动重新加载。连续快速写入会被合并为一次更新，如果要让观看者看清每一步，请在步骤之间稍作停顿。
- 重新加载会保留缩放、滚动位置与选区，但会清空撤销历史，就像重新打开文件那样。
- 如果用户在工程中有未保存的修改，Compositor 会提示他们选择回退到你的版本或保留自己的版本，绝不会静默覆盖。
- 加载失败的写入会被忽略，直到下一次正确的更改才会显示；因此一个错误只要被你修复，正确的版本就能加载出来。
- Compositor 是通过 manifest 内容以及每个图像的文件名和大小来判断变化的，而非文件写入时间。重新写入一个内容不同的 PNG 通常会改变其文件大小。如果用相同字节大小的图像替换原图，还需要同时改动 manifest（例如重命名图层）；仅写出相同的 manifest 字节是不够的。

## 在保 agent/macOS 上的细节

蒙版与图像文件名同步生成，存放在工程根 `images/` 子目录下。Compositor 内部通过文件系统的 file descriptor 来观察变更，能够即时感知而不依赖 mtime。

## 蒙版

通过 `"maskFile": "<id>.mask.png"` 与 `"maskEnabled": true` 给任意图层添加蒙版。蒙版覆盖图层自身的像素，因此其像素尺寸与图层图像一致。灰色提供柔和过渡。

## 调整图层

调整图层包含一个 `adjustment` 对象且没有 `imageFile`，它会影响其下方的所有图层。每种类型都包含 identity 值的 `levels` 与 `curves` 块，以及各自的设置。下面是一个暖色 Curves 调整层的示例：

```json
{
  "id": "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D",
  "name": "Warm Grade",
  "isVisible": true,
  "isGroup": false,
  "opacity": 1,
  "blendMode": "Normal",
  "transform": { "origin": [0, 0], "size": [1920, 1080], "rotation": 0, "flipX": false, "flipY": false, "sampling": "High quality" },
  "adjustment": {
    "kind": "Curves",
    "hue": 0, "saturation": 0, "lightness": 0, "colorize": false,
    "levels": { "channel": "RGB", "ranges": [
      { "black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255 },
      { "black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255 },
      { "black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255 },
      { "black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255 } ] },
    "curves": { "channel": "RGB", "channels": [
      [ { "x": 0, "y": 0 }, { "x": 255, "y": 255 } ],
      [ { "x": 0, "y": 0 }, { "x": 120, "y": 147 }, { "x": 255, "y": 255 } ],
      [ { "x": 0, "y": 0 }, { "x": 100, "y": 114 }, { "x": 255, "y": 255 } ],
      [ { "x": 0, "y": 0 }, { "x": 115, "y": 97 }, { "x": 255, "y": 238 } ] ] }
  }
}
```

- `ranges` 与 `channels` 按 RGB、红、绿、蓝顺序排列。曲线点的 x 从 0 到 255，且 x 必须递增。
- `kind` 可以是以下之一：`Hue/Saturation`、`Levels`、`Curves`、`Exposure`、`Gradient Map`、`Grain`、`Invert`、`Black & White`、`Color Balance`、`Gaussian Blur`、`Motion Blur`、`Add Noise`。
- 对于 Hue/Saturation，请在 `adjustment` 上设置 `hue`、`saturation` 和 `lightness`。Color Balance 使用一个 `colorBalanceSettings` 对象（包含 `shadowCyanRed`、`shadowMagentaGreen`、`shadowYellowBlue`，以及 `mid` 和 `highlight` 的相同字段，每个取值范围 −100 到 100，外加 `preserveLuminosity`）。
- 对于其他类型，获取精确形状最简单的方法是：在 Compositor 中添加一个、保存工程，然后从该工程的 manifest 中复制相应字段。

## 更多内容

- 文件夹、文字图层、图层效果以及其他格式承载的特性，详见 [project-format.zh-CN.md](project-format.zh-CN.md)。
- 限制：画布单边最大 30,000 像素；图层与蒙版的总像素数受 Mac 内存预算限制。