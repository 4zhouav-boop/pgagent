import Foundation
import UIKit
import JavaScriptCore

/// ⭐⭐⭐ v0.11.0 **脚本运行时**（JavaScriptCore，系统自带，⛔ 不需要 JIT / 不需要额外库）
///
/// ## 为什么要它
/// 签名器坏了、爱思签名时好时坏 ⇒ **每改一行 Swift 就要重签重装** = 测试时间全耗在装包上。
/// ⇒ 把「会变的流程逻辑」挪到 **JS 脚本**：电脑端经局域网推脚本、当场在手机上跑、实时回日志。
///    **改流程 ⇒ 只推脚本，⛔ 不重签。** 只有动到 Swift 原语（`pg.*` 本身）时才需要重装。
///
/// ## 用法（电脑端 `_dev/pgdbg.py`）
/// ```
/// py _dev/pgdbg.py eval "pg.log(pg.page())"
/// py _dev/pgdbg.py run  _dev/js/hello.js
/// py _dev/pgdbg.py watch _dev/js/adbox_try.js     ← 存盘即重跑
/// ```
///
/// ## 设计要点
/// · **一次只跑一个脚本**（两个脚本同时点屏幕必乱）；Runner 在跑时默认拒绝（`force=1` 才放行）。
/// · `pg.*` 全部是**同步阻塞**调用（与 Runner 写法一致），⛔ 没有 Promise。
/// · 停止是**协作式**：`pg.sleep/pg.check/任何 pg.* 调用` 处检查停止标志 ⇒
///   ⚠️ 纯 JS 死循环（里面一个 `pg.*` 都不调）停不下来 —— 循环里记得 `pg.sleep()`。
/// · 坐标一律是**基准 451×977**（与 config.json / `/click` / `/swipe` 同一套）。
final class ScriptJob {
    let id: Int
    let name: String
    let startedAt = Date()

    private let lock = NSLock()
    private var _logs: [String] = []
    private var _logBase = 0          // 被裁掉的前缀行数（`since` 偏移要加上它）
    private var _state = "running"    // running / done / error / stopped
    private var _result: Any = NSNull()
    private var _error = ""
    private var _endedAt: Date?
    private var _cancel = false
    private let doneGroup = DispatchGroup()

    static let maxLogLines = 4000

    init(id: Int, name: String) {
        self.id = id
        self.name = name
        doneGroup.enter()
    }

    func append(_ s: String) {
        let t = ScriptJob.ts.string(from: Date())
        lock.lock()
        _logs.append("\(t) \(s)")
        if _logs.count > Self.maxLogLines {
            let cut = _logs.count - Self.maxLogLines
            _logs.removeFirst(cut)
            _logBase += cut
        }
        lock.unlock()
    }

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancel }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _state == "running" }

    func cancel() { lock.lock(); _cancel = true; lock.unlock() }

    func finish(state: String, result: Any, error: String) {
        lock.lock()
        guard _state == "running" else { lock.unlock(); return }
        _state = state
        _result = result
        _error = error
        _endedAt = Date()
        lock.unlock()
        doneGroup.leave()
    }

    /// 阻塞等它结束；返回 `true` = 已结束
    func waitDone(timeout: Double) -> Bool {
        doneGroup.wait(timeout: .now() + timeout) == .success
    }

    /// `since` = 调用方已经拿到的行号（下一次从这里接着拿）
    func snapshot(since: Int = 0) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let from = max(since, _logBase)
        let idx = from - _logBase
        let lines = idx < _logs.count ? Array(_logs[idx...]) : []
        let end = _endedAt ?? Date()
        return [
            "id": id, "name": name, "state": _state,
            "result": _result, "error": _error,
            "elapsed": Double(round(end.timeIntervalSince(startedAt) * 10) / 10),
            "logs": lines, "next": _logBase + _logs.count,
        ]
    }

    static let ts: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

final class ScriptRuntime {

    static let shared = ScriptRuntime()

    private weak var router: APIRouter?
    private let lock = NSLock()
    private var current: ScriptJob?
    private var last: ScriptJob?
    private var nextId = 1

    func attach(router: APIRouter) { self.router = router }

    // MARK: - 脚本目录（Documents/scripts）

