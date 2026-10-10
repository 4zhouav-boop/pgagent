import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ 「大脑」—— **PG 控制台的手机版**（§2240 移植）。
///
/// ## 移植来源（⛔ 不是臆造，逐条对齐 PC 源码）
/// | 手机 | PC（`_dev/_1377_ad_loop.py`）|
/// |---|---|
/// | `FeatureEngine.order` | `FEAT_ORDER = ["adbox","feed","tag","search"]`（L9357 铁证）|
/// | `runAdbox` | 主 while 循环（L9410+）|
/// | `runFeed` | `run_feed()`（L5078）|
/// | `runTag` | `run_tag()`（L6842）|
/// | `runMall` | `run_mall()`（L7609）|
/// | `rotateApp` | `_rotate_app_or_exit()`（L9222）|
///
/// ## 一轮闭环的顺序（⭐ 硬契约，⛔ 不许改）
/// ```
/// 看广告得金币+宝箱  →  刷视频  →  搜索打标签  →  商城逛小店
///                                          ↑ 最后一棒，跑完回任务中心 = 一轮闭环
/// ```
/// 用户令：「闭环是说的看广告得金币收尾。我发现他有时候是突然停止的。
///         要链接起来。不然容易卡住。」
///
/// ## ⛔ 两条铁律（用户令，⛔ 不许违）
/// 1. **广告页放行**：「谁让你强退的，都是跑循环广告，你他妈一个广告就点X」
///    ⇒ 广告页**待够时间**，⛔ 绝不点 ✕。
/// 2. **认不出不自杀**：「认不出就不做了，直接自杀 你还推荐。要眼睛干什么」
///    ⇒ 容忍瞬时态，但**仍然不盲点**。
final class FeatureEngine {

    /// ⭐⭐⭐ **权威执行顺序**（照抄 PC `FEAT_ORDER`）
    static let order = ["adbox", "feed", "tag", "search"]

    /// 中文名（与控制台 `FEATURE_OPTS` 一致，⛔ 用户要中文）
    static func cn(_ key: String) -> String {
        switch key {
        case "adbox":  return "看广告得金币 + 宝箱"
        case "feed":   return "刷视频"
        case "tag":    return "搜索打标签"
        case "search": return "商城逛小店"
        default:       return key
        }
    }

    private let cfgStore: ConfigStore
    private let nav: Navigator
    private let rec: Recognizer
    private let ble: BLEController
    private let grab: () -> UIImage?
    private let log: (String) -> Void
    /// 让上层能中断（Runner 的 cancelFlag）
    private let isCancelled: () -> Bool
    /// 心跳（写到共享容器，App 退后台也能看）
    private let beat: ([String: Any]) -> Void

    init(cfgStore: ConfigStore,
         nav: Navigator,
         rec: Recognizer,
         ble: BLEController,
         grab: @escaping () -> UIImage?,
         isCancelled: @escaping () -> Bool,
         beat: @escaping ([String: Any]) -> Void,
         log: @escaping (String) -> Void) {
        self.cfgStore = cfgStore
        self.nav = nav
        self.rec = rec
        self.ble = ble
        self.grab = grab
        self.isCancelled = isCancelled
        self.beat = beat
        self.log = log
    }

    private var s: ConfigStore.Settings? { cfgStore.cfg?.settings }
    private var baseW: Double { s?.base_w ?? 451 }
    private var baseH: Double { s?.base_h ?? 977 }
    private var yFix: Double { s?.y_fix ?? 4 }

    // MARK: - ⭐ 对外入口：跑**一轮完整闭环**

