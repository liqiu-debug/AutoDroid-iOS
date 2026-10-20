import Foundation

struct ServerAddress {
    let root: URL
    init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api") { text.removeLast(4) }
        guard let u = URL(string: text), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil,
              u.query == nil, u.fragment == nil else {
            throw ClientError(message: "请输入完整的平台地址，例如 http://192.168.1.10:8000。")
        }
        root = u
    }
    func api(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: root, resolvingAgainstBaseURL: false)!
        c.path = root.path + "/api/" + path
        c.queryItems = query.isEmpty ? nil : query
        return c.url!
    }
}

struct HTTPClient {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func send<T: Decodable>(_ request: URLRequest, as: T.Type = T.self) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError(message: "服务器未返回 HTTP 响应。") }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ClientError(message: "登录已过期，请重新登录后同步或运行。", statusCode: 401) }
            let detail = json?["detail"] ?? json?["value"]["message"] ?? .null
            let bodyText = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detailText: String
            if let value = detail.string {
                detailText = value
            } else if detail != .null {
                detailText = detail.pretty
            } else if !bodyText.isEmpty {
                detailText = bodyText
            } else {
                detailText = "服务器未提供错误详情"
            }
            throw ClientError(message: "HTTP \(http.statusCode)：\(detailText)", statusCode: http.statusCode)
        }
        if let error = json?["value"]["error"].string {
            throw ClientError(message: json?["value"]["message"].string ?? error)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct PlatformClient {
    let server: ServerAddress
    let token: String
    var http = HTTPClient()
    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil) throws -> URLRequest {
        var r = URLRequest(url: server.api(path, query: query))
        r.httpMethod = method; r.timeoutInterval = 30
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    static func loginRequest(server: ServerAddress, username: String, password: String) -> URLRequest {
        var r = URLRequest(url: server.api("auth/token")); r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        r.httpBody = Data("username=\(encode(username))&password=\(encode(password))".utf8)
        return r
    }
    func list(_ kind: ScriptKind, skip: Int, keyword: String, folderID: Int? = nil) async throws -> ScriptPage {
        var query: [URLQueryItem] = [
            .init(name: "skip", value: String(skip)), .init(name: "limit", value: "50"), .init(name: "keyword", value: keyword)
        ]
        if let folderID { query.append(.init(name: "folder_id", value: String(folderID))) }
        return try await http.send(request("\(kind.rawValue)/", query: query))
    }
    func folders(_ kind: ScriptKind) async throws -> [FolderChoice] {
        let result: FolderTree = try await http.send(request(kind == .cases ? "folders/tree" : "scenario-folders/tree"))
        return FolderChoice.flatten(result.tree)
    }
    func logoutDevice(platform: String, identity: String) async throws -> JSONValue {
        var request = try request("device-runs/logout", method: "POST", body: .object([
            "platform": .string(platform), "udid": .string(identity)
        ]))
        request.timeoutInterval = 5
        return try await http.send(request)
    }
    func download(_ kind: ScriptKind, id: Int, environmentID: Int?) async throws -> JSONValue {
        var q = [URLQueryItem(name: "platform", value: "ios")]
        if let environmentID { q.append(.init(name: "env_id", value: String(environmentID))) }
        var request = try request("app-runs/\(kind.rawValue)/\(id)/script", query: q)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let bundle: JSONValue = try await http.send(request)
        try BundleValidation.validate(bundle)
        return bundle
    }
    func executions(skip: Int, keyword: String, status: String) async throws -> ExecutionPage {
        try await http.send(request("reports/executions", query: [
            .init(name: "skip", value: String(skip)), .init(name: "limit", value: "30"),
            .init(name: "keyword", value: keyword), .init(name: "status", value: status)
        ]))
    }
    func reportHTML(_ id: Int) async throws -> String {
        let (data, response) = try await http.session.data(for: request("reports/executions/\(id)/download"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ClientError(message: "报告加载失败，请刷新或重新登录。")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ExecutorClient {
    // Always address this phone. Never use the platform's USB relay or a remote WDA.
    let base = URL(string: "http://127.0.0.1:8100")!
    var http = HTTPClient()
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path)); r.httpMethod = method; r.timeoutInterval = 10
        if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    func status() async throws -> ExecutorStatus {
        let response: WDAEnvelope<ExecutorStatus> = try await http.send(request("autodroid/status"))
        guard response.value.version.hasPrefix("autodroid-wda/") else { throw ClientError(message: "需要安装带 AutoDroid 执行器的 WDA。") }
        return response.value
    }
    func logs() async throws -> [String] {
        // Full bounded snapshot avoids cursor corruption after executor log truncation/restart.
        let response: WDAEnvelope<ExecutorLogs> = try await http.send(request("autodroid/logs"))
        return response.value.lines
    }
    func start(_ payload: JSONValue) async throws -> RunAcceptance {
        let response: WDAEnvelope<RunAcceptance> = try await http.send(request("autodroid/run", method: "POST", body: payload))
        guard response.value.accepted else { throw ClientError(message: "执行器未接受脚本。") }
        return response.value
    }
    func stop() async throws {
        let _: WDAEnvelope<JSONValue> = try await http.send(request("autodroid/stop", method: "POST", body: .object([:])))
    }
    func report(runID: String) async throws -> JSONValue? {
        let response: WDAEnvelope<JSONValue> = try await http.send(request("autodroid/report", method: "POST", body: .object(["run_id": .string(runID)])))
        // Older WDA builds boxed the comparison as an integer (1/0).
        let found = response.value["found"]
        return found.bool == true || found == .number(1) ? response.value["report"] : nil
    }
    func schedules(_ body: JSONValue? = nil) async throws -> JSONValue {
        let response: WDAEnvelope<JSONValue> = try await http.send(request("autodroid/schedules", method: body == nil ? "GET" : "POST", body: body))
        return response.value
    }
    func notifications(requestPermission: Bool = false) async throws -> JSONValue {
        let response: WDAEnvelope<JSONValue> = try await http.send(request("autodroid/notifications", method: requestPermission ? "POST" : "GET", body: requestPermission ? .object([:]) : nil))
        return response.value
    }
}
