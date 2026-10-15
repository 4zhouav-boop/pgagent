import Foundation
import CoreBluetooth

/// 连 ESP32 并写 HID 命令（PG 已有的 `P:x,y` / `C:L` / `D:...` 协议）。
///
/// ⭐ 沿用 `_note_1799` 已验证的东西：
///   - 前台用 CoreBluetooth **不需要 entitlement**（免费 Apple ID 可用）
///   - 命令格式与生产脚本里的 `ks_io.py` 完全一致 ⇒ 主机侧逻辑不用改
///
/// ⛔ 本类只做「连接 + 写字节」，不做任何识别决策。
final class BLEController: NSObject, ObservableObject {

    @Published private(set) var state = "idle"
    @Published private(set) var devices: [String] = []
    @Published private(set) var lastError = ""

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var scanStore: ((String) -> Void)?

    // ⭐⭐ §2705 自动重连（蓝牙开启 / 意外断开）
    /// 退避档位（秒）—— ⛔ 不连发，连发会把刚建起的链路打崩
    private static let reconnectBackoff: [Double] = [2, 5, 15, 60]
    /// 连续重连次数（成功就清零；用于选退避档）
    private var reconnectAttempt = 0
    /// 待执行的重连（重连前先 cancel，避免排队叠加）
    private var reconnectWork: DispatchWorkItem?
    /// ⭐ 重连「代数」—— 每次排程 +1，旧的回调凭代数作废（⛔ 防叠加）
    private var reconnectGeneration = 0

    // ⭐⭐ §2252 NUS 命令通道 + 诊断
    /// 认到 NUS 的 RX 特征（`6E400002-…`）—— 手机往这写命令
    private(set) var nusRxFound = false
    /// NUS 的 TX 特征（`6E400003-…`）—— 板子回执走这
    private var notifyChar: CBCharacteristic?
    /// ⭐ 板子最近一条回执（`ok:<命令>`）⇒ 双向通的**直接证据**
    private(set) var lastAck = ""
    /// ⭐ 服务/特征发现过程（`/blediag` 回显，排查用）
    private(set) var probeStore: [String] = []

    /// ESP32 常见的 HID/透传服务 UUID（PG 板子用的是 Nordic UART 风格的透传）
    /// ⚠️ 真机实测后按需调整；也支持不过滤扫描（nil）
    static let candidateServiceUUIDs: [CBUUID] = [
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),   // Nordic UART Service
        CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB"),   // 常见透传
        CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB"),   // HID over GATT
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan(_ onFound: @escaping (String) -> Void) {
        scanStore = onFound
        devices.removeAll()
        guard central.state == .poweredOn else {
            state = "bt-\(central.state.rawValue)"
            return
        }
        state = "scanning"
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        state = "idle"
    }

    func connect(_ nameOrId: String) {
        guard let p = foundPeripherals.first(where: {
            ($0.name ?? "").contains(nameOrId) || $0.identifier.uuidString.hasPrefix(nameOrId)
        }) else {
            lastError = "没找到外设: \(nameOrId)"
            return
        }
        target = p
        p.delegate = self
        state = "connecting"
        central.connect(p, options: nil)
    }

