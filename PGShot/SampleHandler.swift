import ReplayKit
import UIKit

/// ⭐⭐⭐⭐⭐ 「眼」—— **录屏广播扩展**（荔枝/所有 RPA App 的真正做法）。
///
/// ## 架构（v0.10.0：写 **App Group 共享容器**）
/// ```
/// 主 App: RPSystemBroadcastPickerView().triggerPicker()   ← 程序化启动
///   ↓
/// iOS 启动本扩展
///   ↓
/// processSampleBuffer(每帧) ⇒ JPEG ⇒ 写 <group>/Documents/frames/lastframe.jpg
///   ↓
/// 主 App: 读**同一个**目录 ⇒ 拿到帧（⛔ 不依赖前台 / HTTP / 网络）
/// PC    : `ios file ls --app-group=<gid> --path=/Documents/frames`
/// ```
///
/// ## ⛔⛔ 曾经的错误认知（§2200 真机实测推翻）
/// 老注释写「扩展与主 App **共享同一个** Documents」—— **错的**。实测：
/// ```
/// 主 App 容器 : .../run.pgagent.PGAgent.8W9ZSMW4UW/Documents        ⇒ 只有 pgconfig
/// 扩展容器    : .../run.pgagent.PGAgent.8W9ZSMW4UW.PGShot/Documents ⇒ 128 个帧
/// ```
/// ⇒ 扩展写自己的 Documents，主 App **永远读不到**（这正是「眼瞎」的根因）。
///
/// ## 三条路的实测结论
/// | 路 | 结论 |
/// |---|---|
/// | 各写各的 Documents | ⛔ 两个容器，读不到 |
/// | HTTP POST 回主 App | ⚠️ 能用，但要求主 App 活着且在听 |
/// | **⭐ App Group 共享容器** | ✅ **两边同目录**（本版采用，HTTP 作兜底）|
///
/// ## 免费账号约束（`_note_1798`）
/// 免费 Apple ID 的**描述文件**里没有 app group entitlement，
/// 但**签名后实测** App 的 entitlements 里**确实有**
/// `group.run.pgagent.PGAgent.8W9ZSMW4UW`，且该容器**可读写**（§2210）。
/// ⇒ 所以走共享容器，并用「真写一个字节」验证可用性，不可用自动退回本容器。
class SampleHandler: RPBroadcastSampleHandler {

    private var seq = 0
    private var lastWrite = Date.distantPast
    /// ⭐ 写盘频率（帧/秒）—— 2 fps 够识别用，省电省 IO
    private let fps = 2.0
    /// ⭐ 降采样后的宽度（识别够用，写盘快）
    private let outWidth: CGFloat = 451

    /// 停止标志文件名（主 App 放/删它来控制录屏，照荔枝的做法 `_note_2011` §8）
    private let stopFlag = "stop_broadcast"

    /// ⭐ 主 App 的 HTTP 端口（帧 POST 到这里）
    private let port: UInt16 = 8899
    /// ⭐ 复用 URLSession（扩展存活期内一直用）
    private var session: URLSession?

    /// ⭐⭐⭐ 本扩展**自己的** Documents（仅在 App Group 不可用时兜底）
    private var ownDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// ⭐⭐⭐ 探测结果缓存（⛔ **必须缓存**：`dir` 每帧都要用，
    ///    若每帧都「建目录 + 写探针」会白烧 IO 并拖慢取帧）
    private var cachedDir: URL?