    /// 跑一轮：按 `order` 依次跑「勾到的」功能。
    ///
    /// ⭐ 语义**逐条对齐** PC（L9360~9395）：
    /// ```
    /// · features 为空        ⇒ 只跑 adbox（= PC 不设 AISJ_FEATURES 的旧行为）
    /// · 勾了 adbox          ⇒ 先跑广告循环，**跑完再按 order 跑其余**
    /// · 没勾 adbox          ⇒ ⛔ **不进广告循环**，只按 order 跑勾到的
    /// ```
    /// - Returns: 报告（跑了哪些功能、各自结果）—— 写进心跳，便于 PC 侧取证
    @discardableResult
    func runRound() -> [String: Any] {
        var feats = s?.features?.filter { Self.order.contains($0) } ?? []
        if feats.isEmpty { feats = ["adbox"] }            // ⭐ 旧行为：只跑广告
        if !feats.contains("adbox") && s?.features == nil { feats = ["adbox"] }

        // ⭐ 按**权威顺序**排（⛔ 不按用户填写顺序）
        let planned = Self.order.filter { feats.contains($0) }
        log("§feat ═══ 本轮功能：\(planned.map(Self.cn).joined(separator: " → ")) ═══")
        beat(["phase": "round-start", "planned": planned])

        var report: [String: Any] = ["planned": planned, "done": [String]()]
        var done: [String] = []

        for k in planned {
            if isCancelled { log("§feat ⛔ 被中断"); break }
            log("§feat ▶️ 开始【\(Self.cn(k))】")
            beat(["phase": "feat-start", "feat": k, "done": done])

            let ok: Bool
            switch k {
            case "adbox":  ok = runAdbox()
            case "feed":   ok = runFeed()
            case "tag":    ok = runTag()
            case "search": ok = runMall()
            default:       ok = false
            }

            // ⭐ 每个功能跑完**统一回任务中心**（用户令：闭环要「链接起来」）
            log("§feat ⏹ 结束【\(Self.cn(k))】ok=\(ok) ⇒ 回任务中心")
            let centered = ensureInCenter(tag: "\(k)_after")
            beat(["phase": "feat-done", "feat": k, "ok": ok, "centered": centered])

            if ok { done.append(k) }
            if !ok {
                // ⛔ 一个功能失败**不整轮自杀**（用户令：「认不出就不做了，直接自杀 你还推荐」）
                //    ⇒ 继续下一棒；都跑完再由上层决定
                log("§feat ⚠️【\(Self.cn(k))】没跑成 ⇒ 仍继续下一棒（⛔ 不整轮放弃）")
            }
        }

        report["done"] = done
        log("§feat ═══ 本轮结束：完成 \(done.count)/\(planned.count) ═══")
        beat(["phase": "round-done", "done": done, "planned": planned])
        return report
    }

    // MARK: - ① adbox 看广告得金币 + 宝箱

    /// ⭐ 照 PC 主循环：回中心 → 找广告任务 → 点进去 → **广告页待够时间** → 回中心。
    private func runAdbox() -> Bool {
        let count = max(1, s?.ad_count ?? 6)          // PC 控制台「条数」默认 6
        let dwell = s?.ad_dwell ?? 30                  // PC 控制台「广告停留秒」默认 30
        log("§adbox 条数=\(count) 广告停留=\(Int(dwell))s 入口=\(s?.entry ?? "auto")")

        guard ensureInCenter(tag: "adbox_boot") else {
            log("§adbox ⛔ 回不到金币中心 ⇒ 停手")
            return false
        }

        var n = 0
        while n < count {
            if isCancelled { log("§adbox ⛔ 被中断"); break }
            guard let img = grab() else { log("§adbox ⛔ 抓帧失败"); break }
            beat(["phase": "adbox-step", "n": n, "of": count])

            // ① 已经在广告页？⇒ **放行**（⛔ 不点 ✕，用户令）
            if nav.pageHere(img) == "ad_video" {
                log("§adbox ⛔ 广告页 ⇒ 放行（待够 \(Int(dwell))s，⛔ 不点 ✕）")
                dwellOnAd(dwell)
                n += 1
                _ = ensureInCenter(tag: "adbox_back\(n)")
                continue
            }

            // ② 找「广告任务」那一行的按钮并点它
            if let hit = nav.detect("ad_task_btn", img: img) {
                let c = hit.center
                log("§adbox 点广告任务 @(\(Int(c.x)),\(Int(c.y))) score=\(String(format: "%.3f", hit.score))")
                tapBase(Double(c.x), Double(c.y))
                sleep(2.0)
                // ⭐ 点完**立即**再抓一帧看是不是广告页
                if let i2 = grab(), nav.pageHere(i2) == "ad_video" {
                    log("§adbox ⛔ 已进广告页 ⇒ 放行待够 \(Int(dwell))s")
                    dwellOnAd(dwell)
                    n += 1
                    _ = ensureInCenter(tag: "adbox_back\(n)")
                    continue
                }
                log("§adbox ⚠️ 点了任务但没进广告页 ⇒ 重试")
                sleep(1.5)
                continue
            }

            // ③ 认不出 ⇒ 交给漏斗（弹窗优先），不自杀
            if nav.runFunnel(img) {
                log("§adbox 漏斗处理了一层")
                sleep(1.0)
                continue
            }
            log("§adbox ⚠️ 找不到广告任务按钮（第 \(n + 1)/\(count) 条）⇒ 回中心再找")
            if !ensureInCenter(tag: "adbox_re\(n)") {
                log("§adbox ⛔ 也回不了中心 ⇒ 停手")
                break
            }
            // ⭐ 防死循环：回中心后仍找不到 ⇒ 记一次「空转」，连续 3 次就收
            n += 1
            if n >= count { break }
        }
        log("§adbox 跑完 \(n) 条")
        return n > 0
    }

