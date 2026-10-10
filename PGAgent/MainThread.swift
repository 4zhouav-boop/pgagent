import Foundation

/// ⭐ 在主线程上**同步**执行一段代码并取回结果。
///
/// ## 为什么需要它（§2212 真机崩溃日志实证）
/// 本 App 的 HTTP handler 跑在
/// `DispatchQueue.global(qos:.userInitiated)`（见 `HTTPServer.handleAsync`）。
/// 于是任何由 HTTP 触发的、**碰 UIKit 的**代码都在**后台线程**执行 ——
/// 这在 iOS 上是**硬性错误**，直接崩：
/// ```
/// PGAgent-2026-10-10-161734.ips
///   EXC_BREAKPOINT (SIGTRAP)
///   faultingThread 3:
///     _dispatch_assert_queue_fail
///     -[UIImageView _mainQ_beginLoadingIfApplicable]
///     -[UIImageView setHidden:]
///     -[UIButtonLegacyVisualProvider layoutSubviews]
/// ```
///
/// ## 用法
/// ```swift
/// let ok = MainThread.run { self.pip.startOnMain() }
/// ```
/// · 已在主线程 ⇒ **直接跑**（⛔ 不引入异步延迟，也⛔ 不会自锁）
/// · 否则 ⇒ 切到主线程跑，**等它完成**再返回
///
/// ⚠️ **超时保护**：主线程若被别的活占住，这里**超时返回 nil**
///   而不是把 HTTP 请求挂死（宁可报错，也⛔ 不能卡住整个 App）。
enum MainThread {

    /// 在主线程同步执行（默认 5 秒超时）。超时或主线程不可用 ⇒ nil
    @discardableResult
    static func run<T>(timeout: Double = 5, _ work: @escaping () -> T) -> T? {
        // ⭐ 已在主线程 ⇒ 直接执行。这一步是**关键**：
        //    若这里还去 `DispatchQueue.main.sync`，会**立刻自死锁**。
        if Thread.isMainThread { return work() }

        var result: T?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = work()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("PGAgent MainThread: ⛔ 等主线程超时（%.1fs）", timeout)
            return nil
        }
        return result
    }
}
