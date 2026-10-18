import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ **kgx —— 「找 ✕」的 YOLO 模型**（**逐行移植** PC `_1377_ad_loop.py::_x_detect`，L1720~L1815）
///
/// ## 为什么是它（PC 蓝本的**唯一** ✕ 检测实现）
/// PC 原文（`find_x_all` 的 docstring 逐字）：
/// > ⭐ 这是**唯一的 ✕ 检测实现**；新页面/新版式一律**不动它**（模型自己泛化，不用加模板）。
///
/// ⇒ 手机端**必须**有它，否则 `dismiss_overlay` / `find_toast_x` / `find_live_x` /
///   `find_coupon_x` / `find_modal_x` 全部只能退回手工阈值（PC 已证明那些在真机上会漏）。
///
/// ## 移植纪律（⛔ 一个数都不改）
/// | 项 | PC 值 | 出处 |
/// |---|---|---|
/// | 输入尺寸 | **640** | `X_MODEL_INPUT` |
/// | letterbox 补边 | **114.0** | `X_MODEL_PAD`（Ultralytics 默认） |
/// | 置信度闸① | **0.45** | `X_MODEL_CONF`（抄雷神 `yolo.detect(img,0.45,...)`） |
/// | 置信度闸② | **0.49** | `X_MODEL_CONF2`（抄雷神 `if (prob < 0.49) continue`） |
/// | 输出头 | **out0/8、out1/16、out2/32** | `X_MODEL_HEADS` |
/// | DFL | **reg_max=16** | `X_MODEL_REG_MAX` |
/// | 类别数 | **2** | `X_MODEL_NC`（实测 66 = 4×16 + 2） |
/// | NMS IoU | **0.45** | `_x_detect` 内 |
///
/// ## PC 的推理流程（逐条对应下面的代码）
/// ```
/// ① rgb = img.convert("RGB")                      // 基准 451×977
/// ② r = min(640/w, 640/h); nw,nh = round(w*r), round(h*r)
/// ③ lb = full((640,640,3), 114); lb[dy:dy+nh, dx:dx+nw] = resize(rgb)
/// ④ chw = lb[:,:,::-1].T / 255                    // BGR 通道序 + CHW + 归一化
/// ⑤ 三个头各自：DFL(softmax×arange 求和) → 框 → score=max(cls)
/// ⑥ score>=0.45 的进候选；NMS(IoU 0.45)
/// ⑦ 坐标反 letterbox：cx = ((x1+x2)/2)/r - dx/r
/// ```
/// ⛔ 第 ⑤ 步的 `dfl` 离散积分、第 ⑥ 步的 NMS、第 ⑦ 步的反变换**全部照抄**，
///   ⛔ 不用任何"框架自带"的 YOLO 后处理（那会把 PC 调过的参数换掉）。
final class KGXNet {

    // ── PC 常量（⛔ 逐字）──
    static let inputSize = 640
    static let pad = 114.0
    static let conf = 0.45            // X_MODEL_CONF
    static let conf2 = 0.49           // X_MODEL_CONF2
    static let heads: [(String, Int)] = [("out0", 8), ("out1", 16), ("out2", 32)]
    static let regMax = 16
    static let nc = 2
    static let nmsIoU = 0.45

    /// ncnn 的 C API 句柄类型（⛔ 不是 `OpaquePointer`）
    /// 依据：`c_api.h` 里 `typedef struct __ncnn_net_t* ncnn_net_t;`
    ///   ⇒ Swift 侧桥接成 `UnsafeMutablePointer<__ncnn_net_t>`
    private var net: ncnn_net_t?
    private var loaded = false
    private var loadError = ""

    /// 单例（模型只加载一次，5MB 权重 + 255 层）
    static let shared = KGXNet()
    private init() {}

    /// 是否可用（没加载成功时上层要**如实回退**，⛔ 不能假装命中）
    var available: Bool { loaded }
    var error: String { loadError }

    // MARK: - 加载

