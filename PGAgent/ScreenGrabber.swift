import Foundation
import UIKit

/// ⭐⭐⭐ 「眼」—— App **自己取画面**（⛔ 不依赖 PC）。
///
/// ## 为什么必须绕快捷指令
/// iOS 沙箱：第三方 App **无法截别的 App 的屏**
///   · `UIScreen.snapshotView` / `drawHierarchy` 只能截**自己**
///   · ReplayKit `RPScreenRecorder` 官方定义是 *"record audio and video **of your app**"*
///   · ReplayKit 广播扩展要**用户手点**启动 + 状态栏**红标常亮** + iOS 27 起 deprecated
///   · WDA/XCTest 要**开发者模式**（用户令：开了风控太厉害）
///
/// ⇒ **唯一可行**：快捷指令的「拍摄截屏」动作能拍整块屏幕，
///    App 通过 `shortcuts://` URL scheme **自己触发**它，截图落到自己的 Documents。
///
/// ## 链路
/// ```
/// App: UIApplication.open("shortcuts://run-shortcut?name=PGshot")
///   ↓
/// 快捷指令「PGshot」：截屏 → 存储到文件（PGAgent/Documents）
///   ↓
/// App: 轮询 Documents，发现新 PNG ⇒ 这就是「眼」
/// ```
///
/// ⚠️ 已知限制（`_note_1810` 实测）：
///   · 快捷指令运行时**会短暂切到前台**（截图拍的是切走前的画面）
///   · 灵动岛会显示运行状态（Apple 未提供隐藏方式）
///   · 受保护视频/DRM/密码界面可能拍到黑屏
final class ScreenGrabber: ObservableObject {

    /// 截图落地的目录（App 自己的 Documents，快捷指令「存储到文件」写这里）
    static func shotDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
    }

    /// 快捷指令名（用户在手机上导入的那个）
    @Published var shortcutName = "PGshot"

    /// 最近一次抓到的帧
    @Published private(set) var lastShot: URL?
    @Published private(set) var lastError = ""

    /// ⭐ 诊断信息（v0.4.1 加）—— 用来排查「抓帧为什么失败」
    @Published private(set) var lastOpenResult: String = "未尝试"
    @Published private(set) var grabAttempts = 0
    @Published private(set) var grabSuccesses = 0

    private var lastSeen: [String: Date] = [:]

    /// 记录当前 Documents 里的 PNG（用于「发现新文件」）
    func snapshotExisting() {
        lastSeen.removeAll()
        for u in Self.listPNGs() {
            lastSeen[u.lastPathComponent] = modDate(u)
        }
    }

    static func listPNGs() -> [URL] {
        let fm = FileManager.default
        let dir = shotDir()
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "png" }
    }

    private func modDate(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
    }

    /// ⭐ 触发快捷指令（App 自己发起，⛔ 不需要人点）
    @discardableResult
    func triggerShortcut(_ name: String? = nil, completion: ((Bool) -> Void)? = nil) -> Bool {
        let n = name ?? shortcutName
        guard let enc = n.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(enc)") else {
            lastError = "URL 构造失败: \(n)"
            lastOpenResult = "URL 构造失败"
            return false
        }
        lastError = ""
        grabAttempts += 1
        DispatchQueue.main.async {
            // ⭐ 记录 open 的返回结果（排查用）
            UIApplication.shared.open(url, options: [:]) { ok in
                self.lastOpenResult = ok ? "✅ 系统接受了 shortcuts:// (name=\(n))"
                                         : "⛔ 系统拒绝打开（快捷指令没装？名字不对？）"
                completion?(ok)
            }
        }
        return true
    }

    /// ⭐ 抓一帧：触发快捷指令 ⇒ 等新 PNG 出现 ⇒ 返回它
    /// `timeout` 是等文件的最长秒数（快捷指令有启动开销，实测要 1~3 秒）
    func grab(timeout: Double = 8.0, completion: @escaping (URL?, String) -> Void) {
        snapshotExisting()
        let before = Set(lastSeen.keys)
        let beforeCount = before.count

        guard triggerShortcut() else {
            completion(nil, lastError)
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while Date() < deadline {
                guard let self = self else { return }
                let now = Self.listPNGs()
                // 新文件，或已存在文件被覆盖（mtime 变了）
                for u in now {
                    let nm = u.lastPathComponent
                    if !before.contains(nm) {
                        DispatchQueue.main.async {
                            self.lastShot = u
                            self.grabSuccesses += 1
                        }
                        completion(u, "")
                        return
                    }
                    if let old = self.lastSeen[nm], self.modDate(u) > old {
                        DispatchQueue.main.async {
                            self.lastShot = u
                            self.grabSuccesses += 1
                        }
                        completion(u, "")
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            let afterCount = Self.listPNGs().count
            let msg = "超时 \(timeout)s 没等到新截图｜open结果=\(self.lastOpenResult)"
                + "｜抓帧前 PNG 数=\(beforeCount) 现在=\(afterCount)"
                + "｜快捷指令名=\(self.shortcutName)"
            DispatchQueue.main.async { self.lastError = msg }
            completion(nil, msg)
        }
    }
}
