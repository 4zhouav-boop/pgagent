import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ **通用「模态弹窗 ✕」检测** —— 逐字移植 PC `find_gray_x`（`_1377_ad_loop.py:1595`）。
///
/// ## 为什么必须是"通用判据"，⛔ 不是一堆模板（用户令）
/// 用户原话：
/// > 「**就是弹窗处理，应该有。 视频区任务中心和直播间的弹窗。你看看**」
/// > 「**加你麻痹的补丁 闸口。**」
///
/// 我此前为每个弹窗各裁一块模板（`panel_close_x`、`friend_popup_x`…）——
/// ⛔ **那就是"打补丁"**：每换一个版式就要再加一块 png，永远补不完。
///
/// ## PC 的做法（原文）
/// > ★**通用「暖灰圆钮 ✕」检测（ROI 参数化）**
/// > ★阈值是**实测标定**的（§1390）：模态弹窗的圆钮底色 RGB ≈ **(129,121,119)**
/// >   （128~131 / 120~123 / 118~121，跨两种弹窗几乎一模一样）
/// >   ⇒ 判据 = 三通道 ∈ [118,142] 且 max-min ≤ 16。圆钮中间的深色 ✕ 笔画自然落在阈值外。
/// > ★必须带**紧凑度**过滤：白字在深底上的抗锯齿边也会产生这种灰，但那些是"细而散"的，
/// >   不会形成 27×27、填充率 ~0.78 的圆 ⇒ 要求 18 ≤ w,h ≤ 42 且 n/(w*h) ≥ 0.45。
/// > ⭐ §1629：原来只有 `find_modal_x()`（ROI 写死右上角）——
/// >   可**券弹窗的 ✕ 在屏幕中下**，同一个判据换个 ROI 就能认 ⇒ 抽成参数化版本。
///
/// ## 覆盖的弹窗（PC 真机验收，4 种版式 / 19~33px / 配色全不同）
/// ```
///   ① 券弹窗 ✕          ② 顶部「已成功领取」横幅 ✕
///   ③ 奖励弹窗「再看15秒」✕   ④ 直播间右上角关闭
/// ```
/// ⭐ **这正是用户说的"视频区 / 任务中心 / 直播间"的弹窗** —— 一个判据全认。
///
/// ## 与 YOLO 的关系（PC：YOLO 优先、本函数兜底）
/// PC 优先用 `kgx` YOLO 模型（一个模型认所有 ✕），本函数是**兜底**。
/// ⚠️ 手机端**没有 ncnn/YOLO** ⇒ 本函数就是**主路**（⛔ 不是"退而求其次"，
///    因为 PC 真机验收证明它在这些版式上**同样命中**）。
enum ModalX {

    /// PC `BOX_MODALX = (330, 100, 451, 460)` —— 模态弹窗的 ✕ 一般落在右上角这一块
    static let boxModalX = CGRect(x: 330, y: 100, width: 121, height: 360)

    // ── PC 的实测标定常量（⛔ 一个字都不改）──────────────
    /// 暖灰圆钮三通道范围（PC `thr=(118,142)`）
    static let thrLo = 118, thrHi = 142
    /// 通道间最大差（PC `spread=16`）—— 保证是"灰"而不是彩色
    static let spread = 16
    /// 最少像素数（PC `minn=250`）
    static let minN = 250
    /// 尺寸闸（PC `side=(18,42)`）
    static let sideLo = 18, sideHi = 42
    /// 填充率闸（PC `fill=0.45`）—— 挡"细而散"的抗锯齿灰
    static let fill = 0.45

