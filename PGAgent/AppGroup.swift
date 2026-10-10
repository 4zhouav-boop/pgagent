import Foundation

/// ⭐⭐⭐⭐⭐ **App Group 共享容器**（主 App 与 ReplayKit 扩展之间的「眼」通道）。
///
/// ## 为什么需要它（真机实测 §2210）
/// ```
/// 主 App 容器 : run.pgagent.PGAgent.8W9ZSMW4UW/Documents        ⇒ 只有 pgconfig
/// 扩展容器    : run.pgagent.PGAgent.8W9ZSMW4UW.PGShot/Documents ⇒ 128 个帧 ✅
/// ```
/// ⇒ 扩展**写得到**帧，但主 App **读不到**（两个不同容器）。
///
/// ## 三条路的实测结论
/// | 路 | 结果 |
/// |---|---|
/// | 扩展写自己 Documents，主 App 读自己 Documents | ⛔ 两个容器，永远读不到 |
/// | 扩展 HTTP POST 回主 App | ⚠️ 能用，但**要求主 App 活着且 HTTP 在听** |
/// | **⭐ App Group 共享容器** | ✅ **两边同目录，谁写谁读**（本文件）|
///
/// ## 关键：group id 里带**签名 team 后缀**
/// ```
/// 我们构建时:  group.run.pgagent.PGAgent
/// 签名后实测:  group.run.pgagent.PGAgent.8W9ZSMW4UW   ← team id 插在后面
/// ```
/// ⇒ **不能写死**。这里**不猜 entitlements**（那要 SecTask，风险高），
///    而是**用官方 API 试 + 真写一个字节验证**：
///    `containerURL(forSecurityApplicationGroupIdentifier:)` 在**无权限**时返回 nil 或
///    给一个**写不进去**的路径 ⇒ 所以「试 + 写」两步都过了才算数。
enum AppGroup {

