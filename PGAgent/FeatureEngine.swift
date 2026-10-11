import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ 「大脑」—— **PG 控制台的手机版**（§2240 契约 / §2255 实现）。
///
/// ## 移植来源（⛔ 逐条照 PC 抄，⛔ 不臆造）
/// | 手机 | PC（`_dev/_1377_ad_loop.py`）|
/// |---|---|
/// | `FeatureEngine.order` | `FEAT_ORDER = ["adbox","feed","tag","search"]`（L9357 铁证）|
/// | `runAdbox` | 主 while 循环（L9410+）|
/// | `runFeed` | `run_feed()`（L5078）|
/// | `runTag` | `run_tag()`（L6842）|
/// | `runMall` | `run_mall()`（L7609）|
///
/// ## 一轮闭环的顺序（⭐ 硬契约，⛔ 不许改）
/// ```
/// 看广告得金币+宝箱  →  刷视频  →  搜索打标签  →  商城逛小店
///                                          ↑ 最后一棒，跑完回任务中心 = 一轮闭环
/// ```
///
/// ## ⛔ 两条铁律（用户令）
/// 1. **广告页放行**：「谁让你强退的，都是跑循环广告，你他妈一个广告就点X」
///    ⇒ 广告页**待够时间**，⛔ 绝不点 ✕。
/// 2. **打字必须落中文**：「打字一定要做到中文，**拼音绝对不行**」
///    ⇒ ⛔ 绝不提交生拼音（PC §1743 实测：生拼音 ⇒ 空页）。
final class FeatureEngine {

    /// ⭐⭐⭐ **权威执行顺序**（照抄 PC `FEAT_ORDER`，L9357）
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
    private let isCancelled: () -> Bool
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

