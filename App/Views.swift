import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if model.restoringSession { ProgressView("正在验证登录…") }
            else if model.loggedIn {
                TabView(selection: $model.tab) {
                    LibraryView(kind: .cases).tabItem { Label("用例", systemImage: "doc.text") }.tag(0)
                    LibraryView(kind: .scenarios).tabItem { Label("场景", systemImage: "square.stack.3d.up") }.tag(1)
                    ReportsView().tabItem { Label("报告", systemImage: "chart.bar.doc.horizontal") }.tag(2)
                    SchedulesView().tabItem { Label("定时", systemImage: "clock") }.tag(3)
                    SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(4)
                }
            } else { LoginView() }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct ExecutorBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.executorReady ? "checkmark.circle.fill" : "bolt.slash.circle")
                .font(.title2).foregroundStyle(model.executorReady ? .teal : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.executorText).font(.subheadline.weight(.semibold))
                Text(model.executorReady ? "在这台 iPhone 上执行" : "请启动 AutoDroid-WDA 后重新检测")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("检测本机执行器")
        }.padding(.vertical, 5)
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    let kind: ScriptKind
    @State private var items: [ScriptItem] = []
    @State private var total = 0
    @State private var keyword = ""
    @State private var previewItem: ScriptItem?
    @State private var loading = false
    @State private var folders: [FolderChoice] = []
    @State private var folderID: Int?
    var body: some View {
        NavigationStack {
            List {
                Section { ExecutorBanner() }
                Section {
                    FolderFilter(kind: kind, folders: folders, selection: $folderID)
                }
                Section("\(kind.title) · 共 \(total) 项") {
                    if items.isEmpty { ContentUnavailableView("暂无\(kind.title)", systemImage: "doc.text.magnifyingglass", description: Text("下拉刷新，或调整搜索条件。")) }
                    ForEach(items) { item in
                        HStack(alignment: .top) {
                            Button { previewItem = item } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.name).font(.body.weight(.medium))
                                    if let desc = item.description, !desc.isEmpty { Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    Text("\(kind.title) #\(item.id)").font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("预览 \(item.name)")
                            Button { Task { await model.run(item, kind: kind, notify: model.feishu) } } label: {
                                Image(systemName: "play.circle.fill").font(.title2).frame(width: 44, height: 44)
                            }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("运行 \(item.name)").disabled(model.busy || model.hasPendingRun)
                        }.padding(.vertical, 8)
                    }
                    if items.count < total { Button("加载更多") { Task { await load(reset: false) } }.disabled(loading) }
                }
            }
            .navigationTitle(kind.title)
            .searchable(text: $keyword, prompt: "搜索名称")
            .onSubmit(of: .search) { Task { await load(reset: true) } }
            .onChange(of: folderID) { _, _ in Task { await load(reset: true) } }
            .refreshable { await load(reset: true) }
            .task { await load(reset: true) }
            .toolbar { if model.busy || loading { ProgressView() } }
            .navigationDestination(item: $previewItem) { item in
                ScriptPreviewView(item: item, kind: kind)
            }
        }
    }
    func load(reset: Bool) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        await model.perform {
            if reset { folders = try await model.folders(kind) }
            let page = try await model.targets(kind, skip: reset ? 0 : items.count, keyword: keyword, folderID: folderID)
            items = reset ? page.items : items + page.items; total = page.total
        }
    }
}