    // ══════════════════════════════════════════════════════════════════
    // ⭐⭐⭐⭐⭐ §2994 **✕ 形状闸** —— 灰圆 ≠ ✕（这条是手机端独有的，PC 没有）
    // ══════════════════════════════════════════════════════════════════
    //
    // ## ⛔ 为什么必须补（真机血案）
    // §2993 NEG 实测：只验「暖灰圆钮」形态时，1500 帧随机语料里**报了 36 帧**（2.40%）。
    // 逐个肉眼核对（`_var/_2994_calib/neg_all19.jpg`，19 格大图）：
    // ```
    //   #1  _2705_now2_view.png   @(409.0,259.9)   ← ✅ 真 ✕（灰圆 + 深色十字）
    //   #12 _1377_172733_a1_settle1 @(408.7,291.6) ← ✅ 真 ✕
    //   #16 _1377_TAG_ENT_g1_2     @(407.8,199.8)  ← ✅ 真 ✕
    //   #0/#3/#5/#6/#8/#11/#14/#18 灰天空、白墙、渐变 ⇒ ⛔ 纯灰块（无笔画）
    //   #2/#4/#7/#10  直播间「更多直播」浮层        ⇒ ⛔ 暖灰块
    //   #9/#13/#15    人脸/耳朵/白色实物            ⇒ ⛔ 暖灰块
    //   #17           深色轮子边缘                  ⇒ ⛔
    // ```
    //
    // ## 第一性原理
    // 「✕ 圆钮」= **灰圆底** + **中心深色十字笔画**。两件都要验。
    // PC 原文其实已点破但**没实现**（`_1377_ad_loop.py:1601`）：
    // > 圆钮中间的**深色 ✕ 笔画自然落在阈值外**
    // PC 敢不验笔画，是因为 **YOLO(`kgx`) 是主路、`find_gray_x` 只是兜底**
    // （`_1377:1641-1644`）。手机端没 YOLO ⇒ 必须自己验笔画。
    //
    // ## 标定（`_dev/_2994_xshape_calib.py`，19 格肉眼定标 + POS 帧）
    // 特征 `center_dark` = 圆钮中心小圆（半径 = 0.35R）里「深色像素」占比：
    // ```
    //   真 ✕  4 例：0.568 / 0.642 / 0.605 / 0.630     ← 全部 ≥ 0.30
    //   假阳 16 例：0.000 / 0.000 / 0.000 / 0.000 / 0.000 / 0.000
    //              0.000 / 0.000 / 0.000 / 0.000 / 0.000 / 0.000
    //              0.053 / 0.222 / 0.222 / 0.272       ← 全部 < 0.30
    // ```
    // ⇒ **`center_dark ≥ 0.30` 把两组完全分开**（间隔 0.222 → 0.568）。
    // ⚠️ 为什么用中心小圆而不是全圆占比：`dark_ratio` 在假阳 #2/#4/#7/#10 上也有
    //   0.28~0.39（浮层边缘的暗色），**不可分**；而 ✕ 两笔必然交叉过**中心**。

    /// "深色笔画"的亮度上限（灰圆 ~128 ⇒ 笔画远低于此）。
    /// 实测：真 ✕ 笔画 (44,38,40)/(51,46,42) ⇒ 均值 44~46，取 95 留足余量。
    static let darkLumaMax = 95.0
    /// 中心深色占比闸（§2994 标定，⛔ 不是拍脑袋 —— 0.222 假阳 vs 0.568 真阳）
    static let centerDarkMin = 0.30
    /// 中心小圆半径系数（× bbox 半宽）
    static let centerRadFrac = 0.35

    /// ⭐ 在 `roi` 内找**暖灰圆钮 ✕** ⇒ 返回**基准像素**中心或 nil。
    ///
    /// - Parameters:
    ///   - img: 任意尺寸的帧（内部先归一到基准，与识别层一致）
    ///   - roi: 基准像素 ROI（⛔ 会被钳制到帧内 —— PC §1627 血案：越界会 IndexError）
    static func find(_ img: UIImage, roi: CGRect = boxModalX) -> CGPoint? {
        findAll(img, roi: roi).first
    }

