import SwiftUI
import UniformTypeIdentifiers

struct ImageLayer: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isVisible == rhs.isVisible && lhs.transform == rhs.transform
            && lhs.asset?.image === rhs.asset?.image && lhs.parentID == rhs.parentID && lhs.isGroup == rhs.isGroup && lhs.opacity == rhs.opacity && lhs.blendMode == rhs.blendMode && lhs.mask == rhs.mask && lhs.maskSourceID == rhs.maskSourceID && lhs.adjustment == rhs.adjustment && lhs.shape == rhs.shape && lhs.text == rhs.text && lhs.effects == rhs.effects
    }
    let id: UUID
    var asset: ImportedImage?
    var transform: LayerTransform
    var origin: CGPoint { transform.origin }
    var name: String
    var isVisible = true
    var parentID: UUID?
    var isGroup = false
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var maskSourceID: UUID?
    var mask: LayerMask?
    var adjustment: LayerAdjustment?
    /// 由形状工具创建的图层上会设置该项；见 `liveShape`。
    var shape: LayerShape?
    /// 绘制在图层周围的描边与投影，与该图层的像素分开存放。
    var effects: LayerEffects?
    var text: LayerText?
    nonisolated var size: CGSize { transform.size }

    init(asset: ImportedImage, origin: CGPoint) {
        self.id = UUID()
        self.asset = asset
        self.transform = LayerTransform(origin: origin, size: CGSize(width: asset.image.width, height: asset.image.height))
        self.name = asset.name
    }

    init(name: String, blankSize: CGSize) {
        self.id = UUID()
        self.asset = nil // Allocate pixels when painting begins, not when adding an empty layer.
        self.transform = LayerTransform(origin: .zero, size: blankSize)
        self.name = name
    }

    init(id: UUID, asset: ImportedImage?, name: String, isVisible: Bool, transform: LayerTransform, parentID: UUID? = nil, isGroup: Bool = false, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: LayerMask? = nil, maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil, shape: LayerShape? = nil, effects: LayerEffects? = nil, text: LayerText? = nil) {
        self.id = id
        self.asset = asset
        self.name = name
        self.isVisible = isVisible
        self.transform = transform
        self.parentID = parentID
        self.isGroup = isGroup
        self.opacity = opacity
        self.blendMode = blendMode
        self.mask = mask
        self.maskSourceID = maskSourceID
        self.adjustment = adjustment
        self.shape = shape
        self.effects = effects
        self.text = text
    }
}

struct CanvasDocument: Equatable {
    let id: UUID
    let width: Int
    let height: Int
    var resolution: Double = 72
    var layers: [ImageLayer] = [] // Bottom to top.
    /// 用户放置的对齐参考线。随工程保存，也纳入撤销。
    var guides: [CanvasGuide] = []
    /// 属于文档的一部分，因此选区变化也在撤销/重做范围内。不写入磁盘。
    var selection: DocumentSelection?
    var size: CGSize { CGSize(width: width, height: height) }
    init(id: UUID = UUID(), width: Int, height: Int, layers: [ImageLayer] = [], resolution: Double = 72, guides: [CanvasGuide] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.layers = layers
        self.resolution = resolution
        self.guides = guides
    }

    // 几何尺寸上限；光栅内存上限将在图像导入环节一并确定。
    static func validDimension(_ value: String) -> Int? {
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)),
              (1...DocumentLimits.maxSide).contains(n) else { return nil }
        return n
    }
}

enum NavigationTool: String, CaseIterable {
    case move, marquee, lasso, wand, crop, brush, spotHealing, cloneStamp, blur, gradient, shape, type, eyedropper, hand, zoom
    /// 未选择工具 (A)：工具栏中没有选中项，点击画布不会有任何反应。
    case idle
    /// 用笔尖绘制的工具，共用其尺寸、硬度、不透明度与快捷键。
    var isBrushTool: Bool { self == .brush || self == .spotHealing || self == .cloneStamp || self == .blur }
    /// 绘制和编辑选区的工具，共用修饰键、移动与微调操作。
    var isSelectionTool: Bool { self == .marquee || self == .lasso || self == .wand }
    var symbol: String { self == .type ? "textformat" : self == .eyedropper ? "eyedropper" : self == .marquee ? "rectangle.dashed" : self == .lasso ? "lasso" : self == .wand ? "wand.and.stars" : self == .brush ? "paintbrush.pointed" : self == .spotHealing ? "bandage" : self == .cloneStamp ? "seal" : self == .blur ? "drop" : self == .gradient ? "square.bottomhalf.filled" : self == .shape ? "square.on.circle" : self == .crop ? "crop" : self == .move ? "arrow.up.left.and.arrow.down.right" : self == .hand ? "hand.draw" : "magnifyingglass" }
    var label: String { self == .type ? "Type (T)" : self == .eyedropper ? "Eyedropper (I)" : self == .marquee ? "Marquee (M)" : self == .lasso ? "Lasso (L)" : self == .wand ? "Magic (W) · Tab switches Wand and Object" : self == .brush ? "Brush (B) · Eraser (E)" : self == .spotHealing ? "Spot Healing Brush (J)" : self == .cloneStamp ? "Clone Stamp (S) · Option-click sets the source" : self == .blur ? "Smear (R)" : self == .gradient ? "Gradient (G)" : self == .shape ? "Shape (U) · Shift-U switches Rectangle/Ellipse" : self == .crop ? "Crop (C)" : self == .move ? "Move / Transform (V)" : self == .hand ? "Hand (H)" : "Zoom (Z)" }
}

