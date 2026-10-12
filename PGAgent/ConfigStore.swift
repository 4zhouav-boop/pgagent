import Foundation
import UIKit

/// ⭐⭐⭐ 运行时配置 —— **从 Documents 读**，⛔ 不需要重编/重签/重装。
///
/// 设计（`_note_1793` 方案 B+ / `_note_1816` §4）：
///   把「会变的东西」（判据、页面图、漏斗、阈值）放**文件**里，
///   执行器（这个 App）只负责**读配置 + 执行** ⇒ 改逻辑只推文件。
///
/// 文件位置：`Documents/pgconfig/config.json`（+ `Documents/pgconfig/templates/*.png`）
final class ConfigStore: ObservableObject {

    @Published private(set) var cfg: PGConfig?
    @Published private(set) var loadedAt: Date?
    @Published private(set) var lastError = ""

    static func configDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pgconfig", isDirectory: true)
    }

    static func configPath() -> URL {
        configDir().appendingPathComponent("config.json")
    }

    static func templatesDir() -> URL {
        configDir().appendingPathComponent("templates", isDirectory: true)
    }

    /// 确保目录存在
    static func ensureDirs() {
        let fm = FileManager.default
        for d in [configDir(), templatesDir()] {
            if !fm.fileExists(atPath: d.path) {
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
        }
    }

    /// 读配置（⛔ 失败不抛，只记 lastError）
    @discardableResult
    func reload() -> Bool {
        Self.ensureDirs()
        let p = Self.configPath()
        guard FileManager.default.fileExists(atPath: p.path) else {
            lastError = "配置不存在: \(p.path)"
            return false
        }
        do {
            let data = try Data(contentsOf: p)
            let c = try JSONDecoder().decode(PGConfig.self, from: data)
            cfg = c
            loadedAt = Date()
            lastError = ""
            return true
        } catch {
            lastError = "解析失败: \(error)"
            return false
        }
    }

    // MARK: - ⭐⭐⭐⭐⭐ §2269 保存（控制台改设置用）

    /// ⭐ **在手机上直接改设置并落盘**（照 PC 控制台的语义：勾功能 + 设时间）
    ///
    /// ## 为什么必须"改原 JSON 对象"而不是"重新编码整个 PGConfig"
    /// `PGConfig` 是 `Codable`，但它**只声明了程序要用到的字段**；
    /// 而 `config.json` 里有大量**注释键**（`_doc` / `_go_doc` / `_alts_doc` / `_feat_doc` …）
    /// 和未来可能新增的字段。
    /// ⛔ 若"解码成结构体 → 改 → 整体重编码"，**所有注释和未知字段都会被抹掉**
    ///   ⇒ 配置里辛苦写的取证记录**全丢**。
    /// ✅ 做法：**读原始 JSON 字典 → 只改 `settings` 下那几个键 → 写回**
    ///   ⇒ 其余内容**逐字保持**（包括注释键）。
    ///
    /// - Parameter patch: 要写入 `settings` 的键值对（值用 `Any`，nil = 删除该键）
    /// - Returns: (是否成功, 说明)
    @discardableResult
    func saveSettings(_ patch: [String: Any?]) -> (ok: Bool, msg: String) {
        Self.ensureDirs()
        let p = Self.configPath()
        do {
            let data = try Data(contentsOf: p)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "根不是对象")
            }
            var s = (root["settings"] as? [String: Any]) ?? [:]
            for (k, v) in patch {
                if let v = v { s[k] = v } else { s.removeValue(forKey: k) }
            }
            root["settings"] = s
            // ⭐ `.prettyPrinted` + `.withoutEscapingSlashes`：与手写配置风格一致，且中文不被转义
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            try out.write(to: p, options: .atomic)
            // 写完立刻重载，让 Runner 马上用上新值
            _ = reload()
            return (true, "已保存")
        } catch {
            return (false, "保存失败: \(error)")
        }
    }
}