    /// ⭐ 广告页**待够时间**（⛔ 绝不点 ✕ —— 用户令 + 荔枝 40/60 秒）
    private func dwellOnAd(_ seconds: Double) {
        var left = seconds
        while left > 0 {
            if isCancelled { return }
            let d = min(0.5, left)
            Thread.sleep(forTimeInterval: d)
            left -= d
            let prog = 1.0 - (left / max(seconds, 0.001))
            beat(["phase": "ad-dwell", "progress": prog])
        }
    }

    // MARK: - ② feed 刷视频（照 PC `run_feed` L5078）

    /// ⭐ 高价值 ⇒ **完播停留**；低价值 ⇒ **直接划走**；直播间 ⇒ **立即划走**。
    private func runFeed() -> Bool {
        let minutes = featMinutes("feed", dflt: 12)
        let stayHV = s?.feed_stay_hv ?? 22          // PC `STAY_HV`
        let stayLV = s?.feed_stay_lv ?? 3           // PC `STAY_LV`
        let gapMin = s?.feed_gap_min ?? 1.0
        let gapMax = s?.feed_gap_max ?? 2.0
        log("§feed 目标 \(String(format: "%.1f", minutes)) 分钟 ｜ 高价值停留 \(Int(stayHV))s / 低价值划走")
        log("§feed ⛔ 不做点赞/评论/关注（§1505 口径）")

        // ⭐ 进信息流（PC `goto_feed`；进不去 ⇒ 停手，⛔ 不放枪）
        guard gotoFeed(tag: "feed_in") else {
            log("§feed ⛔ 进不了信息流 ⇒ 停手")
            return false
        }

        let end = Date().addingTimeInterval(minutes * 60)
        var n = 0, hits = 0
        while Date() < end {
            if isCancelled { log("§feed ⛔ 被中断"); break }
            guard let img = grab() else { log("§feed ⛔ 抓帧失败"); break }
            n += 1
            beat(["phase": "feed-step", "n": n, "hits": hits,
                  "left_s": Int(end.timeIntervalSinceNow)])

            // ⭐ ① 先关评论区（PC L5131：否则滑动无效、文案读错区）
            if nav.detect("comment_panel", img: img) != nil {
                log("§feed 先关评论区")
                _ = nav.tap("comment_close", img: img)
                sleep(0.8)
            }

            guard let img2 = grab() else { break }

            // ⭐ ② 直播间 ⇒ **立即划走**（PC L5138；⛔ 必须在关评论区**之后**判）
            if nav.detect("live_marker", img: img2) != nil {
                log("§feed 第\(n)条 **直播间** ⇒ 立即划走（0 停留 / 0 互动）")
                swipeUp(gapMin, gapMax)
                continue
            }

            // ⭐ ③ 高价值 ⇒ 完播停留；低价值 ⇒ 直接划走（§1733 用户令）
            let hv = nav.detect("hv_marker", img: img2) != nil
            if hv {
                hits += 1
                log("§feed 第\(n)条 **高价值** ⇒ 完播停留 \(Int(stayHV))s（命中 \(hits)）")
                sleepWithCancel(stayHV)
            } else {
                log("§feed 第\(n)条 低价值 ⇒ 直接划走")
                sleepWithCancel(stayLV)
            }
            swipeUp(gapMin, gapMax)
        }
        log("§feed 刷了 \(n) 条（高价值命中 \(hits)）")
        return n > 0
    }