    /// 懒加载：从 App bundle 读 `kgx.param` + `kgx.bin`
    /// PC 对应 `_x_net()`（L1686）：缺 ncnn / 缺模型 ⇒ 返回 False，让上层退回其它腿
    func loadIfNeeded() {
        if loaded || !loadError.isEmpty { return }
        guard let param = Bundle.main.path(forResource: "kgx", ofType: "param"),
              let bin = Bundle.main.path(forResource: "kgx", ofType: "bin") else {
            loadError = "模型不在 bundle（kgx.param/kgx.bin）"
            NSLog("PGAgent §3130 kgx：%@", loadError)
            return
        }
        guard let n = ncnn_net_create() else {
            loadError = "ncnn_net_create 失败"
            return
        }
        // PC `net.opt.num_threads = AISJ_YOLO_THREADS(默认 4)`；`use_vulkan_compute = False`
        if let opt = ncnn_net_get_option(n) {
            ncnn_option_set_num_threads(opt, 4)
            ncnn_option_set_use_vulkan_compute(opt, 0)
        }

        let r1 = ncnn_net_load_param(n, param)
        let r2 = ncnn_net_load_model(n, bin)
        guard r1 == 0, r2 == 0 else {
            loadError = "load_param=\(r1) load_model=\(r2)"
            ncnn_net_destroy(n)
            NSLog("PGAgent §3130 kgx 加载失败：%@", loadError)
            return
        }
        net = n
        loaded = true
        let ver = ncnn_version().map { String(cString: $0) } ?? "?"
        NSLog("PGAgent §3130 kgx 已加载（ncnn %@，4 线程）", ver)
    }

    // MARK: - 推理（PC `_x_detect` 逐行）

    /// 跑一次 kgx。**永远整帧**（PC 血案：裁小 ROI 会偏出训练分布 ⇒ 漏检，见 `_x_detect` 注释）
    /// - Parameter img: **基准尺度**（451×977）的帧
    /// - Returns: `[(conf, cx, cy, w, h)]`，基准像素坐标；不可用 ⇒ `nil`（与 PC 一致：`None`）
    func detect(_ img: UIImage) -> [(Double, Double, Double, Double, Double)]? {
        loadIfNeeded()
        guard let net = net else { return nil }

        let base = FrameNormalizer.normalize(img)
        guard let cg = base.cgImage else { return nil }
        let w0 = cg.width, h0 = cg.height
        guard w0 > 0, h0 > 0 else { return nil }

        // ② r = min(640/w, 640/h)
        let S = Double(KGXNet.inputSize)
        let r = min(S / Double(w0), S / Double(h0))
        let nw = max(1, Int((Double(w0) * r).rounded()))
        let nh = max(1, Int((Double(h0) * r).rounded()))
        let dx = (KGXNet.inputSize - nw) / 2
        let dy = (KGXNet.inputSize - nh) / 2

        // ③ letterbox：整块填 114，再把缩放后的图贴进中心
        //    ④ 通道序：PC `lb[:, :, ::-1]` = **BGR**（numpy 的 RGB→BGR 反转）
        //       ⇒ 我们必须先拿到 **RGB** 再反转成 BGR
        var chw = [Float](repeating: Float(KGXNet.pad), count: 3 * KGXNet.inputSize * KGXNet.inputSize)
        // 三通道都先铺 pad 值（PC 的 `np.full` 是三通道同时填）
        let plane = KGXNet.inputSize * KGXNet.inputSize
        for c in 0..<3 {
            for i in 0..<plane { chw[c * plane + i] = Float(KGXNet.pad) }
        }
        // 取 RGB（缩放到 nw×nh）
        var rgba = [UInt8](repeating: 0, count: nw * nh * 4)
        guard let ctx = CGContext(data: nil, width: nw, height: nh,
                                  bitsPerComponent: 8, bytesPerRow: nw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium          // 近似 cv2.INTER_LINEAR
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(nw), height: CGFloat(nh)))
        guard let sp = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for j in 0..<nh {
            let src = j * nw * 4
            for i in 0..<nw {
                let o = src + i * 4
                // ⚠️ ctx.data 第 0 行就是顶行（§3111 已真机验证），⛔ 不翻
                let R = Float(sp[o]) / 255.0
                let G = Float(sp[o + 1]) / 255.0
                let B = Float(sp[o + 2]) / 255.0
                let y = dy + j, x = dx + i
                let idx = y * KGXNet.inputSize + x
                // PC：chw = lb[:, :, ::-1].T ⇒ 通道 0 = B, 1 = G, 2 = R
                chw[0 * plane + idx] = B
                chw[1 * plane + idx] = G
                chw[2 * plane + idx] = R
            }
        }