    static func scriptsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("scripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 只允许 `xxx.js`（⛔ 不许带目录、⛔ 不许 `..`）
    static func safeName(_ n: String) -> Bool {
        !n.isEmpty && n.hasSuffix(".js") && !n.contains("/") && !n.contains("\\") && !n.contains("..")
    }

    // MARK: - 作业管理

    func job(id: Int?) -> ScriptJob? {
        lock.lock(); defer { lock.unlock() }
        if let id = id {
            if current?.id == id { return current }
            if last?.id == id { return last }
            return nil
        }
        return current ?? last
    }

    var runningJob: ScriptJob? {
        lock.lock(); defer { lock.unlock() }
        return (current?.isRunning ?? false) ? current : nil
    }

    func stop() -> Bool {
        guard let j = runningJob else { return false }
        j.cancel()
        return true
    }

    /// 起一个脚本。返回 `(job, "")` 或 `(nil, 原因)`。
    func start(source: String, name: String, force: Bool) -> (ScriptJob?, String) {
        guard let rt = router else { return (nil, "router 未就绪") }

        if !force, let running = rt.runner.snapshot()["running"] as? Bool, running {
            return (nil, "Runner 正在跑（先 /runstop，或带 force=1）")
        }

        lock.lock()
        if let c = current, c.isRunning {
            lock.unlock()
            return (nil, "已有脚本在跑：#\(c.id) \(c.name)（先 /js/stop）")
        }
        let j = ScriptJob(id: nextId, name: name)
        nextId += 1
        if let c = current { last = c }
        current = j
        lock.unlock()

        // ⭐ 独立线程 + 大栈：JSContext 只能在创建它的线程用；JSC 递归吃栈
        let th = Thread { [weak self] in
            self?.execute(j, source: source, rt: rt)
        }
        th.stackSize = 8 << 20
        th.name = "pg.js.\(j.id)"
        th.qualityOfService = .userInitiated
        th.start()
        rt.log.log("§js ▶️ #\(j.id) \(name) 开始（\(source.utf8.count)B）")
        return (j, "")
    }

    // MARK: - 执行

    private func execute(_ job: ScriptJob, source: String, rt: APIRouter) {
        guard let ctx = JSContext(virtualMachine: JSVirtualMachine()) else {
            job.finish(state: "error", result: NSNull(), error: "JSContext 创建失败")
            return
        }
        ctx.name = "pg:\(job.name)"

        var jsError = ""
        ctx.exceptionHandler = { _, ex in
            guard let ex = ex else { return }
            let msg = ex.toString() ?? "?"
            let line = ex.objectForKeyedSubscript("line")?.toInt32() ?? 0
            let stack = ex.objectForKeyedSubscript("stack")?.toString() ?? ""
            var s = "\(msg)（第 \(line) 行）"
            if !stack.isEmpty && stack != "undefined" { s += "\n\(stack)" }
            jsError = s
        }

        let bridge = PGBridge(job: job, rt: rt)
        ctx.setObject(bridge.makeObject(in: ctx), forKeyedSubscript: "pg" as NSString)
        ctx.evaluateScript(Self.prelude, withSourceURL: URL(string: "pg://prelude.js"))

        let r = ctx.evaluateScript(source, withSourceURL: URL(string: "pg://\(job.name)"))

        let state: String
        if job.cancelled { state = "stopped" }
        else if !jsError.isEmpty { state = "error" }
        else { state = "done" }

        var result: Any = NSNull()
        if let r = r, !r.isUndefined, !r.isNull {
            result = Self.jsonable(r.toObject())
        }
        if !jsError.isEmpty { job.append("⛔ \(jsError)") }
        job.finish(state: state, result: result, error: jsError)
        rt.log.log("§js ⏹ #\(job.id) \(job.name) \(state)" + (jsError.isEmpty ? "" : "：\(jsError.prefix(200))"))
        ctx.exceptionHandler = nil
    }

    static func jsonable(_ x: Any?) -> Any {
        guard let x = x else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": x]) { return x }
        return String(describing: x)
    }

    /// 纯 JS 写的小工具（不需要重签就能改的部分尽量放这里 / 放 include 的脚本里）
    static let prelude = """
    var console = { log: function(){ pg.log.apply(null, arguments); },
                    error: function(){ pg.log.apply(null, ['⛔'].concat([].slice.call(arguments))); } };
    var print = console.log;
    pg.until = function(fn, timeout, every){
      timeout = timeout || 10; every = every || 0.5;
      var t0 = pg.now();
      while (pg.now() - t0 < timeout) { var v = fn(); if (v) return v; pg.sleep(every); }
      return null;
    };
    pg.findText = function(text, roi){
      var items = pg.ocr(roi);
      for (var i = 0; i < items.length; i++) if (items[i].text.indexOf(text) >= 0) return items[i];
      return null;
    };
    pg.tapText = function(text, roi){
      var h = pg.findText(text, roi);
      if (!h) { pg.log('tapText 没找到「' + text + '」'); return false; }
      pg.tap(h.cx, h.cy); return true;
    };
    pg.waitPage = function(name, timeout){
      return !!pg.until(function(){ pg.waitFrame(4); return pg.page() === name; }, timeout || 10, 0.2);
    };
    pg.assert = function(c, msg){ if (!c) throw new Error('断言失败: ' + (msg || '')); };
    """
}

/// `pg` 对象的 Swift 侧实现。所有方法都在脚本线程上同步执行。
private final class PGBridge {

    let job: ScriptJob
    let rt: APIRouter

    private var nav: Navigator?
    private var navStamp: Date?

    init(job: ScriptJob, rt: APIRouter) {
        self.job = job
        self.rt = rt
    }

    // MARK: 小工具

    private var bw: Double { rt.cfgStore.cfg?.settings?.base_w ?? 451 }
    private var bh: Double { rt.cfgStore.cfg?.settings?.base_h ?? 977 }
    private var yf: Double { rt.cfgStore.cfg?.settings?.y_fix ?? 4 }

    /// 抛 JS 异常（脚本里可以 try/catch）
    @discardableResult
    private func fail(_ msg: String) -> JSValue {
        let c = JSContext.current()
        c?.exception = JSValue(newErrorFromMessage: msg, in: c)
        return JSValue(undefinedIn: c)
    }

    /// 停止检查：被 /js/stop 后，下一次任何 pg.* 调用都会抛「已停止」
    private func stopped() -> Bool {
        if job.cancelled { fail("已停止（/js/stop）"); return true }
        return false
    }

    private func val(_ x: Any?) -> JSValue {
        let c = JSContext.current()
        guard let x = x else { return JSValue(nullIn: c) }
        return JSValue(object: x, in: c)
    }

    private func num(_ v: JSValue?, _ d: Double) -> Double {
        guard let v = v, v.isNumber else { return d }
        return v.toDouble()
    }

    private func rect(_ v: JSValue?) -> CGRect? {
        guard let v = v, v.isArray, let a = v.toArray() as? [NSNumber], a.count == 4 else { return nil }
        return CGRect(x: a[0].doubleValue, y: a[1].doubleValue,
                      width: a[2].doubleValue, height: a[3].doubleValue)
    }

    private func image() -> UIImage? {
        guard let d = rt.broadcaster.lastFrame else { return nil }
        return UIImage(data: d)
    }

