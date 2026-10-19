import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ 「几何层」—— **帧归一化**（§2241 移植 PC `normalize_frame`，L1627）。
///
/// ## ⛔⛔ 这个文件修的是「移植后全部认成 unknown 然后退出」的**真根因**
///
/// ### 现象
/// ```
/// 手机上跑：日志一路 "unknown" ⇒ 「⛔ 连续 N 帧认不出 ⇒ 停手」
/// ```
///
/// ### 根因（两个 bug，同一个病根）
/// **帧没有归一化到标定基准**。实测尺寸：
/// ```
/// 扩展/截图给的帧 : 1353×2925（或 1170×2532）
/// config 的标定基准: 451×977     ← 所有 ROI / 模板 / 坐标都是按这个量的
/// ```
/// ⇒ 于是：
/// | # | 错在哪 | 后果 |
/// |---|---|---|
/// | ① | `findWords` 用 `归一化 bbox × **原始**尺寸` 算 px | px 落在 0~2925，而 ROI 是 62~140 ⇒ **永不相交** ⇒ 全部 `continue` 丢掉 |
/// | ② | 模板是基准尺度的，却在原始帧上滑窗 | 尺度差 **3.0×** ⇒ NCC 永远匹配不上；且 ROI 按基准值裁在原始帧上 ⇒ 错位 |
/// ⇒ `pageHere` 全不命中 ⇒ **unknown ⇒ 退出**。与现象**完全一致**。
///
/// ### 为什么在**取帧处**归一，而不是改 ROI
/// 与 PC 同一理由（`normalize_frame` 的注释逐字）：
/// > 所有既有标定（BOX_* / 各 ROI / plog 的 442 基数 / 像素阈值）**都是按 451×977 量的**。
/// > 只要每帧先归一到基准，**这些标定原样成立**，同时**任意尺寸都能跑**
/// ⇒ 改动面最小、回退风险最低。
///
/// ### PC 的两步（照抄）
/// ```
/// ① 裁手机区：宽高比偏离基准 > 2% ⇒ 认为加了黑边，按 451:977 取最大居中矩形
/// ② 缩放到 451×977（BILINEAR）
/// ```
enum FrameNormalizer {

    /// 标定基准（与 config.json 的 `base_w` / `base_h` 同源）
    ///
    /// ⭐⭐⭐⭐⭐ §3250 **改成"可被 config 覆盖"的 var**（用户令 2026-10-19）
    ///
    /// ## 用户原话（逐字，两轮）
    /// > 「你就直接出 整图  不要压缩换算了。PG控制台是做了压缩的。不能完全一样」
    /// > 「直接用手机原分辨率，你就直接用原分辨率 AI用什么方式识别的。」
    /// > 「就用手机的分辨率，然后AI自己识图 做精确点击。把眼睛和手先测试好 再跑」
    ///
    /// ## 为什么原来是错的（真机事实）
    /// 手机帧 = **888×1920**，而这里硬编码 **451×977** ⇒ 每一帧都被**重采样压扁**。
    /// 📏 实测（2026-10-19 12:22）：把 config 的 `base_w/base_h` 改成 888/1920 并重启 App 后，
    ///    `pg.gray(0,0,888,1920)` **仍然返回 451×977** ⇒ 证明这两个常量**根本不读 config**。
    /// ⇒ 后果：所有 ROI / 阈值 / 模板尺度 / OCR 坐标都建立在**被压缩过的图**上；
    ///   AI 看图也是压缩图（小字糊掉），点击换算多绕一层，误差被放大。
    ///
    /// ## 现在的做法
    /// · 默认值保持 451/977（⛔ 不破没配 config 的场景）
    /// · **App 启动 / config 加载时**由 `ConfigStore` 调 `FrameNormalizer.applyBase(w:h:)` 覆盖
    /// · 归一化只在**尺寸真的不等于 base** 时发生 ⇒ 配成 888×1920 后**完全不重采样**
    static var baseW: CGFloat = 451
    static var baseH: CGFloat = 977

    /// 由 config 注入基准分辨率（`base_w` / `base_h`）
    /// - Parameter log: 只改一次，变了才打日志（⛔ 不刷屏）
    static func applyBase(w: Double, h: Double, log: ((String) -> Void)? = nil) {
        guard w >= 2, h >= 2 else { return }
        let changed = abs(baseW - CGFloat(w)) > 0.5 || abs(baseH - CGFloat(h)) > 0.5
        baseW = CGFloat(w)
        baseH = CGFloat(h)
        didLog = false          // 基准变了 ⇒ 允许再打一次归一化日志
        if changed {
            log?("   §geo 基准分辨率改为 \(Int(w))x\(Int(h))（来自 config）")
        }
    }

    /// ⭐ 把任意尺寸的帧归一到 **451×977**
    ///
    /// ⚠️ 已经等于基准 ⇒ **原样返回**（⛔ 不做无谓的重绘，省 CPU）
    /// - Parameter log: 只在**第一次**归一化时打一行（免得刷屏）
    static func normalize(_ img: UIImage,
                          log: ((String) -> Void)? = nil) -> UIImage {
        let w = img.size.width, h = img.size.height
        guard w > 1, h > 1 else { return img }

        // 已经是基准 ⇒ 直接返回
        if abs(w - baseW) < 1 && abs(h - baseH) < 1 { return img }

        var work = img
        var cw = w, ch = h
        let ar = w / h
        let arb = baseW / baseH

        // ① 宽高比偏离 > 2% ⇒ 先裁出「最大居中矩形」（多半是投屏/截图的黑边）
        if abs(ar - arb) / arb > 0.02 {
            if ar > arb {
                cw = (h * arb).rounded(); ch = h
            } else {
                cw = w; ch = (w / arb).rounded()
            }
            let bx = ((w - cw) / 2).rounded()
            let by = ((h - ch) / 2).rounded()
            if let cg = img.cgImage?.cropping(
                to: CGRect(x: bx * img.scale, y: by * img.scale,
                           width: cw * img.scale, height: ch * img.scale)) {
                work = UIImage(cgImage: cg, scale: img.scale, orientation: img.imageOrientation)
                log?("   §geo 帧 \(Int(w))x\(Int(h)) 宽高比 \(String(format: "%.4f", ar))"
                     + " 偏离基准 \(String(format: "%.4f", arb)) >2% ⇒ 先裁手机区 \(Int(cw))x\(Int(ch))")
            }
        }

        // ② 缩放到基准
        let target = CGSize(width: baseW, height: baseH)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1.0                     // ⭐ 强制 1x ⇒ 像素尺寸**就是** 451×977
        let r = UIGraphicsImageRenderer(size: target, format: fmt)
        let out = r.image { _ in
            work.draw(in: CGRect(origin: .zero, size: target))
        }
        log?("   §geo 帧 \(Int(w))x\(Int(h)) ⇒ 归一化到 \(Int(baseW))x\(Int(baseH))"
             + "（缩放 x\(String(format: "%.4f", w / baseW))"
             + " / y\(String(format: "%.4f", h / baseH))）")
        return out
    }

    /// ⭐ 只归一化**一次**的版本（避免每帧都打日志刷屏）
    static func normalizeOnce(_ img: UIImage, log: ((String) -> Void)? = nil) -> UIImage {
        if !didLog {
            let out = normalize(img) { s in log?(s) }
            didLog = true
            return out
        }
        return normalize(img, log: nil)
    }
    private static var didLog = false
}