    // MARK: - ③ tag 搜索打标签（照 PC `run_tag` L6842）

    /// ⭐ 开搜索页 → 取词 → **落中文** → 搜索 → 浏览结果 → 换词。
    private func runTag() -> Bool {
        let minutes = featMinutes("tag", dflt: 5)
        let roundMin = (s?.tag_round_min ?? 0) > 0
            ? (s?.tag_round_min ?? 0) : max(1.0, minutes / 3.0)
        let words = s?.tag_words ?? []
        log("§tag 目标 \(String(format: "%.1f", minutes)) 分钟 ｜ 每轮预算 \(String(format: "%.1f", roundMin)) 分钟 ｜ 词池 \(words.count) 词")
        log("§tag ⛔ 只搜 APP下载/游戏下载；⛔ 不点 CTA、不碰危险词")

        // ⭐ 入口：**先问搜索页（可重入，1 次抓帧零动作）**，不成才走 feed 重链
        //    （PC §1737c 血案：先走 goto_feed ⇒ 4 轮全废）
        if !openSearch(tag: "tag_open") {
            log("§tag ⚠️ 直接开搜索没成 ⇒ 先回 feed 首页再试")
            if ensureEntryState(want: "feed", tag: "tag_ent") {
                _ = openSearch(tag: "tag_open2")
            }
        }
        guard let first = grab() else { log("§tag ⛔ 抓帧失败"); return false }
        if nav.detect("search_page", img: first) == nil {
            log("§tag ⛔ 打不开搜索页 ⇒ 停手")
            return false
        }

        let end = Date().addingTimeInterval(minutes * 60)
        var rounds = 0, used: [String] = []
        while Date() < end {
            if isCancelled { log("§tag ⛔ 被中断"); break }
            // ⛔ 不连着搜同一个词（PC 看最近 6 个）
            guard let word = pickWord(words, used: used, recent: 6) else {
                log("§tag 词池用尽 ⇒ 结束")
                break
            }
            used.append(word)
            rounds += 1
            beat(["phase": "tag-round", "round": rounds, "word": word,
                  "used": used.count])
            log("§tag ── 第 \(rounds) 轮：搜「\(word)」")

            let roundEnd = min(end, Date().addingTimeInterval(roundMin * 60))
            if !searchOneWord(word, tag: "tag\(rounds)") {
                log("§tag ⚠️ 第 \(rounds) 轮搜索没成 ⇒ 换词继续")
                continue
            }
            browseResults(until: roundEnd, tag: "tag\(rounds)")
        }
        // ⭐ 到时 ⇒ 退回 feed 首页（PC：各腿靠「回首页」接力）
        _ = gotoFeed(tag: "tag_out")
        log("§tag 跑了 \(rounds) 轮，用过 \(used.count) 个词")
        return rounds > 0
    }

    // MARK: - ④ search 商城逛小店（照 PC `run_mall` L7609）