        // 输入张量（3×640×640 float32）
        guard let ex = ncnn_extractor_create(net) else { return nil }
        defer { ncnn_extractor_destroy(ex) }
        guard let inMat = ncnn_mat_create_3d(Int32(KGXNet.inputSize), Int32(KGXNet.inputSize),
                                             Int32(3), nil) else { return nil }
        defer { ncnn_mat_destroy(inMat) }
        // 把 chw 拷进 ncnn 的 Mat（PC 用 `ncnn.Mat(buf).clone()`，等价语义）
        // ⛔ PC 注释里的血案：`ncnn.Mat(numpy)` 只是**零拷贝包装**，必须 clone 进 ncnn 自己的内存，
        //    否则临时数组回收 ⇒ 悬空指针 ⇒ 段错误（`_1377` §1650 实测 exit=139）。
        //    这里我们是**逐元素拷进 ncnn_mat_create_3d 自己分配的内存** ⇒ 天然满足"clone"语义。
        chw.withUnsafeBufferPointer { buf in
            if let dst = ncnn_mat_get_data(inMat) {
                let dp = dst.assumingMemoryBound(to: Float.self)
                for i in 0..<chw.count { dp[i] = buf[i] }
            }
        }
        if ncnn_extractor_input(ex, "in0", inMat) != 0 { return [] }

        var cand: [(Float, Float, Float, Float, Float)] = []   // score, x1, y1, x2, y2（模型输入像素）

        for (name, stride) in KGXNet.heads {
            var outMat: ncnn_mat_t?
            if ncnn_extractor_extract(ex, name, &outMat) != 0 || outMat == nil { continue }
            let side = KGXNet.inputSize / stride
            let nCh = 4 * KGXNet.regMax + KGXNet.nc      // 66
            let wOut = Int(ncnn_mat_get_w(outMat!))
            let hOut = Int(ncnn_mat_get_h(outMat!))
            let cOut = Int(ncnn_mat_get_c(outMat!))
            let cstep = Int(ncnn_mat_get_cstep(outMat!))
            let total = wOut * hOut * max(1, cOut)
            let want = side * side * nCh
            // ⛔⛔⛔ §3148 **先把数据**整块**拷出来，再销毁 Mat**（真机血案）
            //
            // 旧写法：`defer { ncnn_mat_destroy(outMat) }` + 直接读 `outMat` 的裸指针
            //   ⇒ `defer` 是**函数作用域**的，三个头依次 extract 时**不会被及时销毁**，
            //     而 `ncnn_extractor` 下次 extract 会**复用内部缓冲**
            //   ⇒ 读到的是"上一块内存 + 本块头部描述"的混合 ⇒ 数据整体错位
            //   📏 真机症状（0.71，同帧 PC 对照 `_dev/_3132_kgx_ref.py`）：
            //     · 手机：**34 个假阳**、conf 0.9998、`cx` 出现 **-253**、`cy` 全挤在 6~72
            //     · PC 同帧：**0 个命中**（`score` 最大只有 0.796，且 >=0.45 的 5 个格子全落在合法区）
            //   ✅ 正解：`guard let md ...` 之后**立刻**把 `total` 个 Float 拷进 Swift 数组，
            //      然后 `ncnn_mat_destroy(outMat)`，后面只用 Swift 数组。
            guard let md = ncnn_mat_get_data(outMat!) else {
                ncnn_mat_destroy(outMat); continue
            }
            guard total == want else {
                NSLog("PGAgent §3130 kgx：%@ 尺寸 %d ≠ %d（w=%d h=%d c=%d cstep=%d）",
                      name, total, want, wOut, hOut, cOut, cstep)
                ncnn_mat_destroy(outMat)
                continue
            }
            var raw = [Float](repeating: 0, count: total)
            let fpSrc = md.assumingMemoryBound(to: Float.self)
            raw.withUnsafeMutableBufferPointer { dst in
                for i in 0..<total { dst[i] = fpSrc[i] }
            }
            ncnn_mat_destroy(outMat)          // ✅ 数据已拷出，立刻销毁
            let fp = raw                       // 后续只用 Swift 数组
            // 布局（PC 实测）：w=66(通道) h=side(格x) c=side(格y) cstep=w*h
            // ⇒ 格子 (gy,gx) 的 66 个通道 = raw[(gy*side+gx)*66 ... +65]
            for gy in 0..<side {
                for gx in 0..<side {
                    let base = (gy * side + gx) * nCh
                    // score = max(cls)（PC `nc[:, 4*reg_max:].max(1)`）
                    var score: Float = -1
                    for c in 0..<KGXNet.nc {
                        let v = fp[base + 4 * KGXNet.regMax + c]
                        if v > score { score = v }
                    }
                    if score < Float(KGXNet.conf) { continue }
                    // DFL：softmax(reg_max) × arange(reg_max) 求和（PC 逐字）
                    var dist = [Float](repeating: 0, count: 4)
                    for side4 in 0..<4 {
                        let off = base + side4 * KGXNet.regMax
                        var mx: Float = -1e30
                        for t in 0..<KGXNet.regMax { let v = fp[off + t]; if v > mx { mx = v } }
                        var sum: Float = 0
                        var acc: Float = 0
                        for t in 0..<KGXNet.regMax {
                            let e = expf(fp[off + t] - mx)
                            sum += e
                            acc += e * Float(t)
                        }
                        dist[side4] = sum > 0 ? (acc / sum) : 0
                    }
                    let ax = (Float(gx) + 0.5) * Float(stride)
                    let ay = (Float(gy) + 0.5) * Float(stride)
                    let x1 = ax - dist[0] * Float(stride)
                    let y1 = ay - dist[1] * Float(stride)
                    let x2 = ax + dist[2] * Float(stride)
                    let y2 = ay + dist[3] * Float(stride)
                    cand.append((score, x1, y1, x2, y2))
                }
            }
        }

