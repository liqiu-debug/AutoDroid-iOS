import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var serverText: String
    @Published var username: String
    @Published var password = ""
    @Published private(set) var loggedIn = false
    @Published private(set) var restoringSession = false
    @Published var tab = 0
    @Published var notificationRunID: String?
    @Published var environmentText = ""
    @Published var schedules: [LocalSchedule] = []
    @Published var scheduleStatus = "等待同步"
    @Published var notificationStatus = "尚未开启"
    @Published var feishu = UserDefaults.standard.bool(forKey: "feishu") { didSet { UserDefaults.standard.set(feishu, forKey: "feishu") } }
    @Published var systemNotify = UserDefaults.standard.object(forKey: "systemNotify") as? Bool ?? true { didSet { UserDefaults.standard.set(systemNotify, forKey: "systemNotify"); schedulesSynced = false } }
    @Published var runs: [RunRecord] = []
    @Published var busy = false
    @Published var error: String?
    @Published var executorText = "尚未检测"
    @Published var executorReady = false
    @Published var deviceText = "尚未注册"
    private var token = ""
    private var server = ""
    private var account = ""
    private var activeRunID: String?
    private var refreshing = false
    private var lastHeartbeat = Date.distantPast
    private var lastHeartbeatState = ""
    private var loggingOut = false
    private var executorRunning = false
    private var uploadAttempts: [String: Date] = [:]
    private var uploadingRuns = Set<String>()
    private var schedulesSynced = false
    private var schedulerInstance = ""
    private var changingSchedules = false
    private let storage = LocalStorage()
    private let executor = ExecutorClient()
    private let deviceID: String

    init() {
        let defaults = UserDefaults.standard
        serverText = defaults.string(forKey: "server") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        deviceID = defaults.string(forKey: "deviceID") ?? UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(deviceID, forKey: "deviceID")
        do {
            schedules = try storage.read("schedules.json", as: [LocalSchedule].self) ?? []
            runs = try storage.read("runs.json", as: [RunRecord].self) ?? []
            activeRunID = runs.first(where: { !$0.finished })?.id
        } catch { self.error = "读取本地记录失败：\(error.localizedDescription)" }
        if let address = try? ServerAddress(serverText) {
            server = address.root.absoluteString
            account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            token = SessionVault.read("\(server)|\(account)") ?? ""
            restoringSession = !token.isEmpty
        }
        CompletionNotifications.shared.onOpen = { [weak self] id in
            guard let self, self.loggedIn, self.scopedRuns.contains(where: { $0.id == id }) else { return }
            self.tab = 2; self.notificationRunID = id
        }
    }
    var scopedSchedules: [LocalSchedule] { schedules.filter { $0.server == server && $0.username == account } }
    var scopedRuns: [RunRecord] { runs.filter { $0.server == server && $0.username == account || $0.server.isEmpty } }
    var hasPendingRun: Bool { activeRunID != nil }
    var platformLabel: String { server.isEmpty ? "尚未登录平台" : server }
    private func client() throws -> PlatformClient {
        guard loggedIn else { throw ClientError(message: "请先登录平台。") }
        return PlatformClient(server: try ServerAddress(server), token: token)
    }
    func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await work() } catch {
            if (error as? ClientError)?.statusCode == 401 {
                _ = try? await executor.schedules(.object(["items": .array([])]))
                invalidateSession()
            }
            self.error = error.localizedDescription
        }
    }
    func login() async {
        await perform {
            let address = try ServerAddress(serverText)
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !password.isEmpty else { throw ClientError(message: "请输入账号和密码。") }
            struct Login: Decodable { let access_token: String }
            let response: Login = try await HTTPClient().send(PlatformClient.loginRequest(server: address, username: user, password: password))
            try SessionVault.save(response.access_token, account: "\(address.root.absoluteString)|\(user)")
            server = address.root.absoluteString; account = user; token = response.access_token
            serverText = server; username = user; password = ""; loggedIn = true
            UserDefaults.standard.set(server, forKey: "server"); UserDefaults.standard.set(user, forKey: "username")
            lastHeartbeat = .distantPast; schedulesSynced = false; tab = 0
        }
        await refresh()
    }
    private func invalidateSession() {
        SessionVault.remove("\(server)|\(account)"); token = ""; password = ""; loggedIn = false
        tab = 0; schedulesSynced = false; restoringSession = false
    }
    func logout() async {
        guard !loggingOut else { return }
        loggingOut = true
        defer { loggingOut = false }
        // Finish a heartbeat already in flight before sending logout.
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        await perform {
            changingSchedules = true; defer { changingSchedules = false }
            // Do not leave a background scheduler holding this account's credentials.
            if scopedSchedules.contains(where: { $0.enabled }) {
                _ = try await executor.schedules(.object(["items": .array([])]))
            } else { _ = try? await executor.schedules(.object(["items": .array([])])) }
            for i in schedules.indices where schedules[i].server == server && schedules[i].username == account { schedules[i].enabled = false }
            try storage.write(schedules, name: "schedules.json")
            let platform = try client()
            _ = try? await platform.logoutDevice(platform: "ios", identity: deviceID)
            invalidateSession()
        }
    }
    func run(_ item: ScriptItem, kind: ScriptKind, notify: Bool) async {
        await perform {
            _ = try client()
            guard activeRunID == nil else { throw ClientError(message: "请等待当前任务结束。") }
            let environmentID: Int?
            if environmentText.trimmingCharacters(in: .whitespaces).isEmpty { environmentID = nil }
            else if let id = Int(environmentText), id > 0 { environmentID = id }
            else { throw ClientError(message: "环境 ID 必须为正整数，留空使用默认环境。") }
            let bundle = try await client().download(kind, id: item.id, environmentID: environmentID)
            try await start(bundle: bundle, name: item.name, upload: true, notify: notify)
        }
    }
    func selftest() async {
        await perform {
            _ = try client()
            guard let url = Bundle.main.url(forResource: "selftest", withExtension: "json") else { throw ClientError(message: "缺少本机自检脚本。") }
            let bundle = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            try await start(bundle: bundle, name: "本机执行自检", upload: false, notify: false)
        }
    }
    private func start(bundle: JSONValue, name: String, upload: Bool, notify: Bool) async throws {
        _ = try client()
        guard activeRunID == nil else { throw ClientError(message: "有尚未确认结束的运行，请先查看运行记录。") }
        try BundleValidation.validate(bundle)
        let status = try await executor.status()
        guard !status.running else { throw ClientError(message: "本机执行器正在执行其他任务。") }
        if systemNotify { try await prepareNotifications() }
        let id = UUID().uuidString
        var record = RunRecord(id: id, name: name, startedAt: Date(), server: upload ? server : "", username: upload ? account : "", state: "正在提交")
        record.notifyOnCompletion = systemNotify
        // Persist before POST so an app suspension or response timeout cannot lose the run ID.
        var updated = runs; updated.insert(record, at: 0)
        try storage.write(updated, name: "runs.json"); runs = updated; activeRunID = id; tab = 2
        let payload: JSONValue = .object([
            "bundle": bundle, "run_id": .string(id), "platform": .string("ios"),
            "device_serial": .string(deviceID), "server": .string(upload ? server : ""),
            "token": .string(upload ? token : ""), "notify": .bool(notify),
            "system_notify": .bool(false), "notify_app": .bool(systemNotify), "name": .string(name),
            "completion_bundle_id": .string(systemNotify ? (Bundle.main.bundleIdentifier ?? "") : "")
        ])
        // Keep the network handoff alive briefly; execution itself belongs to WDA, not this app.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Submit script")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            let result = try await executor.start(payload)
            guard result.run_id == id else { throw ClientError(message: "执行器返回了不同的运行编号，请检查状态。") }
            updateRun(id, state: "执行中")
        } catch {
            updateRun(id, state: "提交结果待确认")
            self.error = "未确认执行器是否接收，请勿重复启动。\n\(error.localizedDescription)"
        }
        await refresh()
    }
    private func updateRun(_ id: String, state: String, logs: [String]? = nil, result: JSONValue? = nil, finished: Bool = false) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].state = state
        if let logs { runs[index].logs = logs }
        if let result { runs[index].result = result }
        runs[index].finished = finished
        do { try storage.write(runs, name: "runs.json") } catch { self.error = "保存运行记录失败：\(error.localizedDescription)" }
    }
    func refresh() async {
        guard !loggingOut else { return }
        if restoringSession {
            guard !refreshing else { return }; refreshing = true
            do {
                let restored = PlatformClient(server: try ServerAddress(server), token: token)
                let _: JSONValue = try await restored.http.send(restored.request("auth/users/me"))
                loggedIn = true; restoringSession = false
            } catch {
                // No protected UI is shown until the saved session has been validated.
                _ = try? await executor.schedules(.object(["items": .array([])]))
                invalidateSession(); self.error = "请重新连接平台：\(error.localizedDescription)"
            }
            refreshing = false
        }
        guard loggedIn else { return }
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            let status = try await executor.status()
            executorRunning = status.running
            executorReady = true; executorText = status.running ? "本机执行器 · 运行中" : "本机执行器 · 就绪"
            await refreshSchedules()
            if activeRunID == nil, let id = status.run_id,
               runs.contains(where: { $0.id == id && !$0.finished && $0.server == server && $0.username == account }) {
                activeRunID = id
            }
            if let id = activeRunID {
                if status.run_id == id {
                    let logs = try? await executor.logs()
                    if status.running { updateRun(id, state: "执行中", logs: logs) }
                    else if let result = status.last_result, result != .null {
                        let state = result["aborted"].bool == true ? "已停止" : result["success"].bool == true ? "执行成功" : result["success"].bool == false || result["error"].string != nil ? "执行失败" : "执行结束（结果待核对）"
                        if let report = try? await executor.report(runID: id), let index = runs.firstIndex(where: { $0.id == id }) {
                            runs[index].report = report
                        }
                        updateRun(id, state: state, logs: logs, result: result, finished: true); activeRunID = nil
                    } else { updateRun(id, state: "结果待确认", logs: logs) }
                } else {
                    // A later scheduled run may already have replaced the executor's current ID.
                    if let report = try await executor.report(runID: id), let index = runs.firstIndex(where: { $0.id == id }) {
                        runs[index].report = report
                        let result: JSONValue = .object(["success": .bool(report["success"].bool == true), "upload_ok": .bool(false), "aborted": report["aborted"]])
                        updateRun(id, state: report["success"].bool == true ? "执行成功" : "执行失败", logs: report["logs"].array.compactMap(\.string), result: result, finished: true)
                    } else { updateRun(id, state: "执行器已切换任务，结果未知", finished: true) }
                    activeRunID = nil
                }
            }
        } catch {
            executorReady = false; executorText = "本机执行器未连接"
            if let id = activeRunID { updateRun(id, state: "连接中断，等待恢复") }
        }
        // WDA has separate network permissions. Retry persisted results through
        // this app when it returns to the foreground, including failed cases.
        if loggedIn, let record = runs.first(where: {
            $0.needsUpload(server: server, username: account)
                && Date().timeIntervalSince(uploadAttempts[$0.id] ?? .distantPast) >= 60
                && !uploadingRuns.contains($0.id)
        }) {
            do { try await upload(record) }
            catch {
                if let index = runs.firstIndex(where: { $0.id == record.id }) {
                    runs[index].logs.append("[回传] 自动补传失败：\(error.localizedDescription)")
                    try? storage.write(runs, name: "runs.json")
                }
            }
        }
        let heartbeatState = executorReady ? (executorRunning ? "RUNNING" : "READY") : "NOT_READY"
        if loggedIn && !loggingOut && (Date().timeIntervalSince(lastHeartbeat) > 60 || heartbeatState != lastHeartbeatState) {
            lastHeartbeat = Date()
            lastHeartbeatState = heartbeatState
            do {
                let bounds = UIScreen.main.nativeBounds
                let payload: JSONValue = .object([
                    "platform": .string("ios"), "udid": .string(deviceID), "name": .string("AutoDroid · \(UIDevice.current.model)"),
                    "model": .string(UIDevice.current.model), "brand": .string("Apple"), "os_version": .string(UIDevice.current.systemVersion),
                    "resolution": .string("\(Int(bounds.width))x\(Int(bounds.height))"),
                    "executor_status": .string(heartbeatState)
                ])
                let client = try client()
                let _: JSONValue = try await client.http.send(client.request("device-runs/register", method: "POST", body: payload))
                deviceText = "App 在线状态已同步到设备中心"
            } catch {
                deviceText = "平台暂不可达或登录过期"
                if (error as? ClientError)?.statusCode == 401 {
                    _ = try? await executor.schedules(.object(["items": .array([])]))
                    invalidateSession()
                }
            }
        }
        if loggedIn && systemNotify {
            for run in scopedRuns where run.finished && run.notifyOnCompletion == true {
                do { if try await CompletionNotifications.shared.send(run) { tab = 2 } }
                catch { notificationStatus = "通知发送失败：\(error.localizedDescription)" }
            }
        }
    }
    func stop() async {
        await perform {
            _ = try client()
            let status = try await executor.status()
            guard let id = activeRunID, status.run_id == id, status.running else { throw ClientError(message: "当前没有属于本 App 的运行中任务。") }
            try await executor.stop(); updateRun(id, state: "已请求停止，等待当前动作结束")
        }
    }
    func retryUpload(_ record: RunRecord) async {
        await perform { try await upload(record) }
    }
    private func upload(_ record: RunRecord) async throws {
            guard !uploadingRuns.contains(record.id) else { return }
            uploadingRuns.insert(record.id); uploadAttempts[record.id] = Date()
            defer { uploadingRuns.remove(record.id) }
            guard record.server == server, record.username == account, loggedIn else {
                throw ClientError(message: "请登录此运行所属的平台与账号后重试。")
            }
            var report = record.report
            if report == nil { report = try await executor.report(runID: record.id) }
            guard let report, report["run_id"].string == record.id else {
                throw ClientError(message: "本机报告暂不可用。执行器仅保留最近十次运行文件。")
            }
            let client = try client()
            let response: JSONValue = try await client.http.send(client.request("device-runs/report", method: "POST", body: report))
            if let index = runs.firstIndex(where: { $0.id == record.id }) {
                runs[index].report = report
                var result: [String: JSONValue] = [:]
                if case .object(let existing) = runs[index].result { result = existing }
                result["upload_ok"] = .bool(true); result["upload_response"] = response
                result.removeValue(forKey: "upload_error")
                runs[index].result = .object(result)
                runs[index].logs.append("[回传] 执行结果已补传平台")
                try storage.write(runs, name: "runs.json")
            }
    }
    func dismissUnknownRun() {
        if let id = activeRunID { updateRun(id, state: "已结束跟踪（结果未知）", finished: true); activeRunID = nil }
    }

    func reportPage(skip: Int, keyword: String, status: String) async throws -> ExecutionPage {
        try await client().executions(skip: skip, keyword: keyword, status: status)
    }
    func reportHTML(_ id: Int) async throws -> String { try await client().reportHTML(id) }
    func targets(_ kind: ScriptKind, skip: Int, keyword: String, folderID: Int? = nil) async throws -> ScriptPage {
        try await client().list(kind, skip: skip, keyword: keyword, folderID: folderID)
    }
    func folders(_ kind: ScriptKind) async throws -> [FolderChoice] { try await client().folders(kind) }
    func preview(_ kind: ScriptKind, id: Int) async throws -> ScriptPreview {
        do { return try await client().preview(kind, id: id) }
        catch {
            if (error as? ClientError)?.statusCode == 401 {
                _ = try? await executor.schedules(.object(["items": .array([])]))
                invalidateSession()
            }
            throw error
        }
    }
    func saveSchedule(_ input: LocalSchedule, delete: Bool = false) async {
        await perform {
            changingSchedules = true; defer { changingSchedules = false }
            _ = try client()
            var item = input
            item.server = server; item.username = account
            guard delete || (item.targetID > 0 && !item.name.trimmingCharacters(in: .whitespaces).isEmpty) else {
                throw ClientError(message: "请输入任务名称并选择用例或场景。")
            }
            item.nextRun = item.next(after: Date())
            guard delete || !item.enabled || item.nextRun != nil else { throw ClientError(message: "单次执行时间必须晚于当前时间。") }
            var updated = schedules.filter { $0.id != item.id }
            if !delete { updated.append(item) }
            if !delete && item.enabled && systemNotify { try await prepareNotifications() }
            // Commit only after the executor acknowledges the replacement, including deletion.
            try await syncSchedules(updated)
            try storage.write(updated, name: "schedules.json"); schedules = updated
        }
    }
    private func syncSchedules(_ values: [LocalSchedule]) async throws {
        _ = try client()
        let address = try ServerAddress(server)
        let payload = values.filter { $0.server == server && $0.username == account && $0.enabled }.map { item -> JSONValue in
            let components = Calendar.current.dateComponents([.hour, .minute], from: item.date)
            var query = [URLQueryItem(name: "platform", value: "ios")]
            if let env = item.environmentID { query.append(.init(name: "env_id", value: String(env))) }
            return .object([
                "id": .string(item.id), "name": .string(item.name), "rule": .string(item.rule.rawValue),
                "next_run": .number((item.nextRun ?? item.next(after: Date()) ?? .distantPast).timeIntervalSince1970),
                "hour": .number(Double(components.hour ?? 0)), "minute": .number(Double(components.minute ?? 0)),
                "weekday": .number(Double(item.weekday)), "interval": .number(Double(max(1, item.intervalMinutes) * 60)),
                "timezone": .string(TimeZone.current.identifier), "server": .string(server), "username": .string(account),
                "fetch_url": .string(address.api("app-runs/\(item.kind.rawValue)/\(item.targetID)/script", query: query).absoluteString),
                "token": .string(token), "notify": .bool(item.notify), "system_notify": .bool(false),
                "notify_app": .bool(systemNotify), "completion_bundle_id": .string(systemNotify ? (Bundle.main.bundleIdentifier ?? "") : ""),
                "device_serial": .string(deviceID)
            ])
        }
        let response = try await executor.schedules(.object(["items": .array(payload)]))
        schedulerInstance = response["instance"].string ?? ""
        schedulesSynced = true; scheduleStatus = "已同步至本机执行器"
    }
    private func refreshSchedules() async {
        guard !changingSchedules else { return }
        do {
            let state = try await executor.schedules()
            guard !changingSchedules, loggedIn else { return }
            let instance = state["instance"].string ?? ""
            // Read back next occurrences before resyncing, so a completed once-only task is not replayed.
            for remote in state["items"].array {
                if let i = schedules.firstIndex(where: { $0.id == remote["id"].string && $0.server == server && $0.username == account }) {
                    schedules[i].enabled = remote["enabled"].bool ?? schedules[i].enabled
                    if let next = remote["next_run"].number { schedules[i].nextRun = Date(timeIntervalSince1970: next) }
                }
            }
            for event in state["events"].array where event["server"].string == server && event["username"].string == account {
                guard let id = event["run_id"].string else { continue }
                if !runs.contains(where: { $0.id == id }) {
                    var record = RunRecord(id: id, name: event["name"].string ?? "定时任务", startedAt: Date(timeIntervalSince1970: event["started_at"].number ?? Date().timeIntervalSince1970), server: server, username: account, state: "执行中")
                    record.notifyOnCompletion = event["notify_app"].bool ?? false
                    runs.insert(record, at: 0)
                }
                if event["finished"].bool == true {
                    if let index = runs.firstIndex(where: { $0.id == id }), !runs[index].finished {
                        runs[index].report = try? await executor.report(runID: id)
                        let result = event["result"]
                        updateRun(id, state: result["success"].bool == true ? "执行成功" : "执行失败", logs: event["logs"].array.compactMap(\.string), result: result, finished: true)
                        if activeRunID == id { activeRunID = nil }
                    }
                }
            }
            try storage.write(schedules, name: "schedules.json")
            try storage.write(runs, name: "runs.json")
            if !schedulesSynced || schedulerInstance != instance {
                // An interrupted executor cannot catch up by replaying old UI operations.
                for i in schedules.indices where schedules[i].enabled && (schedules[i].nextRun ?? .distantPast) < Date() {
                    schedules[i].nextRun = schedules[i].next(after: Date())
                    if schedules[i].nextRun == nil { schedules[i].enabled = false }
                }
                try await syncSchedules(schedules)
                try storage.write(schedules, name: "schedules.json")
            }
            notificationStatus = await CompletionNotifications.shared.status()
        } catch { schedulesSynced = false; scheduleStatus = "定时任务未同步：\(error.localizedDescription)" }
    }
    func enableNotifications() async {
        await perform {
            _ = try client()
            try await prepareNotifications()
            systemNotify = true
        }
    }
    private func prepareNotifications() async throws {
        _ = try await CompletionNotifications.shared.authorize()
        notificationStatus = await CompletionNotifications.shared.status()
    }
}
