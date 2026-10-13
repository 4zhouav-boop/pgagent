import Foundation
import UIKit
import SwiftUI

/// ⭐⭐⭐ v0.11.0 **局域网在线调试**（电脑和手机连同一个 Wi-Fi 即可）
///
/// ## 为什么
/// 签名器坏了，爱思签名时好时坏 ⇒ 每次改代码都重签重装太慢。
/// ⇒ App 里常驻一个**局域网接口**：电脑端直接
///    · 推脚本并当场运行（`/js/*`，见 `ScriptRuntime.swift`）—— 改流程 ⛔ 不重签
///    · 推 config.json / 模板并热加载（复用原 `/write` + `/reload`）
///    · 看帧、看日志、点、滑（复用原有全部接口）
///
/// ## 与原 8899 的关系（⛔ 原接口一字未动）
/// | 端口 | 绑定 | 令牌 | 用途 |
/// |---|---|---|---|
/// | 8899 | 127.0.0.1 | 不要 | 扩展推帧 + USB 转发调试（原样） |
/// | **8900** | **所有网卡** | **必须** | 电脑端经 Wi-Fi 调试（新增） |
///
/// ## 安全
/// · 除 `/dbg/hello` 外**全部要令牌**（`X-PG-Token` 头或 `?token=`），令牌显示在控制台
/// · 令牌错 5 次 ⇒ 该 IP 锁 60 秒
/// · 远程 ⛔ 不能调 `/frame`（那是扩展专用的推帧口）
/// · 控制台可一键关掉远程调试 / 换令牌
final class RemoteDebug: ObservableObject {

    static let shared = RemoteDebug()
    static let preferredPort: UInt16 = 8900
    private static let kEnabled = "pg.remote.enabled"
    private static let kToken = "pg.remote.token"

    @Published private(set) var enabled: Bool
    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var ips: [String] = []
    @Published private(set) var token: String
    @Published private(set) var lastClient = ""
    @Published private(set) var lastError = ""

    private var server: HTTPServer?
    private weak var router: APIRouter?
    private weak var log: LogStore?
    private var ipTimer: Timer?

    private let failLock = NSLock()
    private var fails: [String: (n: Int, until: Date)] = [:]

    private init() {
        let ud = UserDefaults.standard
        enabled = ud.object(forKey: Self.kEnabled) as? Bool ?? true
        if let t = ud.string(forKey: Self.kToken), t.count >= 6 {
            token = t
        } else {
            let t = Self.makeToken()
            ud.set(t, forKey: Self.kToken)
            token = t
        }
    }

    // MARK: - 生命周期

