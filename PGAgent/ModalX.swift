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

    /// ⭐ 在 `roi` 内找**暖灰圆钮 ✕** ⇒ 返回**基准像素**中心或 nil。
    ///
    /// - Parameters:
    ///   - img: 任意尺寸的帧（内部先归一到基准，与识别层一致）
    ///   - roi: 基准像素 ROI（⛔ 会被钳制到帧内 —— PC §1627 血案：越界会 IndexError）
    static func find(_ img: UIImage, roi: CGRect = boxModalX) -> CGPoint? {
        let base = FrameNormalizer.normalize(img)
        guard let cg = base.cgImage else { return nil }
        let W = cg.width, H = cg.height

        // ⛔ ROI 先钳制（PC §1627 血案）
        let x0 = max(0, Int(roi.minX)), y0 = max(0, Int(roi.minY))
        let x1 = min(W, Int(roi.maxX)), y1 = min(H, Int(roi.maxY))
        let rw = x1 - x0, rh = y1 - y0
        guard rw >= 5, rh >= 5 else { return nil }

        let px = CGFloat(cg.width) / max(base.size.width, 1)
        let cropPx = CGRect(x: CGFloat(x0) * px, y: CGFloat(y0) * px,
                            width: CGFloat(rw) * px, height: CGFloat(rh) * px)
        // ⭐ 直接把 ROI 画进 RGBA 缓冲（省一次整图拷贝）
        var buf = [UInt8](repeating: 0, count: rw * rh * 4)
        guard let ctx = CGContext(data: &buf, width: rw, height: rh,
                                  bitsPerComponent: 8, bytesPerRow: rw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: -cropPx.minX, y: -(CGFloat(cg.height) - cropPx.maxY),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        // ⚠️ CGContext 原点在**左下** ⇒ 缓冲第 0 行是 ROI 的底行 ⇒ 读时翻回来
        var w = 0, h = 0
        // ⭐⭐⭐⭐⭐ §2705 **外接框/填充率只算「最大连通分量」**，⛔ 不算整个 ROI
        //
        // ## 真根因（真机帧像素实测，两台独立取证）
        // 弹窗盖屏时 PC 判据**本该命中**却返回 nil。同一帧上量出来：
        // ```
        //   ✕ 本体窗口内        : n=416  28×23  fill=0.646   ⇒ 过闸 ✅
        //   整个 boxModalX 内    : n=510  86×168 fill=0.035   ⇒ ⛔ 被两个闸同时拒
        // ```
        // ⇒ 根因：**外接框与填充率是按 ROI 里"所有"命中像素算的**。
        //   而弹窗的**圆角与深色遮罩渐变**也有像素落进暖灰区（[118,142]）
        //   ⇒ 与 ✕ 的命中集**合并**成一个 86×168 的大外接框
        //   ⇒ 尺寸闸（≤42）与填充率闸（≥0.45）**同时**把它判成"细而散" ⇒ nil。
        //
        // ## 为什么这正是任务中心那个弹窗（用户口径）
        // > 「**任务中心有弹窗，弹窗一般出现在任务中心 主页和直播间。**」
        // 真机 trace 逐字：`§adbox ⚠️ 点了任务但没进广告页 ⇒ 重试`（连 3 轮 ⇒ 收手），
        // 而取证帧 `ev_233427_01.jpg` 上**正是那个弹窗**（「限时邀1位好友立得现金」）
        // 盖住了任务行 ⇒ 点击全落在弹窗上。
        //
        // ## ✅ 修法（⛔ 阈值一个字不改）
        // 先求**最大 4-连通分量**，只对那个分量算 w/h/fill 再过**同样的**闸。
        // 真机两帧验证：
        // ```
        //   新算法 ⇒ 28×28 fill=0.631 / 29×29 fill=0.543  ⇒ ✅ 命中（质心 (409,260)）
        //   其余散点分量 ⇒ 最大只有 5 个点 ⇒ 仍被 minN=250 挡住 ✅（⛔ 不放松）
        // ```
        var comp = [UInt8](repeating: 0, count: rw * rh)
        var bestN = 0, bestSx = 0, bestSy = 0
        var bestMinX = 0, bestMaxX = 0, bestMinY = 0, bestMaxY = 0
        var queue = [Int](repeating: 0, count: rw * rh)
        for j in 0..<rh {
            let srcRow = (rh - 1 - j) * rw * 4
            for i in 0..<rw {
                if comp[j * rw + i] != 0 { continue }
                let p = srcRow + i * 4
                let r = Int(buf[p]), g = Int(buf[p + 1]), b = Int(buf[p + 2])
                guard r >= thrLo, r <= thrHi,
                      g >= thrLo, g <= thrHi,
                      b >= thrLo, b <= thrHi,
                      (max(r, max(g, b)) - min(r, min(g, b))) <= spread else {
                    comp[j * rw + i] = 2      // 标记"已看不命中"，⛔ 不再重复判
                    continue
                }
                // 4-连通洪泛（显式队列，⛔ 不递归 —— ROI 可能很大）
                var head = 0, tail = 0
                queue[tail] = j * rw + i; tail += 1
                comp[j * rw + i] = 1
                var cn = 0, csx = 0, csy = 0
                var cminX = Int.max, cmaxX = Int.min, cminY = Int.max, cmaxY = Int.min
                while head < tail {
                    let cur = queue[head]; head += 1
                    let cy = cur / rw, cx = cur % rw
                    cn += 1; csx += cx; csy += cy
                    if cx < cminX { cminX = cx }; if cx > cmaxX { cmaxX = cx }
                    if cy < cminY { cminY = cy }; if cy > cmaxY { cmaxY = cy }
                    for (dy, dx) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let ny = cy + dy, nx = cx + dx
                        guard ny >= 0, ny < rh, nx >= 0, nx < rw else { continue }
                        let ni = ny * rw + nx
                        if comp[ni] != 0 { continue }
                        let qp = (rh - 1 - ny) * rw * 4 + nx * 4
                        let qr = Int(buf[qp]), qg = Int(buf[qp + 1]), qb = Int(buf[qp + 2])
                        guard qr >= thrLo, qr <= thrHi,
                              qg >= thrLo, qg <= thrHi,
                              qb >= thrLo, qb <= thrHi,
                              (max(qr, max(qg, qb)) - min(qr, min(qg, qb))) <= spread else {
                            comp[ni] = 2
                            continue
                        }
                        comp[ni] = 1
                        queue[tail] = ni; tail += 1
                    }
                }
                if cn > bestN {
                    bestN = cn; bestSx = csx; bestSy = csy
                    bestMinX = cminX; bestMaxX = cmaxX; bestMinY = cminY; bestMaxY = cmaxY
                }
            }
        }
        guard bestN > 0 else { return nil }
        // ⭐ 对**最大分量**过与 PC 逐字相同的闸
        guard bestN >= minN else { return nil }
        w = bestMaxX - bestMinX + 1
        h = bestMaxY - bestMinY + 1
        guard w >= sideLo, h >= sideLo, w <= sideHi, h <= sideHi else { return nil }
        guard Double(bestN) / Double(w * h) >= fill else { return nil }
        return CGPoint(x: CGFloat(x0) + CGFloat(bestSx) / CGFloat(bestN),
                       y: CGFloat(y0) + CGFloat(bestSy) / CGFloat(bestN))
    }

    /// ⭐ 券弹窗的 ✕（PC `find_coupon_x` 用的 ROI = `BOX_COUPON_X` 比例 (0.42,0.64,0.58,0.78)）
    ///    ⇒ 基准 451×977 下是 x 189~261 / y 625~762
    static let boxCouponX = CGRect(x: 189, y: 625, width: 72, height: 137)

    static func findCoupon(_ img: UIImage) -> CGPoint? {
        find(img, roi: boxCouponX)
    }
}
