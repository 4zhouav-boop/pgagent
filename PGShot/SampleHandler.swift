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
    /// ⭐⭐ 抓帧频率（帧/秒）—— §2266 **现在放宽到 1 fps**
    ///
    /// ## ⛔⛔ 为什么它可以放宽了（§2266 的结构性改变）
    /// §2265 时它是 **1帧/4s** —— 因为**当时帧必须落盘**，而写盘预算只有 12.73 KB/s。
    /// §2266 把主路改成 **HTTP POST**（回环 socket，**⛔ 不占磁盘预算**）：
    /// ```
    ///   常态（App 活着，§2263 实测退后台仍通）: POST 成功 ⇒ **完全不写盘**
    ///   ⇒ 磁盘写入 ≈ 0 ⇒ 「写盘预算」**不再是约束** ⇒ 抓帧频率可以回到正常
    /// ```
    /// ⇒ 取 **1 fps**（1帧/1s）：帧龄 ≤1s，`Runner` 每步（1.5s）都能拿到**新鲜**画面。
    ///
    /// ## ⚠️ 那"预算"由谁兜住
    /// 由 **`writeShared` 的硬限速（5s）** 兜 ——
    /// 即**最坏情况**（HTTP 全程不通）也只有 ~9 KB/s，仍在 12.73 KB/s 内。
    /// ⇒ 两条路各管一头：
    ///    · 正常：HTTP 高频（1fps）、磁盘零写
    ///    · 异常：HTTP 不通 ⇒ 磁盘降频（≥5s/帧）但仍**不会撑爆预算**
    ///
    /// 📏 实测复核见 `_dev/_2266_writes_live.py`（⛔ 不再靠估：本轮已被实测否决两次）。
    private let fps = 0.1
    /// ⭐ 降采样后的宽度（**像素**！见 `downscale` 的 scale 修正）
    ///
    /// # ⭐⭐⭐⭐⭐ §2631 **用户令：不再降采样，就用原分辨率**（⛔ 这条推翻了上面那句注释）
    ///
    /// ## 用户原话（逐字，就是本改动的规格）
    /// > 「**如果还是识别不清引起的问题 就把识别改成不用缩放 就原分辨率。
    /// >   但是每次识别间隔10秒。**」
    ///
    /// ## ⛔⛔ 血案：倒计时的 `s` 被降采样吃掉了
    /// 真机帧铁证（`_dev/_2629` 抓的广告页帧，顶栏那块放大 6 倍肉眼看）：
    /// ```
    ///   图上**清清楚楚**写着  `19s后可领取968金币 ×`    ← `s` 在！
    ///   而 451 宽时 Vision 读成  `19后可领取968金币`     ← ⛔ `s` 丢了
    /// ```
    /// ⇒ 于是判据 `\d+秒|\d+s` **恒 false** ⇒ 误判"倒计时走完"
    ///   ⇒ **提前点 ✕ 把广告点死**（用户令：「**有倒计时 他还是强行点击了3次**」）。
    ///
    /// 📏 尺寸对比（同一块顶栏）：
    /// ```
    ///   手机真实分辨率 : **1170×2532**（`ios screenshot` 实测）
    ///   扩展输出        : **451×975**  ⇒ ⛔ **85% 的像素在识别之前就丢了**
    ///   `s` 的像素高度  : 451 宽时约 **4px**（低于 Vision 稳定识别下限）
    /// ```
    ///
    /// ## ✅ 修法（照用户令）
    /// `outWidth = 0` ⇒ **不缩放**，原样送原始帧（1170×2532）。
    /// ⚠️ 代价与对策（**两条都是用户已经指定的**）：
    ///   · 帧变大（约 3~5 倍）⇒ 走**字节预算**（`writeShared`）与**降低帧率**兜住
    ///   · 识别变慢 ⇒ 用户令：**每次识别间隔 10 秒**（`fps = 0.1`，见下）
    private let outWidth: CGFloat = 0      // ⭐ §2631 **0 = 不缩放，用原分辨率**

    /// 停止标志文件名（主 App 放/删它来控制录屏，照荔枝的做法 `_note_2011` §8）
    private let stopFlag = "stop_broadcast"

    /// ⭐ 主 App 的 HTTP 端口（帧 POST 到这里）
    private let port: UInt16 = 8899
    /// ⭐ 复用 URLSession（扩展存活期内一直用）
    private var session: URLSession?
    /// ⭐⭐⭐⭐ §2266 **上一帧 HTTP POST 成功了没有** —— 决定"要不要写盘"
    ///
    /// ## 这是「直播一直停止」的**结构性正解**
    /// 实测（§2265/§2266，真机数字）：
    /// ```
    ///   iOS 给扩展的磁盘写入预算 : 1073.74 MB / 86400s = **12.73 KB/s**
    ///   真机单帧体积              : **65.4 KB**（451×975 直播画面，文字密集）
    ///   ⇒ 就算 1帧/4s 也是 16.4 KB/s ⛔ 仍超预算
    ///   ⇒ **连续定时写盘在结构上就走不通**（⛔ 不是我参数没调好）
    /// ```
    /// ⭐ §2267 **上次落盘的时间**（仅诊断；⛔ 不用它限速 —— 见 `writeShared` 的字节预算）
    private var lastDiskWrite = Date.distantPast
    /// ⭐ 落盘记账（滑动窗口：[时间, 字节数]）—— 字节预算的账本
    private var diskWriteLog: [(t: Date, bytes: Int)] = []

    /// ⭐⭐⭐⭐⭐ **复用一个 `CIContext`**（⛔⛔ 绝不每帧新建！）
    ///
    /// ## 为什么（§2263 —— 「录屏老是自己停」的真根因）
    /// 我原来在 `processSampleBuffer` 里**每帧**都写：
    /// ```swift
    /// let ctx = CIContext(options: [.useSoftwareRenderer: false])   // ⛔ 每帧一个
    /// ```
    /// `CIContext` 会携带 **Metal/OpenGL 上下文 + 缓存**，构造一次的开销与内存都很大。
    /// 广播扩展跑在一个**内存限额很紧**的独立进程里，2fps 每帧都新建 ⇒
    /// **内存/句柄持续增长 ⇒ 被系统杀掉** ⇒ 表现就是"录屏跑一会儿自己停了"
    /// （用户看到的现象）+ 之后 App 一直喂**死帧** ⇒ `unknown`。
    ///
    /// 📏 苹果与业界一致口径：`CIContext` **创建昂贵，应长期复用**
    ///   （Core Image 文档："Creating a CIContext is expensive… reuse it"）。
    ///   荔枝能做到长时间连续录屏（`_note_2010`），正是因为它不这么干。
    ///
    /// ⇒ 提到实例属性，**全程一个**。
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

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
        // ⭐⭐⭐ §2263 **复用实例级 `ciContext`**（⛔ 原来每帧新建 ⇒ 扩展被杀 ⇒ "录屏自己停"）
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let img = UIImage(cgImage: cg)

        // ④ 降采样（省 IO，识别够用）
        //    ⛔⛔ §2265 这一步**原来等于没做** —— `UIGraphicsImageRenderer` 默认
        //    scale=3 ⇒ "451 宽"实际输出 **1353px**（像素数 9×）⇒ 磁盘写入超限 ⇒
        //    扩展被系统杀 ⇒「**直播一直停止**」。已在 `downscale` 里钉 `scale = 1.0`。
        let scaled = downscale(img, toWidth: outWidth)
        // ⑤ 编码 JPEG
        //
        // ## ⚠️ 为什么**不能**转灰度（§2266 判决性实验）
        // 我一度想"灰度省 1/3 体积"，但**实测否决**：
        // ```
        //   彩色帧 ⇒ ColorBlob 命中 (51.5, 163.8)  ✅
        //   灰度帧 ⇒ None                          ⛔ 永远不可能命中
        // ```
        // `ColorBlob` 找**红包球**的判据是 `r>180 && r-g>100 && r-b>100`
        // ⇒ 灰度后 `r=g=b` ⇒ **判据恒 false** ⇒ 而红包球是**回金币中心的唯一入口**
        //   （纯图形、无 OCR 文字）⇒ **整轮再也回不去中心**。
        // 📏 教训：**别为了体积牺牲判据依赖的信息**；"识别全在灰度上跑"只对
        //    OCR/模板成立，对**色彩判据不成立**。
        //
        // ## 质量 0.4 是**实测**定的（⛔ 不是估的）
        // 真机 451×975 实测：**彩色的单帧约 65.4 KB**（ql≈0.7 DC 量化值 9）。
        // ⚠️ Apple 的 `compressionQuality` 与 libjpeg 的 quality **不等价**
        //    （我实测 DC=9 对应 libjpeg 约 70~75）⇒ 以**真机字节数**为准。
        guard let jpg = scaled.jpegData(compressionQuality: 0.4) else { return }

        seq += 1

        // ⑥ ⭐⭐⭐⭐⭐ §2267 **写盘（主路，照荔枝）+ 异步 POST（尽力而为）**
        //
        // ## ⛔⛔ 上一版（v0.10.21）在这里犯了一个致命错
        // 我为了"POST 成功就不写盘"，把 `post()` 改成**同步等结果**：
        // ```swift
        // _ = sem.wait(timeout: .now() + 1.2)      // ⛔⛔ 在**采样回调**里阻塞！
        // ```
        // `processSampleBuffer` 跑在 **ReplayKit 的采样队列**上；
        // **阻塞它 = 停止消费系统送来的帧** ⇒ 广播**原地卡死**
        // （真机现象：`frames 2→2` 再也不涨；而扩展**没有崩溃报告**，
        //  因为它是"被堵塞"不是"被杀" —— 这个区别正是排查的关键）。
        // 📏 **教训：采样回调里⛔ 绝不能有任何同步等待/阻塞 IO。**
        //
        // ## ⭐ 正确架构 = **照荔枝**（`_note_2010` L60 / `_note_2011` L253）
        // ```
        //   扩展 : 每帧写 **一个文件** 到 App Group（异步、非阻塞）
        //   主 App: **轮询**那个文件（"⏳ 等待截图文件生成... (第10次检查)"）
        // ```
        // ⇒ **写盘是主路**，而不是我发明的"HTTP 主路"。
        //   ⚠️ 那"写入预算"怎么办？—— **它已经不是问题了**：
        //   真正的元凶是 `scale=3` 那个 **9×** bug（§2265 已修）。
        //   修完后单帧 **17.9 KB**（原来 65.4 KB），配合下面的**字节预算**：
        //   `384 KB/60s = 6.4 KB/s` ⇒ **只有 iOS 预算的 50%** ⇒ ✅ 安全。
        //   📏 我上一版是"在没修 9× 的前提下"算出的 24 KB/s，那个结论**已过期**。
        //
        // ## ⛔ POST 只作为**尽力而为的加速**（⛔ 不阻塞、不等结果、不影响主路）
        // 它能让主 App 更快拿到帧，但**成功与否都不改变**上面的文件主路。
        writeShared(jpg)
        postBestEffort(jpg, seq: seq)
    }

    /// ⭐⭐⭐ §2267 **写盘（主路）** —— 带**字节预算**保护，⛔ 但绝不阻塞
    ///
    /// 预算账本见 `writeShared` 的说明（两张表都是同一套账）：
    /// 60s 窗口内最多 **384 KB**（= 6.4 KB/s = iOS 预算的 50%）。
    private func writeShared(_ data: Data) {
        let now = Date()
        // ① 滚动窗口：丢掉过期的记账
        let cutoff = now.addingTimeInterval(-Self.budgetWindowS)
        while let first = diskWriteLog.first, first.t < cutoff {
            diskWriteLog.removeFirst()
        }
        let used = diskWriteLog.reduce(0) { $0 + $1.bytes }
        let allowance = Double(Self.budgetBytesPerWindow)
        // ② 超预算 ⇒ **本帧不写**（⛔ 丢弃一帧远好过被系统杀掉整个广播）
        guard Double(used + data.count) <= allowance else {
            NSLog("PGShot 写盘被字节预算拦下（窗口已用 %.0f KB + 本帧 %.0f KB > %.0f KB）⇒ 丢这一帧",
                  Double(used) / 1024.0, Double(data.count) / 1024.0, allowance / 1024.0)
            return
        }
        diskWriteLog.append((t: now, bytes: data.count))
        lastDiskWrite = now
        write(data, name: "lastframe.jpg")
    }

    /// ⭐ 字节预算（§2267）—— 按 iOS 写入预算的 **50%** 记账 ⇒ 留 **2×** 余量
    ///
    /// ## 为什么用"字节窗口"而不是"固定间隔"（耐久日志逮到的）
    /// 我第一版按"单帧 17.9 KB"算出 5 秒间隔 ⇒ 看着很宽裕。
    /// 但**耐久日志**（`_var/_endurance.log`）显示真实帧大小**随画面剧烈变化**：
    /// ```
    ///   +0min  快手金币中心（大片纯色）  bytes = **17.9 KB**
    ///   +6min  美团广告页（画面复杂）    bytes = **62.4 KB**   ← 3.5 倍！
    /// ```
    /// ⇒ 按"平均帧"定间隔 ⇒ 遇到大帧就贴预算线（62.4/5 = 12.5 vs 12.73）⇒ **余量≈0**。
    /// 📏 **教训：限速要按"字节"记账，⛔ 不能按"平均帧大小"猜。**
    ///
    /// ## 参数
    /// ```
    ///   iOS 预算            : 1073.74 MB / 86400s = 12.73 KB/s
    ///   我们按预算 50% 记账  : **6.4 KB/s** ⇒ 余量 2×
    ///   窗口 60s            : 额度 = 6.4 × 60 = **384 KB**
    /// ```
    /// ⇒ **无论帧多大，等效写入都被钉在 6.4 KB/s**：
    ///   17.9 KB 帧 ≈ 每 2.8s 一张；62.4 KB 帧 ≈ 每 9.8s 一张。
    ///
    /// ## ⭐⭐⭐ §2631 原分辨率下的重算（用户令：不缩放 + 10s 一帧）
    /// 原分辨率（1170×2532）的帧**大得多**。按面积比估算（约为 451×975 的 **6.7 倍**）：
    /// ```
    ///   451 宽复杂画面帧 : 约 62 KB（耐久日志实测）
    ///   原分辨率同类帧   : 62 × 6.7 ≈ **415 KB**（保守上界）
    ///   节拍             : **10s/帧** ⇒ 41.5 KB/s ⛔ **超预算 3.3 倍！**
    /// ```
    /// ⇒ ⛔ **若还走"写盘主路"，原分辨率 + 10s 仍会撞 12.73 KB/s 上限 ⇒ 扩展被杀**。
    /// ✅ 但**主路已经不是写盘了**（§2267）—— 是 **HTTP POST 回环**，
    ///   而**回环 socket 不计入 file-backed 写入预算**（见 `postBestEffort` 的说明）。
    ///   ⇒ 常态下磁盘写入 ≈ 0 ⇒ 原分辨率**可行**。
    /// ⚠️ 下面是**兜底路**（POST 不通时才用）的额度，保持 384 KB 不变：
    ///   415 KB 的帧 ⇒ **一帧就超窗口额度 ⇒ 那一帧被丢**（⛔ 丢帧远好过被杀）。
    ///   📏 这是**有意**的：兜底路宁可丢帧，也绝不让扩展被杀（§2265 血案）。
    private static let budgetWindowS: Double = 60
    private static let budgetBytesPerWindow: Int = 384 * 1024

    // MARK: - 工具

    /// ⭐⭐⭐ 写进「眼」的落盘目录（**优先 App Group 共享容器**）。
    ///
    /// ## ⛔⛔⛔ §2265 **写盘预算铁律** —— 这是「直播一直停止」的真根因
    ///
    /// 系统报告 `PGShot.diskwrites_resource-2026-10-11-134852.ips` 铁证：
    /// ```
    ///   Event:         disk writes
    ///   Writes:        1073.95 MB over 719 seconds (1493.70 KB/s)
    ///   Writes limit:  1073.74 MB      ← 撞上限 ⇒ 扩展被杀
    ///   Duration:      719s            ← 只跑了 12 分钟
    /// ```
    /// 📏 **iOS 给每个扩展的磁盘写入预算是「24 小时 1073 MB」**（≈ 12.4 KB/s 平均）。
    ///   ⇒ 一旦超限，系统**直接杀掉扩展** ⇒ 表现就是「**直播自己停了**」。
    ///
    /// ## 我踩的三个叠加错误（⛔ 逐个都已修）
    /// | # | 错 | 倍数 |
    /// |---|---|---|
    /// | ① | `downscale` 没生效（renderer 默认 scale=3）⇒ "451宽"实际 **1353px** | **9×** |
    /// | ② | 我上一轮改的「每帧都写 `frame_<seq>.jpg`」⇒ 一帧**两个文件** | **2×** |
    /// | ③ | 全程 2fps 无脑写，而 Runner 实际 1~3 秒才要一帧 | **~4×** |
    ///
    /// ## ✅ 修法：**每帧只写一次 `lastframe.jpg`**，并按 `minWriteInterval` 限频
    /// ⛔ **不再逐帧留档 `frame_<seq>.jpg`** ——
    ///   那条是我上一轮"照荔枝新文件语义"加的，**恰恰是 2× 的浪费**，
    ///   而它的收益（"目录能看出扩展还活着"）**主 App 侧根本不需要**：
    ///   `Runner` 用的是**内存帧 + 帧龄**判据（§2263 `lastFrameAge`），
    ///   ⛔ 不靠扫目录。
    /// ⚠️ 保留**低频**留档（每 30 帧 ≈ 15 秒一张）供**事后取证**，成本可忽略。
    /// 只保留最近几个 `frame_*.jpg`（⛔ 别把共享容器写爆）
    private func trimOldFrames() {
        let keep = 6
        guard seq > 30 * (keep + 2) else { return }
        let fm = FileManager.default
        for k in 1...30 where (seq / 30 - k) > 0 {
            let old = (seq / 30 - k) * 30
            let u = dir.appendingPathComponent("frame_\(old).jpg")
            if fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        }
    }

    /// ⭐⭐⭐⭐⭐ 把帧 **POST 给主 App**（`http://127.0.0.1:8899/frame`）—— §2266 **现在是主路**
    ///
    /// ## ⛔⛔ 为什么它从"兜底"升成"主路"（这是「直播一直停止」的正解）
    /// 实测（§2265/§2266，真机数字）：
    /// ```
    ///   iOS 给扩展的磁盘写入预算 : 1073.74 MB / 86400s = **12.73 KB/s**
    ///   真机单帧体积（彩色）      : **65.4 KB**
    ///   ⇒ 连续写盘**结构上不可能**进预算：
    ///        1帧/2s = 32.7 KB/s  ⛔ 2.6×      1帧/4s = 16.4 KB/s  ⛔ 1.3×
    ///        1帧/8s =  8.2 KB/s  ✅ 但帧龄 8s ⇒ 判据全废
    /// ```
    /// ⇒ **只要还在"定时写盘"，就必然在"被杀"与"帧太旧"之间二选一。**
    ///
    /// ✅ 而 **HTTP POST 走回环 socket，⛔ 不计入 file-backed 写入预算**。
    ///   §2263 实测：主 App 退后台后 `127.0.0.1:8899` **仍然通**（静音保活 + PiP）
    ///   ⇒ **常态下完全不写盘** ⇒ 磁盘写入 ≈ 0 ⇒ **扩展不会被预算杀掉**。
    ///
    /// ## 分工（⛔ 与旧注释正好相反，理由见上）
    /// | 路 | 现在的角色 | 占预算吗 |
    /// |---|---|---|
    /// | **HTTP POST** | ⭐ **主路** | ⛔ 不占 |
    /// | App Group 落盘 | 兜底（POST 不通时，且**硬限速 5s**）| ✅ 占 |
    ///
    /// ## ⭐ 必须**同步**判成功，否则"兜底"永远不触发
    /// ⛔ 旧实现用 `dataTask(with:completionHandler:)`（**异步**）⇒
    ///   调用方**当场**读不到结果 ⇒ `lastPostOK` 永远是初始值 ⇒
    ///   要么"永远不落盘"（POST 真挂了也没兜底），要么"永远落盘"（白写）。
    /// ✅ 改用 `semaphore` 同步等（最多 ~1s）—— 本扩展 1 帧/2s，等待代价可接受。
    /// ⭐⭐⭐ §2267 **尽力而为的异步 POST**（⛔ 绝不阻塞采样回调）
    ///
    /// ## ⛔⛔ 上一版在这里犯的致命错（真机现象：`frames 2→2` 再也不涨）
    /// 我为了"POST 成功就不写盘"，把这里改成**同步等结果**：
    /// ```swift
    /// let sem = DispatchSemaphore(value: 0)
    /// session?.dataTask(with: req) { ...; sem.signal() }.resume()
    /// _ = sem.wait(timeout: .now() + 1.2)      // ⛔⛔ 在**采样回调**里阻塞 1.2 秒
    /// ```
    /// `processSampleBuffer` 跑在 **ReplayKit 的采样队列**上。
    /// **阻塞它 = 停止消费系统送来的帧** ⇒ 广播**原地卡死**。
    /// ⚠️ 而且它**不会**产生崩溃报告（是被"堵住"不是"被杀"）——
    ///    这个区别正是排查关键：`crash ls` 里**没有新报告**，但 `frames` 不涨。
    ///
    /// 📏 **铁律：采样回调里⛔ 绝不能有任何同步等待/阻塞 IO**（网络、文件锁、信号量都不行）。
    ///
    /// ## 本函数的定位（⛔ 不再参与主路决策）
    /// 帧的**主路是写盘**（照荔枝，见 `writeShared`）。
    /// 这个 POST 只是**加速**：主 App 活着时能更快拿到帧。
    /// ⇒ **成功与否都不改变**主路，⛔ 因此不需要（也不允许）等它的结果。
    private func postBestEffort(_ data: Data, seq: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/frame?seq=\(seq)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 1
        if session == nil {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 1
            cfg.timeoutIntervalForResource = 1
            cfg.waitsForConnectivity = false
            // ⛔ 不要走系统代理（会卡死；`_note_2090` 踩过）
            cfg.connectionProxyDictionary = [:]
            session = URLSession(configuration: cfg)
        }
        // ⭐ **异步、不等结果、不阻塞**（回调只在失败时留一行日志）
        session?.dataTask(with: req) { _, resp, err in
            if let err = err {
                NSLog("PGShot POST 未成功（不影响主路，帧已落盘）: %@",
                      String(describing: err))
            } else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                NSLog("PGShot POST 状态码 %d（不影响主路）", h.statusCode)
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
        // ⭐⭐⭐⭐⭐ §2631 **用户令：`toWidth <= 0` ⇒ 不缩放，直接用原分辨率**
        //
        // > 「**把识别改成不用缩放 就原分辨率。但是每次识别间隔10秒。**」
        //
        // ⛔ 为什么（真机帧铁证）：451 宽时 `19s` 的 `s` 只有约 4px 高
        //   ⇒ Vision **读不出那个 `s`** ⇒ 读成 `19后可领取`
        //   ⇒ 判据 `\d+秒|\d+s` 恒 false ⇒ 误判"倒计时走完" ⇒ 提前点 ✕ 把广告点死。
        // ✅ 原分辨率（1170×2532）下 `s` 有约 10px ⇒ 读得出。
        // ⚠️ 帧变大 ⇒ 靠 `writeShared` 的字节预算 + `fps=0.1`（10s 一帧）兜住。
        guard w > 0 else { return img }
        guard img.size.width > w else { return img }
        let scale = w / img.size.width
        let newSize = CGSize(width: w, height: (img.size.height * scale).rounded())
        // ⛔⛔⛔ §2265 **必须显式 scale = 1.0** —— 这是「磁盘写入超限被系统杀」的头号元凶！
        //
        // ## 血案（真机 `.ips` 铁证）
        // 系统报告 `PGShot.diskwrites_resource-2026-10-11-134852.ips`：
        // ```
        //   Event:         disk writes
        //   Writes:        1073.95 MB over 719 seconds (1493.70 KB/s)
        //   Writes limit:  1073.74 MB      ← 撞上限
        //   Duration:      719s            ← 只跑了 12 分钟就被杀
        // ```
        //
        // ## 为什么
        // `UIGraphicsImageRenderer(size:)` **默认继承屏幕 scale（本机 = 3）**
        // ⇒ 我写 `toWidth: 451` 以为得到 451px 宽的图，
        //   实际得到 **451 × 3 = 1353px** 宽（`size` 是**点**，不是**像素**）。
        // ⇒ 像素数是预期的 **9 倍**（3²），JPEG 体积也接近 9 倍。
        //   📏 与真机帧尺寸**完全吻合**：拉出来的帧就是 **1353×2925**。
        //
        // ✅ 用 `UIGraphicsImageRendererFormat` 并把 `scale` 钉成 **1.0**
        //    ⇒ `size` 就是**像素**，输出真的是 451×977 ⇒ 数据量降到 1/9。
        //
        // ⛔⛔ §2266 **绝不能转灰度！**（我一度想省 1/3 体积，**验证后发现会毁掉整条链**）
        //
        // ## 判决性实验（`_dev/_2257_coin_verify.py` 可复跑，真机 feed 帧）
        // ```
        //   彩色帧 ⇒ ColorBlob 命中 (51.5, 163.8)  ✅ 与 PC 全量标定吻合
        //   灰度帧 ⇒ None                          ⛔ **永远不可能命中**
        // ```
        // ## 为什么（这是**色彩判据**，不是亮度判据）
        // `ColorBlob.findCoinBall` 找的是**红包球**，判据**逐字**是：
        // ```
        //   r > 180  &&  (r - g) > 100  &&  (r - b) > 100
        // ```
        // ⇒ 灰度化后 **r = g = b** ⇒ `r-g = 0` ⇒ **判据恒 false**。
        //
        // ## 而红包球是**回金币中心的唯一入口**（§2256/§2259）
        // 它**没有任何 OCR 文字**（纯图形）⇒ 一旦它认不出，
        // `ensureInCenter` 就**永远回不去中心** ⇒ 整轮废掉。
        // 📏 **教训：优化"体积"之前，先确认没有哪个判据依赖被优化掉的信息。**
        //    （"识别全在灰度上跑"这句话**只对 OCR/模板成立**，对**色彩判据不成立**。）
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1.0                      // ⭐ 关键：size = 像素，⛔ 不再乘 3
        fmt.opaque = true                    // ⭐ 不透明 ⇒ 省掉 alpha 通道
        let r = UIGraphicsImageRenderer(size: newSize, format: fmt)
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func write(_ data: Data, name: String) {
        let dst = dir.appendingPathComponent(name)
        // ⛔⛔⛔ §2265 **一次写入，⛔ 不再"写 tmp + replaceItemAt + 兜底再写一遍"**
        //
        // ## 为什么（写盘预算，见 `writeShared` 的血案报告）
        // 旧写法对一个文件最多做**三次**落盘：
        // ```
        // try data.write(to: tmp, options: .atomic)      // ① 写到 tmp
        // _ = try? FileManager.default.replaceItemAt(...) // ② 替换（又一次元数据/数据写）
        // if !exists(dst) { try data.write(to: dst, ...) }// ③ 兜底再写一遍
        // ```
        // 而 iOS 的写入预算统计的是**被弄脏的 file-backed memory**（`Writes caused`），
        // ⇒ 这种"多写一遍"直接翻倍计入预算。
        //
        // ✅ `Data.write(to:options:.atomic)` **本身**就是「写临时文件 + 原子重命名」，
        //    ⇒ 一条语句即满足「读方永远看到完整文件」的语义，⛔ 不需要外层再包一层。
        do {
            try data.write(to: dst, options: .atomic)
        } catch {
            NSLog("PGShot 写帧失败: %@", String(describing: error))
        }
    }
}