struct FolderFilter: View {
    let kind: ScriptKind
    let folders: [FolderChoice]
    @Binding var selection: Int?
    var body: some View {
        Picker(selection: $selection) {
            Text("全部\(kind.title)").tag(nil as Int?)
            ForEach(folders) { folder in
                Text(String(repeating: "　", count: folder.depth) + folder.name).tag(Optional(folder.id))
            }
        } label: { Label("文件夹", systemImage: "folder") }
    }
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "play.square.stack.fill").font(.system(size: 44)).foregroundStyle(.teal)
                    Text("把自动化带到手机上").font(.title.bold())
                    Text("连接你的平台，运行用例与场景，\n在这台 iPhone 上查看执行结果。")
                        .foregroundStyle(.secondary).lineSpacing(5)
                }.padding(.top, 24)
                VStack(spacing: 14) {
                    field("平台地址") { TextField("http://192.168.1.10:8000", text: $model.serverText).keyboardType(.URL).textContentType(.URL).accessibilityIdentifier("server") }
                    field("账号") { TextField("用户名", text: $model.username).textContentType(.username).accessibilityIdentifier("username") }
                    field("密码") { SecureField("请输入密码", text: $model.password).textContentType(.password).accessibilityIdentifier("password") }
                }
                Button { Task { await model.login() } } label: {
                    HStack { Spacer(); if model.busy { ProgressView() }; Text("连接平台").fontWeight(.semibold); Spacer() }.padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("login")
                Text("登录后即可使用全部功能。密码不会保存，登录令牌保存在系统钥匙串中。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
    func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content().textInputAutocapitalization(.never).autocorrectionDisabled()
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct RunDetailView: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var body: some View {
        if let run = model.runs.first(where: { $0.id == id }) {
            List {
                Section("执行状态") {
                    Text(run.state).font(.headline)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                    Text(run.result["script_fetch_failed"].bool == true ? "未开始执行，请检查任务配置与平台连接" : run.server.isEmpty ? "本机自检，不上传平台" : run.result["upload_ok"].bool == true ? "结果已回传平台" : "结果等待回传平台")
                    if let reason = run.result["error"].string ?? run.result["upload_error"].string { Text(reason).foregroundStyle(.red) }
                    if run.finished && !run.server.isEmpty && run.result["upload_ok"].bool != true && run.result["script_fetch_failed"].bool != true {
                        Button("重试回传结果") { Task { await model.retryUpload(run) } }.disabled(model.busy)
                    }
                    if !run.finished { Button("停止任务", role: .destructive) { Task { await model.stop() } } }
                }
                if let report = run.report {
                    ForEach(Array(report["cases"].array.enumerated()), id: \.offset) { _, item in
                        Section(item["name"].string ?? "用例") {
                            ForEach(Array(item["steps"].array.enumerated()), id: \.offset) { index, step in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(index + 1). \(step["action"].string ?? "步骤")").font(.headline)
                                    Text(step["status"].string ?? "未知").foregroundStyle(step["status"].string == "PASS" ? .teal : .red)
                                    if let reason = step["error"].string, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                Section("执行日志 · \(run.logs.count) 行") {
                    ForEach(Array(run.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section { Text(run.id).font(.caption.monospaced()).textSelection(.enabled) }
            }.navigationTitle(run.name).navigationBarTitleDisplayMode(.inline)
                .refreshable { await model.refresh() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var smoke = false
    var body: some View {
        NavigationStack {
            Form {
                Section("平台") {
                    Text(model.platformLabel).textSelection(.enabled)
                    LabeledContent("账号", value: model.username)
                    Text(model.deviceText).font(.caption).foregroundStyle(.secondary)
                    Button("退出登录", role: .destructive) { Task { await model.logout() } }.disabled(model.busy)
                }
                Section { TextField("环境 ID（选填）", text: $model.environmentText).keyboardType(.numberPad) }
                    header: { Text("执行环境") }
                    footer: { Text("留空使用平台默认环境，下一次运行立即生效。") }
                Section("通知") {
                    Toggle("默认发送飞书通知", isOn: $model.feishu)
                    Toggle("执行结束发送系统通知", isOn: $model.systemNotify)
                    Button("开启通知权限") { Task { await model.enableNotifications() } }.disabled(model.busy)
                    Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
                    Text("飞书通知使用平台配置。系统通知由 AutoDroid 发出：执行完成后自动返回 App；若锁屏无法返回，则打开 App 后补发。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("本机执行器") {
                    ExecutorBanner()
                    Button("运行本机自检", systemImage: "stethoscope") { smoke = true }.disabled(model.busy || model.hasPendingRun)
                    Text("需要 AutoDroid-WDA 保持运行。执行器重启后，请打开本 App 恢复定时任务；过期的执行时间不会补跑。").font(.footnote).foregroundStyle(.secondary)
                }
                Section { LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") }
            }.navigationTitle("设置")
                .confirmationDialog("运行本机自检？", isPresented: $smoke, titleVisibility: .visible) {
                    Button("开始自检") { Task { await model.selftest() } }
                } message: { Text("将打开系统设置、截图识别并滑动，最后返回桌面。结果只保存在本机。") }
        }
    }
}