// MARK: - 配置数据模型（与 config.json 一一对应）

struct PGConfig: Codable {
    var version: Int?
    var settings: Settings?
    var rois: [String: [Double]]?
    var elements: [String: Element]
    var pages: [String: Page]
    var funnel: [FunnelItem]?
    var stuck: StuckCfg?

    struct Settings: Codable {
        var base_w: Double?
        var base_h: Double?
        var y_fix: Double?
        var ocr_min_confidence: Double?
        var template_threshold: Double?
        var max_steps: Int?

        // ⭐ 自主循环（Runner）—— 全部可在 config.json 里改，⛔ 不用重装
        /// 目标页（默认走到哪）
        var target: String?
        /// 循环最多走几步
        var loop_max_steps: Int?
        /// 每步之间的等待（秒）—— 等界面稳定
        var loop_step_wait: Double?
        /// 抓一帧的最长等待（秒）
        var loop_grab_timeout: Double?
        /// 画面连续 N 次不变就判卡死
        var loop_stall_limit: Int?
        /// ⭐⭐ 连续 N 帧「认不出」才停手（§2240）
        ///
        /// 用户原话：「认不出就不做了，**直接自杀** 你还推荐。**要眼睛干什么**」
        /// ⇒ `unknown` 多是**瞬时态**（转场/广告首尾/弹窗动画/首帧未渲染）
        /// ⇒ 容忍几帧再重抓，默认 6。
        var loop_unknown_limit: Int?

        /// ⭐⭐⭐⭐ **帧新鲜度上限（秒）** —— 超过就**不算"当前画面"**（§2263 照荔枝）
        ///
        /// ## 为什么必须有（真机血案 `_var/_cmp_side.png` 并排对照）
        /// 荔枝只认**新鲜**的帧（`_note_2010` L62 / `_note_2011` L253）：
        /// ```
        /// "⏳ 等待截图文件生成... (第10次检查)"
        /// "📝 截图文件存在但大小不足: 0 bytes，继续等待..."
        /// ```
        /// 而我原来 `grabSync()` **直接返回 `lastFrame`，从不问它多旧** ⇒
        /// 广播一停，那张**死帧**就被反复送去识别 ⇒ **永远 `unknown`**。
        ///
        /// 📏 并排对照（同一时刻取两张）：
        /// ```
        /// 左：iOS 真实截图  13:22 = 「所有快捷指令」+「直播已停止」弹窗
        /// 右：App 喂识别的帧 13:15 = PGAgent 自己的界面   ← ⛔ 7 分钟前的死帧
        /// ```
        /// ⇒ 判 `unknown` 是**对的**（画面确实不是快手）——
        ///   ⛔ 病根在"拿了死帧"，⛔ 不在识别。
        ///
        /// 扩展按 2fps 写帧 ⇒ 正常帧龄 **< 0.5s**；默认 **3.0s** 容忍抖动，
        /// 又能把"广播已死"和"广播在跑"干净分开。
        var loop_frame_max_age: Double?

        // ⭐⭐ 照 **荔枝RPA** 实测值（_note_2010/2011/2012）
        /// 广告页最短停留（秒）—— 荔枝 settingsAdTimeMin = 40
        var ad_stay_min: Double?
        /// 广告页最长停留（秒）—— 荔枝 settingsAdTimeMax = 60
        var ad_stay_max: Double?
        /// 转化关键词（`-` 分隔）—— 荔枝 settingsConversionKeyword
        var conversion_keyword: String?
        /// 转化时滑动次数 —— 荔枝 settingsConversionSwipe = 3
        var conversion_swipe: Int?
        /// 直播间停留（秒）—— 荔枝 settingsLiveStay = 66
        var live_stay: Double?
        /// OCR 等待超时（秒）—— 荔枝实测 10.1s
        var ocr_timeout_s: Double?
        /// OCR 最大尝试次数 —— 荔枝实测 99 次
        var ocr_max_tries: Int?
        /// 刷视频滑动档位：fast / mid / slow
        var swipe_video_speed: String?
        /// 滑动的上边界（比例 0..1）—— 荔枝避让区 766/2556 ≈ 0.30
        var swipe_y_top_pct: Double?
        /// 滑动的下边界（比例 0..1）—— 荔枝避让区 1789/2556 ≈ 0.70
        var swipe_y_bot_pct: Double?
        /// ⭐ OCR 找不到时的模板兜底阈值（替代荔枝的 YOLO）
        var fallback_template_threshold: Double?

