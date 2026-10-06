import CoreImage
import Metal

/// 涂抹与液化在 GPU 上的工作副本：每个 dab 都是把 `WarpStroke` 的 CPU dab 逐一移植过来，
/// 就地运行在画布所读取的位置上，因此笔触不会在每次指针移动时拷贝整份文档——
/// 它过去会新建一份文档的图像再上传，在大文档上这笔开销远高于 dab 本身。
/// 像素只在笔触结束时（或为 Core Graphics 画布绘制的那一帧）一次性回到 CPU。
@MainActor final class MetalWarp {
    let width: Int
    let height: Int
    let texture: MTLTexture
    private let renderer: GPUCanvasRenderer
    /// 涂抹：画笔携带的颜色，边长 (2r+1)² 的方形，取值 0…255。
    private var carried: MTLTexture?
    /// 液化：笔触开始时的图层，以及每个像素相对它移动了多远——每像素一个源偏移，单位为像素。
    /// 每个 dab 只移动偏移量，绝不移动像素本身；绘制时每个像素都通过自己的偏移从未被触碰的像素重新取样。
    /// 若改为在每个 dab 后重采样像素本身，它们每次都会略微变软，而 Photoshop 的液化始终保持锐利。
    private var original: MTLTexture?
    private var offsets: MTLTexture?
    /// 液化：dab 作用区域内在该 dab 之前的偏移量，由该 dab 读取。
    private var scratch: MTLTexture?
    private var buffer: MTLCommandBuffer?
    private var encoder: MTLComputeCommandEncoder?
    private var last: MTLCommandBuffer?

    init?(pixels: CGContext) {
        guard let renderer = GPUCanvasRenderer.shared, Self.pipelines != nil, let data = pixels.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pixels.width,
                                                                  height: pixels.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
        // 行序与文档一致，原点在左上角：点的行号就是它的 y。
        texture.replace(region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixels.bytesPerRow)
        self.renderer = renderer
        self.texture = texture
        width = pixels.width
        height = pixels.height
    }

    /// 供画布绘制的工作副本，即到目前为止发出的那些 dab 运行完毕后的状态。
    var image: CIImage? { CIImage(mtlTexture: texture, options: [.colorSpace: renderer.space]) }

