import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ **LLM 客户端** —— 让**手机自己**调大模型（用户令 2026-10-19）
///
/// # 用户原话（逐字）
/// > 「你试试不用脚本直接把AI接口接入苹果手机里面做控制手机试试倒是我再接入一个账号用里面的token工作，
/// >   然后写成工作流。AI调用工作流应该不是很消耗token」
///
/// > 「干嘛用它ESP32S3 不都是只用执行命令么，而且是AI来执行 **我们的绝对坐标更精准**。
/// >   我们直接把AI接口接入手机 **不需要C口直连**」
///
/// ⇒ 架构定死：**眼/手/脑全在手机上**，⛔ 不依赖 PC、⛔ 不依赖 Mac、⛔ 不换硬件。
///   · 眼 = ReplayKit 录屏帧（已有）
///   · 手 = ESP32 HID **绝对坐标** `Q:x,y`（已有，比 esp32-iphone-agent 的 AssistiveTouch 相对指针更准）
///   · 脑 = 本文件：URLSession 调 OpenAI 兼容接口
///
/// # 为什么必须在 Swift 侧（⛔ 不能在 JS 里发请求）
/// `ScriptRuntime` 用的是**纯 JavaScriptCore**，没有 `fetch` / `XMLHttpRequest`
/// （真机实测 2026-10-19：`typeof fetch = undefined`）⇒ JS 自己发不了网络请求。
/// ⇒ Swift 开一个 `pg.llm(...)` 口，JS 侧一行就能问模型。
///
/// # 省 token 的设计（照用户「写成工作流」的口径）
/// · ⛔ **不做"每帧都问 AI"**——那会把 token 烧穿。
/// · ✅ 工作流（确定性腿序）先跑；**只在全部失败时**问一次，且问的是**选择题**
///   （"现在是 A/B/C 哪一种页面？"），不是开放式对话。
/// · ✅ `maxTokens` 默认 256；`json:true` 时只要 JSON，方便工作流解析。
///
/// # 配置来源（⛔ 不用环境变量 —— 手机上没法设）
/// `Documents/pgconfig/llm.json`：
/// ```json
/// { "baseURL": "https://api.deepseek.com/v1",
///   "model":   "deepseek-chat",
///   "apiKey":  "sk-...",
///   "timeout": 30 }
/// ```
/// ⛔ 缺文件 / 缺 key ⇒ `configured == false`，JS 侧**如实回退**到确定性腿。
///
/// # 真机实测（2026-10-19，PC 侧用同一个 key 验过）
/// · `deepseek-chat` 实际后端是 `deepseek-flash`
/// · **支持看图**：喂 64×64 纯红图 + "What color is this image?" ⇒ 回 `Red` ✅
///   ⇒ 这就是"AI 直接看屏幕"的可行性证据（⛔ 不是推测）
final class LLMClient {

    static let shared = LLMClient()
    private init() {}

    // MARK: - 配置

    private var baseURL = ""
    private var apiKey = ""
    private var model = ""
    private var timeoutS: Double = 30
    private var extraHeaders: [String: String] = [:]

    private(set) var configured = false
    private(set) var lastError = ""
    private var loaded = false

    var providerName: String {
        if baseURL.contains("deepseek") { return "deepseek" }
        if baseURL.contains("bigmodel") || baseURL.contains("zhipu") { return "zhipu" }
        return baseURL.isEmpty ? "-" : baseURL
    }
    var modelName: String { model }

    /// 配置路径（与 config.json 同目录，便于一起推送）
    static func configPath() -> URL {
        ConfigStore.configDir().appendingPathComponent("llm.json")
    }