        // ══════════════════════════════════════════════════════════════
        // ⭐⭐⭐⭐ §2240 **4 个功能模块的参数**（照 PC `_1377_ad_loop.py` 抄）
        //
        // PC 侧这些是环境变量（`AISJ_*`），手机上没有 env ⇒ 搬进 config.json。
        // 顺序契约（PC L9357 铁证）：["adbox","feed","tag","search"]
        // ══════════════════════════════════════════════════════════════

        /// ⭐ 本轮**要跑哪些功能**（⛔ 不填 = 只跑 adbox，与 PC 旧行为一致）
        ///    写入顺序**不重要** ⇒ 执行时一律按 `FeatureEngine.order` 排
        var features: [String]?

        /// ⭐ 要跑哪些 App：`ks` / `kslite`；
        ///    **两个都填 ⇒ 交替循环**（用户令：「跑完快手 4 个功能跑快手极速版 4 个功能再跑快手」）
        var apps: [String]?

        /// ⭐⭐⭐⭐⭐ §2282 **点「开始跑」时是否自动切到目标 App**（默认 true）
        ///
        /// ## 为什么必须有（用户令，逐字）
        /// > 「**我手动启动会打开录屏，然后点击启动后 他需要自动回桌面，然后自己进快手。**」
        /// > 「**脚本启动都不会自动回桌面 自动进快手。**」
        ///
        /// 手机端录屏录的是**当前前台**（不像 PC 抓投屏窗口恒等于手机屏）⇒
        /// 点「开始跑」时前台是 PGAgent 自己 ⇒ 录到控制台 ⇒ 全 `unknown`。
        /// ⇒ **必须由 App 自己**先回桌面、再点快手图标（全程 ESP32）。
        var auto_goto_app: Bool?

        /// ⭐⭐⭐⭐⭐ §2621 **进 App 后等开屏广告走完的秒数**（默认 8.0，用户口径）
        ///
        /// ## 用户令（逐字）
        /// > 「**的确前面进来有开屏广告 你设置一个等待8秒再执行找红包的逻辑。**」
        ///
        /// ## ⛔ 不等的后果（真机血案，本轮）
        /// 冷启动快手极速版**先出开屏广告**，此时红包悬浮球**还没画出来**
        /// ⇒ `find_coin_entry` 返回 None（trace：`§coin 没找到红包悬浮球`）
        /// ⇒ `feed.go = coin_ball` 被记死 ⇒ 退到 `feed.alts` 点「消息」
        /// ⇒ 开屏期间页面还在变 ⇒ 页型把消息页误判成 feed ⇒ **点消息死循环**。
        /// ⇒ 原来只等 2.5s 是**太早**（开屏广告通常 3~5s）。
        var splash_wait_s: Double?

        /// ⭐ 广告**条数**（PC 控制台「条数」）
        var ad_count: Int?

        /// ⭐ 入口：`auto` / `fuli`（福利页）/ `chest`（宝箱）
        var entry: String?

        /// ⭐ 尾部：`continue`（继续跑下一条）/ `center`（回任务中心）
        var tail: String?

        /// ⭐ 广告停留秒（PC 控制台「广告停留秒」，默认 30）
        var ad_dwell: Double?