    /// ⭐⭐⭐⭐ 「眼」的落盘目录 —— **优先 App Group 共享容器**。
    ///
    /// **为什么必须优先共享容器**（§2210 真机实测）：
    /// ```
    /// 主 App 容器 : .../run.pgagent.PGAgent.8W9ZSMW4UW/Documents        ⇒ 只有 pgconfig
    /// 扩展容器    : .../run.pgagent.PGAgent.8W9ZSMW4UW.PGShot/Documents ⇒ 128 个帧 ✅
    /// ```
    /// ⇒ 扩展**写得到**，主 App **读不到**（两个不同容器）。
    /// ⇒ 共享容器一上，**两边同目录** ⇒ 主 App 直接读，⛔ 不依赖 HTTP / 前台。
    ///
    /// 探测方式与主 App 一致（两边**同一份逻辑**，避免不一致）：
    /// 「containerURL 拿得到 + 建目录 + 真写一个字节」都过才算可用。
    private var dir: URL {
        if let d = cachedDir { return d }
        let d = sharedFramesDir() ?? ownDir
        cachedDir = d
        return d
    }

    /// 共享帧目录（`<group>/Documents/frames`）；不可用 ⇒ nil
    ///
    /// ⭐⭐⭐ §2242 **group id 动态推导，⛔ 不写死**
    ///
    /// 为什么必须动态：签名工具会把**签名者的 team id** 插进 group id：
    /// ```
    /// 构建时       : group.run.pgagent.PGAgent
    /// iloader 签名 : group.run.pgagent.PGAgent.8W9ZSMW4UW   ← 这是**某个账号**的 team
    /// ```
    /// ⇒ 换手机 / 换 Apple ID 签名 ⇒ 后缀就变 ⇒ 写死会让整条「眼」失配。
    ///
    /// ✅ 从**本扩展自己的 entitlements** 读真实 group
    ///    （扩展有**独立** entitlements ⇒ 必须各自读，⛔ 不能借用主 App 的）。
    private func sharedFramesDir() -> URL? {
        let fm = FileManager.default
        for g in candidateGroups() {
            guard let root = fm.containerURL(
                forSecurityApplicationGroupIdentifier: g) else { continue }
            let d = root.appendingPathComponent("Documents/frames", isDirectory: true)
            do {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                let probe = d.appendingPathComponent(".pgshotprobe")
                try Data([0x50]).write(to: probe, options: .atomic)
                try? fm.removeItem(at: probe)
                NSLog("PGShot: 共享容器可用 ⇒ %@ (group=%@)", d.path, g)
                return d
            } catch {
                continue
            }
        }
        NSLog("PGShot: ⛔ 无共享容器 ⇒ 退回本扩展 Documents（主 App 读不到）")
        return nil
    }

