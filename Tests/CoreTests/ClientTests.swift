import XCTest
@testable import AutoDroidCore
import Foundation

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = data
            }
            let (status, body) = try Self.handler!(captured)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ClientTests: XCTestCase {
    func http(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> HTTPClient {
        StubProtocol.handler = { request in let (status, body) = try handler(request); return (status, Data(body.utf8)) }
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]
        return HTTPClient(session: URLSession(configuration: c))
    }
    override func tearDown() { StubProtocol.handler = nil }
    func testCasePreviewUsesReadOnlyEndpointsAndIOSLocatorInStepOrder() async throws {
        var paths: [String] = []
        var client = PlatformClient(server: try ServerAddress("https://test/prefix"), token: "token")
        client.http = http { request in
            let path = request.url!.path; paths.append(path)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            if path == "/prefix/api/cases/7" { return (200, #"{"id":7,"name":"登录","description":"最新说明"}"#) }
            XCTAssertEqual(path, "/prefix/api/cases/7/steps")
            return (200, #"[{"id":2,"order":2,"action":"input","args":{"value":"测试"},"platform_overrides":{"android":{"by":"id","selector":"android-id"},"ios":{"by":"label","selector":"账号"}},"execute_on":["ios"],"timeout":15,"error_strategy":"CONTINUE","retry_count":2},{"id":1,"order":1,"action":"start_app","args":{"app_key":"shop"},"execute_on":["android"]}]"#)
        }
        let result = try await client.preview(.cases, id: 7)
        XCTAssertEqual(result.item.description, "最新说明")
        XCTAssertEqual(result.steps.map(\.id), [1, 2])
        XCTAssertFalse(result.steps[0].runsOnIOS)
        XCTAssertEqual(result.steps[1].detail, "label=账号 · 输入：测试")
        XCTAssertEqual(result.steps[1].metadata, "超时 15 秒 · 失败时继续执行 · 重试 2 次")
        XCTAssertEqual(paths.count, 2) // Preview never fetches or starts an executable bundle.
    }

    func testScenarioPreviewPreservesOrderAliasesDuplicateCasesAndMissingCases() async throws {
        var paths: [String] = []
        var client = PlatformClient(server: try ServerAddress("http://test"), token: "token")
        client.http = http { request in
            let path = request.url!.path; paths.append(path)
            switch path {
            case "/api/scenarios/9": return (200, #"{"id":9,"name":"购物流程"}"#)
            case "/api/scenarios/9/steps": return (200, #"[{"id":13,"case_id":7,"order":3,"alias":"第二次登录"},{"id":11,"case_id":7,"order":1,"alias":"第一次登录"},{"id":12,"case_id":8,"order":2}]"#)
            case "/api/cases/7": return (200, #"{"id":7,"name":"登录"}"#)
            case "/api/cases/8": return (404, #"{"detail":"用例不存在"}"#)
            default: XCTFail("Unexpected preview request: \(path)"); return (500, "{}")
            }
        }
        let result = try await client.preview(.scenarios, id: 9)
        XCTAssertEqual(result.cases.map(\.id), [11, 12, 13])
        XCTAssertEqual(result.cases.map { $0.item.id }, [7, 8, 7])
        XCTAssertEqual(result.cases[2].alias, "第二次登录")
        XCTAssertTrue(result.cases[1].missing)
        XCTAssertEqual(paths.filter { $0 == "/api/cases/7" }.count, 1)
        XCTAssertFalse(paths.contains { $0.contains("script") || $0.contains("run") })
    }

    func testPreviewDoesNotTreatExpiredLoginAsMissingCase() async throws {
        var client = PlatformClient(server: try ServerAddress("http://test"), token: "expired")
        client.http = http { request in
            switch request.url!.path {
            case "/api/scenarios/9": return (200, #"{"id":9,"name":"场景"}"#)
            case "/api/scenarios/9/steps": return (200, #"[{"id":1,"order":1,"case_id":7}]"#)
            default: return (401, #"{"detail":"登录已过期"}"#)
            }
        }
        do { _ = try await client.preview(.scenarios, id: 9); XCTFail("Must reject expired login") }
        catch let error as ClientError { XCTAssertEqual(error.statusCode, 401) }
    }
    func testLogoutMarksOnlyThisIOSAppOfflineBeforeDiscardingCredentials() async throws {
        var client = PlatformClient(server: try ServerAddress("http://test"), token: "session-token")
        client.http = http { request in
            XCTAssertEqual(request.url?.path, "/api/device-runs/logout")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let payload = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(payload["platform"].string, "ios")
            XCTAssertEqual(payload["udid"].string, "installation-id")
            return (200, #"{"ok":true}"#)
        }
        let result = try await client.logoutDevice(platform: "ios", identity: "installation-id")
        XCTAssertEqual(result["ok"].bool, true)
    }
    func testFolderTreesKeepNestedAndEmptyFoldersForBothLibraries() async throws {
        for kind in ScriptKind.allCases {
            var client = PlatformClient(server: try ServerAddress("http://test"), token: "token")
            client.http = http { request in
                XCTAssertEqual(request.url?.path, kind == .cases ? "/api/folders/tree" : "/api/scenario-folders/tree")
                return (200, #"{"tree":[{"id":"folder-1","name":"商城","type":"folder","children":[{"id":"folder-2","name":"登录","type":"folder","children":[]},{"id":"case-7","name":"用例","type":"case"}]},{"id":"folder-3","name":"空文件夹","type":"folder"}]}"#)
            }
            let folders = try await client.folders(kind)
            XCTAssertEqual(folders.map(\.id), [1, 2, 3])
            XCTAssertEqual(folders.map(\.depth), [0, 1, 0])
        }
    }
    func testFolderFilterSurvivesSearchAndPaginationAndCanBeCleared() async throws {
        for kind in ScriptKind.allCases {
            for folderID: Int? in [12, nil] {
                var client = PlatformClient(server: try ServerAddress("http://test"), token: "token")
                client.http = http { request in
                    XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path, "/api/\(kind.rawValue)/")
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    XCTAssertEqual(query.first { $0.name == "folder_id" }?.value, folderID.map(String.init))
                    XCTAssertEqual(query.first { $0.name == "keyword" }?.value, "购物车")
                    XCTAssertEqual(query.first { $0.name == "skip" }?.value, "50")
                    return (200, #"{"total":0,"items":[]}"#)
                }
                _ = try await client.list(kind, skip: 50, keyword: "购物车", folderID: folderID)
            }
        }
    }
    func testLegacyRunsDoNotGenerateNewCompletionNotifications() throws {
        let old = #"{"id":"old","name":"旧报告","startedAt":0,"server":"http://test","username":"user","state":"通过","logs":[],"result":null,"finished":true}"#
        let run = try JSONDecoder().decode(RunRecord.self, from: Data(old.utf8))
        XCTAssertNil(run.notifyOnCompletion)
        var current = run; current.notifyOnCompletion = true
        let restored = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.notifyOnCompletion, true)
    }
    func testServerURLNormalizesAPIAndKeepsReverseProxyPrefix() throws {
        let s = try ServerAddress(" https://example.test/autodroid/api/ ")
        XCTAssertEqual(s.api("cases/").absoluteString, "https://example.test/autodroid/api/cases/")
        for bad in ["file:///tmp/test", "http://u:p@server", "http://host?x=1", "host:8000"] {
            XCTAssertThrowsError(try ServerAddress(bad))
        }
    }
    func testLoginEncodingDoesNotCorruptSpecialCharacters() throws {
        let request = PlatformClient.loginRequest(server: try ServerAddress("https://example.test"), username: "a+b&用户", password: " x=+&%")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("username=a%2Bb%26")); XCTAssertTrue(body.contains("password=%20x%3D%2B%26%25"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testScriptListUsesPaginationAndAuthentication() async throws {
        var client = PlatformClient(server: try ServerAddress("http://test"), token: "test-token")
        client.http = http { r in
            XCTAssertEqual(r.url?.absoluteString.hasPrefix("http://test/api/scenarios/?"), true)
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(q.first { $0.name == "skip" }?.value, "50")
            return (200, #"{"total":51,"items":[{"id":7,"name":"场景","description":null}]}"#)
        }
        let page = try await client.list(.scenarios, skip: 50, keyword: "")
        XCTAssertEqual(page.total, 51); XCTAssertEqual(page.items[0].id, 7)
    }
    func fixture() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("Resources/selftest.json")))
    }
    func testRealPlatformBundleDownloadsUnmodifiedAsIOS() async throws {
        let bundle = try fixture()
        var client = PlatformClient(server: try ServerAddress("http://test"), token: "test")
        client.http = http { r in
            XCTAssertEqual(r.url?.path, "/api/app-runs/cases/3/script")
            let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(q.first { $0.name == "platform" }?.value, "ios")
            XCTAssertEqual(q.first { $0.name == "env_id" }?.value, "2")
            return (200, bundle.pretty)
        }
        let downloaded = try await client.download(.cases, id: 3, environmentID: 2)
        XCTAssertEqual(downloaded, bundle)
    }
    func testInvalidBundleCannotReachExecutor() throws {
        guard case .object(var bundle) = try fixture() else { return XCTFail("fixture") }
        bundle["case_files"] = .object(["../../escape.js": .string("danger")])
        XCTAssertThrowsError(try BundleValidation.validate(.object(bundle)))
        bundle["case_files"] = .object([:]); bundle["adapter_js"] = .string("")
        XCTAssertThrowsError(try BundleValidation.validate(.object(bundle)))
    }
    func testWDAStatusEnvelopeAndLocalOnlyEndpoint() async throws {
        var executor = ExecutorClient()
        executor.http = http { r in
            XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:8100/autodroid/status")
            XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
            return (200, #"{"value":{"running":false,"run_id":"abc","last_result":{"success":true,"upload_ok":false},"version":"autodroid-wda/1"},"sessionId":"xyz"}"#)
        }
        let status = try await executor.status()
        XCTAssertFalse(status.running); XCTAssertEqual(status.last_result?["success"].bool, true)
        XCTAssertEqual(status.last_result?["upload_ok"].bool, false)
    }
    func testHTTP200WithWDAErrorIsNotAccepted() async throws {
        var executor = ExecutorClient()
        executor.http = http { _ in (200, #"{"value":{"error":"unknown error","message":"已有执行在进行中"}}"#) }
        do { _ = try await executor.start(.object([:])); XCTFail("must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("已有执行")) }
    }
    func testExpiredTokenProducesLoginMessage() async throws {
        let http = http { _ in (401, #"{"detail":"Unauthorized"}"#) }
        do { let _: JSONValue = try await http.send(URLRequest(url: URL(string: "http://test")!)); XCTFail("must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("重新登录")) }
    }
    func testHTTPErrorFallsBackToPlainTextBody() async throws {
        let http = http { _ in (500, "Internal Server Error") }
        do { let _: JSONValue = try await http.send(URLRequest(url: URL(string: "http://test")!)); XCTFail("must reject") }
        catch { XCTAssertEqual(error.localizedDescription, "HTTP 500：Internal Server Error") }
    }
    func testNetworkLossIsNotACompletedRun() async throws {
        var executor = ExecutorClient()
        executor.http = http { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await executor.status(); XCTFail("must not fabricate a completed status") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testFailedReportIsEligibleForUploadOnlyInItsOwnAccount() {
        var record = RunRecord(id: "failed-run", name: "失败用例", startedAt: Date(),
                               server: "http://platform", username: "owner", state: "执行失败")
        record.finished = true
        record.result = .object(["success": .bool(false), "upload_ok": .bool(false)])
        record.report = .object(["run_id": .string(record.id), "success": .bool(false)])
        XCTAssertTrue(record.needsUpload(server: record.server, username: record.username))
        XCTAssertFalse(record.needsUpload(server: record.server, username: "other"))
        XCTAssertFalse(record.needsUpload(server: "http://other", username: record.username))
        record.result = .object(["upload_ok": .bool(true)])
        XCTAssertFalse(record.needsUpload(server: record.server, username: record.username))
        record.result = .null
        record.report = .object(["run_id": .string("another-run")])
        XCTAssertFalse(record.needsUpload(server: record.server, username: record.username))
    }

    func testReportSupportsLegacyNumericFoundFlag() async throws {
        for found in ["true", "1"] {
            var executor = ExecutorClient()
            executor.http = http { _ in
                (200, "{\"value\":{\"found\":\(found),\"report\":{\"run_id\":\"failed\",\"success\":false}}}")
            }
            let report = try await executor.report(runID: "failed")
            XCTAssertEqual(report?["run_id"].string, "failed")
            XCTAssertEqual(report?["success"].bool, false)
        }
    }

    func testEachRunFetchesLatestBundleWithoutCacheAndPreservesFeishuChoice() async throws {
        let bundle = try fixture()
        var calls = 0
        var platform = PlatformClient(server: try ServerAddress("http://test"), token: "token")
        platform.http = http { request in
            calls += 1
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return (200, bundle.pretty)
        }
        _ = try await platform.download(.cases, id: 1, environmentID: nil)
        _ = try await platform.download(.cases, id: 1, environmentID: nil)
        XCTAssertEqual(calls, 2)
        var executor = ExecutorClient()
        let payload: JSONValue = .object(["bundle": bundle, "notify": .bool(true), "system_notify": .bool(true)])
        let outgoing = try executor.request("autodroid/run", method: "POST", body: payload)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(outgoing.httpBody))
        XCTAssertEqual(encoded["notify"].bool, true)
        XCTAssertEqual(encoded["system_notify"].bool, true)
        XCTAssertEqual(encoded["bundle"], bundle)
        executor.http = http { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, #"{"value":{"accepted":true,"run_id":"fresh"}}"#)
        }
        _ = try await executor.start(payload)
    }

    func testRecurrenceNeverReplaysPastOnceAndWeeklyAdvancesToNextWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        var task = LocalSchedule()
        task.date = now; task.rule = .once
        XCTAssertNil(task.next(after: now, calendar: calendar))
        task.rule = .daily
        XCTAssertEqual(task.next(after: now, calendar: calendar), calendar.date(byAdding: .day, value: 1, to: now))
        task.rule = .weekly; task.weekday = 2
        XCTAssertEqual(task.next(after: now, calendar: calendar), calendar.date(byAdding: .day, value: 7, to: now))
        task.rule = .interval; task.intervalMinutes = 15
        XCTAssertEqual(task.next(after: now, calendar: calendar), now.addingTimeInterval(900))
    }

    func testDailyRecurrenceUsesWallClockAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9))!
        var task = LocalSchedule(); task.rule = .daily; task.date = now
        let next = try XCTUnwrap(task.next(after: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: next), 9)
        XCTAssertEqual(next.timeIntervalSince(now), 23 * 3600)
    }

    func testRunningReportCanHaveNoDurationOrReportFile() async throws {
        var platform = PlatformClient(server: try ServerAddress("http://test"), token: "token")
        platform.http = http { request in
            XCTAssertEqual(request.url?.path, "/api/reports/executions")
            return (200, #"{"total":1,"items":[{"id":1,"scenario_name":"运行中","status":"RUNNING","start_time":"2026-10-19T09:00:00","duration":null}]}"#)
        }
        let page = try await platform.executions(skip: 0, keyword: "", status: "")
        XCTAssertNil(page.items.first?.duration)
    }
}