    /// ⭐⭐⭐ **候选 group id** —— 从 **bundle id 推导**，⛔ 不写死。
    ///
    /// ## 为什么必须动态（§2242 换手机/换账号的坑）
    /// 签名工具会在 group id 里插**签名者的 team id**：
    /// ```
    /// 我们自己构建时 : group.run.pgagent.PGAgent
    /// iloader 签名后 : group.run.pgagent.PGAgent.8W9ZSMW4UW   ← 这个后缀是**签名账号的** team
    /// ```
    /// ⇒ 换一台手机 / 换一个 Apple ID 签名 ⇒ team 后缀就变了
    ///   ⇒ 写死会让**共享容器整条链路失配**（帧读不到、心跳写不出）。
    ///
    /// ## ⚠️ 为什么不用 entitlements API（§2250 编译踩过）
    /// `SecTaskCreateFromSelf` / `SecTaskCopyValueForEntitlement`
    /// 在 **appex 目标里编不过**（`cannot find ... in scope`）——
    /// 它们是 Security 框架的**未公开**部分。
    /// ⇒ 为了 **App 与扩展两边用同一套逻辑**（⛔ 不搞两套），这里也不用它。
    ///
    /// ## ✅ 用**公开**的推导规则
    /// team 后缀**只插在 bundle id 的倒数第二段**（扩展的 `.PGShot` 之前）：
    /// ```
    /// 主 App bundle : run.pgagent.PGAgent.8W9ZSMW4UW
    ///   ⇒ group.run.pgagent.PGAgent.8W9ZSMW4UW
    /// 扩展 bundle   : run.pgagent.PGAgent.8W9ZSMW4UW.PGShot
    ///   ⇒ 去掉最后一段 ⇒ group.run.pgagent.PGAgent.8W9ZSMW4UW  （⭐ 同一个！）
    /// ```
    /// ⇒ 规则：**去掉最后一段**，前面整串加 `group.` 前缀。
    ///
    /// ⚠️ 真正能不能用，由 `probe()` 的「拿路径 + 建目录 + 写探针」决定
    ///    （`containerURL` 无权限时返回 nil）⇒ 候选猜错也**不会误用**。
    static var candidates: [String] {
        var out: [String] = []
        if let bid = Bundle.main.bundleIdentifier {
            let all = bid.split(separator: ".").map(String.init)
            if all.count >= 3 {
                // 去最后一段：run.pgagent.PGAgent.8W9ZSMW4UW.PGShot ⇒ run.pgagent.PGAgent.8W9ZSMW4UW
                out.append("group." + all.dropLast().joined(separator: "."))
            }
            if all.count >= 2 {
                out.append("group." + all.prefix(2).joined(separator: "."))
            }
        }
        // 兜底（⛔ 判据仍是 probe 能不能写）
        out += ["group.run.pgagent.PGAgent",
                "group.run.pgagent.PGAgent.8W9ZSMW4UW",
                "group.pgagent"]
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 诊断用：把探测过程如实回显（排查「换手机后帧读不到」）
    static func diag() -> [String: Any] {
        [
            "bundleID": Bundle.main.bundleIdentifier ?? "?",
            "candidates": candidates,
        ]
    }

    /// 缓存探测结果（会话内只探一次；`force: true` 可重探）
    ///
    /// ⚠️ 必须加锁：`framesDir()` 会被多个 HTTP handler 线程**并发**调用，
    ///    而探测本身要建目录 + 写探针（有 IO）。
    ///    没有锁的话两个线程可能同时探测、同时写缓存（数据竞争）。
    private static var cached: URL?
    private static var probed = false
    private static let lock = NSLock()

    /// ⭐⭐ 「眼」的共享帧目录：`<group>/Documents/frames`
    ///
    /// ⚠️ 放在 `Documents/` 下是**故意的**：go-ios 的
    ///    `file ls/pull --app-group=<gid> --path=/Documents`
    ///    只允许访问 `Library / Documents / tmp`
    ///    （实测：直接放 group 根目录会被拒
    ///     `... is outside the allowed container directories`）
    /// ⇒ 放 `Documents/` 下 ⇒ **PC 也能直接读**，调试不用装新包。
    static func framesDir(force: Bool = false) -> URL? {
        lock.lock()
        if probed && !force {
            let c = cached
            lock.unlock()
            return c
        }
        lock.unlock()

        // ⭐ 探测在**锁外**做（有文件 IO，⛔ 不该占着锁）
        let found = probe()

        lock.lock()
        cached = found
        probed = true
        lock.unlock()
        return found
    }

    /// 探测：对每个候选「拿路径 + 建目录 + 写删一个探针文件」
    private static func probe() -> URL? {
        let fm = FileManager.default
        for g in candidates {
            guard let root = fm.containerURL(
                forSecurityApplicationGroupIdentifier: g) else { continue }
            let dir = root.appendingPathComponent("Documents/frames", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                // ⭐ 真写一个字节 —— 「拿得到路径」不等于「写得进去」
                let probe = dir.appendingPathComponent(".pgprobe")
                try Data([0x50]).write(to: probe, options: .atomic)
                try? fm.removeItem(at: probe)
                NSLog("PGAgent AppGroup: 可用 ⇒ %@ (group=%@)", dir.path, g)
                return dir
            } catch {
                NSLog("PGAgent AppGroup: %@ 不可写：%@", g, String(describing: error))
                continue
            }
        }
        NSLog("PGAgent AppGroup: ⛔ 没有可用的共享容器（回到 HTTP / 本容器兜底）")
        return nil
    }

    /// ⭐ 找到可用的共享容器**根目录**（带缓存；探测逻辑与 `probe()` 同一套）
    private static func containerRoot() -> URL? {
        lock.lock()
        if probed, let c = cached {
            // `cached` 是 frames 目录 ⇒ 它的上一级就是 Documents，再上一级是根
            let root = c.deletingLastPathComponent().deletingLastPathComponent()
            lock.unlock()
            return root
        }
        lock.unlock()

        let fm = FileManager.default
        for g in candidates {
            guard let root = fm.containerURL(
                forSecurityApplicationGroupIdentifier: g) else { continue }
            let d = root.appendingPathComponent("Documents", isDirectory: true)
            do {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                let probe = d.appendingPathComponent(".pgprobe")
                try Data([0x50]).write(to: probe, options: .atomic)
                try? fm.removeItem(at: probe)
                lock.lock(); cached = d.appendingPathComponent("frames", isDirectory: true)
                probed = true; lock.unlock()
                return root
            } catch {
                continue
            }
        }
        lock.lock(); cached = nil; probed = true; lock.unlock()
        return nil
    }

    /// ⭐ 共享目录里的**任意文件**路径（用于心跳/日志；没有共享容器 ⇒ nil）
    static func sharedFile(_ name: String) -> URL? {
        guard let root = containerRoot() else { return nil }
        let d = root.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(name)
    }

    /// 诊断用（`/framediag` 回显）
    static func snapshot() -> [String: Any] {
        var tried: [String: String] = [:]
        let fm = FileManager.default
        for g in candidates {
            if let r = fm.containerURL(forSecurityApplicationGroupIdentifier: g) {
                let dir = r.appendingPathComponent("Documents/frames", isDirectory: true)
                tried[g] = "path=\(dir.path) exists=\(fm.fileExists(atPath: dir.path))"
            } else {
                tried[g] = "(containerURL = nil)"
            }
        }
        var out = diag()                        // ⭐ bundleID / entitled / candidates
        out["probed"] = tried
        out["framesDir"] = framesDir()?.path ?? "(nil) ⛔ 不可用"
        out["active"] = framesDir()?.path ?? "(nil)"
        return out
    }
}
