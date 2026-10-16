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

    /// ⭐⭐⭐⭐⭐ §2645 **上一次 `reload()` 的配置自检结果**（空 = 通过）
    ///
    /// 由 `POST /reload` 的响应字段 `configErrors` 返回（**加字段是零破坏性的**）。
    /// ⛔ 语义：这里报的是**刚推上来的那个文件**的问题，⛔ 不是"当前生效配置"的问题——
    ///   自检不过时 `cfg` **保持上一份有效配置不动**，所以拿 `cfg` 反查会看不到错误。
    @Published private(set) var lastConfigErrors: [String] = []

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
    ///
    /// ⭐⭐⭐⭐⭐ §2645 **自检不过 ⇒ 拒绝加载**（`validate()`）。
    ///
    /// ## 为什么必须"拒绝"而不是"警告后照用"（真机红线）
    /// 配置化之后，`forbid_keys`（禁点词 = **支付红线**）也在文件里了。
    /// 若只是打个警告就用新表 ⇒ **一个手滑就能把"确认支付"从黑名单里删掉**
    /// ⇒ App 会去帮用户点支付（PC §1449 那个血案的原样重演）。
    /// ⇒ 判据是**加法校验**：配置只能**加**禁点词，⛔ 不能减（见 `validate()`）。
    /// ⛔ 因此这里**不覆盖 `cfg`** —— 保留**上一份已验证过**的配置继续跑。
    ///
    /// 📏 自检范式照 `Runner.swift` 的「帧龄自检」（§2631 已证明有效）：
    ///   把"配错会出人命/会全盘失效"的项在**加载点**拦下来，并**说清改哪里**。
    @discardableResult
    func reload() -> Bool {
        Self.ensureDirs()
        let p = Self.configPath()
        guard FileManager.default.fileExists(atPath: p.path) else {
            lastError = "配置不存在: \(p.path)"
            lastConfigErrors = ["配置不存在: \(p.path)"]
            return false
        }
        do {
            let data = try Data(contentsOf: p)
            let c = try JSONDecoder().decode(PGConfig.self, from: data)
            // ⭐ §2645 自检（红线非空 ⇒ 拒绝加载，cfg 保持上一份）
            // ⭐ §2945 **缺陷（warnings）不拒绝** —— 只暴露（见 validateSplit 的说明）
            let (errs, warnings) = Self.validateSplit(c)
            guard errs.isEmpty else {
                lastConfigErrors = errs
                lastError = "配置自检不过（已**拒绝加载**，仍用上一份有效配置）: "
                    + errs.joined(separator: " ｜ ")
                // ⛔ 注意：**不动 `cfg`**（这就是"拒绝加载"）
                return false
            }
            cfg = c
            loadedAt = Date()
            lastConfigErrors = warnings        // ⚠️ 缺陷**照常加载**，但带出来给人看
            if warnings.isEmpty {
                lastError = ""
            } else {
                lastError = "⚠️ 配置已加载，但有 \(warnings.count) 处缺陷（照 §2945）: "
                    + warnings.joined(separator: " ｜ ")
            }
            return true
        } catch {
            lastError = "解析失败: \(error)"
            lastConfigErrors = ["解析失败: \(error)"]
            return false
        }
    }

    // MARK: - ⭐⭐⭐⭐⭐ §2645 配置自检（照 `Runner` 的「帧龄自检」范式，§2631）

    /// ⛔ **禁点词（支付红线）的硬编码基线** —— 配置化之后**只许加，⛔ 不许减**。
    ///
    /// ⚠️ 这张表必须与 `FeatureEngine.forbidKeys` **逐字一致**
    ///   （`validate()` 与执行点读的是**同一张表**，⛔ 不许各写一份）。
    ///   来源：PC `FORBID_KEYS`（`_1377_ad_loop.py:448`）逐字移植 + §1449 血案。
    static let forbidKeysBaseline: [String] = FeatureEngine.forbidKeys

    /// ⛔ §2921 **登录红线的自检基线** —— 与 `forbidKeysBaseline` 同一套纪律
    static let loginKeysBaseline: [String] = FeatureEngine.loginKeys

    /// ⭐⭐⭐⭐⭐ §2645 **配置自检** —— 返回错误清单（空 = 通过）。
    ///
    /// ## 只查"配错会出人命"的那一项（⛔ 不扩大成通用 schema 校验）
    /// `forbid_keys` 是**用户红线**（「可以浏览，绝不做支付/购买」）。
    /// 配置化之后必须防"配错导致帮用户买东西" ⇒ 做**加法校验**：
    /// ```
    /// ① 配置里的词 **少于** 基线        ⇒ ⛔ 拒绝
    /// ② 配置里**删掉了基线的任何一条**   ⇒ ⛔ 拒绝（逐条点名）
    /// ③ 配置里**新增**的词              ⇒ ✅ 允许（只加不减是安全方向）
    /// ```
    /// ⛔ 不许静默接受 —— 错误串会被 `POST /reload` 的 `configErrors` 字段带回。
    ///
    /// ## 逐字证据（PC `_1377_ad_loop.py:448` + §1449）
    /// > 货速发那条广告底部的「**立即秒杀**」是红色药丸，`pink_bands` 按**形状**直接命中并点下去
    /// > ⇒ 打开了快手小店收银台「待支付 ¥9.9」，屏幕上出现「确认支付 / 继续支付」，
    /// >   用户看见以为在买东西。
    /// > 用户口径：**可以浏览，绝不做支付/购买**。
    ///
    /// # ⚠️⚠️ §2945 **本函数的返回值分两类**（⛔ 别把"缺陷"当"红线"）
    /// ```
    ///   errs       —— **红线**（支付/登录）⇒ 调用方**拒绝加载**（cfg 保持上一份）
    ///   warnings   —— **缺陷**（引用不存在等）⇒ **加载照旧**，只把问题暴露出来
    /// ```
    /// 📏 为什么必须分开（我差点自己挖坑）：
    ///   引用完整性（`funnel` 引用了不存在的元素名）是**可容忍的缺陷** ——
    ///   那条腿不动，别的腿还能跑；而 **"拒绝加载"是致命的**（App 直接一步都不动）。
    ///   ⇒ ⛔ 若把缺陷塞进 `errs`，就会"因为一条死腿而让整个 App 起不来"。
    static func validate(_ c: PGConfig) -> [String] {
        validateSplit(c).errs
    }

    /// §2945 **自检的完整结果**：红线（拒绝加载）+ 缺陷（只警告）
    static func validateSplit(_ c: PGConfig) -> (errs: [String], warnings: [String]) {
        var errs: [String] = []
        var warnings: [String] = []
        // ⚠️ 未配置 `forbid_keys` ⇒ 用硬编码基线 ⇒ **天然安全**，⛔ 不报错（向后兼容）
        if let configured = c.settings?.forbid_keys {
            let base = forbidKeysBaseline
            // ② 删掉了基线的任何一条 ⇒ 逐条点名（这是最危险的一种配错）
            let missing = base.filter { !configured.contains($0) }
            if !missing.isEmpty {
                errs.append("`forbid_keys` **删掉了支付红线里的词** "
                    + missing.map { "「\($0)」" }.joined()
                    + " ⇒ ⛔ 拒绝加载（禁点词只许加、⛔ 不许减）")
            }
            // ① 数量少于基线 ⇒ 也拒绝（兜住"用同义词换掉基线"那种绕过）
            if configured.count < base.count {
                errs.append("`forbid_keys` 只有 \(configured.count) 条，"
                    + "少于硬编码基线 \(base.count) 条 ⇒ ⛔ 拒绝加载"
                    + "（只允许在基线之上**追加**，⛔ 不允许缩减）")
            }
            // ④ 空串会 `t.contains("")` **恒真** ⇒ 所有点击全被拒 ⇒ App 一步都走不动（也是配错）
            if configured.contains(where: { $0.isEmpty }) {
                errs.append("`forbid_keys` 里有空串 ⇒ `contains(\"\")` 恒真 ⇒ "
                    + "**任何点击都会被拒** ⇒ ⛔ 拒绝加载")
            }
        }
        // ⛔⛔⛔ §2921 **登录红线**（用户令：「同意授权但是登录 不登陆」）
        //
        // 与 `forbid_keys` **同一套加法校验**（⛔ 只加不减）：
        //   登录是红线，手滑删掉一条就等于"可能替用户登录账号"。
        if let configured = c.settings?.login_keys {
            let base = loginKeysBaseline
            let missing = base.filter { !configured.contains($0) }
            if !missing.isEmpty {
                errs.append("`login_keys` **删掉了登录红线里的词** "
                    + missing.map { "「\($0)」" }.joined()
                    + " ⇒ ⛔ 拒绝加载（登录词只许加、⛔ 不许减）")
            }
            if configured.count < base.count {
                errs.append("`login_keys` 只有 \(configured.count) 条，"
                    + "少于硬编码基线 \(base.count) 条 ⇒ ⛔ 拒绝加载"
                    + "（只允许在基线之上**追加**，⛔ 不允许缩减）")
            }
            if configured.contains(where: { $0.isEmpty }) {
                errs.append("`login_keys` 里有空串 ⇒ `contains(\"\")` 恒真 ⇒ "
                    + "**任何点击都会被拒** ⇒ ⛔ 拒绝加载")
            }
        }
        // ⛔⛔⛔ §2945 **引用完整性自检** —— 治「元素名不存在 ⇒ 静默返回 null」
        //
        // ## 为什么必须有它（真机血案 + 项目自己的规格早就写了）
        // `_note_2874_照PC抄_权威规格与验收门槛.md` **§3 第 3 条**（逐字）：
        // > **8 个元素名在 config 里不存在** ⇒ `pg.detect` **静默返回 null**
        // >   `exit_live`…、**`coupon_x`/`modal_x`/`bottom_popup`**（只能走 `pg.funnel()`）…
        // > 📏 **`pg.detect` 对不存在的元素名返回 null 而不报错** ⇒
        // >   ⛔ **JS 里看不出"是漏了"还是"真没命中"** —— 这正是我这几轮反复踩的坑。
        //
        // ## 真机现场（§2944，2026-10-16）
        // 直播间「奥兴建材工厂店」+ 券弹窗「领取店铺首单券」盖屏 ⇒ **死循环**。
        // `/elements` 逐条复核发现：
        // ```
        //   funnel[11] modal_x      ⛔ 元素不存在 ⇒ 静默什么都不做
        //   funnel[12] coupon_x     ⛔ 元素不存在 ⇒ **就是那个券弹窗**
        //   funnel[14] bottom_popup ⛔ 元素不存在
        //   funnel[13] mid_modal_x  ✅ 命中 @(208,711) ← 该点它，但排在三条死腿之后
        // ```
        //
        // ## ✅ 判据（⛔ 不是"报错就拒绝加载" —— 那会让现有配置直接不可用）
        // 这里**只把问题暴露出来**（进 `configErrors` / 控制台 / `/reload` 回包），
        // ⛔ **不拒绝加载** —— 因为"某条腿暂时没元素"是**可容忍**的（其它腿还能跑），
        // 而"加载不了配置"是**致命**的（App 直接不动）。
        // ⇒ 📏 与 `forbid_keys` 的区别：那条是**红线**（必须拒绝），这条是**缺陷**（必须可见）。
        //
        // ## 检查三处引用
        // ```
        //   ① funnel[].element  ② funnel[].require  ③ pages[].check / alts / go / also_ok / not
        // ```
        // ⚠️ 只查"**名字是否存在**"（⛔ 不查语义对不对）—— 语义靠人/后续 AI 判。
        var refErr: [String] = []
        let known = Set(c.elements.keys)

        /// 特殊元素名：**不走 elements 表**（由代码里的专用判据处理）⇒ 白名单
        ///
        /// 📏 照 `Navigator` 里那几个 `if it.element == "..."` / `if g == "..."` 分支
        ///   （⛔ 逐个 grep 出来的，**不是猜的**）：
        /// ```
        ///   runFunnel:  coin_ball   → ColorBlob.findCoinBall
        ///               modal_x     → ModalX.find
        ///               bottom_popup→ findBottomPopup
        ///               appstore_x  → findDarkCross
        ///               coupon_x    → ModalX.findCoupon      ← ⚠️ 别漏！它有分支
        ///               consent_allow → findConsentAllow
        ///   step/go:    back_edge   → backGestureCmd()（页面图里当出路用）  ← ⚠️ 别漏
        /// ```
        /// ⛔ 漏一个就会**误报**（把有实现的腿说成死腿）——
        ///   我第一版就漏了 `coupon_x` 和 `back_edge`，自检报了 4 条假警报。
        let codeOnly: Set<String> = ["coin_ball", "modal_x", "bottom_popup",
                                     "appstore_x", "coupon_x", "consent_allow",
                                     "back_edge"]

        for (i, it) in (c.funnel ?? []).enumerated() {
            let e = it.element
            if !known.contains(e) && !codeOnly.contains(e) {
                refErr.append("funnel[\(i)].element = 「\(e)」**在 elements 里不存在**"
                    + " ⇒ `detect()` 会**静默返回 nil**（⛔ 这条腿永远不会出手）")
            }
            if let rq = it.require, !known.contains(rq) && !codeOnly.contains(rq) {
                refErr.append("funnel[\(i)].require = 「\(rq)」**在 elements 里不存在**"
                    + " ⇒ 前置闸恒不命中 ⇒ 这条腿被**静默挡住**")
            }
        }
        for (pname, p) in c.pages {
            func chk(_ list: [String]?, _ what: String) {
                for n in list ?? [] where !known.contains(n) && !codeOnly.contains(n) {
                    refErr.append("pages.\(pname).\(what) 引用「\(n)」**不存在** ⇒ 该判据失效")
                }
            }
            chk(p.check, "check"); chk(p.alts, "alts"); chk(p.also_ok, "also_ok")
            chk(p.not, "not")
            if let g = p.go, !known.contains(g), !codeOnly.contains(g) {
                refErr.append("pages.\(pname).go 引用「\(g)」**不存在** ⇒ 该页出路失效")
            }
        }
        if !refErr.isEmpty {
            // ⚠️ §2945 **进 warnings，⛔ 不进 errs**（缺陷 ≠ 红线；见 validate 的说明）
            warnings.append("⚠️ **引用完整性**：\(refErr.count) 处引用不存在的元素名"
                + "（照 §2945；⛔ 这类错**不会报错**，只会静默不动）：\n      "
                + refErr.prefix(12).joined(separator: "\n      ")
                + (refErr.count > 12 ? "\n      …还有 \(refErr.count - 12) 处" : ""))
        }
        return (errs, warnings)
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

        // ══════════════════════════════════════════════════════════════
        // ⭐⭐⭐⭐⭐ §2645 **本次新增的 6 组「硬编码 → 配置」字段**
        //
        // 用户令（逐字，这就是本组字段的由来）：
        // > 「**你直接在软件留可以更改的容量不行么，每次更改都要签名。太浪费时间了**」
        // > 「**你不是留了通道么，直接用通道调试 最快**」
        //
        // ⇒ 推送方式：`POST /write?name=pgconfig/config.json` + `POST /reload`
        //   ⇒ **秒级生效，⛔ 不需要重编译/签名/安装**（一次编译安装 ≈ 3 分钟）。
        //
        // ⛔⛔ **兼容性硬要求**：下面每一个都是 **Optional**；
        //   老 `config.json` **一个老键都不用改**，新键可以**先不写**
        //   ⇒ 缺省路径与改动前的硬编码**逐字一致**（每处读取都带 `?? 默认值`）。
        // ══════════════════════════════════════════════════════════════

        /// ⭐⭐⭐⭐⭐ **广告顶栏 ROI** `[x, y, w, h]`（默认 `[0, 62, 451, 78]`）。
        ///
        /// ## 为什么必须可配（真机实测，本轮）
        /// 硬编码是 `CGRect(x: 0, y: 62, width: bw, height: 78)`（`bw` = `base_w` = 451）。
        /// 而真机上**胶囊文字实际在 y=85~105** ⇒ 用整块 ROI 做 OCR 时，
        /// 上方**大标题**会把胶囊挤掉 ⇒ 读出的是「地政费用/方案查询告…」
        /// 而**不是**「已成功领取982金币」⇒ `looksLikeAdPage`/倒计时判据**全错**。
        /// ⇒ 配置化后可以直接把 ROI 收到 `[0,80,451,110]` 试，⛔ 不用重编译。
        ///
        /// ⚠️ 唯一读取点 = `FeatureEngine.adTopROI(...)`（⛔ 不许各写一份）。
        var ad_top_roi: [Double]?

        /// ⭐⭐⭐ **CTA 文案兜底词表**（默认 = `FeatureEngine.ctaKeys` 那 12 条）。
        ///
        /// 真机实测：底部按钮实际是「**在线咨询**」(OCR conf 0.99)
        /// ⇒ 原来那 12 条**无一命中** ⇒ 文案兜底腿全废。
        ///
        /// ⚠️ 唯一读取点 = `FeatureEngine.ctaKeysCfg`（⛔ 不许各写一份）。
        var cta_keys: [String]?

        /// ⭐⭐⭐ §2896 **安装/打开腿的词表** —— 默认 = `FeatureEngine.installWords` 那 7 条。
        ///
        /// ## ⛔ 为什么必须能配（用户令，逐字）
        /// > 「**没下载的要做下载一般是云图标或者获取 已经下载的要去打开**」
        ///
        /// 📏 实测：PC `click_install`（`_1377_ad_loop.py:8758`）词表 =
        ///   `("获取","安装","下载","免费","获取APP","获取App")` —— **不含「打开」**；
        ///   手机移植时照抄了这个缺口 ⇒ **已下载态两端都不做**。
        ///   真机 `_v2885`：`打开` @(370,106) conf=**1.00**（页首右上，正是本 App 的按钮）
        ///   ⇒ 这是一条**两端都缺**的 MISSING，⛔ 不是"手机漏移植"。
        ///
        /// ⚠️ 唯一读取点 = `FeatureEngine.installWordsCfg`（⛔ 不许各写一份）。
        var install_words: [String]?

        /// ⛔⛔⛔ **禁点词（支付红线）** —— 默认 = `FeatureEngine.forbidKeys` 那 25 条。
        ///
        /// ⚠️ 本字段**受自检保护**：只许在基线之上**追加**，⛔ **不许删减**
        ///    （见 `ConfigStore.validate()`；配错 ⇒ `/reload` **拒绝加载**并报 `configErrors`）。
        /// ⚠️ 唯一读取点 = `FeatureEngine.forbidKeysCfg`（⛔ 不许各写一份）。
        var forbid_keys: [String]?

        /// ⛔⛔⛔ §2921 **登录红线词表** —— 默认 = `FeatureEngine.loginKeys` 那 14 条。
        ///
        /// ## 用户令（逐字）
        /// > 「**外部授权都可以统一 但是不点击登录**」
        /// > 「**同意授权但是登录 不登陆**」
        ///
        /// ## 与 `forbid_keys` 的关系（⛔ 两条独立红线，别混）
        /// ```
        /// ✅ 外部**授权**弹窗（「想要打开 X」）  ⇒ 统一**同意**（点「打开/允许」）
        /// ⛔ **登录**（任何形态）              ⇒ **绝不点**（本字段 = 执行点）
        /// ```
        /// 📏 PC `_1377_ad_loop.py` **全篇没有「登录」二字**（grep 0 命中）⇒
        ///   这是用户**新加**的口径，⛔ 照抄 PC 抄不到，必须以用户令为准。
        ///
        /// ⚠️ 本字段**同样受自检保护**（只许加、⛔ 不许减）——
        ///   登录是红线，配错就等于"替用户登录账号"。
        /// ⚠️ 唯一读取点 = `FeatureEngine.loginKeysCfg`（⛔ 不许各写一份）。
        var login_keys: [String]?

        /// ⭐⭐ **CTA 药丸的颜色判据**（默认 `r_min=200, g_max=120, b_max=150` = 粉色）。
        ///
        /// 真机实测：底部按钮是 **RGB(240,72,0)**（橙色）—— 恰好也满足粉色判据，
        /// 所以形状腿（`widestPinkBand`）**其实能命中**。仍配置化以便换版式时不必重编译。
        /// 键名：`r_min` / `g_max` / `b_max`（三个**各自**可选 ⇒ 只调一个也安全）。
        ///
        /// ⚠️ 唯一读取点 = `FeatureEngine.widestPinkBand(..., color:)`。
        var cta_color: CtaColor?

        /// ⭐⭐⭐⭐ **倒计时「还在走」的正则表**（默认逐字照抄现有判据，见
        ///   `FeatureEngine.runningPatternsDefault`）。
        ///
        /// ⚠️ JSON 里写 `\s` 要转义成 `\\s`（与 Swift 源码里 `"\\s"` 同一个意思）。
        /// ⚠️ 唯一读取点 = `FeatureEngine.adCountdownRunning(..., runningPatterns:)`。
        var countdown_running_regex: [String]?

        /// ⭐⭐⭐ **倒计时「还剩几秒」的正则表**（默认逐字照抄现有 4 条，见
        ///   `FeatureEngine.secondsPatternsDefault` / `secondsFallbackDefault`）。
        ///
        /// ⚠️ **必须带捕获组 1**（`([0-9]+)…`）—— 读取点取的就是第 1 个捕获组。
        /// ⚠️ 唯一读取点 = `FeatureEngine.adCountdownSeconds(..., secondsPatterns:)`。
        var countdown_seconds_regex: [String]?

        /// ⭐⭐⭐ **回广告页的腿序轮数**（默认 **9**，照 PC `for k in range(9)`）。
        ///
        /// ⛔ 注意：**腿的顺序本身没有配置化**（那需要 mini-language，风险大）—— 只配置化数字。
        var return_to_ad_rounds: Int?

        /// ⭐⭐⭐ **回广告页每轮之间的等待（秒）**（默认 **3.2**，照 PC `wait(3.2)`）。
        var return_to_ad_wait: Double?

        /// ⭐⭐ **CTA 药丸的颜色判据**（`settings.cta_color` 的子对象）。
        struct CtaColor: Codable {
            /// 红色**下界**（默认 **200**）—— 判据是 `r > r_min`
            var r_min: Double?
            /// 绿色**上界**（默认 **120**）—— 判据是 `g < g_max`
            var g_max: Double?
            /// 蓝色**上界**（默认 **150**）—— 判据是 `b < b_max`
            var b_max: Double?
        }

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