    /// ⭐⭐⭐⭐⭐ §2992 **连通域版**：逐块判定，返回**所有**合格 ✕（fill 降序）。
    ///
    /// ## ⛔ 为什么必须换算法（真机血案，2026-10-17 用户截图）
    /// 用户截图「限时邀1位好友立得现金」弹窗，右上角 ✕ 在基准 **(404,260)**，
    /// 像素实测 `(128,123,119)` —— 完全符合 PC 暖灰圆钮标定。
    /// 但旧实现（= PC `find_gray_x` 的**全局 bbox**）返回 **nil**：
    /// ```
    /// 颜色闸 n = 498 ✓
    /// 全局 bbox = 88 × 164   ← 483 个真 ✕ 像素 + 15 个散布噪声像素被并为一体
    /// fill = 0.035           ← 挡在形态闸 ⇒ 弹窗永远关不掉
    /// ```
    /// 诊断（按 y 分桶）：真 ✕ 在 y≈240~279（483 px），噪声散在 y≈320~439（15 px）。
    ///
    /// ## 为什么 PC 能用、手机不能
    /// PC 是 **YOLO(`kgx`) 优先、`find_gray_x` 兜底**（`_1377_ad_loop.py:1641-1644`）：
    /// ```python
    /// _y = _yolo_roi_x(img, BOX_MODALX, "模态✕")
    /// if _y: return _y
    /// return find_gray_x(img, BOX_MODALX)
    /// ```
    /// 手机端**没有 ncnn/YOLO** ⇒ 本函数是唯一主路 ⇒ 全局 bbox 缺陷直接暴露。
    ///
    /// ## 修法（换算法，⛔ 不是调参数、⛔ 不是加模板）
    /// 颜色闸命中的像素做 **8-邻域连通域标记**，**每个连通块单独**过三闸
    /// （`n≥250` / `18≤w,h≤42` / `fill≥0.45`），取 fill 最高者。
    ///
    /// 这正好还原 PC 原话「不会形成 27×27、填充率 ~0.78 的圆」的**本意**
    /// ——PC 本意就是找"一个紧凑的圆"，只是实现用全局 bbox 才被噪声带偏。
    ///
    /// ## 离线复算（`_dev/_2992_modalx_cc.py`，真机弹窗帧）
    /// ```
    /// 旧算法（全局 bbox）：0/2 命中   ← 永远 nil
    /// 新算法（连通域）  ：2/2 命中   落点 (408.7,260.5)
    /// 真值              ：(404.0,260.0)   偏差 4.8px
    /// 命中块             ：n=483 bbox=29×29 fill=0.574
    /// ```
    static func findAll(_ img: UIImage, roi: CGRect = boxModalX) -> [CGPoint] {
        let base = FrameNormalizer.normalize(img)
        guard let cg = base.cgImage else { return [] }
        let W = cg.width, H = cg.height

        // ⛔ ROI 先钳制（PC §1627 血案）
        let x0 = max(0, Int(roi.minX)), y0 = max(0, Int(roi.minY))
        let x1 = min(W, Int(roi.maxX)), y1 = min(H, Int(roi.maxY))
        let rw = x1 - x0, rh = y1 - y0
        guard rw >= 5, rh >= 5 else { return [] }

        let px = CGFloat(cg.width) / max(base.size.width, 1)
        let cropPx = CGRect(x: CGFloat(x0) * px, y: CGFloat(y0) * px,
                            width: CGFloat(rw) * px, height: CGFloat(rh) * px)
        var buf = [UInt8](repeating: 0, count: rw * rh * 4)
        guard let ctx = CGContext(data: &buf, width: rw, height: rh,
                                  bitsPerComponent: 8, bytesPerRow: rw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(cg, in: CGRect(x: -cropPx.minX, y: -(CGFloat(cg.height) - cropPx.maxY),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        // ⚠️ CGContext 原点在**左下** ⇒ 缓冲第 0 行是 ROI 的底行 ⇒ 读时翻回来

        // ① 颜色闸 ⇒ 布尔掩码
        var mask = [Bool](repeating: false, count: rw * rh)
        for j in 0..<rh {
            let srcRow = (rh - 1 - j) * rw * 4      // 翻 y
            for i in 0..<rw {
                let p = srcRow + i * 4
                let r = Int(buf[p]), g = Int(buf[p + 1]), b = Int(buf[p + 2])
                if r >= thrLo, r <= thrHi,
                   g >= thrLo, g <= thrHi,
                   b >= thrLo, b <= thrHi,
                   (max(r, max(g, b)) - min(r, min(g, b))) <= spread {
                    mask[j * rw + i] = true
                }
            }
        }

        // ② 8-邻域连通域标记（显式栈，⛔ 不递归 ⇒ 不会爆栈）
        var seen = [Bool](repeating: false, count: rw * rh)
        var out: [(p: CGPoint, fill: Double)] = []
        var stack: [Int] = []
        for sj in 0..<rh {
            for si in 0..<rw {
                let start = sj * rw + si
                if !mask[start] || seen[start] { continue }
                seen[start] = true
                stack.removeAll(keepingCapacity: true)
                stack.append(start)
                var n = 0, sx = 0, sy = 0
                var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
                while let cur = stack.popLast() {
                    let j = cur / rw, i = cur % rw
                    n += 1; sx += i; sy += j
                    if i < minX { minX = i }; if i > maxX { maxX = i }
                    if j < minY { minY = j }; if j > maxY { maxY = j }
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = i + di, nj = j + dj
                            if ni < 0 || ni >= rw || nj < 0 || nj >= rh { continue }
                            let idx = nj * rw + ni
                            if mask[idx] && !seen[idx] {
                                seen[idx] = true
                                stack.append(idx)
                            }
                        }
                    }
                }
                // ③ 逐块过四闸（⛔ 不是全局 bbox）
                guard n >= minN else { continue }
                let w = maxX - minX + 1, h = maxY - minY + 1
                guard w >= sideLo, h >= sideLo, w <= sideHi, h <= sideHi else { continue }
                let fl = Double(n) / Double(w * h)
                guard fl >= fill else { continue }
                let cxD = CGFloat(x0) + CGFloat(sx) / CGFloat(n)
                let cyD = CGFloat(y0) + CGFloat(sy) / CGFloat(n)
                // ⭐⭐⭐ §2994 **✕ 形状闸**（灰圆底 + 中心深色十字笔画）
                //   ⛔ 少了这一闸，1500 帧随机语料报 36 帧假阳（§2993 实测）。
                //   见上方 `centerDarkMin` 的标定数据：假阳 ≤0.222 / 真阳 ≥0.568。
                //   ⚠️ 传的是 **ROI 局部坐标**（`sx/n`,`sy/n`）—— `buf` 是 ROI 局部缓冲，
                //      ⛔ 不能用基准坐标（含 x0/y0 偏移）。
                guard centerDark(buf, rw: rw, rh: rh,
                                 lx: Double(sx) / Double(n),
                                 ly: Double(sy) / Double(n),
                                 w: w, h: h) >= centerDarkMin else { continue }
                out.append((p: CGPoint(x: cxD, y: cyD), fill: fl))
            }
        }
        // ④ fill 最高（= 最像紧凑圆钮）优先；平手取更靠右上的（✕ 惯例位置）
        out.sort { a, b in
            if a.fill != b.fill { return a.fill > b.fill }
            if a.p.x != b.p.x { return a.p.x > b.p.x }
            return a.p.y < b.p.y
        }
        // ⚠️ 用闭包而不是 `\.p` —— Swift **不支持元组成员的 keyPath**（编译会报错）
        return out.map { $0.p }
    }

    /// §2994 **✕ 形状特征**：圆钮**中心小圆**里「深色像素」占比。
    ///
    /// ⚠️ 坐标口径（⛔ 这里踩过一次，写清楚）：`buf` 是 **ROI 局部**缓冲，
    /// 且 CGContext 画出来的**第 0 行是 ROI 底行**（读掩码时 `srcRow = (rh-1-j)*rw*4` 已翻正）。
    /// 本函数收的是 **ROI 局部坐标**（`lx`,`ly`，不含 `x0/y0`），内部做同样的翻行。
    ///
    /// - Returns: `0...1`；越界不计入分母。
    private static func centerDark(_ buf: [UInt8], rw: Int, rh: Int,
                                   lx: Double, ly: Double,
                                   w: Int, h: Int) -> Double {
        let R = Double(max(w, h)) / 2.0 + 1.0
        let rc = max(2, Int(R * centerRadFrac))
        let ix = Int(lx.rounded()), iy = Int(ly.rounded())
        var tot = 0, dark = 0
        for dy in -rc...rc {
            for dx in -rc...rc {
                if dx * dx + dy * dy > rc * rc { continue }
                let j = iy + dy, i = ix + dx
                if i < 0 || i >= rw || j < 0 || j >= rh { continue }
                let srcRow = (rh - 1 - j) * rw * 4      // 翻 y（与上面读掩码同一套）
                let p = srcRow + i * 4
                let r = Double(buf[p]), g = Double(buf[p + 1]), b = Double(buf[p + 2])
                tot += 1
                if (r + g + b) / 3.0 < darkLumaMax { dark += 1 }
            }
        }
        return tot > 0 ? Double(dark) / Double(tot) : 0.0
    }

    /// ⭐ 券弹窗的 ✕（PC `find_coupon_x` 用的 ROI = `BOX_COUPON_X` 比例 (0.42,0.64,0.58,0.78)）
    ///    ⇒ 基准 451×977 下是 x 189~261 / y 625~762
    static let boxCouponX = CGRect(x: 189, y: 625, width: 72, height: 137)

    static func findCoupon(_ img: UIImage) -> CGPoint? {
        find(img, roi: boxCouponX)
    }
}
