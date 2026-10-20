import Foundation

struct PreviewStep: Decodable, Identifiable {
    let id: Int
    let order: Int
    let action: String
    let description: String?
    let args: JSONValue?
    let value: String?
    let execute_on: [String]?
    let platform_overrides: JSONValue?
    let timeout: Int?
    let error_strategy: String?
    let retry_count: Int?

    var runsOnIOS: Bool { execute_on?.contains("ios") ?? true }
    var title: String {
        ["click": "点击", "input": "输入", "wait_until_exists": "等待元素", "assert_text": "文本断言",
         "assert_image": "图像断言", "click_image": "图像点击", "extract_by_ocr": "OCR 提取",
         "sleep": "等待", "swipe": "滑动", "back": "返回", "home": "回到桌面",
         "start_app": "启动应用", "stop_app": "停止应用"][action] ?? action
    }
    private func argument(_ key: String) -> String? {
        guard let v = args?[key], v != .null else { return nil }
        return v.string ?? v.pretty
    }
    var locator: String {
        let override = platform_overrides?["ios"] ?? .null
        if let selector = override["selector"].string, !selector.isEmpty {
            let by = override["by"].string ?? ""
            return by.isEmpty ? selector : "\(by)=\(selector)"
        }
        return argument("text") ?? ""
    }
    var detail: String {
        switch action {
        case "click", "wait_until_exists": return locator
        case "input":
            return [locator, (argument("value") ?? value).map { "输入：\($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "assert_text": return argument("expected_text").map { "包含「\($0)」" } ?? ""
        case "assert_image", "click_image": return argument("image").map { "模板：\($0)" } ?? ""
        case "extract_by_ocr": return [argument("region").map { "区域：\($0)" }, argument("output_var").map { "保存到：\($0)" }].compactMap { $0 }.joined(separator: " · ")
        case "sleep": return argument("seconds").map { "\($0) 秒" } ?? ""
        case "swipe": return argument("direction") ?? ""
        case "start_app", "stop_app": return argument("bundle_id") ?? argument("package") ?? argument("app_key") ?? ""
        default: return ""
        }
    }
    var metadata: String {
        let strategy = error_strategy ?? "ABORT"
        let label = ["ABORT": "停止执行", "CONTINUE": "继续执行", "IGNORE": "忽略错误"][strategy] ?? strategy
        let retries = retry_count ?? 0
        return "超时 \(timeout ?? 10) 秒 · 失败时\(label)" + (retries > 0 ? " · 重试 \(retries) 次" : "")
    }
}

struct PreviewScenarioStep: Decodable {
    let id: Int
    let case_id: Int
    let order: Int
    let alias: String?
}
struct PreviewCase: Identifiable {
    let id: Int // The scenario-step identity preserves repeated references to the same case.
    let order: Int
    let alias: String?
    let item: ScriptItem
    let missing: Bool
}
struct ScriptPreview {
    let item: ScriptItem
    let steps: [PreviewStep]
    let cases: [PreviewCase]
}

extension PlatformClient {
    private func previewRead<T: Decodable>(_ path: String) async throws -> T {
        var r = try request(path)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return try await http.send(r)
    }
    func preview(_ kind: ScriptKind, id: Int) async throws -> ScriptPreview {
        let item: ScriptItem = try await previewRead("\(kind.rawValue)/\(id)")
        if kind == .cases {
            let steps: [PreviewStep] = try await previewRead("cases/\(id)/steps")
            return ScriptPreview(item: item, steps: steps.sorted { ($0.order, $0.id) < ($1.order, $1.id) }, cases: [])
        }
        let rows: [PreviewScenarioStep] = try await previewRead("scenarios/\(id)/steps")
        var names: [Int: ScriptItem] = [:]
        var missing = Set<Int>()
        var cases: [PreviewCase] = []
        for row in rows.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }) {
            try Task.checkCancellation()
            if names[row.case_id] == nil {
                do { names[row.case_id] = try await previewRead("cases/\(row.case_id)") }
                catch let error as ClientError where error.statusCode == 404 {
                    names[row.case_id] = ScriptItem(id: row.case_id, name: "用例 #\(row.case_id)", description: "此用例已删除或不存在")
                    missing.insert(row.case_id)
                }
            }
            if let target = names[row.case_id] {
                cases.append(PreviewCase(id: row.id, order: row.order, alias: row.alias, item: target, missing: missing.contains(row.case_id)))
            }
        }
        return ScriptPreview(item: item, steps: [], cases: cases)
    }
}