        // ── feed（刷视频，PC `run_feed`）──────────────
        /// 高价值 ⇒ **完播停留**秒（PC `STAY_HV`）
        var feed_stay_hv: Double?
        /// 低价值/未命中 ⇒ **直接划走**（PC `STAY_LV`）
        var feed_stay_lv: Double?
        /// 滑动后的间隔下限/上限（PC `GAP_HV` / `GAP_LV`）
        var feed_gap_min: Double?
        var feed_gap_max: Double?

        // ── tag（搜索打标签，PC `run_tag`）─────────────
        /// ⭐ **每轮时间预算**（PC `TAG_ROUND_MIN`；0 = 总时长/3）
        ///    ⛔ 没有它 ⇒ 第 1 个词就把全部时间吃光（PC 真机踩过）
        var tag_round_min: Double?
        /// ⭐ 搜索词池（PC `DL_WORDS`：只搜 APP下载/游戏下载）
        var tag_words: [String]?

        // ── search（商城逛小店，PC `run_mall`）─────────
        /// ⭐ 每轮预算（PC `MALL_ROUND_MIN`）
        var mall_round_min: Double?
        /// ⭐ 浏览**时间下限**（PC `MALL_BROWSE_MIN`）
        ///    「进商城→打字→落中文→搜索」本身就要 ~0.7 分钟 ⇒ 不够就**不再开新轮**
        var mall_browse_min: Double?
        /// ⭐ **只点 ≥ 这个价**的商品（PC `MALL_MIN_PRICE` 默认 500）
        var mall_min_price: Double?
        /// 高价值**商品**词池（PC `HV_SHOP_WORDS`）
        var mall_words: [String]?

        /// ⭐ 各功能的**默认分钟数**（PC 控制台 `FEATURE_OPTS` 的第三列）
        var feat_min: [String: Double]?

