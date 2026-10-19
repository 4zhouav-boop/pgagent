import Foundation
import Network

/// 极简 HTTP/1.1 服务器 —— 只绑 `127.0.0.1`，供主机经 USB 隧道（usbmux forward）调用。
///
/// ⭐ 为什么这样设计（`_note_1801` §4）：
///   - 主机侧：`pymobiledevice3 usbmux forward 8899 8899 --serial <UDID>`
///   - 之后主机 `curl http://127.0.0.1:8899/...` 就能直接调 App
///   - ⛔ 不需要 Wi-Fi、⛔ 不需要开发者模式、⛔ 不需要 Mac
///
/// ⛔ 默认只绑回环：不暴露到局域网（安全）
///
/// ⭐ v0.11.0：加了 `loopbackOnly = false` 模式，给「远程调试」单独起的第二个实例用
///    （`RemoteDebug.swift`，端口 8900，**必须带令牌**）。
///    8899 这个实例**行为一字不变**（扩展往 127.0.0.1:8899/frame 推帧，不能动）。
final class HTTPServer {

    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()
        /// 对端地址（`127.0.0.1` / `192.168.x.x`）—— 远程调试用来区分本机与局域网
        var remoteHost = ""
    }

    /// `true`（默认）= 只绑 127.0.0.1；`false` = 绑所有网卡（局域网可达）
    var loopbackOnly = true
    /// 非空 ⇒ 用 Bonjour 广播（`_pgagent._tcp`），电脑端可自动发现
    var bonjourName: String?
    /// 单个请求体上限（防止被灌爆内存）
    var maxBody = 16 * 1024 * 1024

    struct Response {
        var status = 200
        var contentType = "application/json; charset=utf-8"
        var body = Data()
        /// ⭐ 额外的响应头（如 `Content-Disposition` —— Safari 下载要用）
        var extraHeaders: [String: String] = [:]

        static func json(_ obj: Any, status: Int = 200) -> Response {
            var r = Response()
            r.status = status
            if let d = try? JSONSerialization.data(withJSONObject: obj,
                                                   options: [.prettyPrinted, .sortedKeys]) {
                r.body = d
            } else {
                r.body = Data("{}".utf8)
            }
            return r
        }

        static func text(_ s: String, status: Int = 200) -> Response {
            var r = Response()
            r.status = status
            r.contentType = "text/plain; charset=utf-8"
            r.body = Data(s.utf8)
            return r
        }

        static func data(_ d: Data, type: String = "application/octet-stream",
                         extraHeaders: [String: String] = [:]) -> Response {
            var r = Response()
            r.contentType = type
            r.body = d
            r.extraHeaders = extraHeaders
            return r
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pgagent.http", attributes: .concurrent)
    private var live: Set<ObjectIdentifier> = []
    private let lock = NSLock()

    private(set) var port: UInt16 = 0
    private(set) var lastError = ""

    /// 每个请求都会调它（在后台线程）
    var onRequest: ((Request) -> Response)?

    func start(preferredPort: UInt16 = 8899) {
        // 依次尝试 preferredPort, preferredPort+1, ... 最多 20 个
        for offset in 0..<20 {
            let p = preferredPort + UInt16(offset)
            do {
                try startOn(p)
                port = p
                lastError = ""
                NSLog("PGAgent HTTP 服务已启动 %@:%d", loopbackOnly ? "127.0.0.1" : "0.0.0.0", Int(p))
                return
            } catch {
                lastError = "port \(p): \(error)"
            }
        }
        NSLog("PGAgent HTTP 启动失败: %@", lastError)
    }

    private func startOn(_ p: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: p) else {
            throw NSError(domain: "pg", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l: NWListener
        if loopbackOnly {
            // ⭐ 只绑回环 ⇒ 局域网访问不到
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            l = try NWListener(using: params)
        } else {
            // ⭐ 远程调试：绑所有网卡（首次会弹「本地网络」权限，必须点允许）
            l = try NWListener(using: params, on: nwPort)
            if let n = bonjourName {
                l.service = NWListener.Service(name: n, type: "_pgagent._tcp")
            }
        }
        l.stateUpdateHandler = { st in
            if case .failed(let e) = st { NSLog("PGAgent HTTP listener failed: %@", "\(e)") }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        lock.lock(); live.insert(key); lock.unlock()

        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled:
                self?.drop(key)
            default:
                break
            }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func drop(_ key: ObjectIdentifier) {
        lock.lock(); live.remove(key); lock.unlock()
    }

    /// 读到 \r\n\r\n 为止；若有 Content-Length 再读 body
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isDone, err in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }

            if err != nil { conn.cancel(); return }

            if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: 0..<sep.lowerBound)
                let rest = buf.subdata(in: sep.upperBound..<buf.count)
                let headStr = String(decoding: head, as: UTF8.self)

                var lines = headStr.components(separatedBy: "\r\n")
                let reqLine = lines.isEmpty ? "" : lines.removeFirst()
                var headers: [String: String] = [:]
                for l in lines {
                    if let i = l.firstIndex(of: ":") {
                        let k = String(l[l.startIndex..<i]).trimmingCharacters(in: .whitespaces).lowercased()
                        let v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let want = Int(headers["content-length"] ?? "0") ?? 0
                if want < 0 || want > self.maxBody { conn.cancel(); return }
                if rest.count < want {
                    // body 还没收完
                    self.readRequest(conn, buffer: buf)
                    return
                }
                var r = Request()
                let parts = reqLine.split(separator: " ")
                r.method = parts.count > 0 ? String(parts[0]) : "GET"
                let target = parts.count > 1 ? String(parts[1]) : "/"
                if let q = target.firstIndex(of: "?") {
                    r.path = String(target[target.startIndex..<q])
                    let qs = String(target[target.index(after: q)...])
                    for pair in qs.split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 {
                            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                            let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                            r.query[k] = v
                        } else if kv.count == 1 {
                            r.query[String(kv[0])] = ""
                        }
                    }
                } else {
                    r.path = target
                }
                r.headers = headers
                r.body = rest.prefix(want)
                r.remoteHost = Self.hostString(conn.endpoint)
                // ⭐ 异步处理（慢请求不堵队列）
                self.handleAsync(conn, r)
                _ = isDone
                return
            }

            if buf.count > 256 * 1024 { conn.cancel(); return }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, _ r: Response) {
        let reason: String
        switch r.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 500: reason = "Internal Server Error"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        // ⭐ 额外响应头（如 Content-Disposition —— Safari 下载要用）
        for (k, v) in r.extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// ⭐ 把 handler 放到**独立队列**执行 —— 一个慢请求（如 Vision OCR 几秒）
    ///    不会堵住后面的请求。
    ///
    /// # ⭐⭐⭐ §3468 后台保活：每个请求套 `beginBackgroundTask`
    ///
    /// ## 为什么（用户令 2026-10-19 23:52）
    /// > 「**保活一定需要这样？ 我不信了。开源项目里面没有别的解决方案。
    /// >   而且你这个做法就是因噎废食。调试阶段都搞不好一个活的通道**」
    ///
    /// ## 根因（真机实测）
    /// ```
    /// 全项目搜 beginBackgroundTask ⇒ ⛔ 一个都没有
    /// ```
    /// iOS 的规则：App 进后台后，**网络监听（NWListener）会被系统挂起**，
    /// 即使进程本身还活着（静音音频保活能让进程活着），新连接也进不来。
    ///
    /// ## 解法（照 `swisspol/GCDWebServer` 的做法，业界标准）
    /// GCDWebServer README 原文：
    /// > `GCDWebServer begins a background task whenever the first HTTP connection is opened
    /// >  and ends it only when the last one is closed`
    ///
    /// 也就是：**请求一进来就申请后台任务，响应发完就释放**。
    /// 这样在处理请求的那一小段时间里，App 不会被挂起 ⇒ 响应能真的发出去。
    ///
    /// ⚠️ 注意：`beginBackgroundTask` **不是无限期**（约 30 秒），
    /// 它是"保证这个请求能做完"，不是"让 App 永久后台运行"。
    /// 长时间无人访问时仍可能被挂起 —— 但**一旦有请求进来，会先唤醒再执行**，
    /// 这已经足够"调试通道一直活着"（用户的核心诉求）。
    private func handleAsync(_ conn: NWConnection, _ req: Request) {
        let h = onRequest
        // ⭐ 申请后台任务（主线程调用，Apple 要求）
        let bgTask = BackgroundTask.begin(name: "http-\(req.method) \(req.path)")
        DispatchQueue.global(qos: .userInitiated).async {
            let resp = h?(req) ?? Response.text("no handler", status: 500)
            self.respond(conn, resp)
            // ⭐ 响应发完就释放（不等连接 close，避免泄漏）
            BackgroundTask.end(bgTask)
        }
    }

    /// 把 `NWEndpoint` 变成纯 IP 字符串（去掉 `%en0` 之类的接口后缀）
    static func hostString(_ ep: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = ep else { return "" }
        var s: String
        switch host {
        case .ipv4(let a): s = "\(a)"
        case .ipv6(let a): s = "\(a)"
        case .name(let n, _): s = n
        @unknown default: s = "\(host)"
        }
        if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }
        // 双栈监听时 IPv4 客户端会显示成 `::ffff:192.168.1.5`
        if s.lowercased().hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        live.removeAll()
        lock.unlock()
    }
}
