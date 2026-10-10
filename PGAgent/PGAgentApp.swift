import SwiftUI
import UIKit

// ⭐ PGAgent v0.2 —— 「AI 能调用」版
//
//   ① Documents 读写（快捷指令写截图进来）
//   ② BLE 连 ESP32 发 HID（点击/滑动）
//   ③ ⭐ HTTP 服务（绑 127.0.0.1）⇒ 主机经 USB 隧道直接调用
//   ④ 日志（NSLog + HTTP /log）
//
// ⛔ 这一版**不做识别**，只把「管道」全部打通，让主机能驱动它。

@main
struct PGAgentApp: App {
    @StateObject private var store = LogStore()
    @StateObject private var ble = BLEController()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(ble)
        }
    }
}

/// 全局日志：内存环形 + NSLog（主机 `dvt launch --stream` 能看）
///
/// ## ⛔⛔ 血泪教训（§2212 崩溃日志实证）
/// 曾经的写法是**每条日志**都 `DispatchQueue.main.async { objectWillChange.send() }`。
/// 后果：Runner / HTTP handler 在后台线程高速打日志时，
/// 主线程被**重绘风暴**淹没 —— 每次重绘都要重建整个 `NavigationView` + `ScrollView`，
/// 而 SwiftUI 体里又调用 `store.snapshot()`（**加锁 + 全量拷贝**）。
///
/// 真机崩溃日志（`PGAgent-2026-10-10-161338.ips`）：
/// ```
/// EXC_CRASH (SIGKILL)
/// FRONTBOARD code 0x8BADF00D
///   "scene-update watchdog transgression: app is stuck (deadlock)"
/// faultingThread 0:
///   __psynch_mutexwait ← _pthread_mutex_firstfit_lock_wait
///   ← ScrollView.init(_:showsIndicators:content:)
///   ← NavigationView.init(content:)
///   ← ViewBodyAccessor.updateBody(of:changed:)
/// ```
/// ⇒ **主线程卡在锁上 + 重建 SwiftUI 视图** ⇒ 看门狗**直接 SIGKILL**。
/// ⇒ 用户看到的「**卡死界面上**」「突然停止」就是它。
///
/// ## ✅ 修法（三条一起上）
/// ① **节流通知**：日志照收，但给 UI 的赋值最多 ~4 次/秒
/// ② **不再 `objectWillChange.send()`**：改用 `@Published recentLines`（定长尾部窗口）
/// ③ 视图体只读 `recentLines`（**无锁、定长**），⛔ 不再每帧加锁+全量拷贝
final class LogStore: ObservableObject {
    /// ⭐ 只给 UI 看最近 N 行（⛔ 不要全量拷给 SwiftUI）
    static let uiLimit = 200
    /// ⭐ 内存里最多留这么多行
    private static let memLimit = 2000

    /// ⚠️ `@Published` 会让**每次赋值**都触发重绘
    /// ⇒ 只把「给 UI 看的尾部窗口」放进来，并用节流控制赋值频率
    @Published private(set) var recentLines: [String] = []

    private var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    /// 保护 `lines`
    private let lock = NSLock()
    /// 保护节流状态（**独立锁**：⛔ 不能与 `lock` 混用，
    /// 否则 `schedulePush` → `recent()` 会**自死锁**）
    private let pushLock = NSLock()
    private var lastPush = Date.distantPast
    private var pushScheduled = false

    func log(_ s: String) {
        // ⚠️ DateFormatter 不是线程安全的，但这里只在**同一个** log 调用内用；
        //    为避免并发调用时共用 formatter 出错，格式化的这一句放在锁内。
        lock.lock()
        let line = "[\(fmt.string(from: Date()))] \(s)"
        lines.append(line)
        if lines.count > Self.memLimit { lines.removeFirst(lines.count - Self.memLimit) }
        lock.unlock()
        NSLog("PGAgent %@", line)   // ⛔ NSLog 放到锁外（它本身较慢）
        schedulePush()
    }

