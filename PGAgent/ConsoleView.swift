import SwiftUI

/// ⭐⭐⭐⭐⭐ §2269 **PG 控制台（手机版）** —— 照 PC 控制台 `_1665_pg_console.py` 的用法。
///
/// ## 为什么要有它（用户令）
/// > 「**你把控制台搞好 太混乱了。也没有我PG控制台那么好控制 勾选功能和设置时间**」
///
/// PC 控制台的骨架（`_1665_pg_console.py`）：
/// ```python
/// APP_OPTS     = [("快手极速版","kslite"), ("快手","ks")]
/// ENTRY_OPTS   = [("自动轮换","auto"), ("福利页","fuli"), ("宝箱","chest")]
/// TAIL_OPTS    = [("继续跑下一条","continue"), ("回任务中心","center")]
/// FEATURE_OPTS = [("看广告得金币 + 宝箱","adbox",10),
///                 ("刷视频","feed",12),
///                 ("搜索打标签","tag",5),
///                 ("商城逛小店","search",5)]
/// ```
/// ⇒ 手机端**逐条对齐**：同样的勾选项、同样的中文名、同样的默认分钟数。
///
/// ## 三层信息架构（⛔ 不再把按钮和日志糊成一堆）
/// ```
/// ① 运行   —— ▶️ 开始跑 / ⛔ 停 + 实时进度（页型/动作/第几条）
/// ② 设置   —— ⭐ 勾选功能 + 设时间（照 PC 控制台）
/// ③ 日志   —— 原始日志（排查用）
/// ```
struct ConsoleView: View {

    @ObservedObject var cfgStore: ConfigStore
    @ObservedObject var broadcaster: BroadcastStarter
    @ObservedObject var ble: BLEController
    @ObservedObject var store: LogStore
    @ObservedObject var runner: Runner

    /// 轮到的页签
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("运行").tag(0)
                Text("设置").tag(1)
                Text("日志").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Divider().padding(.top, 6)

            switch tab {
            case 0: RunPane(cfgStore: cfgStore, broadcaster: broadcaster,
                            ble: ble, runner: runner)
            case 1: SettingsPane(cfgStore: cfgStore, store: store)
            default: LogPane(store: store)
            }
        }
    }
}

// MARK: - ① 运行

/// ⭐ 「运行」页 —— 一键跑 + **实时进度**（⛔ 不用去翻日志）
private struct RunPane: View {
    @ObservedObject var cfgStore: ConfigStore
    @ObservedObject var broadcaster: BroadcastStarter
    @ObservedObject var ble: BLEController
    @ObservedObject var runner: Runner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {

                // ── ① 状态卡：一眼看清"眼/手/活/跑" ──────────────
                GroupBox("状态") {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusRow(icon: "👁", name: "眼（录屏取帧）",
                                  ok: broadcaster.frameCount > 0,
                                  detail: frameDetail)
                        StatusRow(icon: "🖐", name: "手（ESP32 蓝牙）",
                                  ok: ble.state.hasPrefix("ready"),
                                  detail: ble.state)
                        StatusRow(icon: "🧠", name: "配置",
                                  ok: cfgStore.cfg != nil,
                                  detail: cfgStore.cfg != nil
                                    ? "\(cfgStore.cfg?.elements.count ?? 0) 元素 / \(cfgStore.cfg?.pages.count ?? 0) 页型"
                                    : cfgStore.lastError)
                        StatusRow(icon: "🏃", name: "本轮",
                                  ok: runner.running,
                                  detail: runner.running
                                    ? "第 \(runner.step) 步 ｜ \(runner.lastPage) ｜ \(runner.lastAction)"
                                    : "待机")
                    }
                    .padding(.vertical, 2)
                }