    /// ⭐ 候选 group：**Bundle 前缀推导** + 常见形态兜底
    ///
    /// ## ⚠️ 为什么不用 `SecTaskCopyValueForEntitlement`（§2250 编译踩过）
    /// 那个 API（`SecTaskCreateFromSelf`）在 **appex 目标里编不过**：
    /// ```
    /// SampleHandler.swift:122: error: cannot find 'SecTaskCreateFromSelf' in scope
    /// ```
    /// ⇒ 它是 **Security 框架的私有/未公开** 部分（主 App 目标能编是巧合）。
    ///
    /// ## ✅ 改用**公开**且**足够准**的推导
    /// 签名工具插的 team 后缀**只加在 bundle id 最后一段**之前，例如：
    /// ```
    /// 扩展 bundle : run.pgagent.PGAgent.8W9ZSMW4UW.PGShot
    /// 对应 group  : group.run.pgagent.PGAgent.8W9ZSMW4UW
    /// ```
    /// ⇒ 规则：**去掉最后一段**，前面整串加 `group.` 前缀。
    ///    再兜常见形态（未签名 / 猜不到时）。
    ///
    /// ⚠️ 但**真正生效与否由 `containerURL(...)` 决定** ——
    ///    它无权限时返回 nil ⇒ 下面的「拿路径 + 建目录 + 写探针」会**自然筛掉**错的候选。
    ///    （这一段逻辑与主 App 的 `AppGroup.probe()` 同一套，⛔ 不靠猜。）
    private func candidateGroups() -> [String] {
        var out: [String] = []
        // ① ⭐ 从**本扩展的 bundle id** 推导（去掉最后一段 = 去掉 .PGShot）
        if let bid = Bundle.main.bundleIdentifier {
            let parts = bid.split(separator: ".")
            if parts.count >= 2 {
                // run.pgagent.PGAgent.8W9ZSMW4UW.PGShot
                //   ⇒ 去掉最后一段 ⇒ group.run.pgagent.PGAgent.8W9ZSMW4UW
                let all = parts.map(String.init)
                out.append("group." + all.dropLast().joined(separator: "."))
                // run.pgagent.PGAgent.PGShot（未插 team 后缀时）
                //   ⇒ 也去掉最后一段 ⇒ group.run.pgagent.PGAgent
                out.append("group." + all.dropLast().joined(separator: "."))
                // bundleIdPrefix 只有两段时（run.pgagent）
                out.append("group." + all.prefix(2).joined(separator: "."))
            }
        }
        // ② 兜底（常见形态；⛔ 真正的判据是 containerURL 能不能写）
        out += ["group.run.pgagent.PGAgent",
                "group.run.pgagent.PGAgent.8W9ZSMW4UW",
                "group.pgagent"]
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// ⭐ 停止标志可能出现在**两个**位置（主 App 写自己的 Documents；
    ///    共享容器可用时也会写到共享目录）⇒ 两处都查，谁先出现算谁。
    private var stopFlagSeen: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(stopFlag).path) { return true }
        if fm.fileExists(atPath: ownDir.appendingPathComponent(stopFlag).path) { return true }
        return false
    }

    /// 清掉两个位置的停止标志（开机时双保险）
    private func clearStopFlags() {
        let fm = FileManager.default
        try? fm.removeItem(at: dir.appendingPathComponent(stopFlag))
        try? fm.removeItem(at: ownDir.appendingPathComponent(stopFlag))
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("PGShot broadcastStarted dir=%@ (共享容器=%@)",
              dir.path, sharedFramesDir() != nil ? "是" : "否")
        // ⭐ 启动时清掉停止标志（主 App 也会清一次，双保险）
        //    两个位置都清 —— 主 App 可能写在它自己的 Documents 里
        clearStopFlags()
    }

    override func broadcastPaused() { NSLog("PGShot broadcastPaused") }
    override func broadcastResumed() { NSLog("PGShot broadcastResumed") }

    override func broadcastFinished() {
        NSLog("PGShot broadcastFinished")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        // ① 限流
        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= (1.0 / fps) else { return }
        lastWrite = now

        // ② 停止标志（荔枝用文件当控制信号）—— 两个位置都查
        if stopFlagSeen {
            NSLog("PGShot 收到停止标志 ⇒ 结束广播")
            endBroadcastCleanly()
            return
        }

        // ③ 出图
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let img = UIImage(cgImage: cg)

        // ④ 降采样（省 IO，识别够用）
        let scaled = downscale(img, toWidth: outWidth)
        guard let jpg = scaled.jpegData(compressionQuality: 0.7) else { return }

        seq += 1

        // ⑤ ⭐⭐⭐ 帧落到**两边都能看见的地方**（按可靠性排序）：
        //
        // ⚠️⚠️ **关键实测（§2200）**：扩展的 Documents **不是主 App 的 Documents**！
        //   · 扩展容器: run.pgagent.PGAgent.8W9ZSMW4UW.PGShot/Documents  ⇒ 实测 128 个帧文件
        //   · 主 App 容器: run.pgagent.PGAgent.8W9ZSMW4UW/Documents        ⇒ 只有 pgconfig
        //
        // ⇒ ① ⭐⭐⭐ **App Group 共享容器** `<group>/Documents/frames/`（§2210 新增）
        //       ⇒ 主 App 直接读，⛔ 不依赖前台、⛔ 不依赖 HTTP、⛔ 不依赖本扩展存活
        //    ② ⭐ HTTP POST 到主 App `127.0.0.1:8899/frame`（主 App 活着时最快）
        //    （共享容器不可用时 `dir` 自动退回本扩展 Documents —— 仅调试用）
        writeShared(jpg)
        post(jpg, seq: seq)
    }

    // MARK: - 工具

    /// ⭐⭐⭐ 写进「眼」的落盘目录（**优先 App Group 共享容器**）。
    ///
    /// 目录由 `dir` 决定（共享可用即共享，否则本容器）。
    /// 同时更新 `lastframe.jpg`（主 App 轮询它）并按序号留档。
    private func writeShared(_ data: Data) {
        write(data, name: "lastframe.jpg")
        if seq % 10 == 0 {
            write(data, name: "frame_\(seq).jpg")
        }
    }

    /// ⭐⭐ 把帧 **POST 给主 App**（`http://127.0.0.1:8899/frame`）—— **兜底路**。
    ///
    /// ## 为什么还要留着它（§2210）
    /// 主路已经是 **App Group 共享容器**（`writeShared` ⇒ 两边同目录）。
    /// 但万一某次签名后**扩展拿不到 app group**，这条 HTTP 路还能救：
    ///   · 同一台设备，`127.0.0.1` 回环可达
    ///   · ⚠️ 前提：主 App **活着**且 HTTP（8899）在听
    ///
    /// ## ⛔ 曾经的错误结论（已更正）
    /// 老注释写「免费 Apple ID **没有 App Group**」—— **不对**。
    /// 真机实测：装上后主 App 的 entitlements **确实有**
    /// `group.run.pgagent.PGAgent.8W9ZSMW4UW`，且该容器**可读写**。
    /// ⇒ 共享容器才是正路，HTTP 只是保险。
    private func post(_ data: Data, seq: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/frame?seq=\(seq)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 2
        if session == nil {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 2
            cfg.timeoutIntervalForResource = 2
            cfg.waitsForConnectivity = false
            // ⛔ 不要走系统代理（会卡死；`_note_2090` 踩过）
            cfg.connectionProxyDictionary = [:]
            session = URLSession(configuration: cfg)
        }
        session?.dataTask(with: req) { _, _, err in
            if let err = err {
                // 主 App 不在前台时会失败，属正常（帧已本地留档）
                NSLog("PGShot frame post: %@", String(describing: err))
            }
        }.resume()
    }

    /// ⭐ 正常结束广播（⛔ 不报错）。
    ///
    /// ⚠️ `finishBroadcastWithoutError()` **在 Swift 里不可见**（它是 RPBroadcastSampleHandler
    ///    的私有/ObjC 方法，`livekit` 也是靠一个 ObjC helper `LKObjCHelpers` 调的）。
    /// ⇒ 这里用 **selector 动态调用** 达到同样效果；
    ///    若将来 iOS 改了名字，就退回「带一个无害错误」结束（体验略差但不会崩）。
    private func endBroadcastCleanly() {
        let sel = NSSelectorFromString("finishBroadcastWithoutError")
        if responds(to: sel) {
            perform(sel)
            return
        }
        // 兜底：带一个自定义错误结束（系统会显示「录制已停止」而不是崩溃）
        let e = NSError(domain: "PGShot", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "已停止录屏"])
        finishBroadcastWithError(e)
    }

    private func downscale(_ img: UIImage, toWidth w: CGFloat) -> UIImage {
        guard img.size.width > w else { return img }
        let scale = w / img.size.width
        let newSize = CGSize(width: w, height: (img.size.height * scale).rounded())
        let r = UIGraphicsImageRenderer(size: newSize)
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func write(_ data: Data, name: String) {
        let dst = dir.appendingPathComponent(name)
        let tmp = dir.appendingPathComponent(name + ".tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            // 原子替换（PC 端要么看到旧的完整帧，要么看到新的完整帧）
            _ = try? FileManager.default.replaceItemAt(dst, withItemAt: tmp)
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
            if !FileManager.default.fileExists(atPath: dst.path) {
                try data.write(to: dst, options: .atomic)
            }
        } catch {
            NSLog("PGShot 写帧失败: %@", String(describing: error))
        }
    }
}