@Observable
final class EditorSession {
    var skipsInitialClipboardCanvasSize = false
    var document: CanvasDocument?
    var canvasFocusRequest = 0
    var showsSampleRing = true
    var adjustmentOriginal: LayerAdjustment?
    var adjustmentEditingID: UUID? { didSet { resumeFileRequests() } }
    /// 当前打开图层样式面板的图层。
    var effectsEditing: LayerEffectSelection?
    var effectsEditingOriginal: LayerEffects?
    var effectSelection: LayerEffectSelection?
    @ObservationIgnored var effectsPreviews = EffectsPreviewCache()
    var projectURL: URL?
    /// 立即阻止重叠的编辑。UI 不观察它：控件只在操作持续到值得提示时才通过
    /// `showsBusy` 变暗，因此快速操作（反相、填充、笔触提交）不会让界面闪一下。
    @ObservationIgnored var isProjectBusy = false {
        didSet {
            if !isProjectBusy {
                let waiters = projectWaiters
                projectWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            resumeFileRequests()
            updateBusyIndicator()
        }
    }
    /// 当 `isProjectBusy` 持续超过 `busyIndicatorDelay` 后为 true。
    private(set) var showsBusy = false
    static let busyIndicatorDelay: Duration = .milliseconds(250)
    @ObservationIgnored private var busyIndicatorTask: Task<Void, Never>?
    private func updateBusyIndicator() {
        if isProjectBusy {
            guard busyIndicatorTask == nil, !showsBusy else { return }
            busyIndicatorTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.busyIndicatorDelay)
                guard let self, !Task.isCancelled, self.isProjectBusy else { return }
                self.showsBusy = true
                self.busyIndicatorTask = nil
            }
        } else {
            busyIndicatorTask?.cancel()
            busyIndicatorTask = nil
            if showsBusy { showsBusy = false }
        }
    }
    private var projectWaiters: [CheckedContinuation<Void, Never>] = []
    private var fileRequestWaiters: [CheckedContinuation<Void, Never>] = []
    var canStartProjectOperation: Bool {
        _ = showsBusy // Re-evaluate in the UI when a long operation starts or ends.
        return selectionAmountOperation == nil && colorRange == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && adjustmentEditingID == nil && !showsConversionSheet
    }
    func waitForFileRequest() async {
        while !canStartProjectOperation {
            await withCheckedContinuation { fileRequestWaiters.append($0) }
        }
    }
    private func resumeFileRequests() {
        guard canStartProjectOperation else { return }
        let waiters = fileRequestWaiters
        fileRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func waitForProjectAccess() async {
        while isProjectBusy {
            await withCheckedContinuation { projectWaiters.append($0) }
        }
    }
    var viewport = CanvasViewport()
    var tool: NavigationTool = .move
    var collapsedGroupIDs: Set<UUID> = []
    var cropRect: CGRect?
    var cropRatioChoice = "Free"
    var cropError: String?
    var transformEdit: TransformEdit?
    @ObservationIgnored var distortPreviewCache: [UUID: DistortPreviewCache] = [:]
    @ObservationIgnored var distortEffectsCache: [UUID: DistortEffectsCache] = [:]
    /// 移动刚刚吸附到的文档位置，在持续期间以参考线的形式绘出。
    @ObservationIgnored var snapGuides: (xs: [CGFloat], ys: [CGFloat]) = ([], [])
    var snappingEnabled = true {
        didSet {
            if !snappingEnabled { snapGuides = ([], []) }
            refreshCanvasPreview?()
        }
    }
    /// 上一笔画笔结束的位置，因此 Shift-单击会从那里接着画一条直线。
    @ObservationIgnored var lastBrushPoint: (point: CGPoint, layerID: UUID, mask: Bool)?
    /// 开启「平滑」时画笔所在的位置——它会拖在指针后面（见 `smoothed`）。
    @ObservationIgnored var brushAnchor: CGPoint?
    /// 指针本身的位置，以便松开按钮后平滑笔触能追上它。
    @ObservationIgnored var brushPointer: CGPoint?
    @ObservationIgnored var maskDistortPreviewCache: MaskDistortPreviewCache?
    /// 进行中的变换上一次为各图层绘制的圆角矩形，连同绘制时的尺寸。
    @ObservationIgnored var shapeTransformPreviewCache: [UUID: (size: CGSize, image: CGImage)] = [:]
    var locksTransformRatio = true
    /// 默认关闭：移动工具的按下会拖动当前图层；按住 Cmd（或打开此项）则改为选取指针下的图层er.
    var transformAutoSelect = ToolDefaults.bool("autoSelect", false) { didSet { ToolDefaults.set(transformAutoSelect, "autoSelect") } }
    /// 移动工具的变换框与手柄 (⌘H)。隐藏时，在任意位置拖动都只是移动图层；
    /// 待定的 ⌘T 变换仍会显示其变换框。
    var showsTransformControls = ToolDefaults.bool("transformControls", true) { didSet { ToolDefaults.set(showsTransformControls, "transformControls") } }
    /// Option-拖动产生的副本，以及拖动之前的选区，以便 Esc 能把它们再撤掉。
    @ObservationIgnored var transformDuplicate: (copies: [UUID], source: Set<UUID>, primary: UUID?)?
    var brushSettings = BrushSettings() { didSet { refreshGradient() } }
    var spotHealingMode: SpotHealingMode = .contentAware
    var blurMode: BlurToolMode = .liquify
    /// 画笔的两种模式：绘制铺上前景色，擦除清除像素 (B 与 E)。
    var brushMode: BrushToolMode = .paint
    /// 工具栏的图标，随工具所处的模式而变。
    func symbol(for tool: NavigationTool) -> String {
        tool == .brush && brushMode == .erase ? "eraser" : tool.symbol
    }
    /// 魔棒工具的两种模式：魔棒按颜色选取，对象选择描摹指针下的对象 (Tab)。
    var wandMode: WandMode = .wand
    /// 仿制图章：Option-单击设定的取样源（文档像素）、其各项设置，以及——笔触开始之后——
    /// 对齐模式下画笔相对取样源保持的偏移量。
    var cloneSource: CGPoint?
    var cloneSettings = CloneSettings()
    /// 未在使用的那一侧的笔尖设置（尺寸、硬度、不透明度）：仿制图章保有自己的一套，
    /// 默认是柔边；而画笔与污点修复画笔共用一套。
    /// 未在使用的那一族画笔的笔尖设置：仿制图章与涂抹各自保有尺寸、硬度和不透明度
    /// （两者初始都是柔边）；其余画笔共用一套。
    @ObservationIgnored var parkedBrushTips: [Int: (diameter: CGFloat, hardness: CGFloat, opacity: CGFloat)] = [1: (40, 0, 1), 2: (40, 0, 1)]
    private static func tipFamily(_ tool: NavigationTool) -> Int { tool == .cloneStamp ? 1 : tool == .blur ? 2 : 0 }
    @ObservationIgnored var cloneOffset: CGSize?
    var maskPaintWhite = false { didSet { refreshGradient() } }
    var backgroundColor = PaletteColor.white { didSet { refreshGradient() } }
    var gradientSettings = GradientSettings() { didSet { refreshGradient() } }
    var gradientEdit: GradientEdit?
    var lassoDraft: LassoDraft?
    var lassoKind = LassoKind.freehand
    var marqueeKind = LassoKind.rectangle
    var textDraft: TextDraft? { didSet { if oldValue != nil && textDraft == nil { resumeFileRequests() } } }
    var textDefaults = LayerTextStyle()
    var shapeKind = ShapeKind.rectangle
    /// 形状工具绘制矩形时的圆角半径（像素）；0 表示保持直角。
    var shapeCornerRadius: Double = 0
    /// 直线形状的粗细（文档像素）。
    var shapeLineWidth: Double = 4
    /// 用形状工具拖出、尚未成为图层的那个形状。
    var shapeDraft: ShapeDraft?
    var selectionModeChoice = SelectionMode.replace
    /// 由当前按住的 Shift/Option 所隐含的模式；两者都未按住时为 nil。
    var heldSelectionMode: SelectionMode?
    /// 拖动移动开始时的选区状态；整段拖动算作一个撤销步骤。
    @ObservationIgnored var selectionMoveOrigin: DocumentSelection?
    var pixelMove: PixelMove?
    @ObservationIgnored var pixelClipboard: PixelClipboard?
    @ObservationIgnored var copiedLayer: CopiedLayer?
    var levels: LevelsEdit? { didSet { resumeFileRequests() } }
    var hueSaturation: HueSaturationEdit?
    /// 当前打开的滤镜（「滤镜」菜单），以及下一次打开时作为起点的设置。
    var filterEdit: FilterEdit?
    var filterSettings = FilterSettings()
    @ObservationIgnored var hueSaturationTask: Task<Void, Never>?
    /// 已有渲染任务进行中时，最新一次预览请求。
    @ObservationIgnored var hueSaturationPending: HueSaturationJob?
    /// 面板打开期间，已就位的吸管与指定调整工具。
    var hueSampleMode: HueSampleMode?
    var hueTargeting = false
    @ObservationIgnored var hueTargetDrag: HueTargetDrag?
    var selectionAntialiased = true
    /// 每次应用羽化时，选区边缘被柔化的程度（文档像素）。
    var selectionAmountOperation: SelectionAmountOperation? { didSet { resumeFileRequests() } }
    /// 「选择 > 色彩范围」面板已打开；按「好」之前显示的选区只是预览。
    var colorRange: ColorRangeEdit? { didSet { resumeFileRequests() } }
    /// 取色器当前打开于哪个对话框上（`ColorPickerTarget.dialog`）。
    @ObservationIgnored var dialogColorChange: ((PaletteColor) -> Void)?
    /// 某个带独立可缩放预览的对话框已打开（如导出 JPEG）：「显示」菜单的缩放命令会作用于该预览而d.
    @ObservationIgnored var previewZoom: ((PreviewZoomCommand) -> Void)?
    /// 字体菜单开始在文字上预览各种字形之前的样式（见 `previewFont`）。
    @ObservationIgnored var fontPreviewOriginal: LayerTextStyle?
    var selectionFeatherAmount = 2
    var wandSettings = WandSettings()
    var objectSelectionSettings = ObjectSelectionSettings()
    var showsPixelGrid = ToolDefaults.bool("pixelGrid", true) { didSet { ToolDefaults.set(showsPixelGrid, "pixelGrid") } }
    /// 布局网格（「显示 > 显示 > 网格」）。开启前不生效；与 800% 像素网格相互独立。
    var showsGrid = ToolDefaults.bool("grid", false) { didSet { ToolDefaults.set(showsGrid, "grid") } }
    /// 布局网格的间距与分段（「显示 > 网格设置…」）。属于使用者设置，不随工程保存。
    var layoutGrid = LayoutGrid(spacing: ToolDefaults.int("gridSpacing", 64), subdivisions: ToolDefaults.int("gridSubdivisions", 8)) {
        didSet {
            ToolDefaults.set(layoutGrid.spacing, "gridSpacing")
            ToolDefaults.set(layoutGrid.subdivisions, "gridSubdivisions")
        }
    }
    /// 布局网格的颜色、线型与不透明度（「显示 > 网格设置…」），同样属于使用者设置。
    var gridAppearance = GridAppearance(
        preset: GridAppearance.Preset(rawValue: ToolDefaults.string("gridColor", "")) ?? .lightGray,
        customColor: PaletteColor(hex: ToolDefaults.string("gridCustomColor", "")) ?? GridAppearance().customColor,
        style: GridAppearance.Style(rawValue: ToolDefaults.string("gridStyle", "")) ?? .lines,
        opacity: ToolDefaults.int("gridOpacity", GridAppearance().opacity)) {
        didSet {
            ToolDefaults.set(gridAppearance.preset.rawValue, "gridColor")
            ToolDefaults.set(gridAppearance.customColor.hex, "gridCustomColor")
            ToolDefaults.set(gridAppearance.style.rawValue, "gridStyle")
            ToolDefaults.set(gridAppearance.opacity, "gridOpacity")
        }
    }
    /// 用户参考线。被隐藏的多余参考线不参与吸附。
    var showsGuides = ToolDefaults.bool("guides", true) { didSet { ToolDefaults.set(showsGuides, "guides") } }
    var showsRulers = ToolDefaults.bool("rulers", false) { didSet { ToolDefaults.set(showsRulers, "rulers") } }
    /// 吸附总开关（「显示 > 吸附」）。打开它，今天设置的图层/画布吸附才能继续生效。
    var snapEnabled = ToolDefaults.bool("snap", true) { didSet { ToolDefaults.set(snapEnabled, "snap") } }
    var snapToGuides = ToolDefaults.bool("snapGuides", true) { didSet { ToolDefaults.set(snapToGuides, "snapGuides") } }
    var snapToGrid = ToolDefaults.bool("snapGrid", false) { didSet { ToolDefaults.set(snapToGrid, "snapGrid") } }
    var snapToLayers = ToolDefaults.bool("snapLayers", true) { didSet { ToolDefaults.set(snapToLayers, "snapLayers") } }
    var snapToDocumentBounds = ToolDefaults.bool("snapBounds", true) { didSet { ToolDefaults.set(snapToDocumentBounds, "snapBounds") } }
    var locksGuides = ToolDefaults.bool("lockGuides", false) { didSet { ToolDefaults.set(locksGuides, "lockGuides") } }
    var guideDrag: GuideDrag?
    /// 「扩展 / 收缩」按钮每次让选区增减的像素数。
    var selectionExpandAmount = 1
    var selectionContractAmount = 1
    @ObservationIgnored var pendingOpacityDigit: (digit: Int, time: TimeInterval)?
    var colorPicker: ColorPickerState?
    var brushError: String?
    var brushRevision = 0
    /// UI 不观察它，因此控件不会在每一笔的持续期间都变暗；
    /// 一笔之内始终沿用开始时的设置，所以笔触中途做的修改不会产生意外后果。
    @ObservationIgnored var brushStroke: BrushStroke? { didSet { resumeFileRequests() } }
    /// 正在进行的一笔涂抹或液化。
    @ObservationIgnored var warpStroke: WarpStroke? { didSet { resumeFileRequests() } }

    var canTransform: Bool {
        guard canEditLayers else { return false }
        // 选中的多个图层，或某个文件夹的内容，作为一个整体一起变换。
        if transformsAsGroup { return !groupTransformMembers.isEmpty }
        return activeLayer?.asset != nil && activeLayer?.isGroup == false && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
    }
    /// 选中了多个图层，或一个文件夹：变换会把它们（文件夹连同其全部内容）作为一个整体一起移动。
    var transformsAsGroup: Bool { selectedLayerIDs.count > 1 || (selectedLayerIDs.count == 1 && activeLayer?.isGroup == true) }
    /// 组合变换所作用的图层：被选中的可见像素图层，以及被选中文件夹内部的图层。
    var groupTransformMembers: [ImageLayer] {
        guard transformsAsGroup, let document else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        let visible = document.effectiveVisibleIDs
        return document.layers.filter { layer in
            guard layer.asset != nil, !layer.isGroup, visible.contains(layer.id) else { return false }
            var current: UUID? = layer.id
            for _ in 0..<64 {
                guard let id = current else { return false }
                if selectedLayerIDs.contains(id) { return true }
                current = parents[id] ?? nil
            }
            return false
        }
    }
    /// 包围 `groupTransformMembers` 的轴对齐矩形。
    var groupTransformBox: LayerTransform? {
        let points = groupTransformMembers.flatMap { DistortWarp.corners(of: $0.transform) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return LayerTransform(origin: CGPoint(x: minX, y: minY), size: CGSize(width: max(1, maxX - minX), height: max(1, maxY - minY)))
    }
    func selectLayer(_ id: UUID?) {
        effectSelection = nil
        if id != activeLayerID, !finishText() { return }
        guard brushStroke == nil, warpStroke == nil, levels == nil else { return }
        if id != activeLayerID { commitTransform(); resolveGradient() }
        activeLayerID = id
    }
    func selectTool(_ value: NavigationTool) {
        if tool != value, !finishText() { return }
        guard !isProjectBusy, brushStroke == nil, warpStroke == nil, levels == nil else { return }
        if tool != value { commitTransform(); cancelCrop(); resolveGradient(); cancelLasso(); cancelShape() }
        let from = Self.tipFamily(tool), to = Self.tipFamily(value)
        if from != to, let parked = parkedBrushTips[to] {
            parkedBrushTips[from] = (brushSettings.diameter, brushSettings.hardness, brushSettings.opacity)
            var settings = brushSettings
            settings.diameter = parked.diameter
            settings.hardness = parked.hardness
            settings.opacity = parked.opacity
            brushSettings = settings
        }
        tool = value
        if value.isBrushTool { _ = MetalBrushCoverage.shared }
        if value == .crop, cropRect == nil, let document {
            cropRatioChoice = "Free"
            let canvas = CGRect(origin: .zero, size: document.size)
            // 有选区时裁剪从其边界开始，与 Photoshop 一致：按 C，再按 Return 即裁到该选区。
            if let selection, !selection.isEmpty {
                let bounds = selection.path.boundingBoxOfPath.integral.intersection(canvas)
                cropRect = CropGeometry.valid(bounds) ? bounds : canvas
            } else {
                cropRect = canvas
            }
        }
    }
    /// Tab 在当前工具自己的各模式之间循环——也就是工具栏最左侧的那项设置。
    /// 没有模式的工具（移动、裁剪、文字、吸管、抓手、缩放）会忽略它。
    func cycleToolMode() {
        guard !isProjectBusy, brushStroke == nil, warpStroke == nil else { return }
        func next<T: CaseIterable & Equatable>(_ value: T) -> T where T.AllCases.Index == Int {
            let all = Array(T.allCases)
            let index = all.firstIndex(of: value) ?? 0
            return all[(index + 1) % all.count]
        }
        switch tool {
        case .marquee: toggleMarqueeKind()
        case .wand: wandMode = next(wandMode)
        case .lasso: toggleLassoKind()
        case .shape: toggleShapeKind()
        case .brush: brushMode = next(brushMode)
        case .blur: blurMode = next(blurMode)
        case .spotHealing: spotHealingMode = next(spotHealingMode)
        case .cloneStamp: cloneSettings.sampleAllLayers.toggle()
        case .gradient: gradientSettings.shape = next(gradientSettings.shape)
        default: break
        }
    }

    func beginTransform(persistent: Bool = true) {
        cancelCrop()
        guard transformEdit == nil, canTransform, let layer = activeLayer else { return }
        tool = .move
        if transformsAsGroup {
            let members = groupTransformMembers
            guard let box = groupTransformBox else { return }
            transformEdit = TransformEdit(layerID: layer.id, draft: box, persistent: persistent,
                group: TransformGroup(box: box, originals: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.transform) })))
            return
        }
        // 未链接的蒙版在选中时单独参与变换；已链接时图层与蒙版一起移动。
        let maskAlone = isMaskSelected && layer.mask?.isLinked == false
        transformEdit = TransformEdit(layerID: layer.id, draft: maskAlone ? layer.maskTransform : layer.transform,
                                      persistent: persistent, mask: maskAlone)
    }
    func previewTransform(_ value: LayerTransform) {
        guard value.isValid, transformEdit != nil else { return }
        transformEdit?.draft = value
    }
    /// Option-拖动会复制所选的根图层及其所有后代，并拖动这些副本。
    func beginDuplicateTransform() {
        guard transformDuplicate == nil, let primary = activeLayerID else { return }
        commitTransform()
        guard canTransform else { return }
        let selection = selectedLayerIDs
        // 从底到顶遍历，使副本保持原有顺序。
        let carried = selection.reduce(into: Set<UUID>()) { $0.formUnion(descendantIDs(of: $1)) }
        let targets = (document?.layers ?? []).filter { selection.contains($0.id) && !carried.contains($0.id) }.map(\.id)
        guard !targets.isEmpty else { return }
        beginEdit(targets.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
        // 与「复制图层」的堆叠方式一致：多个副本一起放在最上方的原图层之上。
        duplicateLayers(targets)
        let copies = selectedLayerIDs.subtracting(selection)
        guard !copies.isEmpty else { endEdit(); selectLayers(selection, primary: primary); return }
        transformDuplicate = (Array(copies), selection, primary)
        selectLayers(copies, primary: activeLayerID)
        beginTransform(persistent: false)
    }
    func commitTransform() {
        snapGuides = ([], [])
        blendPreview = nil
        finishOpacityEdit()
        guard let edit = transformEdit else { return }
        defer {
            if transformDuplicate != nil { transformDuplicate = nil; endEdit() }
        }
        transformEdit = nil
        if let floating = edit.floating {
            // 未改变的情况：原样恢复，避免柔边选区出现接缝。
            if edit.draft == floating.original && edit.corners == nil { cancelFloatingTransform(floating) }
            else { mergeFloatingTransform(edit, floating) }
            return
        }
        if edit.mask { commitMaskTransform(edit); return }
        if let corners = edit.corners { commitDistort(edit, corners: corners); return }
        if let group = edit.group {
            guard edit.draft.isValid else { return }
            beginEdit("Transform Layers")
            for (id, original) in group.originals {
                guard let index = document?.layers.firstIndex(where: { $0.id == id }) else { continue }
                let moved = original.following(from: group.box, to: edit.draft)
                guard moved.isValid else { continue }
                if let mask = document?.layers[index].mask {
                    document?.layers[index].mask?.placement = mask.placement(movingLayer: original, to: moved)
                }
                document?.layers[index].transform = moved
                redrawShape(at: index)
            }
            endEdit()
            return
        }
        guard edit.draft.isValid, let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }) else { return }
        beginEdit("Transform Layer")
        if let mask = document?.layers[index].mask, let old = document?.layers[index].transform {
            document?.layers[index].mask?.placement = mask.placement(movingLayer: old, to: edit.draft)
        }
        document?.layers[index].transform = edit.draft
        redrawShape(at: index)
        endEdit()
    }
    func cancelTransform() {
        snapGuides = ([], [])
        guard let edit = transformEdit else { return }
        transformEdit = nil
        if let duplicate = transformDuplicate {
            let removed = duplicate.copies.reduce(into: Set(duplicate.copies)) { $0.formUnion(descendantIDs(of: $1)) }
            document?.layers.removeAll { removed.contains($0.id) }
            collapsedGroupIDs.subtract(removed)
            selectLayers(duplicate.source, primary: duplicate.primary)
            transformDuplicate = nil
            endEdit()
        }
        if let floating = edit.floating { cancelFloatingTransform(floating) }
    }
    /// 变换所放置的像素——也就是 100% 缩放下 1:1 绘制的部分。没有像素的图层为 nil。
    var transformPixelSize: CGSize? {
        if let group = transformEdit?.group { return group.box.size }
        if transformEdit == nil, transformsAsGroup { return groupTransformBox?.size }
        if transformTargetsMask { return nil }
        if let floating = transformEdit?.floating { return floating.pixelSize }
        guard let image = activeLayer?.asset?.image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }
    func displayedTransform(for layer: ImageLayer) -> LayerTransform {
        if let pending = pendingTransform(for: layer) { return pending }
        // 超出图层边界的内容识别填充，会在扩展后的图层上预览。
        if let edit = filterEdit, let grown = edit.preparedTransform, edit.previewImage(for: layer.id) != nil { return grown }
        return layer.transform
    }
    /// 变换是否只作用于当前图层的蒙版（在图层面板中选中了未链接的蒙版）。
    var transformTargetsMask: Bool { transformEdit.map(\.mask) ?? (isMaskSelected && activeLayer?.mask?.isLinked == false) }
    /// `layer` 的变换手柄所在位置：待定编辑的草稿——该图层或其蒙版的——否则就是该图层本身。
    func editedTransform(for layer: ImageLayer) -> LayerTransform {
        if transformEdit?.layerID == layer.id { return transformEdit!.draft }
        if transformEdit == nil, layer.id == activeLayerID, transformsAsGroup, let box = groupTransformBox { return box }
        return layer.id == activeLayerID && transformTargetsMask ? layer.maskTransform : layer.transform
    }
    /// 待定编辑下某图层的变换：被编辑图层的草稿；组合中的每个图层则沿用包围盒；
    /// 若该编辑不移动它，则为 nil。
    func pendingTransform(for layer: ImageLayer) -> LayerTransform? {
        guard let edit = transformEdit, !edit.mask else { return nil }
        if let group = edit.group { return group.originals[layer.id].map { $0.following(from: group.box, to: edit.draft) } }
        return edit.layerID == layer.id ? edit.draft : nil
    }
    func nudgeLayer(dx: CGFloat, dy: CGFloat) {
        let alreadyEditing = transformEdit != nil
        if !alreadyEditing { beginTransform(persistent: false) }
        guard var value = transformEdit?.draft else { return }
        value.origin.x += dx
        value.origin.y += dy
        previewTransform(value)
        if let corners = transformEdit?.corners { previewCorners(corners.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }) }
        if !alreadyEditing { commitTransform() }
    }
    var showsNewDocument = false { didSet { resumeFileRequests() } }
    var showsImporter = false { didSet { resumeFileRequests() } }
    var isImporting = false { didSet { resumeFileRequests() } }
    var importError: String? { didSet { resumeFileRequests() } }
    var showsConversionSheet = false { didSet { resumeFileRequests() } }
    var conversionRequest: PSDConversionRequest?
    /// 测试会赋此值以跳过转换确认面板。
    @ObservationIgnored var confirmConversions: (([PSDConversion]) async -> Bool)?
    /// 正在显影的 RAW 文件，以及该面板正在编辑的设置（见 RawImporter）。
    var rawDevelop: (url: URL, settings: RawDevelopSettings)?
    var showsRawDevelop = false { didSet { resumeFileRequests() } }
    @ObservationIgnored private var rawContinuation: CheckedContinuation<RawDevelopSettings?, Never>?
    /// 测试会赋此值以在不显示面板的情况下直接显影。
    @ObservationIgnored var confirmRawDevelop: ((URL, RawDevelopSettings) async -> RawDevelopSettings?)?

    /// 弹出显影面板并等待用户的选择；返回 nil 表示导入被取消。
    func developRaw(_ url: URL) async -> RawDevelopSettings? {
        let asShot = RawImporter.asShot(url) ?? RawDevelopSettings()
        if let confirmRawDevelop { return await confirmRawDevelop(url, asShot) }
        return await withCheckedContinuation { continuation in
            rawContinuation = continuation
            rawDevelop = (url, asShot)
            showsRawDevelop = true
        }
    }
    func finishRawDevelop(_ settings: RawDevelopSettings?) {
        showsRawDevelop = false
        rawDevelop = nil
        Task { await RawImporter.Queue.shared.release() }
        let continuation = rawContinuation
        rawContinuation = nil
        continuation?.resume(returning: settings)
    }
    @ObservationIgnored private var conversionContinuation: CheckedContinuation<Bool, Never>?
    /// 在 Photoshop 文件仍在读取时按下了取消。
    @ObservationIgnored private var conversionCancelled = false
    var opacityEditLayerID: UUID?
    var blendPreview: (layerID: UUID, mode: LayerBlendMode)?
    @ObservationIgnored var refreshCanvasPreview: (() -> Void)?
    var isMaskSelected = false { didSet { if !isMaskSelected { viewsMaskAlone = false } } }
    /// 在蒙版缩略图上 Option-单击：画布会以灰度单独显示目标蒙版，使其不受其他内容干扰地
    /// 被绘制，与 Photoshop 的做法相同。改为针对图层像素或另一个图层时即结束该状态。
    var viewsMaskAlone = false
    /// 画布正单独显示其蒙版的那个图层；普通合成时为 nil。
    var maskAloneLayer: ImageLayer? {
        guard viewsMaskAlone, isMaskSelected, let layer = activeLayer, layer.mask != nil else { return nil }
        return layer
    }
    var selectedLayerIDs: Set<UUID> = []
    var activeLayerID: UUID? {
        didSet {
            if activeLayerID != oldValue { isMaskSelected = false }
            selectedLayerIDs = activeLayerID.map { [$0] } ?? []
        }
    }
    var renamingLayerID: UUID? { didSet { resumeFileRequests() } }
    let history = DocumentHistory()
    var isModified: Bool { history.isModified }
    var canUseHistory: Bool {
        _ = showsBusy
        return selectionAmountOperation == nil && colorRange == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && transformEdit == nil && !showsConversionSheet
    }
    var canUndo: Bool { canUseHistory && (history.canUndo || gradientEdit != nil) }
    var canRedo: Bool { canUseHistory && history.canRedo }

    func undo() {
        // 与 Photoshop 一样，第一次撤销会丢弃待定的渐变。
        if gradientEdit != nil { cancelGradient(); return }
        guard canUndo, let snapshot = history.undo() else { return }
        restore(snapshot)
    }

    func redo() {
        guard canRedo, let snapshot = history.redo() else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: DocumentHistory.Snapshot) {
        cancelCrop()
        cancelGradient()
        let changedCanvas = document?.id != snapshot.document?.id
        let keepMaskTarget = isMaskSelected && activeLayerID == snapshot.activeLayerID
        document = snapshot.document
        activeLayerID = snapshot.activeLayerID
        isMaskSelected = keepMaskTarget && activeLayer?.mask != nil
        if changedCanvas, let document { viewport.fit(documentSize: document.size) }
    }

    /// 可嵌套的事务边界；未来的工具可以用它把一个完整手势归为一组。
    /// 名称以未翻译的形式保存，这样切换语言后菜单也能跟着变。
    func beginEdit(_ name: String.LocalizationValue) {
        history.begin(name, document: document, selection: activeLayerID)
    }

    func endEdit() { history.end(document: document, selection: activeLayerID) }
    var activeLayer: ImageLayer? { document?.layers.first { $0.id == activeLayerID } }
    var canEditLayers: Bool {
        _ = showsBusy
        return selectionAmountOperation == nil && colorRange == nil && textDraft == nil && document != nil && brushStroke == nil && warpStroke == nil && !isProjectBusy && !isImporting && !showsNewDocument && !showsImporter && renamingLayerID == nil && transformEdit == nil && cropRect == nil && gradientEdit == nil && pixelMove == nil && hueSaturation == nil && levels == nil && filterEdit == nil && adjustmentEditingID == nil
    }

    func addBlankLayer() {
        guard canEditLayers, let document else { return }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        var layer = ImageLayer(name: "Layer \(number)", blankSize: document.size)
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        var insertion = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        // 选中了文件夹时，图层进入该文件夹的顶部：就在其最后一个（最上层的）内容之上。
        if activeLayer?.isGroup == true, let folder = activeLayerID {
            let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
            func isInside(_ id: UUID) -> Bool {
                var parent = parents[id] ?? nil
                var steps = 0
                while let current = parent, steps < 64 {
                    if current == folder { return true }
                    parent = parents[current] ?? nil
                    steps += 1
                }
                return false
            }
            if let topmost = document.layers.lastIndex(where: { isInside($0.id) }) { insertion = max(insertion, topmost + 1) }
        }
        beginEdit("New Blank Layer")
        defer { endEdit() }
        self.document?.layers.insert(layer, at: insertion)
        activeLayerID = layer.id
    }

    func deleteLayer(_ id: UUID) {
        guard canEditLayers, document?.layers.contains(where: { $0.id == id }) == true else { return }
        guard !deleteWithLiveMaskChoice(id) else { return }
        finishDeletingLayer(id, baked: [:])
    }

    func deleteActiveLayer() {
        if let activeLayerID { deleteLayer(activeLayerID) }
    }

    /// 把所有选中的图层作为一个撤销步骤删除（选中文件夹时会连同其内容一起删除）；
    /// 只选中一个图层时，则只删该图层。
    func deleteSelectedLayers() {
        guard canEditLayers, let document else { return }
        // 先取快照：删除操作会改变当前图层，从而重置选区。
        let ids = document.layers.map(\.id).filter(selectedLayerIDs.contains)
        guard ids.count > 1 else { deleteActiveLayer(); return }
        guard !deleteWithLiveMaskChoice(ids) else { return }
        finishDeletingLayers(ids, baked: [:])
    }

    func renameLayer(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isProjectBusy, !isImporting, !name.isEmpty, let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Rename Layer")
        defer { endEdit() }
        document?.layers[index].name = name
    }

    func toggleLayerVisibility(_ id: UUID) {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        beginEdit(document?.layers[index].isVisible == true ? "Hide Layer" : "Show Layer")
        defer { endEdit() }
        document?.layers[index].isVisible.toggle()
    }

    /// Photoshop 的眼睛横扫：按下某个眼睛可显示或隐藏该图层，拖过其他眼睛则把它们设为同一状态，
    /// 整体算作一个撤销步骤（按下时 `beginEdit`，松开时 `endEdit`）。
    func beginVisibilitySwipe(_ id: UUID) -> Bool? {
        guard canEditLayers, let layer = document?.layers.first(where: { $0.id == id }) else { return nil }
        let visible = !layer.isVisible
        beginEdit(visible ? "Show Layer" : "Hide Layer")
        setVisibilityInSwipe(id, visible: visible)
        return visible
    }
    func setVisibilityInSwipe(_ id: UUID, visible: Bool) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].isVisible != visible else { return }
        document?.layers[index].isVisible = visible
    }
    func endVisibilitySwipe() { endEdit() }

    func reorderLayers(from offsets: IndexSet, to destination: Int) {
        guard canEditLayers, var layers = document?.layers.reversed().map({ $0 }),
              offsets.allSatisfy({ layers.indices.contains($0) }), (0...layers.count).contains(destination) else { return }
        // 列表顺序是从上到下；合成器内部则按从底到顶存储。
        layers.move(fromOffsets: offsets, toOffset: destination)
        beginEdit("Reorder Layers")
        defer { endEdit() }
        document?.layers = layers.reversed()
    }

    func canMoveActiveLayer(by offset: Int) -> Bool {
        guard canEditLayers, let activeLayer else { return false }
        let siblings = document?.layers.filter { $0.parentID == activeLayer.parentID } ?? []
        guard let index = siblings.firstIndex(where: { $0.id == activeLayer.id }) else { return false }
        return siblings.indices.contains(index + offset)
    }
    func moveActiveLayer(by offset: Int) {
        guard canMoveActiveLayer(by: offset), let activeLayer, let layers = document?.layers else { return }
        let siblings = layers.filter { $0.parentID == activeLayer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == activeLayer.id }),
              let a = layers.firstIndex(where: { $0.id == activeLayer.id }),
              let b = layers.firstIndex(where: { $0.id == siblings[index + offset].id }) else { return }
        beginEdit("Reorder Layers")
        document?.layers.swapAt(a, b)
        endEdit()
    }
    private struct ImportRequest {
        let files: [(url: URL, scoped: Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var pendingImports: [ImportRequest] = []

    func importImages(_ urls: [URL], at point: CGPoint? = nil) async {
        guard !urls.isEmpty else { return }
        if brushStroke != nil { await finishBrush() }
        cancelCrop()
        commitTransform()
        // 在请求排队等待解码完成期间，保持沙盒授权。
        let files = urls.map { (url: $0, scoped: $0.startAccessingSecurityScopedResource()) }
        await waitForProjectAccess()
        await withCheckedContinuation { completion in
            pendingImports.append(ImportRequest(files: files, point: point, completion: completion))
            if !isImporting {
                isImporting = true
                Task { await drainImports() }
            }
        }
    }

    private func drainImports() async {
        var failures: [String] = []
        while !pendingImports.isEmpty {
          let request = pendingImports.removeFirst()
          let psdOnly = request.files.allSatisfy { PSDReader.matches($0.0) }
          beginEdit(psdOnly ? "Import Photoshop File" : "Import Images")
          // 尚无文档：第一张成功导入的图像决定画布大小，与拖放位置无关。
          let point = document == nil ? nil : request.point
          for (url, scoped) in request.files {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL else { throw ImageImportError.unsupported }
                let usedPixels = document?.layers.reduce(0) { total, layer in
                    guard let image = layer.asset?.image else { return total }
                    return total + image.width * image.height
                } ?? 0
                if RawImporter.matches(url) {
                    guard let size = RawImporter.pixelSize(url) else { throw ImageImportError.unreadable }
                    guard size.width <= DocumentLimits.maxSide, size.height <= DocumentLimits.maxSide,
                          size.width * size.height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ImageImportError.tooLarge }
                    guard let settings = await developRaw(url) else { continue }
                    // 耗时以秒计：必须离开主 actor，否则按下导入会让窗口卡死。
                    guard let developed = await RawImporter.Queue.shared.develop(url, settings: settings, limit: nil)
                    else { throw ImageImportError.unreadable }
                    let thumbnail = try PixelAdjust.thumbnail(of: developed)
                    insert(ImportedImage(image: developed, thumbnail: thumbnail,
                                         name: url.deletingPathExtension().lastPathComponent), centeredAt: point)
                } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true {
                    let asset = try await ImageImporter.shared.decodeSVG(url, fitting: document?.size,
                                                                         remainingPixels: DocumentLimits.documentPixelBudget - usedPixels)
                    insert(asset, centeredAt: point)
                } else if PSDReader.matches(url) {
                    beginPSDReading(title: "Open “\(url.lastPathComponent)”?", confirmTitle: "Import")
                    let imported: PSDImport
                    do {
                        let parsed = try await ImageImporter.shared.loadPhotoshop(url, remainingPixels: DocumentLimits.documentPixelBudget - usedPixels)
                        // 仅当它只是背景时：Photoshop 不写任何图层记录，只有合并后的图像，
                        // 因此导入的也就是它，作为单个图层。
                        if parsed.layers.isEmpty {
                            endPSDReading()
                            let asset = try await ImageImporter.shared.decode(url, remainingPixels: DocumentLimits.documentPixelBudget - usedPixels,
                                                                              flattenedPhotoshop: true)
                            insert(asset, centeredAt: point)
                            continue
                        }
                        let assets = try await ImageImporter.shared.photoshopAssets(parsed)
                        imported = try PSDDocumentBuilder.makeImport(parsed, assets: assets)
                    } catch {
                        endPSDReading()
                        throw error
                    }
                    if !(await finishPSDReading(imported.conversions)) { continue }
                    try insertPhotoshop(imported, named: url.deletingPathExtension().lastPathComponent, centeredAt: point)
                } else {
                    let asset = try await ImageImporter.shared.decode(url, remainingPixels: DocumentLimits.documentPixelBudget - usedPixels)
                    insert(asset, centeredAt: point)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
          }
          endEdit()
          request.completion.resume()
        }
        isImporting = false
        if !failures.isEmpty { importError = failures.joined(separator: "\n\n") }
    }

    func insert(_ asset: ImportedImage, centeredAt point: CGPoint? = nil) {
        beginEdit("Import Image")
        defer { endEdit() }
        if document == nil {
            document = CanvasDocument(width: asset.image.width, height: asset.image.height)
            viewport.fit(documentSize: document!.size)
        }
        guard let document else { return }
        let center = point ?? CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        var layer = ImageLayer(asset: asset, origin: CGPoint(
            x: floor(center.x - CGFloat(asset.image.width) / 2),
            y: floor(center.y - CGFloat(asset.image.height) / 2)))
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        self.document?.layers.append(layer)
        activeLayerID = layer.id
    }

    /// 在读取文件之前就弹出面板，避免大 PSD 让这次点击毫无回应。
    /// `finishPSDReading` 负责填入内容；若无可报告的内容，则把面板撤下。
    func beginPSDReading(title: String, confirmTitle: String) {
        guard confirmConversions == nil else { return }
        conversionCancelled = false
        conversionRequest = PSDConversionRequest(title: title, confirmTitle: confirmTitle, conversions: [], isReading: true)
        showsConversionSheet = true
    }
    func finishPSDReading(_ conversions: [PSDConversion]) async -> Bool {
        if let confirmConversions {
            if conversions.isEmpty { return true }
            return await confirmConversions(conversions)
        }
        if conversionCancelled { endPSDReading(); return false }
        guard !conversions.isEmpty else { endPSDReading(); return true }
        return await withCheckedContinuation { continuation in
            conversionContinuation = continuation
            conversionRequest?.conversions = conversions
            conversionRequest?.isReading = false
        }
    }
    /// 在没有结论的情况下撤下面板：要么无可报告的内容，要么读取失败。
    func endPSDReading() {
        guard conversionContinuation == nil else { return }
        showsConversionSheet = false
        conversionRequest = nil
    }
    func confirmPSDConversions(_ conversions: [PSDConversion], title: String, confirmTitle: String) async -> Bool {
        if let confirmConversions { return await confirmConversions(conversions) }
        return await withCheckedContinuation { continuation in
            conversionContinuation = continuation
            conversionRequest = PSDConversionRequest(title: title, confirmTitle: confirmTitle, conversions: conversions)
            showsConversionSheet = true
        }
    }

    func finishConversion(_ confirmed: Bool) {
        if !confirmed, conversionRequest?.isReading == true { conversionCancelled = true }
        showsConversionSheet = false
        conversionRequest = nil
        let continuation = conversionContinuation
        conversionContinuation = nil
        continuation?.resume(returning: confirmed)
    }

    func insertPhotoshop(_ imported: PSDImport, named: String, centeredAt point: CGPoint? = nil) throws {
        beginEdit("Import Photoshop File")
        defer { endEdit() }
        var incoming = imported.layers
        let wrapping = document != nil
        let added = incoming.count + (wrapping ? 1 : 0)
        if (document?.layers.count ?? 0) + added > 10_000 { throw ImageImportError.tooLarge }
        if document == nil {
            document = CanvasDocument(width: imported.width, height: imported.height, layers: incoming, resolution: imported.resolution)
            viewport.fit(documentSize: document!.size)
            activeLayerID = incoming.last(where: { $0.parentID == nil })?.id ?? incoming.last?.id
            return
        }
        guard document != nil else { return }
        var group = ImageLayer(name: named, blankSize: document!.size)
        group.isGroup = true
        group.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let point {
            let box = incoming.filter { !$0.isGroup }.reduce(CGRect.null) { $0.union(CGRect(origin: $1.origin, size: $1.size)) }
            if !box.isNull, !box.isInfinite, !box.isEmpty, box.origin.x.isFinite, box.origin.y.isFinite {
                let dx = point.x - box.midX, dy = point.y - box.midY
                for index in incoming.indices {
                    incoming[index].transform.origin.x += dx
                    incoming[index].transform.origin.y += dy
                }
            }
        }
        for index in incoming.indices where incoming[index].parentID == nil {
            incoming[index].parentID = group.id
        }
        self.document?.layers.append(group)
        self.document?.layers.append(contentsOf: incoming)
        if let parent = group.parentID { collapsedGroupIDs.remove(parent) }
        collapsedGroupIDs.remove(group.id)
        activeLayerID = group.id
    }

    /// `emptyLayer` 以一个选中的空白「图层 1」启动画布，与「文件 > 新建」一致。
    func createDocument(width: Int, height: Int, emptyLayer: Bool = false) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        commitTransform()
        beginEdit("New Canvas")
        defer { endEdit() }
        var document = CanvasDocument(width: width, height: height)
        let layer = emptyLayer ? ImageLayer(name: "Layer 1", blankSize: document.size) : nil
        if let layer { document.layers = [layer] }
        self.document = document
        activeLayerID = layer?.id
        renamingLayerID = nil
        viewport.fit(documentSize: document.size)
        showsNewDocument = false
    }

    func fit() {
        guard let document else { return }
        viewport.fit(documentSize: document.size)
    }

    func zoom(to value: CGFloat, anchor: CGPoint? = nil) {
        guard let document else { return }
        viewport.setZoom(value, anchoredAt: anchor ?? viewport.center, documentSize: document.size)
    }

    /// 在保持视图中心不变的前提下，逐级切换键盘缩放档位。
    enum PreviewZoomCommand { case zoomIn, zoomOut, fit, actual }

    func zoomKeyboard(by step: Int) {
        guard let document, step != 0 else { return }
        let target = viewport.keyboardZoomTarget(by: step)
        guard target != viewport.zoom else { return }
        viewport.setZoom(target, anchoredAt: viewport.center, documentSize: document.size)
    }
}
