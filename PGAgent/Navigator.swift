import Foundation
import UIKit

/// ⭐ 导航引擎 —— **配置驱动**（判据/页面图/漏斗全部来自 config.json）。
///
/// 三层结构（照 Alas `ui_goto` + `_1765_nav.py`）：
///   ① 到目的地了吗？
///   ② **恢复漏斗**（弹窗/盖屏优先 —— 弹窗盖屏时底下什么都点不到）
///   ③ 页面图上「前进一跳」
///   ④ 都失败 ⇒ 停手（⛔ 不盲点）
///
/// ⛔ 铁律：**先找到再点**。⛔ 广告页**放行**（用户令：「都是跑循环广告」）。
final class Navigator {

    let cfg: PGConfig
    let rec: Recognizer
    let ble: BLEController
    let log: (String) -> Void

    private var funnelLast: [String: Date] = [:]

    init(cfg: PGConfig, rec: Recognizer, ble: BLEController, log: @escaping (String) -> Void) {
        self.cfg = cfg
        self.rec = rec
        self.ble = ble
        self.log = log
    }

    // MARK: - 基准坐标

    var baseW: Double { cfg.settings?.base_w ?? 451 }
    var baseH: Double { cfg.settings?.base_h ?? 977 }
    var yFix: Double { cfg.settings?.y_fix ?? 4 }
    var tplThr: Double { cfg.settings?.template_threshold ?? 0.80 }

    /// ROI 支持两种写法：绝对像素 `[x0,y0,x1,y1]`，或全 0..1 的**比例**
    /// ⭐ 元素的 roi 直接内联（数组），也兼容 `rois` 表里的 key 字符串。
    func roi(_ inline: [Double]?) -> CGRect? {
        guard let a = inline, a.count == 4 else { return nil }
        return rect4(a)
    }

    /// 从 `rois` 表按 key 取（元素想复用时用）
    func roiKey(_ key: String?) -> CGRect? {
        guard let key = key, let a = cfg.rois?[key], a.count == 4 else { return nil }
        return rect4(a)
    }

    private func rect4(_ a: [Double]) -> CGRect {
        let frac = a.allSatisfy { $0 >= 0 && $0 <= 1 }
        if frac {
            return CGRect(x: a[0] * baseW, y: a[1] * baseH,
                          width: (a[2] - a[0]) * baseW, height: (a[3] - a[1]) * baseH)
        }
        return CGRect(x: a[0], y: a[1], width: a[2] - a[0], height: a[3] - a[1])
    }

    // MARK: - 检测一个元素

    /// 返回元素命中框（基准像素）或 nil
    func detect(_ name: String, img: UIImage) -> Recognizer.Hit? {
        guard let e = cfg.elements[name] else { return nil }
        // ⭐ 元素的 roi 直接内联；若为 null 则不过滤（全帧）
        let r = roi(e.roi)
        switch e.match {
        case "ocr":
            let words = e.words ?? []
            let h = rec.findWords(img, words: words, roi: r,
                                  minHits: e.min_hits ?? 1,
                                  minConfidence: cfg.settings?.ocr_min_confidence ?? 0.5)
            if var hh = h { hh.name = name; return hh }
            return nil
        case "template":
            let names = e.templates ?? []
            guard !names.isEmpty else { return nil }
            if let (rect, score, used) = rec.poolMatch(img, tplNames: names, roi: r,
                                                       threshold: e.threshold ?? tplThr,
                                                       mask: e.mask) {
                return Recognizer.Hit(name: name, rect: rect, score: score,
                                      evidence: used)
            }
            return nil
        default:
            return nil
        }
    }

    /// 页面判定（支持 `not` 反向）
    func pageHere(_ img: UIImage) -> String? {
        for (pname, p) in cfg.pages {
            if p.island == true { continue }              // 孤岛页不参与"我在哪"
            guard let checks = p.check else { continue }
            var ok = true
            for c in checks where detect(c, img: img) == nil { ok = false; break }
            if !ok { continue }
            if let nots = p.not {
                for n in nots where detect(n, img: img) != nil { ok = false; break }
            }
            if ok { return pname }
        }
        return nil
    }

    // MARK: - 动作

    /// 点击一个元素（⛔ 必须先找到 ⇒ 坐标是识别结果，不是盲点坐标）
    @discardableResult
    func tap(_ name: String, img: UIImage) -> Bool {
        guard let h = detect(name, img: img) else { return false }
        let c = h.center
        let cmds = BLEController.moveAndClick(x: Double(c.x), y: Double(c.y),
                                              baseW: baseW, baseH: baseH, yFix: yFix)
        for cmd in cmds { ble.send(cmd) }
        log("   §click \(name) @(\(Int(c.x)),\(Int(c.y))) score=\(String(format: "%.3f", h.score)) ev=\(h.evidence)")
        return true
    }

    // MARK: - 漏斗（② 步）

    func runFunnel(_ img: UIImage) -> Bool {
        guard let items = cfg.funnel else { return false }
        let now = Date()
        for it in items {
            if let last = funnelLast[it.element],
               now.timeIntervalSince(last) < (it.interval ?? 1.0) { continue }
            if detect(it.element, img: img) != nil {
                funnelLast[it.element] = now
                log("   §funnel \(it.element)（\(it.desc ?? "")）")
                return tap(it.element, img: img)
            }
        }
        return false
    }

    // MARK: - 到目的地（①②③④ 主循环）

    /// 走到目标页。`dest` = config 里的 page key；`img` 为当前帧。
    @discardableResult
    func go(to dest: String, img: UIImage) -> Bool {
        let steps = cfg.settings?.max_steps ?? 12
        var cur = img
        for k in 0..<steps {
            // ① 到目的地了吗？
            if pageHere(cur) == dest {
                log("   §nav ✅ 已在 \(dest)（第 \(k + 1) 步）")
                return true
            }
            // ⛔ 广告页放行（用户令）
            if let ad = cfg.pages["ad_video"], let c = ad.check,
               c.allSatisfy({ detect($0, img: cur) != nil }) {
                log("   §nav ⛔ 这是广告页 ⇒ 放行（不碰，交给广告模块）")
                return false
            }
            // ② 恢复漏斗（弹窗盖屏优先）
            if runFunnel(cur) { return true }   // 处理一层就重抓（调用方循环）
            // ③ 页面图上前进一跳
            if let here = pageHere(cur), let p = cfg.pages[here], let go = p.go,
               go != "stop" {
                log("   §nav 在 \(here) ⇒ 点 \(go)")
                if tap(go, img: cur) { return true }
            }
            // ④ 停手（⛔ 不盲点）
            let here = pageHere(cur) ?? "unknown"
            log("   §nav ⛔ 认不出出路（\(here)）⇒ 停手（第 \(k + 1) 步）")
            return false
        }
        return false
    }
}
