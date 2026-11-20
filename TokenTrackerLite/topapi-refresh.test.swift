import Foundation

private final class RefreshProtocol: URLProtocol, @unchecked Sendable {
    static var respond: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class RefreshState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var posts = 0
    private(set) var reads = 0
    private(set) var reservations = 0
    private var readsBeforePost = 0
    func reserve(_ allowed: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; reservations += 1; return allowed }
    func post() { lock.lock(); defer { lock.unlock() }; precondition(reservations == 1); readsBeforePost = reads; posts += 1 }
    func read() -> (posts: Int, reads: Int, afterPost: Int) { lock.lock(); defer { lock.unlock() }; reads += 1; return (posts, reads, reads - readsBeforePost) }
}

@main private struct RefreshTests {
    static func main() async throws {
        let key = "sk-test-only-not-a-real-credential"
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func log(at date: Date, updated: Bool) throws -> Data {
            let meta = try json(["billing_source": "subscription", "subscription_id": 1,
                "subscription_plan_title": "测试套餐", "subscription_used": updated ? 1_500_000 : 1_000_000,
                "subscription_remain": updated ? 3_500_000 : 4_000_000, "subscription_total": 5_000_000])
            return try json(["success": true, "data": [["id": updated ? 2 : 1,
                "request_id": updated ? "fresh-" + UUID().uuidString : "old", "created_at": date.timeIntervalSince1970,
                "type": 2, "quota": 100, "other": String(data: meta, encoding: .utf8)!]]])
        }
        @Sendable func body(_ request: URLRequest) -> Data {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { preconditionFailure("缺少触发请求体") }
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024), data = Data()
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(bytes, count: count) }
            return data
        }
        func run(age: TimeInterval, allow: Bool = true, triggerStatus: Int = 200, unchanged: Bool = false,
                 failRead: Bool = false, failReserve: Bool = false, delayedReads: Int = 0, noPlan: Bool = false,
                 previous: TopAPISnapshot? = nil, recentAge: TimeInterval? = nil, recentType: Int = 2) async throws -> (TopAPISnapshot, RefreshState) {
            let state = RefreshState()
            var preparedLogs = try log(at: now.addingTimeInterval(-age), updated: false)
            if let recentAge = recentAge {
                var envelope = try JSONSerialization.jsonObject(with: preparedLogs) as! [String: Any]
                var rows = envelope["data"] as! [[String: Any]]
                rows.append(["id": 3, "request_id": "recent-wallet", "created_at": now.addingTimeInterval(-recentAge).timeIntervalSince1970,
                    "type": recentType, "quota": 0, "other": "{\"billing_source\":\"wallet\"}"])
                envelope["data"] = rows
                preparedLogs = try json(envelope)
            }
            let oldLogs = preparedLogs
            let newLogs = try log(at: now, updated: true)
            let usage = try json(["code": true, "data": ["name": "测试", "total_used": 500000]])
            let status = try json(["success": true, "data": ["quota_per_unit": 500000, "quota_display_type": "USD"]])
            let balance = try json(["success": true, "data": ["balance": 103.4, "currency": "USD"]])
            let reply = try json(["choices": [["finish_reason": "stop"]]])
            RefreshProtocol.respond = { request in
                precondition(request.url?.scheme == "https" && request.url?.host == "api-top.com")
                let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.path
                precondition(path == "/api/status" ? request.value(forHTTPHeaderField: "Authorization") == nil :
                    request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
                if request.httpMethod == "POST" {
                    precondition(path == "/v1/chat/completions")
                    precondition(state.reads > 0, "必须先检查消费记录，再决定是否触发对话")
                    state.post()
                    let value = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
                    precondition(value["model"] as? String == TopAPIRefreshPolicy.triggerModel && value["max_tokens"] as? Int == 16)
                    precondition((value["messages"] as? [[String: Any]])?.count == 1 && value["stream"] as? Bool == false)
                    return (triggerStatus, reply)
                }
                precondition(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                switch path {
                case "/api/log/token":
                    let position = state.read()
                    if failRead { throw URLError(.notConnectedToInternet) }
                    return (200, noPlan ? Data("{\"success\":true,\"data\":[]}".utf8) :
                        position.posts > 0 && !unchanged && position.afterPost > delayedReads ? newLogs : oldLogs)
                case "/api/usage/token/": return (200, usage)
                case "/api/status": return (200, status)
                case "/api/usage/balance": return (200, balance)
                default: preconditionFailure("非预期请求")
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RefreshProtocol.self]
            let snapshot = try await TopAPIClient(configuration: configuration).refresh(key: key, previous: previous, now: now,
                reserveTrigger: { _ in if failReserve { throw TopAPIFailure.cacheWrite }; return state.reserve(allow) }, waitForLog: { })
            return (snapshot, state)
        }
        for age: TimeInterval in [0, 1799, 1800] {
            let (_, state) = try await run(age: age)
            precondition(state.posts == 0 && state.reservations == 0, "新快照和30分钟边界不能触发收费对话")
        }
        let (updated, triggered) = try await run(age: 1801)
        precondition(triggered.posts == 1 && triggered.reads == 2 && updated.recordedPlan?.remainingUSD == 7)
        precondition(updated.lastTriggerAt == now && updated.planError == nil)
        for age: TimeInterval in [0, 60, 1800] {
            let (active, activeState) = try await run(age: 3600, recentAge: age)
            precondition(activeState.posts == 0 && activeState.reservations == 0 && active.lastConversationAt == now.addingTimeInterval(-age),
                         "30分钟内有成功消费时，不因旧套餐快照补发对话")
        }
        let (_, inactive) = try await run(age: 3600, recentAge: 1801)
        precondition(inactive.posts == 1, "最近成功消费超过30分钟才允许补发")
        let (_, failedConversation) = try await run(age: 3600, recentAge: 60, recentType: 5)
        precondition(failedConversation.posts == 1, "失败日志不能当作近期成功对话")
        let (_, repeated) = try await run(age: 0, previous: updated)
        precondition(repeated.posts == 0 && repeated.reservations == 0, "近期已有对话时连续手动刷新不重复发送")
        let (denied, deniedState) = try await run(age: 3600, allow: false)
        precondition(deniedState.posts == 0 && denied.recordedPlan?.remainingUSD == 8 && denied.planError != nil)
        let (failed, failedState) = try await run(age: 3600, triggerStatus: 500)
        precondition(failedState.posts == 1 && failedState.reads == 1 && failed.recordedPlan?.remainingUSD == 8 && failed.lastTriggerAt == now && failed.planError != nil)
        let (delayed, delayedState) = try await run(age: 3600, delayedReads: 1)
        precondition(delayedState.posts == 1 && delayedState.reads == 3 && delayed.recordedPlan?.remainingUSD == 7)
        let (pending, pendingState) = try await run(age: 3600, unchanged: true)
        precondition(pendingState.posts == 1 && pendingState.reads == 4 && pending.planError != nil && pending.recordedPlan?.remainingUSD == 8)
        let (_, unwritable) = try await run(age: 3600, failReserve: true)
        precondition(unwritable.posts == 0, "无法保存触发状态时不能发起收费请求")
        let (unknown, unknownState) = try await run(age: 3600, noPlan: true)
        precondition(unknown.recordedPlan == nil && unknownState.posts == 0, "无有效套餐记录时不盲目触发收费对话")
        do { _ = try await run(age: 3600, failRead: true); preconditionFailure("查询失败应保留监控层旧快照") }
        catch { precondition(true) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lite-trigger-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TopAPITriggerGate(directory: directory)
        let first = try gate.reserve(key: key, at: now)
        let restarted = try TopAPITriggerGate(directory: directory).reserve(key: key, at: now.addingTimeInterval(1799))
        let due = try gate.reserve(key: key, at: now.addingTimeInterval(1800))
        let isolated = try gate.reserve(key: key + "-other", at: now)
        precondition(first && !restarted && due && isolated, "冷却跨重启持久化，30分钟后可再次触发，按Key隔离")
        let duplicate = try gate.reserve(key: key, at: now.addingTimeInterval(1801))
        precondition(!duplicate, "手动刷新同样受30分钟冷却保护")
        let saved = try String(contentsOf: gate.file, encoding: .utf8)
        precondition(!saved.contains(key), "触发记录不能保存密钥原文")
        try Data("broken".utf8).write(to: gate.file)
        do { _ = try gate.reserve(key: key, at: now.addingTimeInterval(3600)); preconditionFailure("损坏状态必须停止触发") }
        catch { precondition(true) }
        print("快照触发验证通过：30分钟边界、只读优先、同Key单次16Token对话、持久化冷却、失败保留、入账延迟和状态损坏保护")
    }
}