    private func navigator() -> Navigator? {
        guard let c = rt.cfgStore.cfg else { return nil }
        // 配置被 /reload 过 ⇒ 重建（模板缓存、页面图都跟着换）
        if nav == nil || navStamp != rt.cfgStore.loadedAt {
            let rec = Recognizer(templatesDir: ConfigStore.templatesDir())
            nav = Navigator(cfg: c, rec: rec, ble: rt.ble) { [weak self] s in self?.job.append(s) }
            navStamp = rt.cfgStore.loadedAt
        }
        return nav
    }

    private func hitDict(_ h: Recognizer.Hit) -> [String: Any] {
        ["name": h.name, "score": Double(round(h.score * 1000) / 1000), "ev": h.evidence,
         "x": Double(h.rect.minX), "y": Double(h.rect.minY),
         "w": Double(h.rect.width), "h": Double(h.rect.height),
         "cx": Double(h.rect.midX), "cy": Double(h.rect.midY)]
    }

    private func sleepS(_ s: Double) -> Bool {
        var left = max(0, s)
        while left > 0 {
            if job.cancelled { return false }
            let step = min(0.1, left)
            Thread.sleep(forTimeInterval: step)
            left -= step
        }
        return !job.cancelled
    }

    private func jsString(_ v: JSValue) -> String {
        if v.isString { return v.toString() }
        if v.isObject, !v.isNull,
           let json = JSContext.current()?.objectForKeyedSubscript("JSON"),
           let s = json.invokeMethod("stringify", withArguments: [v]), s.isString {
            return s.toString()
        }
        return v.toString() ?? "?"
    }

    // MARK: 组装 pg 对象

    func makeObject(in ctx: JSContext) -> JSValue {
        let pg = JSValue(newObjectIn: ctx)!
        func def(_ name: String, _ block: Any) {
            pg.setObject(block, forKeyedSubscript: name as NSString)
        }

        // ── 日志 / 时间 / 停止 ──
        let fLog: @convention(block) () -> Void = {
            let args = (JSContext.currentArguments() as? [JSValue]) ?? []
            let s = args.map { self.jsString($0) }.joined(separator: " ")
            self.job.append(s)
            self.rt.log.log("§js \(s)")
        }
        def("log", unsafeBitCast(fLog, to: AnyObject.self))

        let fNow: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
        def("now", unsafeBitCast(fNow, to: AnyObject.self))

        let fSleep: @convention(block) (JSValue) -> Bool = { v in
            if !self.sleepS(self.num(v, 1)) { self.fail("已停止（/js/stop）"); return false }
            return true
        }
        def("sleep", unsafeBitCast(fSleep, to: AnyObject.self))

        let fCheck: @convention(block) () -> Bool = { !self.stopped() }
        def("check", unsafeBitCast(fCheck, to: AnyObject.self))

        // ── 调任意现有 HTTP 接口（进程内直调，⛔ 不走网络）──
        //    pg.api('GET', '/status') / pg.api('POST', '/settings', null, {feed_stay_hv: 20})
        let fApi: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            m, p, q, b in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard p.isString else { return self.fail("pg.api(method, path, query?, body?)：path 必须是字符串") }
            var req = HTTPServer.Request()
            req.method = m.isString ? m.toString().uppercased() : "GET"
            req.path = p.toString()
            req.remoteHost = "script"
            if req.path.hasPrefix("/js/") { return self.fail("脚本里不能再调 /js/*") }
            if q.isObject, let d = q.toDictionary() {
                for (k, v) in d { req.query["\(k)"] = "\(v)" }
            }
            if b.isString {
                req.body = Data(b.toString().utf8)
            } else if b.isObject, !b.isNull, let o = b.toObject(),
                      JSONSerialization.isValidJSONObject(o),
                      let d = try? JSONSerialization.data(withJSONObject: o) {
                req.body = d
            }
            let resp = self.rt.handle(req)
            if resp.contentType.hasPrefix("application/json"),
               let o = try? JSONSerialization.jsonObject(with: resp.body, options: [.fragmentsAllowed]) {
                if var d = o as? [String: Any] { d["_status"] = resp.status; return self.val(d) }
                return self.val(o)
            }
            if resp.contentType.hasPrefix("text/") {
                return self.val(["_status": resp.status,
                                 "text": String(decoding: resp.body, as: UTF8.self)])
            }
            return self.val(["_status": resp.status, "contentType": resp.contentType,
                             "bytes": resp.body.count])
        }
        def("api", unsafeBitCast(fApi, to: AnyObject.self))

        // ── 眼：帧 ──
        let fFrame: @convention(block) () -> JSValue = {
            guard let d = self.rt.broadcaster.lastFrame else {
                return self.val(["ok": false, "error": "还没有帧（先开录屏）"])
            }
            let im = UIImage(data: d)
            return self.val(["ok": true, "bytes": d.count,
                             "age": self.rt.broadcaster.lastFrameAge() ?? -1,
                             "w": Double(im?.size.width ?? 0) * Double(im?.scale ?? 1),
                             "h": Double(im?.size.height ?? 0) * Double(im?.scale ?? 1)])
        }
        def("frame", unsafeBitCast(fFrame, to: AnyObject.self))

