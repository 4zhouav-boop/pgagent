import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ **色彩块检测**（移植电脑端 `_1377_ad_loop.py:746` `find_coin_entry`）。
///
/// ## 为什么必须有它（§2256 实测卡点）
/// 手机端 `Runner` 跑到 adbox 第一步「回金币中心」就卡住（trace 铁证）：
/// ```
/// §adbox_boot ⚠️ 在 unknown 找不到回中心的路（第 1 步）
/// …（8 步全废）
/// §adbox ⛔ 回不到金币中心 ⇒ 停手
/// ```
/// **根因**：回中心的**唯一入口**是 feed 页左上那个**红包/金币悬浮球**，
/// 而它是**纯图形**（没有文字）⇒ **OCR 认不出** ⇒ 我原来配的
/// `featured.go = center_marker`（OCR 近似）**根本点不到**。
///
/// 电脑端用**色彩判据**找它（`find_coin_entry`），
/// 而且是**全量 1706 帧**验证过的：
/// ```
/// POS（含悬浮球的信息流帧）12/12 命中；形心 x∈[49,51]（跨度只有 2px）、y∈[153,196]
/// NEG（1694 张广告/落地页/面板帧）0 命中
/// ```
///
/// ## 两个**结构性**分离量（⛔ 不是阈值凑的，PC 原文）
/// ① **x 窗口** —— 悬浮球是**左对齐悬浮件**，12 帧跨 4+ 种版式 x 只差 2px；
/// ② **fill 窗口** —— 真球核是**实心圆角块** fill 0.743~0.785；
///    误报要么**过散**（0.55~0.62）要么**过实**（0.929）
///    ⇒ 用**区间** `[0.68, 0.88]` 一刀切开。
enum ColorBlob {

    /// ⭐ 红包球搜索区（**PC `COIN_ROI` 逐字**）
    ///
    /// PC 注释（L728-731）解释了为什么下界是 235 而不是 205：
    /// > 悬浮球有**两种 y 位置**：历史版式球核 y 137..174（形心 y≈153）；
    /// > **今天这一版**信息流上方多了一条充电状态条 ⇒ 整体下移，球核 y 175..208。
    /// > ⇒ 窄 ROI（下界 205）只剩 13px 余量，**换个版式就漏** ⇒ 必须放宽到 235。
    static let coinROI = CGRect(x: 35, y: 120, width: 80, height: 115)   // (35,120)-(115,235)

    /// 红色判据（照 PC `COIN_RED_MIN_R/DG/DB`）
    static let redMinR = 180
    static let redDG = 100
    static let redDB = 100
    /// 膨胀次数（把被暗带切开的上下两块并起来，照 PC `COIN_DILATE = 2`）
    static let dilate = 2
    /// 尺寸闸（照 PC `COIN_WH_LO/HI`）
    static let whLo = 20, whHi = 55
    /// ⭐ fill **区间**（照 PC `COIN_FILL_LO/HI`）—— ⛔ 不是单边下限
    static let fillLo = 0.68, fillHi = 0.88

    /// ⭐⭐⭐ 定位**红包/金币悬浮球**（feed 页左上的「回金币中心」唯一入口）
    ///
    /// 纯像素（**零 OCR**）⇒ 再贵也只是一次小 ROI 扫描（80×115）。
    ///
    /// - Parameter img: **基准尺度**的帧（内部会先 `norm`）
    /// - Returns: 球心（**基准像素**）或 `nil`
    ///
    /// ⛔ 铁律②：**先找到再点** —— 找不到就返回 nil，调用方**什么都不做**。
    static func findCoinBall(_ img: UIImage) -> CGPoint? {
        // ① 归一到基准（451×977）—— ROI 是按这个尺度量的
        let base = FrameNormalizer.normalize(img)
        guard let cgAll = base.cgImage else { return nil }

        let W = cgAll.width, H = cgAll.height
        let x0 = max(0, Int(coinROI.minX)), y0 = max(0, Int(coinROI.minY))
        let x1 = min(Int(coinROI.maxX), W), y1 = min(Int(coinROI.maxY), H)
        let rw = x1 - x0, rh = y1 - y0
        guard rw > 4, rh > 4 else { return nil }

        // ② ⭐ 先把 ROI **裁出来**（`cropping` 用左上原点坐标，简单可靠）
        //    ⛔ 不要在 CGContext 里平移整图再翻转 y —— 那样极易搞错
        guard let cg = cgAll.cropping(to: CGRect(x: x0, y: y0,
                                                 width: rw, height: rh))
        else { return nil }

        // ③ 画进 RGBA 缓冲（⚠️ premultipliedLast + 默认字节序 ⇒ 内存里就是 R,G,B,A）
        var buf = [UInt8](repeating: 0, count: rw * rh * 4)
        guard let ctx = CGContext(data: &buf, width: rw, height: rh,
                                  bitsPerComponent: 8, bytesPerRow: rw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: rw, height: rh))
        // ⚠️ CGContext 原点在**左下** ⇒ 缓冲第 0 行是 ROI 的**底行**
        //    ⇒ 读像素时把行翻过来（下面统一用 `srcRow`）