    /// ⭐ 节流推送：最快 ~4 次/秒把尾部窗口同步给 UI（合并突发日志）。
    ///
    /// · 节流状态用**独立的** `pushLock`，`recent()` 用 `lock` ⇒ 不会自死锁
    /// · `recentLines` 只在**主线程**赋值（`@Published` + SwiftUI 的要求）
    private func schedulePush() {
        let now = Date()
        pushLock.lock()
        let since = now.timeIntervalSince(lastPush)
        if since >= 0.25 {
            lastPush = now
            pushLock.unlock()
            pushToUI()
            return
        }
        // 冷却期内 ⇒ 只安排**一次**尾部补推
        if pushScheduled { pushLock.unlock(); return }
        pushScheduled = true
        pushLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + (0.25 - since)) { [weak self] in
            guard let self = self else { return }
            self.pushLock.lock()
            self.pushScheduled = false
            self.lastPush = Date()
            self.pushLock.unlock()
            self.pushToUI()
        }
    }

    /// 把尾部窗口送到主线程的 `@Published`
    private func pushToUI() {
        let tail = recent(Self.uiLimit)
        if Thread.isMainThread {
            recentLines = tail
        } else {
            DispatchQueue.main.async { self.recentLines = tail }
        }
    }

    /// 取尾部 n 行（**加锁 + 只拷 n 个**，⛔ 不全量）
    func recent(_ n: Int = uiLimit) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if lines.count <= n { return lines }
        return Array(lines.suffix(n))
    }

    /// 诊断接口（`/log` 用）—— 返回全部
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
        if Thread.isMainThread {
            recentLines = []
        } else {
            DispatchQueue.main.async { self.recentLines = [] }
        }
    }
}

/// ⚠️ `HTTPServer` 不是 `ObservableObject`（它只管网络，不发 UI 通知）
/// ⇒ 用这个 holder 把它包一层，才能放进 `@StateObject`
final class HTTPServerHolder: ObservableObject {
    let server = HTTPServer()
    @Published var port: UInt16 = 0
    @Published var lastError = ""
}

