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
    }

    struct Page: Codable {
        var desc: String?
        var check: [String]?
        var not: [String]?
        var parent: String?
        var go: String?
        var island: Bool?
    }

    struct FunnelItem: Codable {
        var element: String
        var interval: Double?
        var desc: String?
    }

    struct StuckCfg: Codable {
        var same_n: Int?
        var same_window: Int?
        var alt_n: Int?
        var no_progress_s: Double?
    }
}
