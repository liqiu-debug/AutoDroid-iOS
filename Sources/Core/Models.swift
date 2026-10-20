import Foundation

// Preserve script bundles without narrowing their schema or changing source strings.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    var pretty: String { guard let d = try? JSONEncoder.pretty.encode(self) else { return "" }; return String(decoding: d, as: UTF8.self) }
}

struct ExecutionPage: Decodable { let total: Int; let items: [ExecutionItem] }
struct ExecutionItem: Decodable, Identifiable {
    let id: Int
    let scenario_name: String
    let status: String
    let platform: String?
    let start_time: String
    let duration: Double?
    let report_id: String?
}

enum RepeatRule: String, Codable, CaseIterable {
    case once, daily, weekly, interval
    var title: String { switch self { case .once: return "单次"; case .daily: return "每天"; case .weekly: return "每周"; case .interval: return "间隔" } }
}
struct LocalSchedule: Codable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var kind: ScriptKind = .cases
    var targetID = 0
    var targetName = ""
    var rule: RepeatRule = .daily
    var date = Date().addingTimeInterval(3600)
    var weekday = 2 // Calendar: Sunday = 1
    var intervalMinutes = 60
    var notify = true
    var enabled = true
    var server = ""
    var username = ""
    var nextRun: Date?
    var environmentID: Int?
    func next(after now: Date, calendar: Calendar = .current) -> Date? {
        switch rule {
        case .once: return date > now ? date : nil
        case .interval: return now.addingTimeInterval(Double(max(1, intervalMinutes)) * 60)
        case .daily, .weekly:
            var components = calendar.dateComponents([.hour, .minute], from: date)
            components.second = 0
            if rule == .weekly { components.weekday = weekday }
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        }
    }
}
extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
enum ScriptKind: String, Codable, CaseIterable {
    case cases, scenarios
    var title: String { self == .cases ? "用例" : "场景" }
}
struct ScriptItem: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String?
}
struct ScriptPage: Codable { let total: Int; let items: [ScriptItem] }
struct FolderTree: Decodable { let tree: [FolderNode] }
struct FolderNode: Decodable {
    let id: String
    let name: String
    let type: String
    let children: [FolderNode]?
}
struct FolderChoice: Identifiable, Equatable {
    let id: Int
    let name: String
    let depth: Int
    static func flatten(_ nodes: [FolderNode], depth: Int = 0) -> [FolderChoice] {
        nodes.flatMap { node -> [FolderChoice] in
            guard node.type == "folder", let id = Int(node.id.replacingOccurrences(of: "folder-", with: "")) else { return [] }
            return [FolderChoice(id: id, name: node.name, depth: depth)] + flatten(node.children ?? [], depth: depth + 1)
        }
    }
}
struct RunRecord: Codable, Identifiable {
    let id: String
    let name: String
    let startedAt: Date
    let server: String
    let username: String
    var state: String
    var logs: [String] = []
    var result: JSONValue = .null
    var finished: Bool = false
    var report: JSONValue?
    var notifyOnCompletion: Bool? = nil

    func needsUpload(server: String, username: String) -> Bool {
        finished && !self.server.isEmpty && self.server == server && self.username == username
            && result["upload_ok"].bool != true && result["script_fetch_failed"].bool != true
            && (report?["run_id"].string == id || report == nil && result["success"].bool != nil)
    }
}
struct ExecutorStatus: Decodable {
    let running: Bool
    let run_id: String?
    let last_result: JSONValue?
    let version: String
}
struct WDAEnvelope<T: Decodable>: Decodable { let value: T }
struct ExecutorLogs: Decodable { let lines: [String]; let next: Int }
struct RunAcceptance: Decodable { let accepted: Bool; let run_id: String }

struct ClientError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

enum BundleValidation {
    static func validate(_ bundle: JSONValue) throws {
        guard bundle["format_version"] == .number(1), bundle["manifest"]["platform"].string == "ios",
              !(bundle["runtime_js"].string ?? "").isEmpty,
              !(bundle["main_js"].string ?? "").isEmpty,
              !(bundle["adapter_js"].string ?? "").isEmpty else {
            throw ClientError(message: "脚本包不是受支持的 iOS 格式，或缺少运行时/适配层。")
        }
        guard bundle["precheck"]["ok"].bool == true else {
            throw ClientError(message: "脚本预检未通过：\n\(bundle["precheck"].pretty)")
        }
        // The executor writes these relative paths into its sandbox.
        if case .object(let files) = bundle["case_files"] {
            for path in files.keys { try validatePath(path) }
        } else if case .array(let files) = bundle["case_files"] {
            for file in files {
                guard let path = file["path"].string, file["content"].string != nil else {
                    throw ClientError(message: "脚本文件缺少 path/content。")
                }
                try validatePath(path)
            }
        } else { throw ClientError(message: "脚本包缺少 case_files。") }
        if case .object(let assets) = bundle["assets"] {
            for path in assets.keys { try validatePath(path) }
        }
    }
    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            throw ClientError(message: "脚本包包含非法文件路径。")
        }
    }
}