    /// ⭐ 进小店 → 搜高价值商品词 → **只点 ≥ 门槛价**的商品 → 拟人停留。
    private func runMall() -> Bool {
        let minutes = featMinutes("search", dflt: 5)
        let roundMin = (s?.mall_round_min ?? 0) > 0
            ? (s?.mall_round_min ?? 0) : max(1.0, minutes / 3.0)
        let browseMin = s?.mall_browse_min ?? 0.4
        let minPrice = s?.mall_min_price ?? 500
        let words = s?.mall_words ?? []
        log("§mall 目标 \(String(format: "%.1f", minutes)) 分钟 ｜ 每轮 \(String(format: "%.1f", roundMin)) 分钟 ｜ 门槛 ¥\(Int(minPrice)) ｜ 词池 \(words.count)")
        log("§mall ⛔ 不点购买键、不点赞/评论/关注")

        // ⭐ 先进「已知入口态」（PC L7628 血案：否则 enter_mall 会瞎退 6 跳）
        if !ensureEntryState(want: "feed", tag: "mall_ent") {
            log("§mall ⚠️ 没到 feed 首页 ⇒ 仍试一次进小店（它可重入）")
        }
        guard enterMall(tag: "mall_in") else {
            log("§mall ⛔ 进不了小店首页 ⇒ 停手")
            return false
        }

        let end = Date().addingTimeInterval(minutes * 60)
        var rounds = 0, used: [String] = []
        while Date() < end {
            if isCancelled { log("§mall ⛔ 被中断"); break }
            // ⭐ 浏览要留**时间下限**（PC L7664：进商城→打字→落中文→搜索本身 ~0.7 分钟）
            let leftMin = end.timeIntervalSinceNow / 60.0
            if leftMin < browseMin {
                log("§mall ⏱ 剩 \(String(format: "%.1f", leftMin)) 分钟 < 浏览下限 \(String(format: "%.1f", browseMin)) ⇒ 不再开新轮")
                break
            }
            guard let word = pickWord(words, used: used, recent: 6) else {
                log("§mall 词池用尽 ⇒ 结束")
                break
            }
            used.append(word)
            rounds += 1
            beat(["phase": "mall-round", "round": rounds, "word": word])
            log("§mall ── 第 \(rounds) 轮：搜「\(word)」")

            let roundEnd = min(end, Date().addingTimeInterval(roundMin * 60))
            if !searchOneWord(word, tag: "mall\(rounds)") {
                log("§mall ⚠️ 第 \(rounds) 轮搜索没成 ⇒ 换词继续")
                continue
            }
            // ⭐ 结果页**只点 ≥ 门槛价**的商品
            browseResults(until: roundEnd, tag: "mall\(rounds)", minPrice: minPrice)
        }
        _ = gotoFeed(tag: "mall_out")
        log("§mall 跑了 \(rounds) 轮，用过 \(used.count) 个词")
        return rounds > 0
    }

    // MARK: - ⭐⭐ 共用腿（导航/搜索/浏览/滑动）

    /// ⭐ 回任务中心（= PC `ensure_in_center`）
    private func ensureInCenter(tag: String) -> Bool {
        guard let cfg = cfgStore.cfg else { return false }
        for k in 0..<8 {
            if isCancelled { return false }
            guard let img = grab() else { return false }
            let here = nav.pageHere(img) ?? "unknown"
            if here == (cfg.settings?.target ?? "center") {
                log("   §\(tag) ✅ 已在任务中心（第 \(k + 1) 步）")
                return true
            }
            // ⛔ 广告页放行（用户令）—— 但**交接点**上「广告页」不等于「回中心」
            if here == "ad_video" {
                log("   §\(tag) ⛔ 停在广告页 ⇒ 等它结束（⛔ 不点 ✕）")
                dwellOnAd(s?.ad_stay_min ?? 40)
                continue
            }
            if nav.runFunnel(img) { sleep(1.0); continue }
            if let p = cfg.pages[here], let go = p.go, go != "stop",
               nav.tap(go, img: img) {
                sleep(1.5)
                continue
            }
            log("   §\(tag) ⚠️ 在 \(here) 找不到回中心的路（第 \(k + 1) 步）")
            sleep(1.0)
        }
        return false
    }

    /// ⭐ 送到某个已知入口态（= PC `_ensure_entry_state(want:)`）
    private func ensureEntryState(want: String, tag: String) -> Bool {
        for k in 0..<3 {
            if isCancelled { return false }
            guard let img = grab() else { return false }
            let here = nav.pageHere(img) ?? "unknown"
            if here == want {
                log("   §\(tag) ✅ 已在 \(want)（第 \(k + 1) 次）")
                return true
            }
            if nav.runFunnel(img) { sleep(1.0); continue }
            _ = ensureInCenter(tag: "\(tag)_via_center")
            sleep(0.8)
        }
        return false
    }

