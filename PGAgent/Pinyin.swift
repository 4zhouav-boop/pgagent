import Foundation

/// ⭐⭐⭐⭐ **拼音转换**（移植电脑端 `_dev/pinyin.py` 的 `pinyin_of`）
///
/// ## 为什么需要（照 `pinyin.py` 头注）
/// 模块 D（搜索打标签）/ E（商城逛小店）要把**高价值词**送进快手搜索框。
/// HID 固件只有 `T:<文本>` 一条打字腿，而它走 `Keyboard.print` ⇒ **只能发 ASCII**
/// ⇒ 中文词必须先转**拼音**才能打进去。
///
/// ## ⛔⛔ 铁律（用户令 + PC §1743）
/// > 「**打字一定要做到中文，拼音绝对不行**」
///
/// 但 iOS 侧实测（PC `_1377_ad_loop.py` §1743）：
/// ```
/// ⛔ 拿生拼音 `bingxiang` 去搜，小店直接返回「无相关商品」空页 ⇒ 整轮白跑
/// ✅ 所以有「**落中文硬闸**」：框内必须**真的出现目标中文词**才允许提交
/// ```
/// ⇒ 本模块**只负责转拼音**；「打完必须点 IME 候选落到中文」那条闸在 `FeatureEngine` 里。
///
/// ## 实现选择：用 **iOS 系统 API**（⛔ 不硬编码表）
/// 电脑端用 `pypinyin`（第三方），拿不到时退回 171 条内置表。
/// iOS 有**系统级**的等价物 —— `CFStringTransform` 的 `kCFStringTransformMandarinLatin`：
///   · ⛔ 不需要第三方库、⛔ 不需要网络
///   · ✅ 覆盖**任意**汉字（比 171 条表强得多）
///   · ✅ 系统维护（读音准确）
enum Pinyin {

    /// 汉字 → 无声调拼音（小写、无空格）
    ///
    /// ```
    /// Pinyin.of("冰箱")     → "bingxiang"
    /// Pinyin.of("吸尘器")   → "xichenqi"
    /// Pinyin.of("abc")      → "abc"       （ASCII 原样保留，照 PC `keep_ascii=True`）
    /// ```
    /// - Returns: 拼音串；**转不出来** ⇒ `nil`（照 PC：调用方**降级**换词）
    static func of(_ word: String, keepAscii: Bool = true) -> String? {
        if word.isEmpty { return nil }

        // ⭐ 纯 ASCII ⇒ 原样返回（照 PC `keep_ascii=True`）
        if word.allSatisfy({ $0.isASCII }) {
            return keepAscii ? word : nil
        }

        // ① 汉字 → 带声调拉丁（`bīng xiāng`）
        let m = NSMutableString(string: word) as CFMutableString
        guard CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false) else {
            return nil
        }
        // ② 去掉声调符号（`bīng xiāng` → `bing xiang`）
        guard CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false) else {
            return nil
        }
        let latin = (m as String).lowercased()

        // ③ 只留 a-z0-9（去空格/标点）—— HID 只能发 ASCII
        let cleaned = latin.unicodeScalars.filter {
            ($0.value >= 97 && $0.value <= 122) ||   // a-z
            ($0.value >= 48 && $0.value <= 57)       // 0-9
        }
        let out = String(String.UnicodeScalarView(cleaned))
        return out.isEmpty ? nil : out
    }

    /// ⭐ 这个词**能不能**打进搜索框（= 能转出拼音）
    ///
    /// 照 PC `pinyin.covers(word)` 的语义：调用方用它**过滤词池**，
    /// ⛔ 转不出来的词**不选**（选了也打不进去，白费一轮）。
    static func covers(_ word: String) -> Bool {
        of(word) != nil
    }

    /// ⭐ 给诊断用：本模块用的是**系统 API**（⛔ 不是内置表）
    static var engineName: String { "iOS CFStringTransform (MandarinLatin)" }
}
