import Foundation

private final class PlanTestProtocol: URLProtocol, @unchecked Sendable {
    static var response: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.response!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class PlanTestRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = [String]()
    func append(_ path: String) { lock.lock(); defer { lock.unlock() }; paths.append(path) }
    func complete() -> Bool { lock.lock(); defer { lock.unlock() }; return paths.count == 4 && Set(paths) == Set(["/api/usage/token/", "/api/log/token", "/api/status", "/api/usage/balance"]) }
}

@main private struct RecordedPlanClientTests {
    static func main() async throws {
        let key = "sk-test-only-not-a-real-credential"
        let old = Date().addingTimeInterval(-86400).timeIntervalSince1970.rounded(.down)
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let bodies: [String: Data] = [
            "/api/usage/token/": try json(["code": true, "data": ["name": "测试", "total_used": 500000]]),
            "/api/status": try json(["success": true, "data": ["quota_per_unit": 500000, "quota_display_type": "USD"]]),
            "/api/usage/balance": try json(["success": true, "data": ["balance": 103.4, "currency": "USD"]])]
        func fetch(_ previous: TopAPISnapshot?, used: Int = 6_375_000, remaining: Int = 8_000_000,
                   seconds: Double = 0, empty: Bool = false, offline: Bool = false) async throws -> TopAPISnapshot {
            let meta = try json(["billing_source": "subscription", "subscription_id": 1,
                "subscription_total": 14_375_000, "subscription_used": used, "subscription_remain": remaining])
            let logs = try json(["success": true, "data": empty ? [] : [["request_id": "latest", "created_at": old + seconds,
                "type": 2, "quota": 500000, "other": String(data: meta, encoding: .utf8)!]]])
            let requests = PlanTestRequests()
            PlanTestProtocol.response = { request in
                precondition(request.url?.scheme == "https" && request.url?.host == "api-top.com")
                let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.path
                precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                precondition(path == "/api/status" ? request.value(forHTTPHeaderField: "Authorization") == nil :
                    request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key, "全部认证请求共用原 API Key")
                requests.append(path)
                if path == "/api/log/token" {
                    if offline { throw URLError(.notConnectedToInternet) }
                    return (200, logs)
                }
                guard let body = bodies[path] else { preconditionFailure("出现非预期请求") }
                return (200, body)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlanTestProtocol.self]
            let result = try await TopAPIClient(configuration: configuration).fetch(key: key, previous: previous)
            precondition(requests.complete(), "每次刷新必须重新请求四个接口")
            return result
        }
        let first = try await fetch(nil)
        precondition(first.recordedPlan?.usedUSD == 12.75 && first.recordedPlan?.remainingUSD == 16)
        precondition(first.todayUSD == 0 && first.accountBalanceUSD == 103.4)
        let changed = try await fetch(first, used: 7_000_000, remaining: 6_000_000, seconds: 60)
        precondition(changed.recordedPlan?.usedUSD == 14 && changed.recordedPlan?.remainingUSD == 12)
        precondition(changed.recordedPlan!.recordedAt > first.recordedPlan!.recordedAt)
        let unchanged = try await fetch(changed, used: 7_000_000, remaining: 6_000_000, seconds: 60)
        precondition(unchanged.recordedPlan?.recordedAt == changed.recordedPlan?.recordedAt && unchanged.fetchedAt > changed.fetchedAt)
        let absent = try await fetch(changed, empty: true)
        precondition(absent.recordedPlan?.remainingUSD == 12 && absent.recordedPlan?.recordedAt == changed.recordedPlan?.recordedAt)
        do {
            _ = try await fetch(changed, offline: true)
            preconditionFailure("日志请求失败必须向监控层报告，保留上次快照")
        } catch { precondition(changed.recordedPlan?.remainingUSD == 12) }
        print("套餐客户端验证通过：同 Key 四接口、重复刷新重新请求、最新记录金额/时间、无新记录与网络失败")
    }
}