    /// 所有 dab 运行完毕后，工作副本的像素回到 `pixels`（同样大小）。
    func read(into pixels: CGContext) {
        commit()
        last?.waitUntilCompleted()
        guard let data = pixels.data else { return }
        texture.getBytes(data, bytesPerRow: pixels.bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }

    private struct Dab {
        var center: SIMD2<Int32>
        var radius: Int32
        var size: SIMD2<Int32>
        /// 液化：dab 取样区域的起点与大小。
        var origin: SIMD2<Int32>
        var area: SIMD2<Int32>
        var inverseRadius: Float
        var hardness: Float
        var keep: Float
        var move: SIMD2<Float>
    }

    private func texture(_ current: MTLTexture?, side: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let current, current.width >= side, current.height >= side { return current }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return renderer.device.makeTexture(descriptor: descriptor)
    }

    private func dispatch(_ name: String, _ dab: Dab, textures: [MTLTexture], threads: Int) {
        guard let pipeline = Self.pipelines?[name] else { return }
        if encoder == nil {
            buffer = renderer.queue.makeCommandBuffer()
            encoder = buffer?.makeComputeCommandEncoder()
        }
        guard let encoder else { return }
        var dab = dab
        // 每个 dab 都在前一个 dab 留下的结果上继续工作。
        encoder.memoryBarrier(scope: .textures)
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setBytes(&dab, length: MemoryLayout<Dab>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (threads + 15) / 16, height: (threads + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
    }

    /// 发送到目前为止已编码的各个 dab。画布在同一个队列上、排在它们之后绘制。
    func commit() {
        encoder?.endEncoding()
        buffer?.commit()
        if let buffer { last = buffer }
        encoder = nil
        buffer = nil
    }

    func pickUp(at center: CGPoint, radius: Int) {
        let side = 2 * radius + 1
        guard let carried = texture(carried, side: side, format: .rgba32Float) else { return }
        self.carried = carried
        dispatch("warp_pick_up", Dab(center: SIMD2(Int32(center.x.rounded()), Int32(center.y.rounded())), radius: Int32(radius),
                                     size: SIMD2(Int32(width), Int32(height)), origin: .zero, area: .zero,
                                     inverseRadius: 0, hardness: 0, keep: 0, move: .zero),
                 textures: [texture, carried], threads: side)
    }

    func smudge(at center: CGPoint, radius: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        guard let carried else { return }
        dispatch("warp_smudge", Dab(center: SIMD2(Int32(center.x.rounded()), Int32(center.y.rounded())), radius: Int32(radius),
                                    size: SIMD2(Int32(width), Int32(height)), origin: .zero, area: .zero,
                                    inverseRadius: 1 / Float(diameter / 2), hardness: Float(hardness), keep: Float(strength), move: .zero),
                 textures: [texture, carried], threads: 2 * radius + 1)
    }

    /// 前向变形，与 `WarpStroke.push` 相同：画笔之下的内容随之移动，中心处位移最大，向边缘逐渐衰减到零
    /// ——它作用在偏移量上（见 `offsets`），dab 之下的像素则从未被触碰的像素重新绘制。
    func push(from a: CGPoint, to b: CGPoint, radius r: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        let whole = Dab(center: .zero, radius: 0, size: SIMD2(Int32(width), Int32(height)), origin: .zero,
                        area: SIMD2(Int32(width), Int32(height)), inverseRadius: 0, hardness: 0, keep: 0, move: .zero)
        // 第一次 push 保持图层原样，并把每个偏移量都初始化为零。
        if original == nil {
            guard let original = sized(width: width, height: height, format: .rgba8Unorm),
                  let offsets = sized(width: width, height: height, format: .rg32Float) else { return }
            self.original = original
            self.offsets = offsets
            dispatch("warp_copy", whole, textures: [texture, original], threads: max(width, height))
            dispatch("warp_clear", whole, textures: [offsets], threads: max(width, height))
        }
        guard let original, let offsets, let scratch = texture(scratch, side: max(cw, ch), format: .rg32Float) else { return }
        self.scratch = scratch
        let dab = Dab(center: SIMD2(Int32(cx), Int32(cy)), radius: Int32(r), size: SIMD2(Int32(width), Int32(height)),
                      origin: SIMD2(Int32(x0), Int32(y0)), area: SIMD2(Int32(cw), Int32(ch)),
                      inverseRadius: 1 / Float(diameter / 2), hardness: Float(hardness), keep: 0, move: move)
        dispatch("warp_copy", dab, textures: [offsets, scratch], threads: max(cw, ch))
        dispatch("warp_push", dab, textures: [offsets, scratch, original, texture], threads: 2 * r + 1)
    }

    private func sized(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return renderer.device.makeTexture(descriptor: descriptor)
    }

    static let pipelines: [String: MTLComputePipelineState]? = {
        guard let device = MTLCreateSystemDefaultDevice(), let library = try? device.makeLibrary(source: source, options: nil)
        else { return nil }
        var result: [String: MTLComputePipelineState] = [:]
        for name in ["warp_pick_up", "warp_smudge", "warp_copy", "warp_clear", "warp_push"] {
            guard let function = library.makeFunction(name: name),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            result[name] = pipeline
        }
        return result
    }()

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Dab {
        int2 center; int radius; int2 size; int2 origin; int2 area;
        float inverseRadius; float hardness; float keep; float2 move;
    };

    // 一个 dab 对距其中心距离为 u 的像素产生的位移量（0 为中心，1 为边缘）。
    static inline float weight(float u, float hardness) {
        if (u >= 1.0f) return 0.0f;
        if (u <= hardness) return 1.0f;
        float t = (1.0f - u) / (1.0f - hardness);
        return t * t * (3.0f - 2.0f * t);
    }

    kernel void warp_pick_up(texture2d<float, access::read> canvas [[texture(0)]],
                             texture2d<float, access::write> carried [[texture(1)]],
                             constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int side = 2 * d.radius + 1;
        if (int(gid.x) >= side || int(gid.y) >= side) return;
        int2 p = d.center + int2(gid) - d.radius;
        bool inside = p.x >= 0 && p.y >= 0 && p.x < d.size.x && p.y < d.size.y;
        carried.write(inside ? canvas.read(uint2(p)) * 255.0f : float4(0.0f), gid);
    }

    kernel void warp_smudge(texture2d<float, access::read_write> canvas [[texture(0)]],
                            texture2d<float, access::read_write> carried [[texture(1)]],
                            constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int side = 2 * d.radius + 1;
        if (int(gid.x) >= side || int(gid.y) >= side) return;
        int2 offset = int2(gid) - d.radius, p = d.center + offset;
        if (p.x < 0 || p.y < 0 || p.x >= d.size.x || p.y >= d.size.y) return;
        float w = weight(sqrt(float(offset.x * offset.x + offset.y * offset.y)) * d.inverseRadius, d.hardness);
        if (w <= 0.0f) return;
        float4 under = canvas.read(uint2(p)) * 255.0f, held = carried.read(gid);
        // 上一个 dab 时画笔之下的内容，这里按涂抹强度铺下；画笔随后携带的是它刚刚留下的东西，
        // 而不是更早的（见 WarpStroke.smudge）。
        float4 painted = under + (held - under) * w * d.keep;
        canvas.write(clamp(round(painted), 0.0f, 255.0f) / 255.0f, uint2(p));
        carried.write(painted, gid);
    }

    kernel void warp_copy(texture2d<float, access::read> from [[texture(0)]],
                          texture2d<float, access::write> to [[texture(1)]],
                          constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= d.area.x || int(gid.y) >= d.area.y) return;
        to.write(from.read(uint2(d.origin + int2(gid))), gid);
    }

    kernel void warp_clear(texture2d<float, access::write> to [[texture(0)]],
                           constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= d.area.x || int(gid.y) >= d.area.y) return;
        to.write(float4(0.0f), gid);
    }

    // 前向变形：画笔之下的内容随之移动，中心处位移最大，向边缘逐渐衰减到零。像素采用的偏移量
    // 是沿画笔移动路径的相反方向找到的那个，再减去移动距离；它的颜色取自该处未被触碰的图层，
    // 只需采样一次。
    kernel void warp_push(texture2d<float, access::write> offsets [[texture(0)]],
                          texture2d<float, access::read> before [[texture(1)]],
                          texture2d<float, access::read> original [[texture(2)]],
                          texture2d<float, access::write> canvas [[texture(3)]],
                          constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int side = 2 * d.radius + 1;
        if (int(gid.x) >= side || int(gid.y) >= side) return;
        int2 offset = int2(gid) - d.radius, p = d.center + offset;
        int2 last = d.origin + d.area - 1;
        if (p.x < d.origin.x || p.y < d.origin.y || p.x > last.x || p.y > last.y) return;
        float w = weight(sqrt(float(offset.x * offset.x + offset.y * offset.y)) * d.inverseRadius, d.hardness);
        if (w <= 0.0f) return;
        // 双线性采样：沿画笔移动路径的反方向，取该处当时的偏移量。
        float sx = min(float(d.area.x - 1), max(0.0f, float(p.x - d.origin.x) - d.move.x * w));
        float sy = min(float(d.area.y - 1), max(0.0f, float(p.y - d.origin.y) - d.move.y * w));
        int ix = min(d.area.x - 2, int(sx)), iy = min(d.area.y - 2, int(sy));
        if (ix < 0 || iy < 0) return;
        float fx = sx - float(ix), fy = sy - float(iy);
        float2 o00 = before.read(uint2(ix, iy)).xy, o10 = before.read(uint2(ix + 1, iy)).xy;
        float2 o01 = before.read(uint2(ix, iy + 1)).xy, o11 = before.read(uint2(ix + 1, iy + 1)).xy;
        float2 moved = mix(mix(o00, o10, fx), mix(o01, o11, fx), fy) - d.move * w;
        offsets.write(float4(moved, 0.0f, 0.0f), uint2(p));
        // 该偏移量所指向的、未经触碰的图层，采样时钳制到其边缘。
        float2 source = clamp(float2(p) + moved, float2(0.0f), float2(d.size - 1));
        int2 i = min(int2(source), d.size - 2);
        float2 f = source - float2(i);
        float4 c00 = original.read(uint2(i)), c10 = original.read(uint2(i + int2(1, 0)));
        float4 c01 = original.read(uint2(i + int2(0, 1))), c11 = original.read(uint2(i + int2(1, 1)));
        float4 color = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
        canvas.write(clamp(round(color * 255.0f), 0.0f, 255.0f) / 255.0f, uint2(p));
    }
    """
}
