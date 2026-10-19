//
//  BackgroundTask.swift
//  PGAgent
//
//  ⭐⭐⭐ §3468 **后台任务（iOS 官方 API）** —— 让"请求进来 → 响应发出"这一段不被挂起
//
//  ## 为什么需要（用户令 2026-10-19 23:52）
//  > 「**保活一定需要这样？ 我不信了。开源项目里面没有别的解决方案。
//  >   而且你这个做法就是因噎废食。调试阶段都搞不好一个活的通道**」
//
//  ## 事实（真机实测）
//  ```
//  全项目搜 beginBackgroundTask ⇒ ⛔ 一个都没有
//  静音音频保活：playing=true, volume=0, loops=-1  ← 进程活着
//  但 App 进后台后，新 HTTP 连接进不来（NWListener 被挂起）
//  ```
//  ⇒ **进程活着 ≠ 网络可用。这是两件事。**
//
//  ## 解法来源
//  `swisspol/GCDWebServer`（6613 stars，iOS 上最经典的 HTTP server）README 原文：
//  > `GCDWebServer begins a background task whenever the first HTTP connection is opened
//  >  and ends it only when the last one is closed`
//  ```
//  // 它源码里的等价写法
//  UIBackgroundTaskIdentifier task =
//      [[UIApplication sharedApplication] beginBackgroundTaskWithName:name
//          expirationHandler:^{ ... }];
//  ...
//  [[UIApplication sharedApplication] endBackgroundTask:task];
//  ```
//
//  ## 这个 API 到底给什么
//  · **保证当前这段工作能做完**（约 30 秒额度）
//  · **不是**让 App 永久后台运行（那是 PiP / 音频 / 定位的事）
//  · 用途：请求处理到响应发送这一段，保证不被系统掐断
//
//  ⚠️ 必须在**主线程**调用（Apple 文档要求）。
//

import Foundation
import UIKit

enum BackgroundTask {

    /// 申请一个后台任务。返回 identifier；调用方**必须**在完成后调 `end()`。
    ///
    /// - Parameter name: 只用于调试显示（不传也行）
    /// - Returns: `UIBackgroundTaskIdentifier`，失败时是 `.invalid`
    @discardableResult
    static func begin(name: String? = nil) -> UIBackgroundTaskIdentifier {
        // ⚠️ Apple 要求在主线程；不在就同步切过去
        if !Thread.isMainThread {
            var result: UIBackgroundTaskIdentifier = .invalid
            DispatchQueue.main.sync {
                result = beginOnMain(name: name)
            }
            return result
        }
        return beginOnMain(name: name)
    }

    private static func beginOnMain(name: String?) -> UIBackgroundTaskIdentifier {
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid

        let begin = {
            // expirationHandler 在"额度用完、系统要挂起你"时被调用
            // ⇒ 此时必须尽快 end，否则系统会强杀 App
            task = app.beginBackgroundTask(withName: name) { [weak app] in
                _ = app
                NSLog("PGAgent BGT: ⚠️ 到期，系统即将挂起（%@）", name ?? "-")
                if task != .invalid {
                    app?.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }

        if Thread.isMainThread {
            begin()
        } else {
            DispatchQueue.main.sync(execute: begin)
        }

        if task == .invalid {
            NSLog("PGAgent BGT: ⛔ beginBackgroundTask 失败（%@）", name ?? "-")
        } else {
            NSLog("PGAgent BGT: ▶️ 开始 %@ (id=%lu)", name ?? "-", task.rawValue)
        }
        return task
    }

    /// 结束后台任务。⛔ 必须调用，否则额度泄漏（系统最多给几十个）。
    static func end(_ task: UIBackgroundTaskIdentifier) {
        guard task != .invalid else { return }
        let finish = {
            UIApplication.shared.endBackgroundTask(task)
            NSLog("PGAgent BGT: ⏹ 结束 (id=%lu)", task.rawValue)
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    /// 剩余额度秒数（诊断用；`.invalid` 时返回 -1）
    static var remaining: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
}