        /// 转化关键词数组
        var conversionKeywords: [String] {
            guard let s = conversion_keyword, !s.isEmpty else { return [] }
            return s.split(separator: "-").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    struct Element: Codable {
        var desc: String?
        var roi: [Double]?
        var match: String?            // "template" | "ocr"
        var templates: [String]?
        var threshold: Double?
        var mask: String?             // "ink" | "none"
        var words: [String]?
        var min_hits: Int?
        var target_pos: String?
        /// ⭐⭐ §2304 **本元素自己的 OCR 置信度下限**（可选，不给则用 `settings.ocr_min_confidence`）。
        ///
        /// ## 为什么必须有它（真机血案）
        /// 直播间的唯一性锚点「说点什么」，
        /// **Vision 读出来了但只给 conf=0.3**（`/ocr` 真机回读：`y=909 x=74 conf=0.3 说点什么⋯`），
        /// 而全局阈值是 **0.5** ⇒ 这条**被过滤掉** ⇒ `live_marker` 恒 miss
        /// ⇒ 直播间判 `unknown` ⇒ 卡死（用户原话：“刚刚那不是直播间么 你识别成未知”）。
        ///
        /// ⛔ **不能靠调全局阈值解决**：那会让**所有** OCR 判据都变松
        /// （其他页型的误判风险都上升）。只有这一条锚点需要放宽。
        var min_conf: Double?
        /// ⭐ §2307 **否定词**：命中这些词就**不算**本元素命中。
        ///
        /// 用在「面包屑」上（与 PC `find_breadcrumb` 的弱否定闸逐字一致）：
        /// 快手 App 自己在状态栏画了个**水印**（OCR 读成 `快手极速版`），
        /// 它**几乎每一页都在** ⇒ 不加否定闸会在 80% 的页面上误击中（PC §1752 实测 16/20 帧）。
        var not_words: [String]?

        /// ⭐⭐⭐⭐⭐ §2621 **色彩判据元素**（`match: "color"` 时用）——目前只有 `coin_ball`。
        ///
        /// ## 为什么必须补这一种（用户令逐字）
        /// > 「**你移植一个一个移植吧。怎么总是卡死要自己制造方案。
        /// >   就调用PG控制器的方案就行了啊。**」
        ///
        /// PC 判 **feed 首页**用的是 `ks_is_feed_home`（`_1377_ad_loop.py:5655`）：
        /// ```python
        /// if feed_judge(img):                       # ⭐ 红包球（零 OCR）**优先**
        ///     return True
        /// return all(k in txt(img, KS_BAND_TOP) for k in KS_TOP_HOME)   # 或 顶栏 同城+商城
        /// ```
        /// 而 `feed_judge` = `find_coin_entry(img) is not None`（L4622）
        /// ⇒ **PC 判 feed ⛔ 从来不用底栏「首页」**。
        ///
        /// 我原来把 `coin_ball` 只写在**漏斗**里 ⇒ 页型判据里用不上它
        /// ⇒ `feed.check` 只能拿底栏「首页」凑合 ⇒ **消息页底栏也有「首页」**
        /// ⇒ 页型误判成 feed ⇒ 「点消息 → 还判 feed → 再点消息」死循环（§2621 血案）。
        var color: String?
    }

    struct Page: Codable {
        var desc: String?
        var check: [String]?
        var not: [String]?
        /// ⭐⭐ §2275 **并列判据**（任一命中即算本页型）—— 用于**抗 OCR 错字**
        ///
        /// 为什么需要（真机血案）：`ad_video` 原来只认 `ad_capsule`
        /// （词「可领取/已成功领取/金币」），而真机胶囊是 `已成功领取438金币 ×`
        /// ⇒ OCR 读不出 ⇒ 判 `unknown` ⇒ **「广告页放行」失效** ⇒ 空转到停手。
        /// PC 早记过同类错字（§1543：把「可领取」读成「善厨领取」）并给出对策：
        /// 「补一条**抗错字**的判据：顶栏同时含「广告」+「金币」」。
        /// ⇒ 这里用 `also_ok` 表达"**并列的、同样可信的**判据"。
        var also_ok: [String]?
        var parent: String?
        var go: String?
        /// ⭐⭐ **备用出路**（§2247 移植 PC `PAGES[...]["alts"]`）
        ///
        /// 为什么必须有（PC `_nav_to_center` 里写得很清楚）：
        /// > ⛔ 真机血案：`breadcrumb` 点了没变 ⇒ 记死 ⇒ 第 2 步**直接停手**，
        /// >   而页面**明明还认得出来**
        /// > 📏 Alas `ui_additional` 思路：**意外情况必须有多条 handler**
        ///
        /// ⇒ 主 `go` 点不动时，依次试 `alts`，⛔ 而不是整页放弃。
        var alts: [String]?
        var island: Bool?
    }

    struct FunnelItem: Codable {
        var element: String
        var interval: Double?
        var desc: String?
        /// ⭐⭐ **前置闸**（§2247）：必须**同时命中**这个元素，才允许点 `element`。
        ///
        /// ## 为什么需要它（PC 的两级设计）
        /// 系统弹窗的处理分两步（照抄 PC `dismiss_sys_prompt`）：
        /// ```
        /// ① **检测形态**：按钮行里同时出现「不允许」**和**「允许」
        ///    （= 系统级二选一弹窗；⛔ 不猜文案，因为 iOS 有跳转/定位/通知/相机多种弹窗）
        /// ② 命中后才去**定位消极项**（不允许/取消/拒绝/以后）并点它
        /// ```
        /// ⇒ 「点哪个」和「凭什么认为是弹窗」是**两件事** ⇒ 需要两个元素：
        ///    · `element`  = 要点的（`sys_prompt_deny`）
        ///    · `require`  = 前置闸（`sys_prompt_btns`）
        ///
        /// ⛔ 如果只用 `element`：普通页面出现「取消」二字就会误点 ⇒ **误伤**。
        var require: String?
    }

    struct StuckCfg: Codable {
        var same_n: Int?
        var same_window: Int?
        var alt_n: Int?
        var no_progress_s: Double?
    }
}
