import SwiftUI
import WebKit

struct ReportsView: View {
    @EnvironmentObject var model: AppModel
    @State private var local = false
    @State private var items: [ExecutionItem] = []
    @State private var total = 0
    @State private var keyword = ""
    @State private var status = ""
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var loadedQuery = ""
    @State private var loadedStatus = ""
    var body: some View {
        NavigationStack {
            List {
                Picker("来源", selection: $local) {
                    Text("平台报告").tag(false); Text("本机记录").tag(true)
                }.pickerStyle(.segmented)
                if model.hasPendingRun {
                    Section { ExecutorBanner(); Button("停止当前任务", role: .destructive) { Task { await model.stop() } }.disabled(model.busy) }
                }
                if local {
                    if model.scopedRuns.isEmpty { ContentUnavailableView("暂无本机记录", systemImage: "clock") }
                    ForEach(model.scopedRuns) { run in
                        NavigationLink { RunDetailView(id: run.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.name).font(.headline)
                                Text(run.state).foregroundStyle(run.result["success"].bool == true ? .teal : .secondary)
                                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } else {
                    Picker("状态", selection: $status) {
                        Text("全部").tag(""); Text("成功").tag("PASS"); Text("失败").tag("FAIL"); Text("运行中").tag("RUNNING")
                    }
                    Section("共 \(total) 条报告") {
                        if items.isEmpty { ContentUnavailableView("暂无报告", systemImage: "chart.bar.doc.horizontal") }
                        ForEach(items) { item in
                            NavigationLink { PlatformReportView(item: item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.scenario_name).font(.headline)
                                    HStack {
                                        Text(item.status).foregroundStyle(item.status == "PASS" ? .teal : .secondary)
                                        Text("\(item.duration ?? 0, specifier: "%.1f") 秒")
                                        Text(item.platform ?? "")
                                    }.font(.caption)
                                    Text(item.start_time.replacingOccurrences(of: "T", with: " ")).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                        if items.count < total { Button("加载更多") { Task { await load(reset: false) } }.disabled(loading) }
                    }
                }
            }.navigationTitle("报告")
                .navigationBarTitleDisplayMode(.inline)
                .contentMargins(.top, 8, for: .scrollContent)
                .navigationDestination(isPresented: Binding(get: { model.notificationRunID != nil }, set: { if !$0 { model.notificationRunID = nil } })) {
                    if let id = model.notificationRunID { RunDetailView(id: id) }
                }
                .searchable(text: $keyword, prompt: "搜索平台报告")
                .onSubmit(of: .search) { Task { await load(reset: true) } }
                .onChange(of: keyword) { _, value in if value.isEmpty { Task { await load(reset: true) } } }
                .onChange(of: status) { _, _ in Task { await load(reset: true) } }
                .task { local = model.hasPendingRun; await load(reset: true) }
                .onChange(of: model.hasPendingRun) { _, active in if active { local = true } }
                .refreshable { await model.refresh(); await load(reset: true) }
                .toolbar { if loading { ProgressView() } }
        }
    }
    func load(reset: Bool) async {
        guard reset || !loading else { return }
        let id = UUID(); loadID = id; loading = true
        let query = reset ? keyword : loadedQuery, filter = reset ? status : loadedStatus, skip = reset ? 0 : items.count
        defer { if loadID == id { loading = false } }
        await model.read {
            let page = try await model.reportPage(skip: skip, keyword: query, status: filter)
            guard loadID == id, !Task.isCancelled else { return }
            loadedQuery = query; loadedStatus = filter
            items = reset ? page.items : items + page.items; total = page.total
        }
    }
}

struct PlatformReportView: View {
    @EnvironmentObject var model: AppModel
    let item: ExecutionItem
    @State private var html: String?
    @State private var failure: String?
    var body: some View {
        Group {
            if let html { ReportWebView(html: html, baseURL: URL(string: model.platformLabel + "/")) }
            else if let failure { ContentUnavailableView("报告加载失败", systemImage: "exclamationmark.triangle", description: Text(failure)) }
            else { ProgressView("加载报告…") }
        }.navigationTitle(item.scenario_name).navigationBarTitleDisplayMode(.inline)
            .task {
                await model.read {
                    do { html = try await model.reportHTML(item.id) }
                    catch { failure = error.localizedDescription; throw error }
                }
            }
    }
}
struct ReportWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct SchedulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: LocalSchedule?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.scheduleStatus).font(.subheadline)
                    Text("切换应用后由本机执行器定时运行。执行器需保持运行；重启后打开 AutoDroid 恢复。忙碌时顺延，错过的历史时间不补跑。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.scopedSchedules.isEmpty { ContentUnavailableView("暂无定时任务", systemImage: "clock.badge.plus", description: Text("添加用例或场景，按时间自动运行。")) }
                ForEach(model.scopedSchedules) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button { editing = item } label: { Text(item.name).font(.headline) }.buttonStyle(.plain)
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { item.enabled }, set: { enabled in
                                var updated = item; updated.enabled = enabled
                                Task { await model.saveSchedule(updated) }
                            })).labelsHidden().disabled(model.busy)
                        }
                        Text("\(item.kind.title) · \(item.targetName) · \(item.rule.title)").font(.caption).foregroundStyle(.secondary)
                        if item.enabled, let next = item.nextRun { Text("下次：\(next.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                        if item.notify { Label("飞书通知", systemImage: "bell").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                        .swipeActions { Button("删除", role: .destructive) { Task { await model.saveSchedule(item, delete: true) } } }
                }
            }.navigationTitle("定时")
                .navigationBarTitleDisplayMode(.inline)
                .contentMargins(.top, 8, for: .scrollContent)
                .toolbar { Button { var item = LocalSchedule(); item.notify = model.feishu; editing = item } label: { Image(systemName: "plus") }.accessibilityLabel("添加定时任务") }
                .refreshable { await model.refresh() }
                .sheet(item: $editing) { item in ScheduleEditor(item: item) }
        }
    }
}
struct ScheduleEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var item: LocalSchedule
    @State private var environment = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称", text: $item.name)
                    Picker("类型", selection: $item.kind) { ForEach(ScriptKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .onChange(of: item.kind) { _, _ in item.targetID = 0; item.targetName = "" }
                    NavigationLink { TargetPicker(kind: item.kind) { target in
                        item.targetID = target.id; item.targetName = target.name
                        if item.name.isEmpty { item.name = target.name }
                    } } label: { LabeledContent("执行目标", value: item.targetName.isEmpty ? "请选择" : item.targetName) }
                    TextField("环境 ID（选填）", text: $environment).keyboardType(.numberPad)
                }
                Section("执行时间") {
                    Picker("重复", selection: $item.rule) { ForEach(RepeatRule.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if item.rule == .interval { Stepper("每 \(item.intervalMinutes) 分钟", value: $item.intervalMinutes, in: 1...10080) }
                    else {
                        DatePicker("时间", selection: $item.date, displayedComponents: item.rule == .once ? [.date, .hourAndMinute] : [.hourAndMinute])
                        if item.rule == .weekly {
                            Picker("星期", selection: $item.weekday) {
                                Text("周一").tag(2); Text("周二").tag(3); Text("周三").tag(4); Text("周四").tag(5); Text("周五").tag(6); Text("周六").tag(7); Text("周日").tag(1)
                            }
                        }
                    }
                    Toggle("启用任务", isOn: $item.enabled)
                    Toggle("完成后发送飞书通知", isOn: $item.notify)
                }
            }.navigationTitle("定时任务").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if !environment.isEmpty && (Int(environment) ?? 0) <= 0 { model.error = "环境 ID 必须为正整数。"; return }
                            item.environmentID = Int(environment)
                            Task {
                                await model.saveSchedule(item)
                                if model.error == nil { dismiss() }
                            }
                        }.disabled(model.busy)
                    }
                }.onAppear { environment = item.environmentID.map(String.init) ?? "" }
        }
    }
}
struct TargetPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: ScriptKind
    let select: (ScriptItem) -> Void
    @State private var items: [ScriptItem] = []
    @State private var total = 0
    @State private var keyword = ""
    @State private var folders: [FolderChoice] = []
    @State private var folderID: Int?
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var loadedQuery = ""
    @State private var loadedFolderID: Int?
    var body: some View {
        List {
            FolderFilter(kind: kind, folders: folders, selection: $folderID)
            ForEach(items) { item in Button(item.name) { select(item); dismiss() } }
            if items.count < total { Button("加载更多") { Task { await load(reset: false) } }.disabled(loading) }
        }.navigationTitle("选择\(kind.title)").searchable(text: $keyword)
            .task { await load(reset: true) }
            .onSubmit(of: .search) { Task { await load(reset: true) } }
            .onChange(of: keyword) { _, value in if value.isEmpty { Task { await load(reset: true) } } }
            .onChange(of: folderID) { _, _ in Task { await load(reset: true) } }
    }
    func load(reset: Bool) async {
        guard reset || !loading else { return }
        let id = UUID(); loadID = id; loading = true
        let query = reset ? keyword : loadedQuery, folder = reset ? folderID : loadedFolderID, skip = reset ? 0 : items.count
        defer { if loadID == id { loading = false } }
        await model.read {
            let choices = reset ? try await model.folders(kind) : folders
            let page = try await model.targets(kind, skip: skip, keyword: query, folderID: folder)
            guard loadID == id, !Task.isCancelled else { return }
            folders = choices
            loadedQuery = query; loadedFolderID = folder
            items = reset ? page.items : items + page.items; total = page.total
        }
    }
}