                // ── ② 主操作：开始 / 停 ──────────────────────────
                HStack(spacing: 10) {
                    Button {
                        runner.start(dest: nil)
                    } label: {
                        Label("开始跑", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.running)

                    Button {
                        runner.stop()
                    } label: {
                        Label("停", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!runner.running)
                }

                // ── ③ 录屏（「眼」的开关，⛔ 不是每次都要动）──────
                GroupBox("录屏（眼）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("帧 \(broadcaster.frameCount) ｜ 最新帧 \(frameAgoText)")
                            .font(.system(size: 12, design: .monospaced))
                        // ⛔⛔ §2267 **按钮文字会变**（开始直播 / 停止直播）——
                        //   所以这里只**触发系统面板**，由人去点面板上正确的那个按钮，
                        //   ⛔ 绝不在代码里盲点固定坐标（那会把正常录屏停掉）。
                        Button {
                            _ = broadcaster.start()
                        } label: {
                            Label("开录屏（会弹系统面板，点「开始直播」）",
                                  systemImage: "record.circle")
                        }
                        Text("⚠️ 系统面板上的按钮会变：没在录时是「开始直播」；"
                             + "已在录时是「停止直播」——**看清再点**。")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("本轮要跑的（在「设置」里改）") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(plannedRows, id: \.0) { (name, mins) in
                            HStack {
                                Text("✅ \(name)")
                                Spacer()
                                Text(mins > 0 ? "\(Int(mins)) 分钟" : "按条数")
                                    .foregroundColor(.secondary)
                            }
                            .font(.system(size: 13))
                        }
                        if plannedRows.isEmpty {
                            Text("（没勾任何功能 ⇒ 只跑广告循环）")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !runner.stopReason.isEmpty && runner.stopReason != "-" {
                    Text("上次停手：\(runner.stopReason)")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            .padding(12)
        }
    }

    private var frameDetail: String {
        if broadcaster.frameCount == 0 { return "还没有帧" }
        return "\(broadcaster.frameCount) 帧 ｜ 最新 \(frameAgoText)"
    }

    private var frameAgoText: String {
        guard let age = broadcaster.lastFrameAge() else { return "无" }
        return String(format: "%.1fs 前", age)
    }

    /// 从配置读出"本轮要跑的"，照 `FeatureEngine.order` 排序（⛔ 不按填写顺序）
    private var plannedRows: [(String, Double)] {
        let feats = cfgStore.cfg?.settings?.features ?? []
        let mins = cfgStore.cfg?.settings?.feat_min ?? [:]
        var list = feats.isEmpty ? ["adbox"] : feats
        list = FeatureEngine.order.filter { list.contains($0) }
        return list.map { (FeatureEngine.cn($0), mins[$0] ?? 0) }
    }
}

/// 一行状态（✅/⛔ + 名称 + 细节）
private struct StatusRow: View {
    let icon: String
    let name: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(ok ? "✅" : "⛔").font(.system(size: 12))
            Text("\(icon) \(name)")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }
}

// MARK: - ② 设置（⭐ 勾选功能 + 设时间）

/// ⭐⭐⭐⭐⭐ 「设置」页 —— **照 PC 控制台**：勾选功能 + 设时间。
///
/// ⛔ 关键设计：改动**先进本地草稿**，按「保存」才落盘 ——
///    否则改一个数字就写一次盘，Runner 正在跑时会读到**半套配置**。
private struct SettingsPane: View {
    @ObservedObject var cfgStore: ConfigStore
    @ObservedObject var store: LogStore

    /// 本地草稿（⛔ 不直接改 cfgStore，避免边改边生效）
    @State private var feats: Set<String> = []
    @State private var mins: [String: Double] = [:]
    @State private var adCount: Double = 6
    @State private var adDwell: Double = 30
    @State private var apps: Set<String> = []
    @State private var entry: String = "auto"
    @State private var tail: String = "continue"
    @State private var loaded = false

    /// ⭐ 照 PC `FEATURE_OPTS`（⛔ 中文名与默认分钟数逐字一致）
    private static let featureOpts: [(String, String, Double)] = [
        ("看广告得金币 + 宝箱", "adbox", 10),
        ("刷视频", "feed", 12),
        ("搜索打标签", "tag", 5),
        ("商城逛小店", "search", 5),
    ]
    /// ⭐ 照 PC `APP_OPTS`
    private static let appOpts: [(String, String)] = [
        ("快手极速版", "kslite"), ("快手", "ks"),
    ]
    /// ⭐ 照 PC `ENTRY_OPTS` / `TAIL_OPTS`
    private static let entryOpts: [(String, String)] = [
        ("自动轮换", "auto"), ("福利页", "fuli"), ("宝箱", "chest"),
    ]
    private static let tailOpts: [(String, String)] = [
        ("继续跑下一条", "continue"), ("回任务中心", "center"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                GroupBox("① 跑哪些功能（勾选）") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.featureOpts, id: \.1) { (cn, key, dflt) in
                            HStack {
                                Toggle(cn, isOn: Binding(
                                    get: { feats.contains(key) },
                                    set: { $0 ? feats.insert(key) : feats.remove(key) }))
                                // ⭐ 时间就在勾选项右边（照 PC 控制台的布局）
                                TextField("分", value: Binding(
                                    get: { mins[key] ?? dflt },
                                    set: { mins[key] = $0 }), format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 52)
                                    .textFieldStyle(.roundedBorder)
                                Text("分钟").font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                        Text("⛔ 一个都不勾 = 只跑广告循环（与 PC 旧行为一致）")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Text("⚠️ 执行顺序固定：广告 → 刷视频 → 搜索 → 商城（⛔ 不按勾选顺序）")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("② 广告") {
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper("条数：\(Int(adCount))", value: $adCount, in: 1...99)
                        HStack {
                            Text("广告停留")
                            TextField("秒", value: $adDwell, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60).textFieldStyle(.roundedBorder)
                            Text("秒").foregroundColor(.secondary)
                        }
                        .font(.system(size: 13))
                        Text("⛔ 广告页只等时间，绝不点 ✕（用户令）")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("③ App 交替") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.appOpts, id: \.1) { (cn, key) in
                            Toggle(cn, isOn: Binding(
                                get: { apps.contains(key) },
                                set: { $0 ? apps.insert(key) : apps.remove(key) }))
                        }
                        Text("⭐ 两个都勾 ⇒ **交替循环**（跑完一个 App 的 4 个功能，换另一个）")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("④ 入口 / 尾部") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("入口", selection: $entry) {
                            ForEach(Self.entryOpts, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        Picker("尾部", selection: $tail) {
                            ForEach(Self.tailOpts, id: \.1) { Text($0.0).tag($0.1) }
                        }
                    }
                    .padding(.vertical, 2)
                }

                // ── 保存 ─────────────────────────────────────────
                Button {
                    save()
                } label: {
                    Label("保存设置", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Text("📏 保存后**立即生效**（跑下一轮时用新值），⛔ 不用重装 App。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(12)
        }
        .onAppear(perform: loadFromConfig)
    }

    /// 从配置读进草稿（只在首次进入时做，⛔ 不覆盖用户正在编辑的内容）
    private func loadFromConfig() {
        guard !loaded, let s = cfgStore.cfg?.settings else { return }
        loaded = true
        feats = Set(s.features ?? [])
        apps = Set(s.apps ?? [])
        mins = s.feat_min ?? [:]
        for (_, key, dflt) in Self.featureOpts where mins[key] == nil { mins[key] = dflt }
        adCount = Double(s.ad_count ?? 6)
        adDwell = s.ad_dwell ?? 30
        entry = s.entry ?? "auto"
        tail = s.tail ?? "continue"
    }

    private func save() {
        // ⛔ 顺序按 `FeatureEngine.order`（⛔ 不按勾选顺序）—— 与 PC `FEAT_ORDER` 一致
        let ordered = FeatureEngine.order.filter { feats.contains($0) }
        let appList = ["kslite", "ks"].filter { apps.contains($0) }
        let patch: [String: Any?] = [
            "features": ordered,
            "apps": appList,
            "feat_min": mins,
            "ad_count": Int(adCount),
            "ad_dwell": adDwell,
            "entry": entry,
            "tail": tail,
        ]
        let r = cfgStore.saveSettings(patch)
        store.log("💾 保存设置: \(r.ok ? "✅" : "⛔") \(r.msg)"
                  + " ｜ 功能=\(ordered.joined(separator: ","))"
                  + " ｜ 条数=\(Int(adCount)) 停留=\(Int(adDwell))s")
    }
}

// MARK: - ③ 日志

/// ⭐ 「日志」页 —— 原始日志（排查用）
private struct LogPane: View {
    @ObservedObject var store: LogStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.recentLines.count) 行").font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("清空") { store.clear() }.font(.system(size: 12))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.recentLines.enumerated()), id: \.offset) { _, l in
                        Text(l)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            // ⛔⛔ **不要**在这里调 `store.snapshot()`：
            //   它会**加锁 + 全量拷贝**，而 body 每次重绘都执行
            //   ⇒ 主线程卡在锁上 ⇒ 看门狗 SIGKILL（§2212 崩溃日志实证）
            //   ✅ 改为读 `store.recentLines`（无锁、定长）
        }
    }
}