    /// ⭐⭐⭐ **连到「已经配对过」的板子**（§2249 —— 照 PC `for_device()` 的语义）
    ///
    /// ## 为什么必须有（真机实测的坑）
    /// 板子日志显示 `蓝牙=已连` 时，它**已经连到某台设备，因此不再广播**
    /// ⇒ `scanForPeripherals` **扫不到它**（实测 `found: []`）
    /// ⇒ 只有 `scan` + `connect` 一条路的话 ⇒ **永远连不上**。
    ///
    /// ## PC 是怎么解决的
    /// PC 有 `for_device()`：**⛔ 不靠"扫到"，靠"认得"**
    /// （按 `fw_id > instance_path > location > com_hint` 四重解析串口）。
    /// 手机端对应的机制是 **`retrieveConnectedPeripherals`** ——
    /// 它能拿到**系统层面已配对/已连接**的外设，⛔ 不需要广播。
    ///
    /// ⚠️ 注意：iOS 的这个 API 返回的是「**本机**已配对的外设」，
    ///    所以**必须是这台手机自己配过的板子**（也正是我们要的语义）。
    @discardableResult
    func connectPaired(hint: String? = nil) -> Int {
        // ⛔⛔ **不能传空数组**（§2252 我踩的坑）：
        //    Apple 文档：`retrieveConnectedPeripherals(withServices:)` 的 `services`
        //    **必须非空**，传 `[]` **直接返回空数组** ⇒ 什么都拿不到。
        //    我原来就是传 `[]` ⇒ 恒返回 0 个 ⇒ "没有已配对的外设"。
        //
        // ✅ 正确：传我们关心的**具体服务 UUID**。
        //    板子是 **BLE HID 键盘/鼠标**（服务 `0x1812`）+ 我们新加的 **NUS**。
        var svcs: [CBUUID] = [
            CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB"),  // ⭐ HID（板子主服务）
            CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),  // ⭐ 我们新加的 NUS
        ]
        svcs += Self.candidateServiceUUIDs
        var cands: [CBPeripheral] = central.retrieveConnectedPeripherals(withServices: svcs)
        // ② 再用「上次连过的 UUID」retrieve 一次（跨次开机也能连）
        if let id = lastKnownID,
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            if !cands.contains(where: { $0.identifier == p.identifier }) {
                cands.append(p)
            }
        }
        var n = 0
        for p in cands {
            let nm = p.name ?? ""
            if let h = hint, !h.isEmpty, !nm.contains(h) { continue }
            p.delegate = self
            target = p
            state = "connecting"
            central.connect(p, options: nil)
            NSLog("PGAgent BLE: 尝试连已配对外设 %@ (%@)", nm, p.identifier.uuidString)
            n += 1
            if hint == nil { break }     // 没指定名字 ⇒ 先连一个试试
        }
        if n == 0 {
            lastError = "没有已配对的外设（已连的 HID/NUS 里没找到；可先「扫 BLE」一次）"
        }
        return n
    }

    /// 写一条 HID 命令（自动补 \n，PG 固件按行解析）
    @discardableResult
    func send(_ cmd: String) -> Bool {
        guard let ch = writeChar, let p = target else {
            lastError = "未连接（writeChar=\(writeChar == nil ? "nil" : "ok")）"
            return false
        }
        var s = cmd
        if !s.hasSuffix("\n") { s += "\n" }
        guard let d = s.data(using: .ascii) else {
            lastError = "命令不是 ASCII: \(cmd)"
            return false
        }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(d, for: ch, type: type)
        return true
    }

    /// ⭐⭐⭐⭐⭐ 把 PG 的基准坐标（默认 451×977）转成**一次真正的点击**。
    ///
    /// # ⛔⛔⛔ §2600 血案：原来的 `["P:\(hx),\(hy)", "C:L"]` **点不动**（用户当场抓到的现象）
    ///
    /// ## 现象（用户亲眼看到，逐字）
    /// > 「**看你哪个失败的点击命令 就是圆点一直显示在那里。这就是和别的点击命令最大的区别。**」
    /// > 「**别的都能点击 就你这个不行。**」
    /// ⇒ iOS 连接蓝牙鼠标后会显示一个**圆点光标**。失败时**圆点一直停在那里不消失**
    ///   = HID 的**抬起事件没被 iOS 消费** ⇒ iOS 认为手指还按着 ⇒
    ///   按钮**只高亮、从不触发**（点击不成立）。
    ///
    /// ## 根因（库源码 + 真机实测，两条独立证据）
    /// ① **库源码**（`BleComboMouse.cpp` 的 `clickAbs` 注释，原文逐字）：
    ///    > `★★修复⑤(§1369, 真机铁证): iOS 还会丢弃【坐标完全相同的重复报告】——`
    ///    > `· P:x,y + C:L 点开关 ⇒ 开关停在"按住高亮"态,【不切换】;`
    ///    > `· 同坐标再点一次 ⇒ 画面 0 变化(报告被整个丢弃);`
    ///    > `· 仅把坐标移动 1px ⇒ 开关立刻恢复正常`
    ///    ⇒ `C:L` 走 `clickAbs()`：**按下帧与抬起帧坐标完全相同** ⇒ 抬起被丢。
    ///
    /// ② **真机实测**（`_dev/_2580_dot_stuck.py` / `_var/_var.py`，本机本轮）：
    ///    ```
    ///      ① P: + C:L（原文）                → 圆点卡住、页面纹丝不动
    ///      ② P: + D:x,y,x,y,600（长按）      → ✅ **一次就进广告页**
    ///    ```
    ///    实测成功的那条：
    ///    ```
    ///      P:28640,28300
    ///      D:28640,28300,28640,28300,600
    ///      → 页型: 任务中心 → 广告页（顶栏 '已成功领取1124金币×'）
    ///    ```
    ///    📏 而 `D:` 走的是 `swipeAbs()`：**按下后保持 14 帧插值移动** ⇒
    ///      抬起帧的形态/时间与按下帧**不同** ⇒ iOS 正常消费 ⇒ 点击成立。
    ///
    /// ## ✅ 结论（本函数现在的做法）
    /// ```
    ///   ① P:<hx>,<hy>              先 8 帧插值到位（库内 moveTo 自带）
    ///   ② D:<hx>,<hy>,<hx>,<hy>,ms 用 swipeAbs 做"原地长按" ⇒ 按下/抬起都被消费
    /// ```
    /// ⛔ **不再发 `C:L`** —— 它的抬起帧会被 iOS 丢弃（圆点卡住就是这个）。
    ///
    /// - Parameter holdMs: 按下→抬起总时长。**600ms** 是本机实测有效的值
    ///   （库里 `swipeAbs` 会把 holdMs 分给 14 帧，单帧 ≥4ms）。
    static func moveAndClick(x: Double, y: Double,
                             baseW: Double = 451, baseH: Double = 977,
                             yFix: Double = 4,
                             holdMs: Int = 600) -> [String] {
        let (hx, hy) = norm(x, y, baseW: baseW, baseH: baseH, yFix: yFix)
        return ["P:\(hx),\(hy)",
                "D:\(hx),\(hy),\(hx),\(hy),\(holdMs)"]
    }

    /// ⭐⭐ **原子点击**（`Q:x,y`）—— 固件的「移+按+放**一条** HID 序列」
    ///
    /// ## 为什么要有两条点击路（照电脑端 `_1377_ad_loop.py:3176`）
    /// ```python
    /// def _ext_q(cx, cy):
    ///     """★§1699b 走固件**原子通道** Q:x,y
    ///        （Mouse.moveToWithButtons = 移+按+放**一条** HID 序列）"""
    /// ```
    /// | 命令 | HID 序列 | 适用 |
    /// |---|---|---|
    /// | `P:` + `C:L` | **两条** | 通用（`click_at` 用它）|
    /// | **`Q:x,y`** | **一条（原子）** | ⭐ **时序敏感**场景：系统弹窗 |
    ///
    /// 📏 为什么弹窗要用原子的：`P:` 与 `C:L` 之间若被抢断/延迟，
    ///    指针可能已经不在目标上 ⇒ 点空。
    ///    一条序列发出 ⇒ **不可能被拆开**。
    static func atomicClickCmd(x: Double, y: Double,
                               baseW: Double = 451, baseH: Double = 977,
                               yFix: Double = 4) -> String {
        let (hx, hy) = norm(x, y, baseW: baseW, baseH: baseH, yFix: yFix)
        return "Q:\(hx),\(hy)"
    }

    /// ⭐ 坐标归一化（像素 → HID 0..32767）—— 与 `ks_io.py` 的 `plog()` 一致
    static func norm(_ x: Double, _ y: Double,
                     baseW: Double = 451, baseH: Double = 977,
                     yFix: Double = 4) -> (Int, Int) {
        let hx = max(0, min(32767, Int((x / baseW) * 32767.0)))
        let hy = max(0, min(32767, Int(((y + yFix) / baseH) * 32767.0)))
        return (hx, hy)
    }

    /// ⭐⭐ 滑动（`D:x1,y1,x2,y2,ms`）
    ///
    /// 📏 时长分档（照 **荔枝** 实测的两档，`_note_2012` §4）：
    ///   · `fast`  = **100 ms**（快速甩 —— 刷视频翻页）
    ///   · `mid`   = **220 ms**（默认 —— 通用）
    ///   · `slow`  = **2000 ms**（慢速拖 —— 需要精确控制的场景）
    ///
    /// 荔枝日志实证：
    /// ```
    /// x1=589 y1=766  → x2=589 y2=1789  hs=100     (x16)  快甩
    /// x1=589 y1=1789 → x2=589 y2=766   hs=2000    (x40)  慢拖
    /// ```
    enum SwipeSpeed: String {
        case fast, mid, slow
        /// ⭐ 回主屏专用档（§1645 实测：**120ms 生效、250ms 无效**）
        /// PC `HOME_FLING = (225,971,225,300,**120**)` —— 与 `.fast`(100) 不同，
        /// ⛔ 不要用 `.fast` 代替：注释写 120 而代码发 100 是曾经的 bug。
        case homeFling
        var ms: Int {
            switch self {
            case .fast:      return 100
            case .mid:       return 220
            case .slow:      return 2000
            case .homeFling: return 120
            }
        }
    }

    static func swipe(x1: Double, y1: Double, x2: Double, y2: Double,
                      speed: SwipeSpeed = .mid,
                      baseW: Double = 451, baseH: Double = 977,
                      yFix: Double = 4) -> String {
        let a = norm(x1, y1, baseW: baseW, baseH: baseH, yFix: yFix)
        let b = norm(x2, y2, baseW: baseW, baseH: baseH, yFix: yFix)
        return "D:\(a.0),\(a.1),\(b.0),\(b.1),\(speed.ms)"
    }

    /// ⭐⭐ 刷视频的「上滑换下一个」——x 固定屏幕中线，y 取**避让区**（避开顶/底栏）
    ///
    /// 荔枝的避让区（在 1179x2556 上）：`y 766 ~ 1789`
    /// ⇒ 归一化到基准 451x977：`766/2556*977 = 293`，`1789/2556*977 = 684`
    /// ⇒ ⭐ 即 `y1=684 → y2=293`（上滑）
    static func swipeNextVideo(speed: SwipeSpeed = .fast,
                               baseW: Double = 451, baseH: Double = 977,
                               yFix: Double = 4) -> String {
        let midX = baseW / 2.0
        let yTop = baseH * 0.30     // ≈293
        let yBot = baseH * 0.70     // ≈684
        return swipe(x1: midX, y1: yBot, x2: midX, y2: yTop, speed: speed,
                     baseW: baseW, baseH: baseH, yFix: yFix)
    }

    /// ⭐⭐ **iOS 左边缘右滑 = 返回手势**（固件的 `B:` 专用命令）
    ///
    /// ## 为什么必须有（§2253 对齐电脑端 + 固件注释）
    /// 固件 `B[:y]` 的实现：
    /// ```cpp
    /// int by = a.length() ? constrain(a.toInt(),0,32767) : 16383;
    /// Mouse.swipeAbs(40, by, 14000, by, 260);   // ⭐ 左边缘 40 → 右边 14000
    /// ```
    /// 固件源码里的用途注释：
    /// > 「★新增(§1372)：iOS **返回手势**(左边缘右滑)、广告转化浏览滑动、
    /// >   直播间换间都要用它」
    ///
    /// 📏 为什么它比点 `〈` 更可靠：
    /// **沉浸式页面（直播间/全屏视频）整页没有任何 `〈` 或 `✕`** ——
    /// 唯一出路就是这条**系统级返回手势**（电脑端 `_note_1377b` 实测）。
    ///
    /// - Parameter yNorm: 滑动的 y（HID 0..32767）；不传用固件默认 `16383`（屏幕中线）
    static func backGestureCmd(yNorm: Int? = nil) -> String {
        if let y = yNorm { return "B:\(y)" }
        return "B"          // 固件默认 y=16383
    }

    private var foundPeripherals: [CBPeripheral] = []

    /// ⭐⭐ **上次连成功的板子 UUID**（持久化）
    ///
    /// 用途：板子已连时**不广播** ⇒ 扫不到 ⇒ 需要 `retrievePeripherals([id])` 才能重连。
    /// 存起来 ⇒ 下次开机**自动重连**（照 PC `for_device()` 的"认得板子"语义）。
    private static let lastIDKey = "pgagent.ble.lastPeripheralID"

    var lastKnownID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: Self.lastIDKey) else { return nil }
            return UUID(uuidString: s)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastIDKey)
        }
    }
}