    /// ⭐ 进信息流（= PC `goto_feed`）
    private func gotoFeed(tag: String) -> Bool {
        guard let cfg = cfgStore.cfg else { return false }
        for _ in 0..<3 {
            if isCancelled { return false }
            guard let img = grab() else { return false }
            if nav.pageHere(img) == "feed" { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            guard let p = cfg.pages["feed"], let go = p.go else { return false }
            if nav.tap(go, img: img) { sleep(1.8); continue }
            return false
        }
        return nav.pageHere(grab() ?? UIImage()) == "feed"
    }

    /// ⭐ 打开搜索页（**可重入**：已在搜索/结果页 ⇒ 直接算成功）
    private func openSearch(tag: String) -> Bool {
        for _ in 0..<3 {
            if isCancelled { return false }
            guard let img = grab() else { return false }
            if nav.detect("search_page", img: img) != nil { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            if nav.tap("search_entry", img: img) { sleep(1.8); continue }
            return false
        }
        return false
    }

    /// ⭐ 进小店首页（可重入）
    private func enterMall(tag: String) -> Bool {
        for _ in 0..<4 {
            if isCancelled { return false }
            guard let img = grab() else { return false }
            if nav.pageHere(img) == "mall"
                || nav.detect("mall_entry", img: img) != nil { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            if nav.tap("mall_entry", img: img) { sleep(1.8); continue }
            _ = ensureInCenter(tag: "\(tag)_center")
            sleep(0.8)
        }
        return false
    }

    /// ⭐⭐ 搜一个词：**点框 → 落中文（硬闸）→ 点搜索**
    ///
    /// ⚠️⚠️ **落中文硬闸**（PC §1743，⛔ 移植时最容易漏的一条）：
    ///   `BLE` 的 `T:` 只能发 **ASCII** ⇒ 中文得靠**拼音 + 点 IME 候选词**。
    ///   ⛔ **绝不能**在框里还是生拼音时就提交（用户令：「打字一定要做到中文，拼音绝对不行」）
    ///   ⇒ 打完拼音后**必须**看一眼框里是否真出现中文（OCR 验证）才点搜索。
    private func searchOneWord(_ word: String, tag: String) -> Bool {
        guard let img = grab() else { return false }

        // ① 点搜索框
        guard let box = nav.detect("search_box", img: img) else {
            log("   §\(tag) ⛔ 找不到搜索框")
            return false
        }
        tapBase(Double(box.center.x), Double(box.center.y))
        sleep(1.2)

        // ② 清框（PC：清框走模板找清除 ✕）
        if let i2 = grab(), nav.detect("search_clear", img: i2) != nil {
            _ = nav.tap("search_clear", img: i2)
            sleep(0.8)
        }

        // ③ ⭐ 落中文：拼音 + 点 IME 候选（⛔ 硬闸）
        guard typeChinese(word, tag: tag) else {
            log("   §\(tag) ⛔ 落中文失败 ⇒ ⛔ 不提交（避免留下生拼音）")
            return false
        }

        // ④ 点「搜索」
        guard let i3 = grab() else { return false }
        if nav.detect("search_btn", img: i3) != nil {
            _ = nav.tap("search_btn", img: i3)
        } else {
            keyTap("ENTER")          // 兜底：回车
        }
        sleep(2.0)
        return true
    }

    /// ⭐⭐ **落中文硬闸**：打拼音 → 点 IME 候选 → **OCR 验证框里真是中文**
    ///
    /// ## 为什么必须验证（PC §1743 血案）
    /// 用户令：「**打字一定要做到中文，拼音绝对不行**」
    /// 后来的解法（用户确认）：「拼音问题已经解决了 **不完全打字选下面的文字推荐**」
    /// ⇒ 打法：HID 发**拼音**（ASCII 可发）→ 键盘上方出现候选 → 点第一个候选。
    ///
    /// ⚠️ 但**候选不一定出现**（词太生僻/输入法状态不对）⇒
    ///   打完若框里还是**拼音字母**，这次**必须放弃**，⛔ 不能提交。
    private func typeChinese(_ word: String, tag: String) -> Bool {
        guard let pinyin = PinyinMap.toPinyin(word) else {
            log("   §\(tag) ⚠️ 「\(word)」转不出拼音 ⇒ 跳过这个词")
            return false
        }
        // 发拼音（ASCII 可发）
        ble.send("T:\(pinyin)")
        sleep(1.2)
        // 点第一个 IME 候选（键盘候选条第一格）
        if let img = grab(), let cand = nav.detect("ime_candidate1", img: img) {
            tapBase(Double(cand.center.x), Double(cand.center.y))
            sleep(1.0)
        } else {
            log("   §\(tag) ⚠️ 没看到 IME 候选条")
        }
        // ⭐ 硬闸：OCR 验证框里**真的是中文**
        guard let i2 = grab() else { return false }
        let r = nav.roi([0, 0, Double(baseW), Double(baseH) * 0.5])
        let found = rec.findWords(i2, words: [word], roi: r,
                                  minHits: 1,
                                  minConfidence: s?.ocr_min_confidence ?? 0.5)
        if found != nil {
            log("   §\(tag) ✅ 落中文成功：「\(word)」")
            return true
        }
        log("   §\(tag) ⛔ 框里没出现「\(word)」⇒ 判定还是拼音 ⇒ **不提交**")
        return false
    }

    /// ⭐ 浏览结果页（点卡片、完播/短停、退回）
    private func browseResults(until end: Date, tag: String, minPrice: Double? = nil) {
        var n = 0
        while Date() < end {
            if isCancelled { return }
            guard let img = grab() else { return }
            // 商品卡（有价格门槛时用 mall_item）
            let key = (minPrice != nil) ? "mall_item" : "result_card"
            guard let hit = nav.detect(key, img: img) else {
                log("   §\(tag) 没有更多卡片 ⇒ 结束浏览")
                return
            }
            n += 1
            tapBase(Double(hit.center.x), Double(hit.center.y))
            sleep(2.0)
            // 详情页**拟人停留**（完播/短停）
            sleepWithCancel(min(12.0, max(3.0, end.timeIntervalSinceNow * 0.2)))
            // 退回结果页
            if let i2 = grab() {
                if nav.detect("back_arrow", img: i2) != nil {
                    _ = nav.tap("back_arrow", img: i2)
                } else {
                    keyTap("ESC")
                }
            }
            sleep(1.2)
        }
        log("   §\(tag) 浏览了 \(n) 个卡片")
    }

    /// ⭐ 挑词：⛔ 不连着搜同一个词（PC 看最近 6 个）
    private func pickWord(_ pool: [String], used: [String], recent: Int) -> String? {
        let tail = Set(used.suffix(recent))
        let avail = pool.filter { !tail.contains($0) }
        if let w = avail.randomElement() { return w }
        return pool.first { !used.contains($0) }        // 都用过 ⇒ 放宽，只排最近
    }

    private func featMinutes(_ key: String, dflt: Double) -> Double {
        if let m = s?.feat_min?[key], m > 0 { return m }
        return dflt
    }

    // MARK: - 底层动作（全部走 ESP32 HID，坐标是**基准 451×977**）

    private func tapBase(_ x: Double, _ y: Double) {
        let cmds = BLEController.moveAndClick(x: x, y: y,
                                              baseW: baseW, baseH: baseH, yFix: yFix)
        for c in cmds { ble.send(c) }
        sleep(0.25)
        ble.send("C:L")
    }

    private func swipeUp(_ gapMin: Double, _ gapMax: Double) {
        let midX = baseW / 2.0
        let yBot = baseH * (s?.swipe_y_bot_pct ?? 0.70)
        let yTop = baseH * (s?.swipe_y_top_pct ?? 0.30)
        let speed: BLEController.SwipeSpeed =
            (s?.swipe_video_speed == "slow") ? .slow
            : (s?.swipe_video_speed == "mid") ? .mid : .fast
        let cmd = BLEController.swipe(x1: midX, y1: yBot, x2: midX, y2: yTop,
                                      speed: speed, baseW: baseW, baseH: baseH, yFix: yFix)
        ble.send(cmd)
        let g = Double.random(in: gapMin...max(gapMin, gapMax))
        sleepWithCancel(g)
    }

    private func keyTap(_ k: String) { ble.send("K:\(k)") }

    /// ⭐ 可中断的等待（⛔ 不用 `Thread.sleep` 裸睡，否则「停止」要等很久才生效）
    private func sleep(_ s: Double) { sleepWithCancel(s) }

    private func sleepWithCancel(_ seconds: Double) {
        var left = seconds
        while left > 0 && !isCancelled {
            let d = min(0.2, left)
            Thread.sleep(forTimeInterval: d)
            left -= d
        }
    }
}