    /// 懒加载 `llm.json`
    /// ⛔ 失败**不抛**（上层要能"没有 AI 也照跑"）
    func loadIfNeeded() {
        if loaded { return }
        loaded = true
        let p = LLMClient.configPath()
        guard let d = try? Data(contentsOf: p),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            lastError = "没有 llm.json（\(p.path)）"
            NSLog("PGAgent §3180 LLM：%@", lastError)
            return
        }
        baseURL = ((o["baseURL"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        apiKey = (o["apiKey"] as? String) ?? ""
        model = (o["model"] as? String) ?? ""
        if let t = o["timeout"] as? Double { timeoutS = max(5, min(120, t)) }
        if let h = o["headers"] as? [String: String] { extraHeaders = h }
        guard !baseURL.isEmpty, !model.isEmpty else {
            lastError = "llm.json 缺 baseURL 或 model"
            NSLog("PGAgent §3180 LLM：%@", lastError)
            return
        }
        configured = true
        lastError = ""
        NSLog("PGAgent §3180 LLM 已配置：%@ model=%@ key=%@",
              providerName, model, apiKey.isEmpty ? "(无)" : "有")
    }

    /// 重新加载（推了新配置之后调）
    func reload() { loaded = false; configured = false; loadIfNeeded() }

    // MARK: - 调用

    struct Reply { var text: String; var model: String }

    /// 同步调用（内部用信号量等 URLSession 回调）—— 与 `pg.*` 其它原语一致
    ///
    /// - Parameters:
    ///   - prompt: 用户内容
    ///   - system: 系统提示（nil = 不传）
    ///   - image: JPEG/PNG 数据；非 nil ⇒ 走**视觉**格式（`image_url` + base64 data URI）
    ///   - maxTokens: 默认 256（省 token）
    ///   - json: true ⇒ 追加"只回 JSON"约束 + `response_format`
    func complete(prompt: String, system: String? = nil, image: Data? = nil,
                  maxTokens: Int = 256, json: Bool = false) -> Reply? {
        loadIfNeeded()
        guard configured, let url = URL(string: baseURL + "/chat/completions") else {
            if lastError.isEmpty { lastError = "LLM 未配置" }
            return nil
        }

        var sys = system ?? ""
        if json {
            let hint = "Reply with ONE JSON object and nothing else (no markdown fences, no prose)."
            sys = sys.isEmpty ? hint : (sys + "\n\n" + hint)
        }

        // 组装 content
        var userContent: Any
        if let img = image {
            let b64 = img.base64EncodedString()
            // ⚠️ 图片格式：按前两字节判 PNG/JPEG（真机帧是 JPEG）
            let mime = img.count > 2 && img[0] == 0x89 && img[1] == 0x50 ? "image/png" : "image/jpeg"
            userContent = [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(b64)"]],
            ]
        } else {
            userContent = prompt
        }

        var msgs: [[String: Any]] = []
        if !sys.isEmpty { msgs.append(["role": "system", "content": sys]) }
        msgs.append(["role": "user", "content": userContent])

        var body: [String: Any] = [
            "model": model,
            "messages": msgs,
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": false,
        ]
        if json { body["response_format"] = ["type": "json_object"] }

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            lastError = "请求体序列化失败"
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutS
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = payload

        var out: Reply? = nil
        var errText = ""
        let sem = DispatchSemaphore(value: 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutS
        cfg.timeoutIntervalForResource = timeoutS + 10
        let session = URLSession(configuration: cfg)
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { errText = "网络错误：\(err.localizedDescription)"; return }
            guard let http = resp as? HTTPURLResponse else { errText = "没有 HTTP 响应"; return }
            guard let data = data else { errText = "响应为空"; return }
            if http.statusCode != 200 {
                let s = String(decoding: data, as: UTF8.self)
                errText = "HTTP \(http.statusCode)：\(s.prefix(300))"
                return
            }
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = o["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any] else {
                errText = "响应格式不是 OpenAI 兼容格式"
                return
            }
            // ⚠️ 推理型模型可能只给 reasoning_content、content 为空（PhoneAgent 也踩过）
            let content = (msg["content"] as? String) ?? ""
            let used = (o["model"] as? String) ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errText = "模型回空内容（finish_reason=\(first["finish_reason"] ?? "?")）"
                out = Reply(text: "", model: used)
                return
            }
            out = Reply(text: content, model: used)
        }
        task.resume()
        // ⛔ 同步语义：最多等到 timeoutS + 5
        if sem.wait(timeout: .now() + timeoutS + 5) == .timedOut {
            task.cancel()
            lastError = "AI 调用超时（\(Int(timeoutS))s）"
            return nil
        }
        if let r = out {
            if r.text.isEmpty {
                lastError = errText.isEmpty ? "空回复" : errText
                return nil
            }
            lastError = ""
            return r
        }
        lastError = errText.isEmpty ? "未知错误" : errText
        NSLog("PGAgent §3180 LLM 失败：%@", lastError)
        return nil
    }
}