struct ContentView: View {
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var ble: BLEController
    @StateObject private var http = HTTPServerHolder()
    @StateObject private var cfgStore = ConfigStore()
    @StateObject private var grabber = ScreenGrabber()
    @StateObject private var broadcaster = BroadcastStarter()
    @StateObject private var pip = PiPManager()
    @State private var router: APIRouter?
    @State private var started = false
    @State private var port: UInt16 = 0
    /// ⭐ 自主循环的运行状态（UI 显示）
    @State private var runState = "-"
    /// ⭐ 循环实例（boot 里创建，UI 按钮用）
    @State private var runnerRef: Runner?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HTTP 127.0.0.1:\(port == 0 ? "…" : "\(port)")")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text("BLE: \(ble.state)")
                        .font(.system(size: 12, design: .monospaced))
                    Text("Documents: \(DocsScanner.docPath())")
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)

                HStack(spacing: 6) {
                    Button("扫 BLE") { ble.scan { _ in } }
                    Button("停扫") { ble.stopScan() }
                    Button("清日志") { store.clear() }
                }
                .padding(.horizontal, 8)

                // ⭐⭐⭐⭐ 「眼」正路 —— 录屏广播（⛔ 不用快捷指令、⛔ 不用人手点）
                HStack(spacing: 6) {
                    Button("🔴 开录屏") {
                        let ok = broadcaster.start()
                        store.log("▶️ 启动录屏广播: \(ok ? "✅ 已触发" : "⛔ \(broadcaster.lastError)")")
                    }
                    Text("帧 \(broadcaster.frames)")
                        .font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // 「眼」备选 —— 快捷指令截图
                HStack(spacing: 6) {
                    Button("📷 抓一帧") {
                        store.log("▶️ 手动抓帧（快捷指令 \(grabber.shortcutName)）")
                        grabber.grab(timeout: 10) { u, e in
                            if let u = u {
                                store.log("✅ 抓到 \(u.lastPathComponent)")
                            } else {
                                store.log("⛔ 抓帧失败：\(e)")
                            }
                        }
                    }
                    Button("只触发") {
                        let ok = grabber.triggerShortcut()
                        store.log("触发快捷指令: \(ok ? "✅ 已发起" : "⛔ \(grabber.lastError)")")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // ⭐⭐⭐⭐ 「活」—— 画中画保活（照荔枝的做法）
                HStack(spacing: 6) {
                    Button("🖼 开画中画") {
                        let ok = pip.start()
                        store.log("▶️ 启动画中画保活: \(ok ? "✅ 已发起" : "⛔ \(pip.lastError)")")
                    }
                    Button("关") { pip.stop() }
                    Text(pip.active ? "PiP 活" : "PiP 停")
                        .font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // ⭐⭐⭐ 自主循环 —— App 自己在手机上跑（⛔ 不需要 PC / USB / 开发者模式）
                HStack(spacing: 6) {
                    Button("▶️ 开始跑") {
                        store.log("▶️ 手动启动自主循环")
                        runnerRef?.start(dest: nil)
                    }
                    Button("⛔ 停") { runnerRef?.stop() }
                    Text(runState)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // ⛔⛔ **不要**在这里调 `store.snapshot()`：
                //   它会**加锁 + 全量拷贝**，而本 body 每次重绘都会执行
                //   ⇒ 主线程卡在锁上 ⇒ 看门狗 SIGKILL（§2212 崩溃日志实证）
                //   ✅ 改为读 `store.recentLines` —— 由 LogStore 节流推送（无锁、定长）
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.recentLines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
            }
            .navigationTitle("PGAgent v0.10.0")
            .onAppear(perform: boot)
        }
        .navigationViewStyle(.stack)
    }

    private func boot() {
        guard !started else { return }
        started = true

        store.log("=== PGAgent v0.10.0 启动 ===")
        store.log("Documents = \(DocsScanner.docPath())")
        // ⭐ 「眼」的关键诊断：共享容器可用 ⇒ 帧能读到
        store.log("共享帧目录 = \(AppGroup.framesDir()?.path ?? "⛔ 无（帧读不到！）")")

        // ⭐ 自主循环（App 自己在手机上跑，⛔ 不需要 PC）
        let runner = Runner(cfgStore: cfgStore, grabber: grabber, ble: ble,
                              broadcaster: broadcaster) { s in
            store.log(s)
        }
        runnerRef = runner
        // 每秒刷新一次 UI 上的循环状态
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let s = runner.snapshot()
            let running = (s["running"] as? Bool) ?? false
            let step = (s["step"] as? Int) ?? 0
            let page = (s["page"] as? String) ?? "-"
            let reason = (s["stopReason"] as? String) ?? "-"
            runState = running ? "跑中 步\(step) \(page)" : "停 \(reason)"
            // ⭐ 把状态同步到画中画（荔枝的做法：PiP 里显示进度）
            if pip.active { pip.text = runner.pipLine() }
        }

        // ⭐⭐⭐ 静音音频保活（§2235）—— 开机就开，这样**任何时候**退后台都不被挂起
        store.log("保活（静音音频）= \(SilentKeepAlive.shared.start() ? "✅ 已开" : "⛔ \(SilentKeepAlive.shared.lastError)")")

        // ⭐ 起 HTTP 服务
        let rt = APIRouter(log: store, ble: ble, cfgStore: cfgStore,
                           grabber: grabber, runner: runner,
                           broadcaster: broadcaster, pip: pip)
        router = rt
        http.server.onRequest = { [weak rt] req in
            rt?.handle(req) ?? HTTPServer.Response.text("no router", status: 500)
        }
        http.server.start(preferredPort: 8899)
        port = http.server.port
        http.port = http.server.port
        http.lastError = http.server.lastError
        rt.httpPort = http.server.port
        store.log("HTTP 已起 127.0.0.1:\(http.server.port)  err=\(http.server.lastError)")

        // ⭐ 读运行时配置（改逻辑只推这个文件，⛔ 不重装）
        ConfigStore.ensureDirs()
        if cfgStore.reload() {
            store.log("✅ 配置已加载：\(cfgStore.cfg?.elements.count ?? 0) 个元素 / \(cfgStore.cfg?.pages.count ?? 0) 个页型")
        } else {
            store.log("⚠️ 配置未加载：\(cfgStore.lastError)")
        }

        // 通知
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { _ in store.log("⏸ didEnterBackground") }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { _ in store.log("▶️ willEnterForeground") }

        // 开机扫一次 Documents
        store.log("--- 扫 Documents ---")
        let n = (try? FileManager.default
            .contentsOfDirectory(atPath: DocsScanner.docPath()).count) ?? -1
        store.log("共 \(n) 个文件")
    }
}