        // 等一帧「比调用时刻更新」的画面；返回 true/false
        let fWaitFrame: @convention(block) (JSValue) -> Bool = { v in
            let timeout = self.num(v, 6)
            let t0 = Date()
            while Date().timeIntervalSince(t0) < timeout {
                if self.stopped() { return false }
                if let a = self.rt.broadcaster.lastFrameAge(), a < Date().timeIntervalSince(t0) { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        }
        def("waitFrame", unsafeBitCast(fWaitFrame, to: AnyObject.self))

        let fSaveFrame: @convention(block) (JSValue) -> JSValue = { v in
            guard let d = self.rt.broadcaster.lastFrame else { return self.fail("还没有帧") }
            let name = v.isString ? v.toString()! : "js_\(Int(Date().timeIntervalSince1970)).jpg"
            if name.contains("..") { return self.fail("bad name") }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            do { try d.write(to: docs.appendingPathComponent(name)) } catch { return self.fail("\(error)") }
            return self.val(name)
        }
        def("saveFrame", unsafeBitCast(fSaveFrame, to: AnyObject.self))

        // ── 识别 ──
        let fPage: @convention(block) () -> JSValue = {
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard let nav = self.navigator() else { return self.fail("配置未加载") }
            guard let im = self.image() else { return self.fail("还没有帧") }
            return self.val(nav.pageHere(im))
        }
        def("page", unsafeBitCast(fPage, to: AnyObject.self))

        let fDetect: @convention(block) (JSValue) -> JSValue = { v in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard v.isString else { return self.fail("pg.detect(元素名)") }
            guard let nav = self.navigator() else { return self.fail("配置未加载") }
            guard let im = self.image() else { return self.fail("还没有帧") }
            guard let h = nav.detect(v.toString(), img: im) else { return self.val(nil) }
            return self.val(self.hitDict(h))
        }
        def("detect", unsafeBitCast(fDetect, to: AnyObject.self))

        let fDetectAll: @convention(block) () -> JSValue = {
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard let nav = self.navigator(), let c = self.rt.cfgStore.cfg else { return self.fail("配置未加载") }
            guard let im = self.image() else { return self.fail("还没有帧") }
            var out: [[String: Any]] = []
            for n in c.elements.keys.sorted() {
                if let h = nav.detect(n, img: im) { out.append(self.hitDict(h)) }
            }
            return self.val(out)
        }
        def("detectAll", unsafeBitCast(fDetectAll, to: AnyObject.self))

        // pg.ocr() 整屏；pg.ocr([x,y,w,h]) 只认这块（快很多）；第二参数 = 最低置信度
        let fOcr: @convention(block) (JSValue, JSValue) -> JSValue = { r, mc in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard let nav = self.navigator() else { return self.fail("配置未加载") }
            guard let im = self.image() else { return self.fail("还没有帧") }
            let minC = self.num(mc, 0.3)
            let items: [(String, CGRect, Double)]
            if let roi = self.rect(r) {
                items = nav.rec.ocrRegion(im, rect: roi, minConfidence: minC)
            } else {
                items = nav.rec.ocr(im, minConfidence: minC)
            }
            return self.val(items.map { (t, rr, c) -> [String: Any] in
                ["text": t, "conf": c,
                 "x": Double(rr.minX), "y": Double(rr.minY),
                 "w": Double(rr.width), "h": Double(rr.height),
                 "cx": Double(rr.midX), "cy": Double(rr.midY)]
            })
        }
        def("ocr", unsafeBitCast(fOcr, to: AnyObject.self))

        // ── 手：点 / 滑 / 原始命令（全部走 ESP32）──
        let fTap: @convention(block) (JSValue, JSValue, JSValue) -> Bool = { x, y, at in
            if self.stopped() { return false }
            guard x.isNumber, y.isNumber else { self.fail("pg.tap(x, y)"); return false }
            guard let nav = self.navigator() else { self.fail("配置未加载"); return false }
            let ok = nav.tapPoint(x.toDouble(), y.toDouble(), atomic: at.isBoolean && at.toBool())
            self.job.append("   §tap @(\(Int(x.toDouble())),\(Int(y.toDouble())))")
            return ok
        }
        def("tap", unsafeBitCast(fTap, to: AnyObject.self))

        let fTapEl: @convention(block) (JSValue, JSValue) -> Bool = { v, at in
            if self.stopped() { return false }
            guard v.isString else { self.fail("pg.tapEl(元素名)"); return false }
            guard let nav = self.navigator() else { self.fail("配置未加载"); return false }
            guard let im = self.image() else { self.fail("还没有帧"); return false }
            return nav.tap(v.toString(), img: im, atomic: at.isBoolean && at.toBool())
        }
        def("tapEl", unsafeBitCast(fTapEl, to: AnyObject.self))

        let fSwipe: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> Bool = {
            x1, y1, x2, y2, ms in
            if self.stopped() { return false }
            guard x1.isNumber, y1.isNumber, x2.isNumber, y2.isNumber else {
                self.fail("pg.swipe(x1, y1, x2, y2, ms?)"); return false
            }
            let t = Int(self.num(ms, 220))
            let speed: BLEController.SwipeSpeed = t <= 120 ? .fast : (t >= 1000 ? .slow : .mid)
            let cmd = BLEController.swipe(x1: x1.toDouble(), y1: y1.toDouble(),
                                          x2: x2.toDouble(), y2: y2.toDouble(),
                                          speed: speed, baseW: self.bw, baseH: self.bh, yFix: self.yf)
            let ok = self.rt.ble.send(cmd)
            self.job.append("   §swipe \(cmd)")
            _ = self.sleepS(Double(speed.ms + 400) / 1000)
            return ok
        }
        def("swipe", unsafeBitCast(fSwipe, to: AnyObject.self))

        let fSend: @convention(block) (JSValue) -> Bool = { v in
            if self.stopped() { return false }
            guard v.isString else { self.fail("pg.send('P:1,2')"); return false }
            return self.rt.ble.send(v.toString())
        }
        def("send", unsafeBitCast(fSend, to: AnyObject.self))

        let fBack: @convention(block) () -> Bool = {
            if self.stopped() { return false }
            guard let nav = self.navigator() else { self.fail("配置未加载"); return false }
            return nav.backEdge()
        }
        def("back", unsafeBitCast(fBack, to: AnyObject.self))

        // ── 导航（用 config.json 的页面图 + 漏斗）──
        let fGo: @convention(block) (JSValue) -> Bool = { v in
            if self.stopped() { return false }
            guard v.isString else { self.fail("pg.go(页型)"); return false }
            guard let nav = self.navigator() else { self.fail("配置未加载"); return false }
            guard let im = self.image() else { self.fail("还没有帧"); return false }
            return nav.go(to: v.toString(), img: im)
        }
        def("go", unsafeBitCast(fGo, to: AnyObject.self))

        let fFunnel: @convention(block) () -> Bool = {
            if self.stopped() { return false }
            guard let nav = self.navigator() else { self.fail("配置未加载"); return false }
            guard let im = self.image() else { self.fail("还没有帧"); return false }
            return nav.runFunnel(im)
        }
        def("funnel", unsafeBitCast(fFunnel, to: AnyObject.self))

        // ── 配置 / 引入其它脚本 ──
        let fSettings: @convention(block) () -> JSValue = {
            guard let d = try? Data(contentsOf: ConfigStore.configPath()),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return self.fail("读不到 config.json")
            }
            return self.val(o["settings"] ?? [:])
        }
        def("settings", unsafeBitCast(fSettings, to: AnyObject.self))

        let fInclude: @convention(block) (JSValue) -> JSValue = { v in
            guard v.isString, ScriptRuntime.safeName(v.toString()) else { return self.fail("pg.include('xxx.js')") }
            let u = ScriptRuntime.scriptsDir().appendingPathComponent(v.toString())
            guard let src = try? String(contentsOf: u, encoding: .utf8) else {
                return self.fail("没有这个脚本：\(v.toString())（先 pgdbg push）")
            }
            return JSContext.current().evaluateScript(src, withSourceURL: URL(string: "pg://\(v.toString())"))
        }
        def("include", unsafeBitCast(fInclude, to: AnyObject.self))

        let fBle: @convention(block) () -> String = { self.rt.ble.state }
        def("ble", unsafeBitCast(fBle, to: AnyObject.self))

        // ── ⭐ §3100 像素原语（**只搬像素 / 只算 NCC**，⛔ 不含任何业务判据）──
        //
        // 为什么必须有（用户令 2026-10-18：「1比1 把 PG 控制台移植过来做执行大脑」）：
        //   PC 蓝本 `_1377_ad_loop.py` 的判据**大量是像素级**的
        //   （`find_coin_entry` 红块 / `widestPinkBand` 粉带 / `find_modal_x` 暖灰圆钮 /
        //     `find_toast_x` 胶囊 ✕ / `find_live_x` / `_find_cross_x` / `find_appstore_x` 的 MAE 块比）。
        //   原来的 `pg` 只有 OCR / 模板（走 config 元素表）/ 点击 ⇒ **这些腿在 JS 里没法 1:1 抄**。
        //   ⇒ 补三个原语，让 JS 侧可以**逐行照抄 PC 的算法**（阈值、ROI、掩码全在 JS 里写）。
        //
        // ⛔ 三个原语都**先归一到基准 451×977**（与 `FrameNormalizer` / 全项目 ROI 同一坐标系），
        //   返回的坐标也一律是**基准像素**。
        // ⛔ 灰度用 **PC/PIL `.convert("L")` 的 ITU-R 601 口径**（0.299R+0.587G+0.114B），
        //   ⛔ 不用 `Recognizer.gray` 的 linearGray —— 那样与 PC 的像素阈值不可比。
        //
        // `pg.pix(x,y,w,h)` ⇒ `{ok, x, y, w, h, data}`，`data` = base64(R,G,B,A 逐行，左上原点)
        let fPix: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            x, y, w, h in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard let im = self.image() else { return self.fail("还没有帧") }
            let base = FrameNormalizer.normalize(im)
            guard let cgAll = base.cgImage else { return self.fail("帧没有 cgImage") }
            let W = cgAll.width, H = cgAll.height
            let bx = max(0, Int(self.num(x, 0))), by = max(0, Int(self.num(y, 0)))
            let bw = min(W - bx, Int(self.num(w, Double(W)))), bh = min(H - by, Int(self.num(h, Double(H))))
            guard bx < W, by < H, bw > 0, bh > 0 else { return self.fail("pg.pix 区域越界") }
            guard let cg = cgAll.cropping(to: CGRect(x: CGFloat(bx), y: CGFloat(by), width: CGFloat(bw), height: CGFloat(bh)))
            else { return self.fail("pg.pix 裁剪失败") }
            // ⛔⛔⛔ §3106 **必须用 `data: nil` + `ctx.data` 取指针**（真机血案，2026-10-18）
            //
            // 原来的写法 `CGContext(data: &buf, ...)` 把 Swift 数组的**临时指针**交给 CGContext：
            //   那个指针只在**初始化表达式的那一次调用期间**保证有效，CGContext **不持有它**。
            //   之后 `ctx.draw()` 再往里写 ⇒ **写到一个已经失效的地址** ⇒ 读回来的像素全是错的。
            // 📏 真机取证（同一帧、同一点）：
            //   PC（PIL 归一化 451×977）(50,140) = **RGB(249,95,75)**（红包球的红）
            //   手机端 `pg.pix`          (50,140) = **255,255,255,255**（读成纯白）
            //   ⇒ ROI 内红像素：PC **946** ／ 手机端 **3** ⇒ 判据全部落空。
            // ⛔ 这不是"判据不对"，是**板子（取像素的方式）不对** ⇒ 换板子，不贴胶布。
            // ✅ 正解：让 CGContext **自己分配**缓冲（`data: nil`），再用 `ctx.data` 取它的指针；
            //   生命周期由 CGContext 管，`draw` 写的一定是同一块内存。
            guard let ctx = CGContext(data: nil, width: bw, height: bh,
                                      bitsPerComponent: 8, bytesPerRow: bw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return self.fail("pg.pix 建缓冲失败") }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(bw), height: CGFloat(bh)))
            guard let src = ctx.data else { return self.fail("pg.pix 取不到缓冲") }
            let srcPtr = src.assumingMemoryBound(to: UInt8.self)
            // ⛔⛔⛔ §3111 **不要再翻行**（真机血案，2026-10-18：我在这里多翻了一次）
            //
            // 📏 决定性取证（同一帧，PC(PIL 归一化) vs 手机 `pg.pix`）：
            //   · PC `(100,470)` = RGB(0,136,254) 蓝色 ／ JS `(100,470)` = (243,242,248) 白
            //   · JS `(100, 976-470)` = **RGB(0,137,253)** 蓝色  ← 与 PC 吻合
            //   · PC `(50,140)` = RGB(25,25,25) 深灰 ／ JS `(50, 976-140)` = **(3,3,3)** ✅
            //   ⇒ **画面被上下翻转了**。根因：`CGContext.draw` 之后 `ctx.data` 的**第 0 行就是
            //      ROI 的顶行**（CoreGraphics 在 bitmap 上下文里按"左上原点"落盘，
            //      与 `UIImage`/`UIGraphicsImageRenderer` 的约定一致），**不需要翻**。
            //   ⚠️ 我原来按"CGContext 原点在左下"的老经验翻了一次 ⇒ 每个点都取到了对称行。
            //      （同族错误在 `ColorBlob.findCoinBall` 里也翻过一次 —— 但那边用的是
            //        `CGContext(data: &buf)` + `cropping`，行为不同，不能外推。）
            // ⇒ 正解：**原样拷贝**，不做任何行重排。
            var out = [UInt8](repeating: 0, count: bw * bh * 4)
            out.withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.baseAddress else { return }
                dst.copyMemory(from: src, byteCount: bw * bh * 4)
            }
            return self.val(["ok": true, "x": bx, "y": by, "w": bw, "h": bh,
                             "data": Data(out).base64EncodedString()])
        }
        def("pix", unsafeBitCast(fPix, to: AnyObject.self))

        // `pg.gray(x,y,w,h)` ⇒ `{ok, x, y, w, h, data}`，`data` = base64(单字节灰度，左上原点)
        let fGray: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            x, y, w, h in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard let im = self.image() else { return self.fail("还没有帧") }
            let base = FrameNormalizer.normalize(im)
            guard let cgAll = base.cgImage else { return self.fail("帧没有 cgImage") }
            let W = cgAll.width, H = cgAll.height
            let bx = max(0, Int(self.num(x, 0))), by = max(0, Int(self.num(y, 0)))
            let bw = min(W - bx, Int(self.num(w, Double(W)))), bh = min(H - by, Int(self.num(h, Double(H))))
            guard bx < W, by < H, bw > 0, bh > 0 else { return self.fail("pg.gray 区域越界") }
            guard let cg = cgAll.cropping(to: CGRect(x: CGFloat(bx), y: CGFloat(by), width: CGFloat(bw), height: CGFloat(bh)))
            else { return self.fail("pg.gray 裁剪失败") }
            // ⛔ §3106 同 `pg.pix`：`data: nil` + `ctx.data`（`&buf` 的临时指针会在初始化后失效）
            guard let ctx = CGContext(data: nil, width: bw, height: bh,
                                      bitsPerComponent: 8, bytesPerRow: bw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return self.fail("pg.gray 建缓冲失败") }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(bw), height: CGFloat(bh)))
            guard let srcB = ctx.data else { return self.fail("pg.gray 取不到缓冲") }
            let srcPtr = srcB.assumingMemoryBound(to: UInt8.self)
            // ⛔ §3111 不翻行（见 `pg.pix` 的取证注释：`ctx.data` 第 0 行**就是** ROI 顶行）
            var g = [UInt8](repeating: 0, count: bw * bh)
            for j in 0..<bh {
                let s = j * bw * 4
                let d = j * bw
                for i in 0..<bw {
                    let o = s + i * 4
                    let r = Int(srcPtr[o]), gg = Int(srcPtr[o + 1]), b = Int(srcPtr[o + 2])
                    // PIL `convert("L")`：L = round(0.299R + 0.587G + 0.114B)
                    g[d + i] = UInt8(max(0, min(255, (299 * r + 587 * gg + 114 * b + 500) / 1000)))
                }
            }
            return self.val(["ok": true, "x": bx, "y": by, "w": bw, "h": bh,
                             "data": Data(g).base64EncodedString()])
        }
        def("gray", unsafeBitCast(fGray, to: AnyObject.self))

        // `pg.tpl(name, x,y,w,h, threshold, mask, scales)`
        //   ⇒ `{ok, score, cx, cy, x, y, w, h, tpl, scale}` 或 `{ok:true, hit:false, score}`
        //
        // 语义**逐条照抄 PC**（`_ks_match` / `Recognizer.matchTemplate` / `_1765_match.py`）：
        //   ① 灰度用上面同一条 ITU-R 601 口径（模板文件也一样）
        //   ② **模板质量闸**：模板灰度标准差 < 6.0 ⇒ 拒用（OpenCV TM_CCOEFF_NORMED 对平坦模板
        //      会整张填 1.0 ⇒ 确定性误报；`_1377:5270` 原文，本仓库最平模板 11.91）
        //   ③ **ink 掩码**：`mask=='ink'` 时只让"墨迹 + pad 2 邻域"参与 NCC（照 MaaFW 语义）
        //   ④ 多尺度（默认 1.0；PC 的 `X_TPL_SCALES=(0.85,1.00,1.15)` 由 JS 侧传入）
        //   ⑤ 分数 = TM_CCOEFF_NORMED 等价式，`< threshold` ⇒ 不算命中
        // `name` 是 `Documents/pgconfig/templates/` 下的相对路径（与 config.json 的 `templates` 同源）
        let fTpl: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue,
                                      JSValue, JSValue, JSValue) -> JSValue = {
            nameV, xV, yV, wV, hV, thrV, maskV, scalesV in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard nameV.isString else { return self.fail("pg.tpl(名字, x,y,w,h, thr?, mask?, scales?)") }
            guard let im = self.image() else { return self.fail("还没有帧") }
            let tplURL = ConfigStore.templatesDir().appendingPathComponent(nameV.toString()!)
            guard let td = try? Data(contentsOf: tplURL), let timg = UIImage(data: td) else {
                return self.fail("模板读不到：\(nameV.toString() ?? "?")")
            }
            let base = FrameNormalizer.normalize(im)
            guard let cgAll = base.cgImage else { return self.fail("帧没有 cgImage") }
            let W = cgAll.width, H = cgAll.height
            let bx = max(0, Int(self.num(xV, 0))), by = max(0, Int(self.num(yV, 0)))
            let bw = min(W - bx, Int(self.num(wV, Double(W)))), bh = min(H - by, Int(self.num(hV, Double(H))))
            let thr = self.num(thrV, 0.80)
            let mask = maskV.isString ? maskV.toString()! : ""
            var scales: [Double] = [1.0]
            if scalesV.isArray, let a = scalesV.toArray() as? [NSNumber], !a.isEmpty {
                scales = a.map { $0.doubleValue }
            }
            guard bx < W, by < H, bw > 2, bh > 2 else { return self.fail("pg.tpl 区域越界") }
            guard let cg = cgAll.cropping(to: CGRect(x: CGFloat(bx), y: CGFloat(by), width: CGFloat(bw), height: CGFloat(bh)))
            else { return self.fail("pg.tpl 裁剪失败") }
            // ROI 灰度（与 pg.gray 同一口径）—— ⛔ §3106 同样用 `data: nil` + `ctx.data`
            guard let ctx = CGContext(data: nil, width: bw, height: bh,
                                      bitsPerComponent: 8, bytesPerRow: bw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return self.fail("pg.tpl 建缓冲失败") }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(bw), height: CGFloat(bh)))
            guard let srcB = ctx.data else { return self.fail("pg.tpl 取不到缓冲") }
            let srcPtr = srcB.assumingMemoryBound(to: UInt8.self)
            var s = [Double](repeating: 0, count: bw * bh)
            for j in 0..<bh {
                // ⛔ §3111 不翻行（同 `pg.pix`）
                let src = j * bw * 4
                for i in 0..<bw {
                    let o = src + i * 4
                    let r = Double(srcPtr[o]), g = Double(srcPtr[o + 1]), b = Double(srcPtr[o + 2])
                    s[j * bw + i] = 0.299 * r + 0.587 * g + 0.114 * b
                }
            }
            // 模板灰度（缩放到基准尺度，再用同一公式）
            func grayOf(_ img: UIImage, scale: Double) -> (w: Int, h: Int, p: [Double])? {
                let tw0 = Double(img.size.width * img.scale)
                let th0 = Double(img.size.height * img.scale)
                let tw = max(1, Int((tw0 * scale).rounded()))
                let th = max(1, Int((th0 * scale).rounded()))
                guard let tctx = CGContext(data: nil, width: tw, height: th,
                                           bitsPerComponent: 8, bytesPerRow: tw * 4,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let tcg = img.cgImage else { return nil }
                tctx.draw(tcg, in: CGRect(x: 0, y: 0, width: CGFloat(tw), height: CGFloat(th)))
                guard let tbB = tctx.data else { return nil }
                let tb = tbB.assumingMemoryBound(to: UInt8.self)
                var p = [Double](repeating: 0, count: tw * th)
                for j in 0..<th {
                    // ⛔ §3111 不翻行（同 `pg.pix`；模板与 ROI 用**同一套**行序才可比）
                    let src = j * tw * 4
                    for i in 0..<tw {
                        let o = src + i * 4
                        p[j * tw + i] = 0.299 * Double(tb[o]) + 0.587 * Double(tb[o + 1])
                                        + 0.114 * Double(tb[o + 2])
                    }
                }
                return (tw, th, p)
            }
            var best: (score: Double, x: Int, y: Int, tw: Int, th: Int, scale: Double)?
            for sc in scales {
                guard let tg = grayOf(timg, scale: sc) else { continue }
                let TW = tg.w, TH = tg.h
                guard TW > 2, TH > 2, TW <= bw, TH <= bh else { continue }
                // ② 模板质量闸（PC `MIN_TPL_STD = 6.0`）
                var ms = 0.0, ms2 = 0.0
                let nAll = Double(TW * TH)
                for k in 0..<(TW * TH) { let v = tg.p[k]; ms += v; ms2 += v * v }
                let mean0 = ms / nAll
                let std0 = max(0, ms2 / nAll - mean0 * mean0).squareRoot()
                if std0 < 6.0 { continue }
                // ③ ink 掩码（墨迹 < 128，pad=2 膨胀；墨太少 ⇒ 不用掩码）
                var maskIdx: [Int] = []
                if mask == "ink" {
                    let pad = 2
                    var isInk = [Bool](repeating: false, count: TW * TH)
                    for k in 0..<(TW * TH) where tg.p[k] < 128 { isInk[k] = true }
                    var dil = isInk
                    for j in 0..<TH {
                        for i in 0..<TW where isInk[j * TW + i] {
                            for dj in -pad...pad {
                                let nj = j + dj
                                guard nj >= 0, nj < TH else { continue }
                                for di in -pad...pad {
                                    let ni = i + di
                                    guard ni >= 0, ni < TW else { continue }
                                    dil[nj * TW + ni] = true
                                }
                            }
                        }
                    }
                    for k in 0..<(TW * TH) where dil[k] { maskIdx.append(k) }
                    if maskIdx.count < 30 { maskIdx = [] }
                }
                let useMask = !maskIdx.isEmpty
                let n = Double(useMask ? maskIdx.count : TW * TH)
                var tSum = 0.0, tSum2 = 0.0
                if useMask {
                    for k in maskIdx { let v = tg.p[k]; tSum += v; tSum2 += v * v }
                } else {
                    for k in 0..<(TW * TH) { let v = tg.p[k]; tSum += v; tSum2 += v * v }
                }
                let tMean = tSum / n
                let tVar = max(1e-6, tSum2 / n - tMean * tMean)
                let tStd = tVar.squareRoot()
                let y1 = bh - TH, x1 = bw - TW
                guard x1 >= 0, y1 >= 0 else { continue }
                for yy in 0...y1 {
                    for xx in 0...x1 {
                        var sSum = 0.0, sSum2 = 0.0, cross = 0.0
                        if useMask {
                            for k in maskIdx {
                                let sv = s[(yy + k / TW) * bw + (xx + k % TW)]
                                let tv = tg.p[k]
                                sSum += sv; sSum2 += sv * sv; cross += sv * tv
                            }
                        } else {
                            for j in 0..<TH {
                                let srow = (yy + j) * bw + xx
                                let trow = j * TW
                                for i in 0..<TW {
                                    let sv = s[srow + i], tv = tg.p[trow + i]
                                    sSum += sv; sSum2 += sv * sv; cross += sv * tv
                                }
                            }
                        }
                        let sMean = sSum / n
                        let sVar = max(1e-6, sSum2 / n - sMean * sMean)
                        let ncc = (cross / n - sMean * tMean) / (sVar.squareRoot() * tStd)
                        if best == nil || ncc > best!.score {
                            best = (ncc, xx, yy, TW, TH, sc)
                        }
                    }
                }
            }
            guard let b = best else {
                return self.val(["ok": true, "hit": false, "score": 0.0,
                                 "why": "模板不可用（尺寸 > ROI 或过平）"])
            }
            if b.score < thr {
                return self.val(["ok": true, "hit": false, "score": b.score,
                                 "threshold": thr])
            }
            return self.val(["ok": true, "hit": true, "score": b.score,
                             "threshold": thr, "scale": b.scale,
                             "x": bx + b.x, "y": by + b.y, "w": b.tw, "h": b.th,
                             "cx": Double(bx + b.x) + Double(b.tw) / 2.0,
                             "cy": Double(by + b.y) + Double(b.th) / 2.0,
                             "tpl": nameV.toString() ?? ""])
        }
        def("tpl", unsafeBitCast(fTpl, to: AnyObject.self))

        // ⭐⭐⭐ §3130 **`pg.kgx(box?)` —— 「找 ✕」的 YOLO（PC `find_x_all` 的等价物）**
        //
        // PC 依据（`_1377_ad_loop.py`）：
        // ```python
        // def find_x_all(img, box=None, conf2=None, tag=""):
        //     d = _x_raw(img)                       # 整帧推理一次（同帧缓存）
        //     hit = [x for x in d if x[0] >= conf2] # conf2 = 0.49
        //     if box is not None:                   # box 是**结果过滤窗**，不是裁剪
        //         hit = [x for x in hit if bx0<=x[1]<=bx1 and by0<=x[2]<=by1]
        //     return [(x[1], x[2], x[0], x[3], x[4]) for x in hit]   # (cx,cy,conf,w,h)
        // ```
        // ⇒ 这里**语义一一对应**：
        //   `pg.kgx()`            → 全帧，conf2=0.49
        //   `pg.kgx([x0,y0,x1,y1])` → 按结果中心过滤
        //   返回 `{ok, n, hits:[{cx,cy,conf,w,h}], ms}`；模型不可用 ⇒ `{ok:false, why}`
        // ⛔ `ok:false` 必须让 JS 侧**如实回退**（⛔ 不能当成"没找到 ✕"—— 那是两回事）
        let fKgx: @convention(block) (JSValue) -> JSValue = { boxV in
            if self.stopped() { return JSValue(undefinedIn: JSContext.current()) }
            guard let im = self.image() else { return self.fail("还没有帧") }
            let net = KGXNet.shared
            if !net.available {
                net.loadIfNeeded()
                if !net.available {
                    return self.val(["ok": false, "why": "kgx 不可用：" + net.error,
                                     "n": 0, "hits": []])
                }
            }
            var box: CGRect? = nil
            if let r = self.rect(boxV) { box = r }
            let t0 = Date()
            let hits = net.findAll(im, box: box)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var arr: [[String: Any]] = []
            for h in hits {
                arr.append(["cx": h.cx, "cy": h.cy, "conf": h.conf, "w": h.w, "h": h.h])
            }
            if !arr.isEmpty {
                let top = hits.prefix(5).map {
                    String(format: "(%.0f,%.0f)%.2f", $0.cx, $0.cy, $0.conf)
                }.joined(separator: " ")
                NSLog("PGAgent §3130 ✕ 命中 %d 个：%@", arr.count, top)
            }
            return self.val(["ok": true, "n": arr.count, "hits": arr, "ms": ms])
        }
        def("kgx", unsafeBitCast(fKgx, to: AnyObject.self))

        // 诊断：模型是否加载好了（省得每次都跑一遍才知道）
        let fKgxReady: @convention(block) () -> JSValue = {
            let net = KGXNet.shared
            net.loadIfNeeded()
            return self.val(["ok": net.available, "why": net.error])
        }
        def("kgxReady", unsafeBitCast(fKgxReady, to: AnyObject.self))

        return pg
    }
}
