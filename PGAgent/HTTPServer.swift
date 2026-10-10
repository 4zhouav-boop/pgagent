import Foundation
import Network

/// 极简 HTTP/1.1 服务器 —— 只绑 `127.0.0.1`，供主机经 USB 隧道（usbmux forward）调用。
///
/// ⭐ 为什么这样设计（`_note_1801` §4）：
///   - 主机侧：`pymobiledevice3 usbmux forward 8899 8899 --serial <UDID>`
///   - 之后主机 `curl http://127.0.0.1:8899/...` 就能直接调 App
///   - ⛔ 不需要 Wi-Fi、⛔ 不需要开发者模式、⛔ 不需要 Mac
///
/// ⛔ 只绑回环：不暴露到局域网（安全）
final class HTTPServer {

    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()
    }

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
                NSLog("PGAgent HTTP 服务已启动 127.0.0.1:%d", Int(p))
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
        // ⭐ 只绑回环 ⇒ 局域网访问不到
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let l = try NWListener(using: params)
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
        case 404: reason = "Not Found"
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
    private func handleAsync(_ conn: NWConnection, _ req: Request) {
        let h = onRequest
        DispatchQueue.global(qos: .userInitiated).async {
            let resp = h?(req) ?? Response.text("no handler", status: 500)
            self.respond(conn, resp)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        live.removeAll()
        lock.unlock()
    }
}
