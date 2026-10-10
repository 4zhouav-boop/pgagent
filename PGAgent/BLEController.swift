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
        // ⚠️ `retrievePeripherals(withIdentifiers:)` 传**空数组会返回空**
        //    （它要的是「你确实知道的那几个 UUID」）⇒ 所以只能：
        //      ① `retrieveConnectedPeripherals` —— 系统里**当前已连接**的
        //      ② 记住我们**上次连过**的 UUID（`lastKnownID`）→ 下次直接 retrieve
        var cands: [CBPeripheral] = central.retrieveConnectedPeripherals(withServices: [])
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
            lastError = "没有已配对的外设（先去「扫 BLE」连一次）"
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

    /// ⭐ 把 PG 的基准坐标（默认 451×977）转成 HID 的 0..32767
    ///    公式与生产脚本 `ks_io.py` 一致（含 `Y_FIX = 4`）
    static func moveAndClick(x: Double, y: Double,
                             baseW: Double = 451, baseH: Double = 977,
                             yFix: Double = 4) -> [String] {
        let hx = Int((x / baseW) * 32767.0)
        let hy = Int(((y + yFix) / baseH) * 32767.0)
        return ["P:\(hx),\(hy)", "C:L"]
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
        var ms: Int {
            switch self {
            case .fast: return 100
            case .mid:  return 220
            case .slow: return 2000
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

    /// ⭐ 刷视频的「上滑换下一个」——x 固定屏幕中线，y 取**避让区**（避开顶/底栏）
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
        if c.state != .poweredOn { lastError = "蓝牙不可用 (state=\(c.state.rawValue))" }
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
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = "connect-failed"
        lastError = "连接失败: \(error?.localizedDescription ?? "?")"
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        state = "disconnected"
        writeChar = nil
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                if writeChar == nil { writeChar = ch }   // 取第一个可写的
            }
        }
        if writeChar != nil {
            state = "ready:\(p.name ?? "?")"
        } else {
            lastError = "外设没找到可写 characteristic"
        }
    }
}