extension BLEController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        state = "bt-\(c.state.rawValue)"
        if c.state != .poweredOn {
            lastError = "蓝牙不可用 (state=\(c.state.rawValue))"
            return
        }
        // ⭐⭐⭐⭐⭐ §2705 蓝牙**变成可用**时补一次重连
        //
        // ## 真根因（REPORT_2703 + 实机复现）
        // App 原来**只在开机试一次**重连（`boot()` 里 `asyncAfter(1.5s){ connectPaired() }`）。
        // 而那一刻蓝牙往往**还是关的**（`state=bt-4`）⇒ 那次 `retrieveConnectedPeripherals`
        // 返回 0 个 ⇒ 之后**再也不会重连**。
        // ⇒ 表现：「明明连了蓝牙，App 状态还是灰的/`disconnected`」，直到手动调
        //   `/ble/connect-paired` 才变 `ready:…`（实测：调一次立刻好，90s 稳定不掉）。
        // ⇒ 修法：**状态一变 poweredOn 就补连**（这才是"蓝牙开了就连"的正确语义）。
        lastError = ""
        scheduleReconnect(reason: "蓝牙已开启")
    }

    /// ⭐ §2705 带**退避**的重连（⛔ 不连发 —— 连发会把刚建起的链路打崩）
    ///
    /// 退避档：2s / 5s / 15s / 60s，到顶后维持 60s。
    /// 只重连**没有就绪通道**的情况（`ready*` 时不打扰）。
    private func scheduleReconnect(reason: String) {
        guard central.state == .poweredOn else { return }
        guard !state.hasPrefix("ready") else { return }
        reconnectAttempt += 1
        reconnectGeneration += 1
        let gen = reconnectGeneration
        let idx = min(reconnectAttempt - 1, Self.reconnectBackoff.count - 1)
        let delay = Self.reconnectBackoff[idx]
        NSLog("PGAgent BLE: %@ ⇒ %.0fs 后重连（第 %d 次）", reason, delay, reconnectAttempt)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // ⛔ 已经排了更新的一次 ⇒ 这次作废（⛔ 不要叠加重连，避免把链路打崩）
            guard gen == self.reconnectGeneration else { return }
            guard self.central.state == .poweredOn else { return }
            guard !self.state.hasPrefix("ready") else { return }
            let n = self.connectPaired()
            NSLog("PGAgent BLE: 补连尝试打到 %d 个外设 state=%@", n, self.state)
            // 还是没就绪 ⇒ 继续退避重试（⛔ 不放弃：板子可能还没上电）
            if !self.state.hasPrefix("ready") { self.scheduleReconnect(reason: "仍未就绪") }
        }
        reconnectWork?.cancel()
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !foundPeripherals.contains(where: { $0.identifier == p.identifier }) else { return }
        foundPeripherals.append(p)
        let n = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "(无名)"
        let line = "\(n) | \(p.identifier.uuidString.prefix(8)) | rssi=\(RSSI)"
        devices.append(line)
        scanStore?(line)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = "connected:\(p.name ?? "?")"
        // ⭐ 记住它 ⇒ 下次开机自动重连（板子已连时**不广播**，只能靠这个）
        lastKnownID = p.identifier
        // ⭐ §2705 连上了 ⇒ 退避计数清零（下一次断开从最短档重来）
        reconnectAttempt = 0
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = "connect-failed"
        lastError = "连接失败: \(error?.localizedDescription ?? "?")"
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        state = "disconnected"
        writeChar = nil
        nusRxFound = false
        // ⭐ §2705 记下 error 原文（区分「加密失败」还是「板子复位」，见 SWIFT_BATCH #3）
        lastError = error.map { "断开: \($0.localizedDescription)" } ?? ""
        NSLog("PGAgent BLE: 断开 %@ error=%@", p.name ?? "?", lastError.isEmpty ? "(无)" : lastError)
        // ⭐⭐⭐ §2705 意外断开 ⇒ **自动重连**（板子还在的话几秒内就回来）
        //   ⛔ 原来这里什么都不做 ⇒ 掉一次就永久黑，直到手动 `/ble/connect-paired`。
        scheduleReconnect(reason: "意外断开")
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        // ⭐ 诊断：把发现的服务打出来（排查「找不到可写特征」）
        for s in p.services ?? [] {
            NSLog("PGAgent BLE: 发现服务 %@", s.uuid.uuidString)
            probeStore.append("服务 \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
        if (p.services ?? []).isEmpty {
            lastError = "外设没暴露任何服务"
            NSLog("PGAgent BLE: %@", lastError)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            let w = ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)
            let n = ch.properties.contains(.notify) || ch.properties.contains(.indicate)
            probeStore.append("  特征 \(ch.uuid.uuidString) write=\(w) notify=\(n)")
            NSLog("PGAgent BLE: 特征 %@ (%@) write=%d notify=%d",
                  ch.uuid.uuidString, s.uuid.uuidString, w ? 1 : 0, n ? 1 : 0)

            // ⭐⭐ **优先认 NUS 的 RX 特征**（`6E400002-…`）——
            //    那是固件里我们**专门给手机发命令**加的可写特征。
            //    ⛔ 不能"取第一个可写的"：HID 服务里也有可写特征
            //       （如 HID Control Point `0x2A4C`），写它**不是**我们的命令协议。
            if ch.uuid == CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
                writeChar = ch
                nusRxFound = true
                NSLog("PGAgent BLE: ⭐ 认到 NUS 命令特征")
            } else if ch.uuid == CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") {
                notifyChar = ch
                p.setNotifyValue(true, for: ch)
                NSLog("PGAgent BLE: ⭐ 订阅 NUS 回执特征")
            } else if writeChar == nil && w {
                // 兜底：没找到 NUS 时的兼容路径（老固件）
                writeChar = ch
            }
        }
        if nusRxFound {
            state = "ready:\(p.name ?? "?")"
            lastError = ""
            // ⭐ §2705 通道真就绪 ⇒ 重连退避计数清零
            reconnectAttempt = 0
        } else if writeChar != nil {
            state = "ready(非NUS):\(p.name ?? "?")"
            lastError = "板子没有 NUS 命令特征（固件要烧 v2251 双向版）"
        } else {
            lastError = "外设没找到可写 characteristic"
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        // ⭐ 收到板子的回执（`ok:<命令>`）⇒ 证明**双向通了**
        if let d = ch.value, let s = String(data: d, encoding: .utf8) {
            lastAck = s.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("PGAgent BLE: 板子回执 %@", lastAck)
        }
    }
}