        if cand.isEmpty { return [] }

        // ⑥ NMS（PC 逐字：按 score 降序，IoU > 0.45 丢弃）
        cand.sort { $0.0 > $1.0 }
        var keep: [(Float, Float, Float, Float, Float)] = []
        for c in cand {
            var drop = false
            for kk in keep {
                let ix = min(c.3, kk.3) - max(c.1, kk.1)
                let iy = min(c.4, kk.4) - max(c.2, kk.2)
                if ix <= 0 || iy <= 0 { continue }
                let inter = ix * iy
                let a1 = (c.3 - c.1) * (c.4 - c.2)
                let a2 = (kk.3 - kk.1) * (kk.4 - kk.2)
                if Double(inter) / Double(max(a1 + a2 - inter, 1e-9)) > KGXNet.nmsIoU {
                    drop = true; break
                }
            }
            if !drop { keep.append(c) }
        }

        // ⑦ 反 letterbox：cx = (x1+x2)/2/r - dx/r（PC 逐字）
        let rf = Float(r)
        let dxf = Float(dx), dyf = Float(dy)
        var out: [(Double, Double, Double, Double, Double)] = []
        for (conf, x1, y1, x2, y2) in keep {
            let cx = ((x1 + x2) / 2) / rf - dxf / rf
            let cy = ((y1 + y2) / 2) / rf - dyf / rf
            let bw = (x2 - x1) / rf
            let bh = (y2 - y1) / rf
            out.append((Double(conf),
                        (Double(cx) * 10).rounded() / 10,
                        (Double(cy) * 10).rounded() / 10,
                        (Double(bw) * 10).rounded() / 10,
                        (Double(bh) * 10).rounded() / 10))
        }
        return out
    }

    /// PC `find_x_all(img, box, conf2, tag)`（L1833）：整帧推理 + **按矩形过滤** + 置信度闸②
    /// ⛔ `box` 是**结果过滤窗**（不是"裁剪后送推理"）—— PC 注释里写死了这个语义
    func findAll(_ img: UIImage, box: CGRect? = nil,
                 conf2: Double = KGXNet.conf2) -> [(cx: Double, cy: Double, conf: Double, w: Double, h: Double)] {
        guard let d = detect(img) else { return [] }
        var hit = d.filter { $0.0 >= conf2 }
        if let b = box {
            hit = hit.filter { $0.1 >= Double(b.minX) && $0.1 <= Double(b.maxX)
                            && $0.2 >= Double(b.minY) && $0.2 <= Double(b.maxY) }
        }
        return hit.map { (cx: $0.1, cy: $0.2, conf: $0.0, w: $0.3, h: $0.4) }
    }
}
