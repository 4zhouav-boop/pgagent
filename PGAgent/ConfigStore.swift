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