        // ④ 红色掩码（照 PC 判据：r>180 且 r-g>100 且 r-b>100）
        var red = [Bool](repeating: false, count: rw * rh)
        for j in 0..<rh {
            let srcRow = (rh - 1 - j) * rw * 4      // 翻 y
            for i in 0..<rw {
                let p = srcRow + i * 4
                let r = Int(buf[p]), g = Int(buf[p + 1]), b = Int(buf[p + 2])
                if r > redMinR && (r - g) > redDG && (r - b) > redDB {
                    red[j * rw + i] = true
                }
            }
        }

        // ④ 膨胀（照 PC `COIN_DILATE`）
        var dil = red
        for j in 0..<rh {
            for i in 0..<rw where red[j * rw + i] {
                for jj in max(0, j - dilate)...min(rh - 1, j + dilate) {
                    for ii in max(0, i - dilate)...min(rw - 1, i + dilate) {
                        dil[jj * rw + ii] = true
                    }
                }
            }
        }

        // ⑤ 连通域 + 尺寸/fill 双闸（照 PC）
        var seen = [Bool](repeating: false, count: rw * rh)
        var best: (cx: Double, cy: Double, n: Int)?
        for j in 0..<rh {
            for i in 0..<rw {
                if !dil[j * rw + i] || seen[j * rw + i] { continue }
                // BFS 找一块连通
                var stack = [(i, j)]
                seen[j * rw + i] = true
                var cells: [(Int, Int)] = []
                while let (ci, cj) = stack.popLast() {
                    cells.append((ci, cj))
                    for (ni, nj) in [(ci + 1, cj), (ci - 1, cj), (ci, cj + 1), (ci, cj - 1)] {
                        if ni >= 0, ni < rw, nj >= 0, nj < rh,
                           dil[nj * rw + ni], !seen[nj * rw + ni] {
                            seen[nj * rw + ni] = true
                            stack.append((ni, nj))
                        }
                    }
                }
                // ⚠️ 只用**原本就是红**的像素算尺寸/fill（膨胀只为连通，不算面积）
                let orig = cells.filter { red[$0.1 * rw + $0.0] }
                if orig.isEmpty { continue }
                if let b = best, orig.count <= b.n { continue }
                let xs = orig.map { $0.0 }, ys = orig.map { $0.1 }
                let w = (xs.max()! - xs.min()!) + 1
                let h = (ys.max()! - ys.min()!) + 1
                guard w >= whLo, w <= whHi, h >= whLo, h <= whHi else { continue }
                let fill = Double(orig.count) / Double(w * h)
                // ★ 区间判据（⛔ 不是单边下限）—— 挡"过散"和"过实"两种误报
                guard fill >= fillLo, fill <= fillHi else { continue }
                let cx = Double(x0) + Double(xs.reduce(0, +)) / Double(orig.count)
                let cy = Double(y0) + Double(ys.reduce(0, +)) / Double(orig.count)
                best = (cx, cy, orig.count)
            }
        }
        guard let b = best else { return nil }
        return CGPoint(x: b.cx, y: b.cy)
    }
}
