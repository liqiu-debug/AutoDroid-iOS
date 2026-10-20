import SwiftUI

struct ScriptPreviewView: View {
    @EnvironmentObject var model: AppModel
    let item: ScriptItem
    let kind: ScriptKind
    @State private var preview: ScriptPreview?
    @State private var loading = false
    @State private var loadError: String?
    @State private var notify = false

    var body: some View {
        List {
            Section {
                Text(preview?.item.name ?? item.name).font(.title3.weight(.semibold))
                if let description = (preview?.item ?? item).description, !description.isEmpty {
                    Text(description).foregroundStyle(.secondary)
                }
                Text("\(kind.title) #\(item.id)").font(.caption).foregroundStyle(.secondary)
            }
            if loading { Section { ProgressView("正在加载预览…") } }
            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("重新加载") { Task { await load() } }.disabled(loading)
                }
            }
            if let preview {
                if kind == .cases {
                    Section("步骤 · 共 \(preview.steps.count) 步") {
                        if preview.steps.isEmpty { Text("此用例暂无步骤").foregroundStyle(.secondary) }
                        ForEach(preview.steps) { step in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(step.order). \(step.title)").font(.headline)
                                if !step.detail.isEmpty { Text(step.detail).textSelection(.enabled) }
                                if let description = step.description, !description.isEmpty { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                                if !step.runsOnIOS { Label("此步骤不在 iOS 执行", systemImage: "forward.end").font(.caption).foregroundStyle(.orange) }
                                Text(step.metadata).font(.caption).foregroundStyle(.secondary)
                                if let args = step.args, args != .null, args != .object([:]) {
                                    DisclosureGroup("步骤参数") { Text(args.pretty).font(.caption.monospaced()).textSelection(.enabled) }.font(.caption)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                } else {
                    Section("包含用例 · 共 \(preview.cases.count) 项") {
                        if preview.cases.isEmpty { Text("此场景暂无用例").foregroundStyle(.secondary) }
                        ForEach(preview.cases) { entry in
                            NavigationLink {
                                ScriptPreviewView(item: entry.item, kind: .cases)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(entry.order). \(entry.item.name)").font(.body.weight(.medium))
                                    if let alias = entry.alias, !alias.isEmpty { Text("别名：\(alias)").font(.subheadline).foregroundStyle(.secondary) }
                                    Text(entry.missing ? "此用例已删除或不存在" : "用例 #\(entry.item.id) · 查看步骤").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 6)
                            }.disabled(entry.missing)
                        }
                    }
                }
            }
            Section {
                Toggle("完成后发送飞书通知", isOn: $notify)
            } footer: { Text("运行时获取平台最新内容，使用设置中的执行环境。") }
        }
        .navigationTitle("\(kind.title)预览").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await model.run(preview?.item ?? item, kind: kind, notify: notify) }
            } label: {
                Label("运行此\(kind.title)", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent)
                .disabled(model.busy || model.hasPendingRun || !model.loggedIn || loading || preview == nil || loadError != nil)
                .padding().background(.bar)
        }
        .task { notify = model.feishu; await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; loadError = nil
        defer { loading = false }
        do { preview = try await model.preview(kind, id: item.id) }
        catch is CancellationError { }
        catch { loadError = error.localizedDescription }
    }
}
