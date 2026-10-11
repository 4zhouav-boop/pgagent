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

        var sx = 0, sy = 0, n = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for j in 0..<rh {
            let srcRow = (rh - 1 - j) * rw * 4      // 翻 y
            for i in 0..<rw {
                let p = srcRow + i * 4
                let r = Int(buf[p]), g = Int(buf[p + 1]), b = Int(buf[p + 2])
                guard r >= thrLo, r <= thrHi,
                      g >= thrLo, g <= thrHi,
                      b >= thrLo, b <= thrHi,
                      (max(r, max(g, b)) - min(r, min(g, b))) <= spread else { continue }
                n += 1; sx += i; sy += j
                if i < minX { minX = i }; if i > maxX { maxX = i }
                if j < minY { minY = j }; if j > maxY { maxY = j }
            }
        }
        guard n >= minN else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1
        // ⭐ 紧凑度闸（PC：18 ≤ w,h ≤ 42 且 填充率 ≥ 0.45）
        guard w >= sideLo, h >= sideLo, w <= sideHi, h <= sideHi else { return nil }
        guard Double(n) / Double(w * h) >= fill else { return nil }
        return CGPoint(x: CGFloat(x0) + CGFloat(sx) / CGFloat(n),
                       y: CGFloat(y0) + CGFloat(sy) / CGFloat(n))
    }

    /// ⭐ 券弹窗的 ✕（PC `find_coupon_x` 用的 ROI = `BOX_COUPON_X` 比例 (0.42,0.64,0.58,0.78)）
    ///    ⇒ 基准 451×977 下是 x 189~261 / y 625~762
    static let boxCouponX = CGRect(x: 189, y: 625, width: 72, height: 137)

    static func findCoupon(_ img: UIImage) -> CGPoint? {
        find(img, roi: boxCouponX)
    }
}