    /// ⚠️ `Settings` 嵌在 `PGConfig` 里（⛔ 不是 `ConfigStore.Settings`）—— 我上一版栽在这
    private var s: PGConfig.Settings? { cfgStore.cfg?.settings }
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
    @discardableResult
    func runRound() -> [String: Any] {
        var feats = s?.features?.filter { Self.order.contains($0) } ?? []
        if feats.isEmpty { feats = ["adbox"] }          // ⭐ 旧行为：只跑广告

        // ⭐ 按**权威顺序**排（⛔ 不按用户填写顺序）
        let planned = Self.order.filter { feats.contains($0) }
        log("§feat ═══ 本轮功能：\(planned.map(Self.cn).joined(separator: " → ")) ═══")
        beat(["phase": "round-start", "planned": planned])

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
                log("§feat ⚠️【\(Self.cn(k))】没跑成 ⇒ 仍继续下一棒（⛔ 不整轮放弃）")
            }
        }

        log("§feat ═══ 本轮结束：完成 \(done.count)/\(planned.count) ═══")
        beat(["phase": "round-done", "done": done, "planned": planned])
        return ["planned": planned, "done": done]
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
        var emptyRounds = 0
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

            // ② 找「广告任务」那一行的按钮并点它（PC `find_ad_row_button`）
            if nav.detect("ad_task_btn", img: img) != nil {
                if nav.tap("ad_task_btn", img: img) {
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
            // ⭐ 防死循环：连续 3 轮都找不到 ⇒ 收（照 PC `stuck` 语义）
            emptyRounds += 1
            if emptyRounds >= 3 {
                log("§adbox ⛔ 连续 \(emptyRounds) 轮找不到广告任务 ⇒ 收手")
                break
            }
            n += 1
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
        var opened = openSearch(tag: "tag_open")
        if !opened {
            log("§tag ⚠️ 直接开搜索没成 ⇒ 先回 feed 首页再试")
            if ensureEntryState(want: "feed", tag: "tag_ent") {
                opened = openSearch(tag: "tag_open2")
            }
        }
        guard opened else {
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
            beat(["phase": "tag-round", "round": rounds, "word": word])
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
            _ = minPrice
            browseResults(until: roundEnd, tag: "mall\(rounds)")
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
            let r = nav.step(from: here, img: img) { [weak self] in self?.grab() }
            if r.acted { sleep(1.0); continue }
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
        for _ in 0..<3 {
            if isCancelled { return false }
            guard let img = grab() else { return false }
            if nav.pageHere(img) == "feed" { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            let here = nav.pageHere(img) ?? "unknown"
            let r = nav.step(from: here, img: img) { [weak self] in self?.grab() }
            if !r.acted { return false }
            sleep(1.2)
        }
        return false
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
    /// ## ⛔⛔ 落中文硬闸（用户令 + PC §1743，⛔ 这是最容易漏的一条）
    /// > 用户令：「**打字一定要做到中文，拼音绝对不行**」
    ///
    /// 电脑端血案原文（`_1377_ad_loop.py` L6241）：
    /// > ⛔ 旧实现有「候选栏没命中 ⇒ 点搜索键（快手后端解析拼音）」的兜底腿。
    /// >   真机实测拿**生拼音** `bingxiang` 去搜，小店直接返回「**无相关商品**」空页
    /// >   ⇒ 整轮白跑。**这条腿已删除。**
    ///
    /// ⇒ 纪律：**框内必须真的出现目标中文词，才允许提交**。
    ///   三条腿全不成 ⇒ **一个字都不提交**，返回 false 让调用方换词。
    private func searchOneWord(_ word: String, tag: String) -> Bool {
        guard let img = grab() else { return false }

        // ① 点搜索框
        guard let box = nav.detect("search_box", img: img) else {
            log("   §\(tag) ⛔ 找不到搜索框")
            return false
        }
        nav.tapPoint(Double(box.center.x), Double(box.center.y))
        sleep(1.2)

        // ② 清框（PC：清框只能点**框内清除 ✕** —— 退格/⌘A 实测不吃）
        if let i2 = grab(), nav.detect("search_clear", img: i2) != nil {
            _ = nav.tap("search_clear", img: i2)
            sleep(0.8)
        }

        // ③ ⭐ 打拼音
        guard let py = Pinyin.of(word) else {
            log("   §\(tag) ⚠️ 「\(word)」转不出拼音 ⇒ 跳过这个词")
            return false
        }
        log("   §\(tag) HID 打字 T:\(py)（\(word)）")
        ble.send("T:\(py)")
        sleep(1.2)

        // ④ ⭐⭐ **落中文硬闸**：框内必须真出现中文
        guard landChinese(word, tag: tag) else {
            log("   §\(tag) ⛔ 没落成中文 ⇒ **不提交**（避免留下生拼音）")
            return false
        }

        // ⑤ 点「搜索」
        guard let i3 = grab() else { return false }
        if nav.detect("search_btn", img: i3) != nil {
            _ = nav.tap("search_btn", img: i3)
        } else {
            ble.send("K:RETURN")          // 兜底：回车
        }
        sleep(2.0)
        return true
    }

    /// ⭐⭐ **落中文**（照 PC §1743 的腿序）
    ///
    /// ## PC 的两条腿（`_1377_ad_loop.py` L6251）
    /// ```
    /// ① 快手**联想词**里与目标词**完全一致**的那一行（§1737k 真机正解）
    /// ② iOS **IME 候选栏**按编号选字（§1737b 真机验过 `T:1` ⇒ 框内变中文）
    /// ```
    /// ⚠️ **编号只能从字面 OCR 读，⛔ 不能"按位置序号推"**（PC L5727）：
    /// > 2 号是 emoji 候选，OCR 会跳过，按位置推会把 3 号当成 2 号 ⇒ **选中错的字**
    private func landChinese(_ word: String, tag: String) -> Bool {
        // 先看是不是**已经**落好了（有的输入法直接上屏）
        if let im = grab(), boxHas(im, word: word) {
            log("   §\(tag) ✅ 打字后框内已是中文「\(word)」")
            return true
        }

        // ⭐ 腿①：IME 候选栏里**完全一致**的那一项（按**字面编号**选）
        if let im = grab() {
            let cands = imeCandidates(im)
            if !cands.isEmpty {
                log("   §\(tag) IME 候选 \(cands.count) 项："
                    + cands.map { "\($0.0)\($0.1)" }.joined(separator: " "))
                if let hit = cands.first(where: { $0.1 == word }) {
                    log("   §\(tag) ⇒ 选候选 \(hit.0)（\(hit.1)）")
                    ble.send("T:\(hit.0)")
                    sleep(1.2)
                    if let im2 = grab(), boxHas(im2, word: word) {
                        log("   §\(tag) ✅ 落中文成功（候选 \(hit.0)）")
                        return true
                    }
                } else {
                    log("   §\(tag) ⚠️ 候选里没有与「\(word)」**完全一致**的项 ⇒ 不按数字键")
                }
            } else {
                log("   §\(tag) ⚠️ 没看到 IME 候选栏")
            }
        }
        return false
    }

    /// ⭐ 读 iOS **IME 候选栏** ⇒ `[(编号, 词, 框)]`（编号从**字面**读，照 PC `ks_ime_candidates`）
    ///
    /// PC 实测：iOS 候选栏在 `y≈98~144`（基准尺度），每项形如 `1汽车`
    private func imeCandidates(_ img: UIImage) -> [(Int, String, CGRect)] {
        let roi = CGRect(x: 0, y: 98, width: baseW, height: 46)
        var out: [(Int, String, CGRect)] = []
        for (t, r, _c) in rec.ocrRegion(img, rect: roi, minConfidence: 0.3) {
            // 形如「1汽车」/「3 汽车站」⇒ 抠出编号和词
            let s = t.trimmingCharacters(in: .whitespaces)
            guard let first = s.first, let n = Int(String(first)), n >= 1, n <= 9 else { continue }
            let rest = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            out.append((n, rest, r))
        }
        return out
    }

    /// ⭐ 框内是否已含**目标词**（照 PC `_box_ok` 的「包含」判据）
    ///
    /// ⚠️ PC 为什么用「包含」而不是全等（L6253）：
    /// > 真机框内文本会把左侧放大镜 OCR 成 `Q`（`Q冰箱@(95,79)`）⇒ 全等会**误判失败**
    private func boxHas(_ img: UIImage, word: String) -> Bool {
        let roi = CGRect(x: 0, y: 55, width: baseW, height: 60)   // 搜索框那一带
        let items = rec.ocrRegion(img, rect: roi, minConfidence: 0.3)
        for (t, _r, _c) in items where t.contains(word) { return true }
        return false
    }

    /// ⭐ 浏览结果页（点卡片、完播/短停、退回）
    private func browseResults(until end: Date, tag: String) {
        var n = 0
        while Date() < end {
            if isCancelled { return }
            guard let img = grab() else { return }
            guard let hit = nav.detect("result_card", img: img) else {
                log("   §\(tag) 没有更多卡片 ⇒ 结束浏览")
                return
            }
            n += 1
            nav.tapPoint(Double(hit.center.x), Double(hit.center.y))
            sleep(2.0)
            // 详情页**拟人停留**（完播/短停）
            sleepWithCancel(min(12.0, max(3.0, end.timeIntervalSinceNow * 0.2)))
            // 退回结果页
            nav.backEdge()
            sleep(1.2)
        }
        log("   §\(tag) 浏览了 \(n) 个卡片")
    }

    /// ⭐ 挑词：⛔ 不连着搜同一个词（PC 看最近 6 个）
    ///
    /// ⚠️ 还带**能转拼音**过滤（照 PC `covers`）：转不出的词选了也白费一轮。
    private func pickWord(_ pool: [String], used: [String], recent: Int) -> String? {
        let usable = pool.filter { Pinyin.covers($0) }
        if usable.isEmpty { return nil }
        let tail = Set(used.suffix(recent))
        let avail = usable.filter { !tail.contains($0) }
        if let w = avail.randomElement() { return w }
        return usable.first { !used.contains($0) }      // 都用过 ⇒ 放宽，只排最近
    }

    private func featMinutes(_ key: String, dflt: Double) -> Double {
        if let m = s?.feat_min?[key], m > 0 { return m }
        return dflt
    }

    // MARK: - 底层动作（全部走 ESP32 HID，坐标是**基准 451×977**）

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
        let a = min(gapMin, gapMax), b = max(gapMin, gapMax)
        let g = b > a ? Double.random(in: a...b) : a
        sleepWithCancel(g)
    }

    /// ⭐ 可中断的等待（⛔ 不用裸 `Thread.sleep`，否则「停止」要等很久才生效）
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
