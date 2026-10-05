# 编写 Compositor 工程（给 AI agent 与脚本）

> 🌐 **English**：[docs/writing-comp-files.zh-CN.md](docs/writing-comp-files.zh-CN.md) ｜ 简体中文（当前文件）

Compositor 工程（`.comp`）是一个装满 PNG 图层和一份 `manifest.json` 的文件夹。任何能写文件的程序都能构建或修改它，而 Compositor 会随着文件改动实时刷新打开的画布。不需要插件或额外接口。

## 试一下

1. 在 Compositor 1.3 或更新版本里打开一个工程（先另存一个新画布，比如 `~/Desktop/demo.comp`），保持打开。
2. 让一个能在你 Mac 上编辑文件的 AI agent（Claude Code、Codex 之类）做这件事：

   > 读 github.com/robbietilton/Compositor 里的 docs/writing-comp-files.md，然后在 ~/Desktop/demo.comp 里画一张阴郁的夜色。一次写一两个图层，分步进行。

3. 盯着画布。每次 agent 写入工程，Compositor 就会重新读取它，通常不到半秒。

你能拿到的就是普通图层：选中、改不透明度或混合模式、在蒙版上涂画、存储。

## 包布局

```
Example.comp/
├── manifest.json
└── images/
    ├── 6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.png        图层像素
    └── 6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.mask.png   它的蒙版（可选）
```

一张铺满画布的最小工程：

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

- `layers` 按**从底到顶**排序：最后一个图层绘制在最上面。
- 编辑现有工程时保留 `documentID`。
- `transform` 用文档像素放置图层——`origin` 是左上角，`size` 是宽和高，`rotation` 用度表示，顺时针。图像会被拉伸到 `size`，因此图层可以比画布小（一块剪贴物配合 `origin` 放置）也可以缩放。
- `sampling` 可取 `"High quality"`、`"Smooth"` 或 `"Nearest"`。
- `opacity` 取值范围 0 到 1。

## 必须遵守的规则

违反任何一条，Compositor 会**静默地拒绝整个文件**：画布原封不动。如果什么都没更新，先看这些。
- **图片以图层命名。** 某图层 `"id": "6F1D…"` 必须用 `"imageFile": "6F1D….png"`，对应蒙版用 `"maskFile": "6F1D….mask.png"`，并且 ID 必须按清单所写的全大写形式。一个项目里 ID 唯一。
- **图片是放在 `images/` 里的 8-bit PNG。** 图层是 RGBA，蒙版是 8-bit 灰度（白显黑隐）。
- **混合模式的拼写必须精确**，按 Compositor 的命名：`Normal`、`Darken`、`Multiply`、`Color Burn`、`Linear Burn`、`Lighten`、`Screen`、`Color Dodge`、`Linear Dodge (Add)`、`Overlay`、`Soft Light`、`Hard Light`、`Vivid Light`、`Linear Light`、`Pin Light`、`Hard Mix`、`Difference`、`Exclusion`、`Subtract`、`Divide`、`Hue`、`Saturation`、`Color`、`Luminosity`。
- **清单里命名的每个图层都有对应的图片**，且清单本身是合法 JSON。

## 工程打开时安全写入

Compositor 在文件变化时立刻读，所以你绝不能留半个状态：

1. 先把所有新增或修改的 PNG 写到 `images/` 里。
3. 接着把清单写到一个临时文件里（包内的任意位置，例如 `.manifest.json.tmp`），然后用原子重命名覆盖 `manifest.json`。rename 是原子的：Compositor 看到的要么是旧清单要么是新清单，永远不会看到其中一半。

要改一个现有图层，保留它的 `id`，覆盖它的 PNG，然后重写清单。图层会在图层堆的同一位置就地更新。

清单不再引用的图片，过段时间就可以删掉。

Compositor 保存的工程里还有一个 `QuickLook` 目录（`Preview.jpg`），Finder 用空格键预览时会显示这张图。你修改工程后，把那个目录删掉，让 Finder 不要显示过时的预览；Compositor 下次保存时会重新写入。

## 打开的 App 行为

- 写入停止后约三分之一秒会重新载入。连续多次写入会合并为一次更新，如果观察者想看清每一步，写入之间要稍微停顿。
- 重载保留缩放、滚动与选区，但清空撤销历史（像重新打开文件一样）。
- 如果使用者自己还有未保存的修改，Compositor 会询问：放弃他们的改动保留你的，还是保留他们自己的。它不会悄悄覆盖。
- 一次失败写入会被忽略到下次写入为止，所以你写错了再改，也能正确显示。
- 修改是被识别的依据是清单内容和每张图的名称与尺寸，而不是文件写入时间。改写 PNG 通常会改变其字节大小。如果替换后字节大小完全相同，同时也要改清单（比如重命名图层）；只把清单原样写回去是不够的。

## 蒙版

用 `"maskFile": "<id>.mask.png"` 和 `"maskEnabled": true` 给任意图层加蒙版。蒙版覆盖图层自己的像素，所以与图层图片同尺寸。灰色代表半透明边缘。

## 调整图层

调整图层有 `adjustment` 对象且没有 `imageFile`，它会影响它下方的一切。每一类都携带恒等的 `levels`、`curves` 块以及自己的设置。一个偏暖的 Curves 调整图层：

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

- `ranges` 和 `channels` 按 RGB 然后红绿蓝的顺序排列。曲线控制点 x 从 0 到 255，x 单调递增。
- `kind` 是 `Hue/Saturation`、`Levels`、`Curves`、`Exposure`、`Gradient Map`、`Grain`、`Invert`、`Black & White`、`Color Balance`、`Gaussian Blur`、`Motion Blur`、`Add Noise` 之一。
- 对 Hue/Saturation，直接在调整对象上设 `hue`、`saturation`、`lightness`。Color Balance 用 `colorBalanceSettings` 对象（`shadowCyanRed`、`shadowMagentaGreen`、`shadowYellowBlue`，以及 `mid` 和 `highlight` 同名三组，每项 −100 到 100，再加上 `preserveLuminosity`）。
- 其它类型最容易拿到精确形状的办法：在 Compositor 里加一个，存储，再从那个工程的清单里复制出来。

## 更多

- 文件夹、文字图层、图层样式以及格式支持的其它全部内容：[project-format.md](project-format.md)。
- 限制：画布每边最多 30000 像素；图层与蒙版都会计入一个按 Mac 性能扩展的内存预算。