    /// 在 `boot()` 里、APIRouter 建好之后调一次（主线程）
    func start(router: APIRouter, log: LogStore) {
        self.router = router
        self.log = log
        ScriptRuntime.shared.attach(router: router)
        if enabled { startServer() }

        ipTimer?.invalidate()
        ipTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshIPs()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshIPs() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.kEnabled)
        enabled = on
        if on { startServer() } else { stopServer() }
        log?.log("🛰 远程调试 \(on ? "已开" : "已关")")
    }

    func regenerateToken() {
        let t = Self.makeToken()
        UserDefaults.standard.set(t, forKey: Self.kToken)
        token = t
        log?.log("🛰 远程调试令牌已更换：\(t)")
    }

    private func startServer() {
        guard server == nil else { return }
        let s = HTTPServer()
        s.loopbackOnly = false
        s.bonjourName = "PGAgent"
        s.onRequest = { [weak self] req in
            self?.handle(req) ?? HTTPServer.Response.text("remote debug off", status: 403)
        }
        s.start(preferredPort: Self.preferredPort)
        server = s
        port = s.port
        running = s.port != 0
        lastError = s.lastError
        refreshIPs()
        log?.log("🛰 远程调试 \(summary())")
    }

    private func stopServer() {
        server?.stop()
        server = nil
        running = false
        port = 0
    }

    /// 一行摘要（启动日志 / 控制台用）
    func summary() -> String {
        guard running else { return "未运行 \(lastError)" }
        let addr = ips.isEmpty ? "（没连 Wi-Fi？）" : ips.map { "\($0):\(port)" }.joined(separator: " , ")
        return "\(addr)  令牌 \(token)"
    }

    func refreshIPs() {
        let now = Self.localIPv4s()
        if Thread.isMainThread { ips = now } else { DispatchQueue.main.async { self.ips = now } }
    }

    // MARK: - 请求处理（后台线程）

    private func isLoopback(_ h: String) -> Bool {
        // ⛔ 认不出对端（空串）一律当远程处理 ⇒ 照样要令牌
        h == "127.0.0.1" || h == "::1"
    }

    private func handle(_ req: HTTPServer.Request) -> HTTPServer.Response {
        // 探活：不要令牌（电脑端用它扫网段找手机）
        if req.path == "/dbg/hello" {
            return .json(["app": "PGAgent", "version": AppVersion.display,
                          "port": Int(port), "needsToken": true])
        }

        let who = req.remoteHost
        if !isLoopback(who) {
            if let left = lockedFor(who) {
                return .json(["ok": false, "error": "令牌错太多次，\(Int(left)) 秒后再试"], status: 403)
            }
            let given = req.headers["x-pg-token"] ?? req.query["token"] ?? ""
            guard given == token else {
                noteFail(who)
                return .json(["ok": false, "error": "令牌不对（看手机控制台「远程调试」那一栏）"], status: 401)
            }
            clearFail(who)
        }
        DispatchQueue.main.async { self.lastClient = "\(who) \(ScriptJob.ts.string(from: Date()))" }

        // ⛔ 推帧口只给扩展用
        if req.path == "/frame" {
            return .json(["ok": false, "error": "/frame 只允许本机扩展调用"], status: 403)
        }

        if req.path.hasPrefix("/js/") || req.path.hasPrefix("/dbg/") {
            return handleDebug(req)
        }
        guard let rt = router else { return .text("router 未就绪", status: 500) }
        return rt.handle(req)
    }

    private func handleDebug(_ r: HTTPServer.Request) -> HTTPServer.Response {
        let rt = ScriptRuntime.shared
        let q = r.query

        switch (r.method, r.path) {

        // 跑一段代码（请求体 = JS 源码）。默认等它跑完（最多 wait 秒）再回结果
        case ("POST", "/js/eval"):
            let src = String(decoding: r.body, as: UTF8.self)
            guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .json(["ok": false, "error": "请求体是空的"], status: 400)
            }
            return startAndMaybeWait(src: src, name: q["name"] ?? "eval.js",
                                     wait: Double(q["wait"] ?? "60") ?? 60, force: q["force"] == "1")

        // 存脚本到 Documents/scripts/<name>
        case ("POST", "/js/put"):
            guard let name = q["name"], ScriptRuntime.safeName(name) else {
                return .json(["ok": false, "error": "need ?name=xxx.js"], status: 400)
            }
            do {
                try r.body.write(to: ScriptRuntime.scriptsDir().appendingPathComponent(name))
                return .json(["ok": true, "name": name, "bytes": r.body.count])
            } catch {
                return .json(["ok": false, "error": "\(error)"], status: 500)
            }

        // 跑已存的脚本。默认不等（wait=0）⇒ 立刻回 id，电脑端轮询 /js/job
        case ("POST", "/js/run"):
            guard let name = q["name"], ScriptRuntime.safeName(name) else {
                return .json(["ok": false, "error": "need ?name=xxx.js"], status: 400)
            }
            let u = ScriptRuntime.scriptsDir().appendingPathComponent(name)
            guard let src = try? String(contentsOf: u, encoding: .utf8) else {
                return .json(["ok": false, "error": "没有这个脚本：\(name)"], status: 404)
            }
            return startAndMaybeWait(src: src, name: name,
                                     wait: Double(q["wait"] ?? "0") ?? 0, force: q["force"] == "1")

        case ("GET", "/js/job"):
            guard let j = rt.job(id: q["id"].flatMap { Int($0) }) else {
                return .json(["ok": false, "error": "还没有跑过脚本"], status: 404)
            }
            var s = j.snapshot(since: Int(q["since"] ?? "0") ?? 0)
            s["ok"] = true
            return .json(s)

        case ("POST", "/js/stop"):
            let had = rt.stop()
            return .json(["ok": true, "stopped": had])

        case ("GET", "/js/list"):
            let dir = ScriptRuntime.scriptsDir()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".js") }.sorted()
            return .json(["ok": true, "dir": dir.path, "scripts": names])

        case ("GET", "/js/get"):
            guard let name = q["name"], ScriptRuntime.safeName(name),
                  let d = try? Data(contentsOf: ScriptRuntime.scriptsDir().appendingPathComponent(name)) else {
                return .text("not found", status: 404)
            }
            return .data(d, type: "text/plain; charset=utf-8")

        case ("GET", "/dbg/info"):
            let rr = router
            let script: Any = rt.runningJob.map { j -> Any in ["id": j.id, "name": j.name] } ?? NSNull()
            return .json([
                "ok": true, "version": AppVersion.display,
                "ips": ips, "port": Int(port),
                "script": script,
                "runner": rr?.runner.snapshot() ?? [:],
                "frameAge": rr?.broadcaster.lastFrameAge() ?? -1,
                "ble": rr?.ble.state ?? "-",
                "configLoaded": rr?.cfgStore.cfg != nil,
            ])

        default:
            return .json(["error": "no route", "path": r.path], status: 404)
        }
    }

    private func startAndMaybeWait(src: String, name: String, wait: Double, force: Bool) -> HTTPServer.Response {
        let (job, err) = ScriptRuntime.shared.start(source: src, name: name, force: force)
        guard let j = job else {
            return .json(["ok": false, "error": err], status: 409)
        }
        if wait > 0 {
            let done = j.waitDone(timeout: min(wait, 600))
            var s = j.snapshot()
            s["ok"] = true
            s["finished"] = done
            return .json(s)
        }
        return .json(["ok": true, "id": j.id, "name": j.name, "finished": false])
    }

    // MARK: - 令牌防爆破

    private func lockedFor(_ ip: String) -> Double? {
        failLock.lock(); defer { failLock.unlock() }
        guard let f = fails[ip], f.n >= 5 else { return nil }
        let left = f.until.timeIntervalSinceNow
        if left <= 0 { fails[ip] = nil; return nil }
        return left
    }

    private func noteFail(_ ip: String) {
        failLock.lock(); defer { failLock.unlock() }
        let n = (fails[ip]?.n ?? 0) + 1
        fails[ip] = (n, Date().addingTimeInterval(60))
    }

    private func clearFail(_ ip: String) {
        failLock.lock(); fails[ip] = nil; failLock.unlock()
    }

    // MARK: - 工具

    static func makeToken() -> String {
        let cs = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in cs[Int.random(in: 0..<cs.count)] })
    }

    /// Wi-Fi（en*）和个人热点（bridge*）上的 IPv4
    static func localIPv4s() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            p = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") && !out.contains(ip) { out.append(ip) }
            }
        }
        return out
    }
}

/// 控制台上的一栏：地址 + 令牌 + 开关
struct RemoteDebugBar: View {
    @ObservedObject var rd = RemoteDebug.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("🛰 远程调试").font(.system(size: 12, weight: .semibold))
                Toggle("", isOn: Binding(get: { rd.enabled }, set: { rd.setEnabled($0) }))
                    .labelsHidden()
                    .scaleEffect(0.8)
                Spacer()
                if rd.enabled {
                    Button("刷新") { rd.refreshIPs() }.font(.system(size: 11))
                    Button("换令牌") { rd.regenerateToken() }.font(.system(size: 11))
                }
            }
            if rd.enabled {
                Group {
                    if !rd.running {
                        Text("⛔ 没起来：\(rd.lastError)")
                    } else if rd.ips.isEmpty {
                        Text("⚠️ 没拿到局域网 IP（连上 Wi-Fi 再点刷新）")
                    } else {
                        Text(rd.ips.map { "\($0):\(rd.port)" }.joined(separator: "  "))
                    }
                    Text("令牌 \(rd.token)")
                    if !rd.lastClient.isEmpty { Text("最近连接 \(rd.lastClient)").foregroundColor(.secondary) }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
    }
}
