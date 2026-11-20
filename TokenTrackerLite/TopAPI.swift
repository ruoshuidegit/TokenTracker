import Foundation
import Security
import CryptoKit
import LocalAuthentication
import Darwin

enum TopAPIRefreshPolicy {
    static let interval: TimeInterval = 30 * 60
    static let triggerModel = "gpt-5.6-luna"

    static func needsTrigger(_ snapshot: TopAPISnapshot, at now: Date) -> Bool {
        guard snapshot.valid, let plan = snapshot.recordedPlan else { return false }
        if let conversation = snapshot.lastConversationAt, conversation <= now.addingTimeInterval(300),
           now.timeIntervalSince(conversation) <= interval { return false }
        return now.timeIntervalSince(plan.recordedAt) > interval
    }
}

// 先持久化触发意图，再发收费请求；手动与自动刷新都遵守冷却。
struct TopAPITriggerGate {
    let file: URL

    init(directory: URL) { file = directory.appendingPathComponent("topapi-trigger-attempts.json") }

    func reserve(key: String, at now: Date) throws -> Bool {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TopAPIFailure.cacheWrite }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return false }
            throw TopAPIFailure.cacheWrite
        }
        defer { flock(descriptor, LOCK_UN) }
        var attempts = [String: Date]()
        if FileManager.default.fileExists(atPath: file.path) {
            attempts = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: file))
        }
        let fingerprint = TopAPICredential.fingerprint(key)
        if let previous = attempts[fingerprint], now.timeIntervalSince(previous) < TopAPIRefreshPolicy.interval { return false }
        attempts[fingerprint] = now
        try JSONEncoder().encode(attempts).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}

enum TopAPIFailure: Error {
    case missingKey, keychain, invalidKey, rejected, rateLimited, unavailable, invalidResponse, cacheWrite, invalidCycle, missingCycle

    var message: String {
        switch self {
        case .missingKey: return "尚未配置监控密钥。"
        case .keychain: return "无法读取钥匙串，请重新设置监控密钥。"
        case .invalidKey: return "密钥格式无效，请重新设置。"
        case .rejected: return "平台未授权或查询失败，请检查监控密钥。"
        case .rateLimited: return "查询过于频繁，请稍后手动刷新或等待下一轮自动刷新。"
        case .unavailable: return "暂时无法连接平台，保留上次结果。"
        case .invalidResponse: return "平台账单格式异常，保留上次结果。"
        case .cacheWrite: return "账单已更新，但本地缓存未能保存。"
        case .invalidCycle: return "周期校准参数无效，请使用第1至4周、第1至7天及有效日期。"
        case .missingCycle: return "尚未读取到有效套餐周期，暂时无法校准。"
        }
    }
}

enum TopAPICredential {
    private static let service = "local.tokentracker.lite.topapi"
    private static let account = "api-top.com"

    static func validated(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), (20...256).contains(key.utf8.count),
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw TopAPIFailure.invalidKey
        }
        return key
    }

    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read() throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw TopAPIFailure.keychain }
        return try validated(value)
    }

    static func save(_ value: String) throws -> String {
        let key = try validated(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrLabel as String] = "TokenTracker Lite · api-top.com 监控密钥"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TopAPIFailure.keychain }
        } else if updated != errSecSuccess { throw TopAPIFailure.keychain }
        return key
    }
}

struct TopAPIPlan: Codable {
    let title: String
    let usedUSD: Double
    let remainingUSD: Double
    let totalUSD: Double
    let recordedAt: Date
    var subscriptionID: Int? = nil
    var planID: Int? = nil
    var requestID: String? = nil

    static func remainingDaysText(until expiry: Date, now: Date = Date()) -> String {
        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 { return "已到期" }
        if remaining < 86400 { return "不足 1 天" }
        return String(format: "%.0f 天", ceil(remaining / 86400))
    }
}

struct TopAPIAccountData {
    let account: Data
    let subscriptions: Data
}

struct TopAPIDailyRecord: Codable {
    let id: String
    let recordedAt: Date
    let costUSD: Double
}

struct TopAPISnapshot: Codable {
    let schemaVersion: Int
    let keyFingerprint: String
    let keyName: String
    let todayUSD: Double
    let dayStart: Date
    let todayComplete: Bool
    let todayRecords: [TopAPIDailyRecord]
    let cumulativeUSD: Double
    let returnedLogCount: Int
    let windowStart: Date?
    let windowEnd: Date?
    let fetchedAt: Date
    var plan: TopAPIPlan?
    var accountBalanceUSD: Double?
    var planExpiresAt: Date?
    var accountName: String?
    var accountError: String?
    var balanceError: String?
    var cycle: TopAPIWeekCycle?
    var planSource: String? = nil
    var planError: String? = nil
    var lastTriggerAt: Date? = nil
    var lastConversationAt: Date? = nil

    // 无来源标记的旧版缓存也来自消费日志；账号套餐查询缓存不冒充消费记录。
    var recordedPlan: TopAPIPlan? { planSource == nil || planSource == "consumption_log" ? plan : nil }

    var valid: Bool {
        schemaVersion == 1 && todayUSD.isFinite && todayUSD >= 0 && cumulativeUSD.isFinite && cumulativeUSD >= 0 &&
        returnedLogCount >= 0 && fetchedAt.timeIntervalSince1970.isFinite &&
        Set(todayRecords.map { $0.id }).count == todayRecords.count &&
        todayRecords.allSatisfy({ !$0.id.isEmpty && $0.costUSD.isFinite && $0.costUSD >= 0 && $0.recordedAt >= dayStart && $0.recordedAt < dayStart.addingTimeInterval(86400) }) &&
        (plan.map { $0.usedUSD.isFinite && $0.usedUSD >= 0 && $0.remainingUSD.isFinite && $0.totalUSD.isFinite && $0.totalUSD > 0 && $0.recordedAt.timeIntervalSince1970.isFinite && $0.recordedAt.timeIntervalSince1970 > 0 } ?? true) &&
        (accountBalanceUSD?.isFinite ?? true) &&
        (planExpiresAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? true) &&
        (lastTriggerAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? true) &&
        (lastConversationAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? true) &&
        (cycle?.valid ?? true)
    }

    static func beijingDayStart(_ now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(for: now)
    }

    static func parse(usage: Data, logs: Data, status: Data, key: String,
                      previous: TopAPISnapshot? = nil, now: Date = Date(), account: TopAPIAccountData? = nil,
                      balanceData: Data? = nil, balanceFailure: String? = nil) throws -> TopAPISnapshot {
        struct Envelope<T: Decodable>: Decodable {
            let success: Bool?
            let code: Bool?
            let data: T?
        }
        struct UserQuota: Decodable { let total_available: Double? }
        struct Usage: Decodable { let name: String; let total_used: Double; let user_quota: UserQuota? }
        struct Status: Decodable { let quota_per_unit: Double; let quota_display_type: String }
        struct Log: Decodable { let id: Int?; let created_at: Double; let type: Int; let quota: Double; let other: String?; let request_id: String? }
        struct Identifier: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { value = number > 0 ? String(number) : "" }
                else { value = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            var number: Int? { Int(value).flatMap { $0 > 0 ? $0 : nil } }
            var valid: Bool { !value.isEmpty && value.utf8.count <= 256 }
        }
        struct Metadata: Decodable {
            let billing_source: String?
            let subscription_plan_title: String?
            let subscription_used: Double?
            let subscription_remain: Double?
            let subscription_total: Double?
            let subscription_id: Identifier?
            let subscription_plan_id: Identifier?
            let subscription_consumed: Double?
        }
        struct User: Decodable { let quota: Double; let display_name: String?; let username: String? }
        struct AccountBalance: Decodable { let balance: Double; let currency: String }
        struct Subscription: Decodable {
            let id: Int
            let plan_id: Int
            let status: String
            let end_time: Double
        }
        struct SubscriptionEntry: Decodable { let subscription: Subscription }
        struct Subscriptions: Decodable {
            let subscriptions: [SubscriptionEntry]?
            let all_subscriptions: [SubscriptionEntry]?
        }
        func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
            guard data.count <= 12 * 1024 * 1024,
                  let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { throw TopAPIFailure.invalidResponse }
            guard envelope.success == true || envelope.code == true else { throw TopAPIFailure.rejected }
            guard let value = envelope.data else { throw TopAPIFailure.invalidResponse }
            return value
        }
        let usage = try decode(Usage.self, usage)
        let logs = try decode([Log].self, logs)
        let status = try decode(Status.self, status)
        guard status.quota_per_unit.isFinite, status.quota_per_unit > 0, status.quota_display_type == "USD",
              usage.total_used.isFinite, usage.total_used >= 0,
              logs.allSatisfy({ $0.quota.isFinite && $0.quota >= 0 && $0.created_at.isFinite && $0.created_at > 0 }) else {
            throw TopAPIFailure.invalidResponse
        }
        let quotaPerUSD = status.quota_per_unit
        var seenConsumption = Set<String>()
        let consumptionRows = logs.enumerated().filter { $0.element.type == 2 }.sorted {
            $0.element.created_at == $1.element.created_at ? $0.offset < $1.offset : $0.element.created_at > $1.element.created_at
        }.filter {
            guard let requestID = $0.element.request_id, !requestID.isEmpty else { return true }
            return seenConsumption.insert(requestID).inserted
        }
        let billed = consumptionRows.map { $0.element }
        let dayStart = beijingDayStart(now)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let fingerprint = TopAPICredential.fingerprint(key)
        let matchingPrevious = previous.flatMap { $0.keyFingerprint == fingerprint && $0.valid ? $0 : nil }
        let previous = matchingPrevious.flatMap { $0.dayStart == dayStart ? $0 : nil }
        var records = Dictionary(uniqueKeysWithValues: (previous?.todayRecords ?? []).map { ($0.id, $0) })
        var overlaps = false
        for log in billed {
            let date = Date(timeIntervalSince1970: log.created_at)
            guard date >= dayStart, date < dayEnd else { continue }
            guard let id = log.request_id, !id.isEmpty, id.utf8.count <= 256 else { throw TopAPIFailure.invalidResponse }
            if records[id] != nil { overlaps = true }
            records[id] = TopAPIDailyRecord(id: id, recordedAt: date, costUSD: log.quota / quotaPerUSD)
        }
        let timestamps = logs.map { $0.created_at }
        // 日志达到上限且未覆盖零点时，今日金额只能作为下限。后续按请求 ID 去重累积。
        let coversMidnight = timestamps.min().map { $0 <= dayStart.timeIntervalSince1970 } ?? (usage.total_used == 0)
        let todayRecords = records.values.sorted { $0.id < $1.id }
        let todayUSD = todayRecords.reduce(0) { $0 + $1.costUSD }
        let complete = coversMidnight || (previous?.todayComplete == true && overlaps) ||
            abs(todayUSD - usage.total_used / quotaPerUSD) < 0.5 / quotaPerUSD
        var cycleEvents = [TopAPICycleEvent]()
        var latestPlan: TopAPIPlan?
        var latestLogID: Int?
        var requestPositions = [String: Int]()
        for indexed in consumptionRows {
            let index = indexed.offset
            let log = indexed.element
            if let requestID = log.request_id { requestPositions[requestID] = min(requestPositions[requestID] ?? index, index) }
            guard log.type == 2, let other = log.other?.data(using: .utf8),
                  let meta = try? JSONDecoder().decode(Metadata.self, from: other), meta.billing_source == "subscription",
                  let used = meta.subscription_used, let remaining = meta.subscription_remain, let total = meta.subscription_total else { continue }
            let recordedAt = Date(timeIntervalSince1970: log.created_at)
            if recordedAt <= now.addingTimeInterval(300), meta.subscription_id?.valid == true,
               used.isFinite, used >= 0, remaining.isFinite, total.isFinite, total > 0,
               latestPlan == nil || recordedAt > latestPlan!.recordedAt ||
                (recordedAt == latestPlan!.recordedAt && (log.id ?? Int.min) > (latestLogID ?? Int.min)) {
                latestPlan = TopAPIPlan(title: String((meta.subscription_plan_title ?? "套餐").prefix(40)),
                    usedUSD: used / quotaPerUSD, remainingUSD: remaining / quotaPerUSD, totalUSD: total / quotaPerUSD,
                    recordedAt: recordedAt, subscriptionID: meta.subscription_id?.number, planID: meta.subscription_plan_id?.number,
                    requestID: log.request_id)
                latestLogID = log.id
            }
            cycleEvents.append(TopAPICycleEvent(requestID: log.request_id ?? "", recordedAt: Date(timeIntervalSince1970: log.created_at),
                responseIndex: index, subscriptionID: meta.subscription_id?.number,
                planID: meta.subscription_plan_id?.number,
                title: meta.subscription_plan_title ?? "", totalQuota: total,
                usedQuota: used, remainingQuota: remaining, consumedQuota: meta.subscription_consumed))
        }
        let cycle = TopAPIWeekCycle.update(previous: matchingPrevious?.cycle, events: cycleEvents, positions: requestPositions)
        // 每次请求重新选最新消费记录；窗口缺失或倒退时保留同一 Key 的历史记录及其原始时间。
        let cachedPlan = matchingPrevious?.recordedPlan
        let plan = latestPlan.flatMap { fresh in
            cachedPlan.map { $0.recordedAt > fresh.recordedAt ? $0 : fresh } ?? fresh
        } ?? cachedPlan
        let planError = latestPlan == nil ? (plan == nil ? "未查到套餐消费记录" : "未查到套餐新记录，保留上次记录") : nil
        // 成功消费包括钱包等来源；失败日志不用于判断最近是否已发起过对话，且不受北京时间跨日影响。
        let logConversation = billed.map { Date(timeIntervalSince1970: $0.created_at) }.filter { $0 <= now.addingTimeInterval(300) }.max()
        let lastConversation = [logConversation, matchingPrevious?.lastConversationAt, plan?.recordedAt]
            .compactMap { $0 }.filter { $0 <= now.addingTimeInterval(300) }.max()
        // user_quota 才是账户钱包；令牌顶层 total_available 和 expires_at 均不用于这两张卡。
        var balance = usage.user_quota?.total_available.flatMap { $0.isFinite ? $0 / quotaPerUSD : nil }
        var expiresAt: Date?
        var accountName: String?
        var accountError: String?
        if let account = account {
            do {
                let user = try decode(User.self, account.account)
                guard user.quota.isFinite else { throw TopAPIFailure.invalidResponse }
                balance = user.quota / quotaPerUSD
                accountName = String((user.display_name ?? user.username ?? "").prefix(40))
            } catch { accountError = "账户余额查询失败" }
            do {
                let data = try decode(Subscriptions.self, account.subscriptions)
                guard data.subscriptions != nil || data.all_subscriptions != nil else { throw TopAPIFailure.invalidResponse }
                var seen = Set<Int>()
                let subscriptions = ((data.subscriptions ?? []) + (data.all_subscriptions ?? [])).map { $0.subscription }
                    .filter { seen.insert($0.id).inserted }
                guard subscriptions.allSatisfy({ $0.end_time.isFinite && $0.end_time >= 0 }) else { throw TopAPIFailure.invalidResponse }
                let active = subscriptions.filter { $0.status == "active" && $0.end_time > now.timeIntervalSince1970 }
                let selected: Subscription?
                if let id = cycle?.subscriptionID {
                    selected = subscriptions.first { $0.id == id }
                } else if let id = cycle?.planID {
                    let matching = subscriptions.filter { $0.plan_id == id }
                    selected = matching.count == 1 ? matching.first : nil
                } else {
                    selected = active.count == 1 ? active.first : subscriptions.count == 1 ? subscriptions.first : nil
                }
                if let end = selected?.end_time, end > 0 { expiresAt = Date(timeIntervalSince1970: end) }
                if expiresAt == nil, subscriptions.count > 1 { accountError = "多个套餐，请在平台查看到期时间" }
            } catch { accountError = "套餐到期时间查询失败" }
        }
        var balanceError = balanceFailure
        if let balanceData = balanceData {
            do {
                let result = try decode(AccountBalance.self, balanceData)
                guard result.currency == "USD", result.balance.isFinite else { throw TopAPIFailure.invalidResponse }
                // 站点专用接口已换算为 USD，不能再次除以 quota_per_unit，也不能读取 token_remaining。
                balance = result.balance
                balanceError = nil
            } catch { balanceError = "充值余额格式异常，稍后刷新" }
        }
        if balance != nil { balanceError = nil }
        else if balanceError != nil { balance = matchingPrevious?.accountBalanceUSD }
        let snapshot = TopAPISnapshot(schemaVersion: 1, keyFingerprint: fingerprint,
            keyName: String(usage.name.prefix(40)), todayUSD: todayUSD,
            dayStart: dayStart, todayComplete: complete, todayRecords: todayRecords,
            cumulativeUSD: usage.total_used / quotaPerUSD, returnedLogCount: logs.count,
            windowStart: timestamps.min().map { Date(timeIntervalSince1970: $0) },
            windowEnd: timestamps.max().map { Date(timeIntervalSince1970: $0) }, fetchedAt: now, plan: plan,
            accountBalanceUSD: balance, planExpiresAt: expiresAt, accountName: accountName, accountError: accountError,
            balanceError: balanceError, cycle: cycle, planSource: plan == nil ? nil : "consumption_log", planError: planError,
            lastTriggerAt: matchingPrevious?.lastTriggerAt, lastConversationAt: lastConversation)
        guard snapshot.valid else { throw TopAPIFailure.invalidResponse }
        return snapshot
    }


}

// 重定向一律拒绝，认证头仅发往固定平台；独立于本机队列采集。
final class TopAPIClient: NSObject, URLSessionTaskDelegate {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func fetch(key: String, previous: TopAPISnapshot? = nil, account: TopAPIAccountData? = nil) async throws -> TopAPISnapshot {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        @Sendable func get(_ path: String, authenticated: Bool = true) async throws -> Data {
            guard let url = URL(string: "https://api-top.com" + path) else { throw TopAPIFailure.invalidResponse }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if path == "/api/usage/balance" { request.setValue("cc-switch/1.0", forHTTPHeaderField: "User-Agent") }
            if authenticated { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            return try await send(request, session: session)
        }
        async let usage = get("/api/usage/token/")
        async let logs = get("/api/log/token")
        async let status = get("/api/status", authenticated: false)
        @Sendable func getBalance() async -> (Data?, String?) {
            do { return (try await get("/api/usage/balance"), nil) }
            catch { return (nil, "充值余额暂时无法更新") }
        }
        async let balance = getBalance()
        let (balanceData, balanceFailure) = await balance
        return try await TopAPISnapshot.parse(usage: usage, logs: logs, status: status, key: key, previous: previous,
            account: account, balanceData: balanceData, balanceFailure: balanceFailure)
    }

    // 手动与自动刷新都先查日志；近30分钟没有成功消费且套餐快照过旧时才补发一次对话。
    func refresh(key: String, previous: TopAPISnapshot? = nil, now: Date? = nil,
                 reserveTrigger: @Sendable (Date) throws -> Bool,
                 waitForLog: @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) async throws -> TopAPISnapshot {
        var fresh = try await fetch(key: key, previous: previous)
        let checkedAt = now ?? Date()
        guard TopAPIRefreshPolicy.needsTrigger(fresh, at: checkedAt) else { return fresh }
        try Task.checkCancellation()
        do {
            guard try reserveTrigger(checkedAt) else {
                fresh.planError = "消费快照较旧，30分钟内不重复触发对话"
                return fresh
            }
        } catch {
            fresh.planError = "无法保存触发状态，本次未发起对话"
            return fresh
        }
        fresh.lastTriggerAt = checkedAt
        do {
            try Task.checkCancellation()
            try await triggerSnapshot(key: key)
        } catch {
            try Task.checkCancellation()
            fresh.planError = "快照触发对话失败，30分钟内不重复尝试"
            return fresh
        }
        let oldPlan = fresh.recordedPlan
        for attempt in 0..<3 {
            if attempt > 0 { try await waitForLog() }
            try Task.checkCancellation()
            do {
                var snapshot = try await fetch(key: key, previous: fresh)
                snapshot.lastTriggerAt = checkedAt
                fresh = snapshot
                if let record = snapshot.recordedPlan,
                   record.recordedAt.timeIntervalSince1970 >= floor(checkedAt.timeIntervalSince1970),
                   record.recordedAt > (oldPlan?.recordedAt ?? .distantPast) ||
                    (record.recordedAt == oldPlan?.recordedAt && record.requestID != nil && record.requestID != oldPlan?.requestID),
                   !TopAPIRefreshPolicy.needsTrigger(snapshot, at: checkedAt) { return snapshot }
            } catch {
                try Task.checkCancellation()
                // 已收费请求不重发；只在有限次数内重新读取账单。
            }
        }
        fresh.planError = "已触发对话，暂未取得新消费记录，请稍后刷新"
        return fresh
    }

    private func makeSession() -> URLSession {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 12 * 1024 * 1024 else { throw TopAPIFailure.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw TopAPIFailure.rejected
        case 429: throw TopAPIFailure.rateLimited
        default: throw TopAPIFailure.unavailable
        }
    }

    private func triggerSnapshot(key: String) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api-top.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": TopAPIRefreshPolicy.triggerModel,
            "messages": [["role": "user", "content": "Reply only OK."]], "max_tokens": 16, "stream": false])
        let data = try await send(request, session: session)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["error"] == nil,
              let choices = body["choices"] as? [[String: Any]], !choices.isEmpty else { throw TopAPIFailure.invalidResponse }
    }
}

@MainActor final class TopAPIMonitor {
    private(set) var snapshot: TopAPISnapshot?
    private(set) var isRefreshing = false
    private(set) var error: String?
    private(set) var isConfigured = false
    var onChange: (() -> Void)?
    private var key: String?
    private var lastStarted = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let cache: URL

    init() {
        cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenTrackerLite/topapi-snapshot.json")
        do {
            key = try TopAPICredential.read()
            isConfigured = key != nil
            if let key = key, let data = try? Data(contentsOf: cache),
               let saved = try? JSONDecoder().decode(TopAPISnapshot.self, from: data), saved.valid,
               saved.keyFingerprint == TopAPICredential.fingerprint(key) {
                snapshot = saved
                lastStarted = saved.fetchedAt
            }
        } catch { self.error = (error as? TopAPIFailure ?? .keychain).message }
    }

    func configure(_ value: String) throws {
        let saved = try TopAPICredential.save(value)
        let retained = snapshot.flatMap { $0.valid && $0.keyFingerprint == TopAPICredential.fingerprint(saved) ? $0 : nil }
        generation = UUID()
        task?.cancel(); task = nil; isRefreshing = false
        key = saved; isConfigured = true; snapshot = retained; error = nil
        lastStarted = .distantPast
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard let key = key, !isRefreshing, force || Date().timeIntervalSince(lastStarted) >= TopAPIRefreshPolicy.interval else { return }
        lastStarted = Date()
        let requestGeneration = generation
        let previous = snapshot
        let gate = TopAPITriggerGate(directory: cache.deletingLastPathComponent())
        isRefreshing = true
        error = nil
        onChange?()
        task = Task { [weak self] in
            do {
                let fresh = try await TopAPIClient().refresh(key: key, previous: previous,
                    reserveTrigger: { try gate.reserve(key: key, at: $0) })
                guard !Task.isCancelled, let self = self, self.generation == requestGeneration else { return }
                self.snapshot = fresh
                self.lastStarted = fresh.fetchedAt
                do {
                    try FileManager.default.createDirectory(at: self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(fresh).write(to: self.cache, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.cache.path)
                } catch { self.error = TopAPIFailure.cacheWrite.message }
            } catch {
                guard !Task.isCancelled, let self = self, self.generation == requestGeneration else { return }
                self.error = (error as? TopAPIFailure ?? .unavailable).message
            }
            guard let self = self, self.generation == requestGeneration else { return }
            self.isRefreshing = false; self.task = nil
            self.onChange?()
        }
    }

    func cancel() { task?.cancel(); task = nil }
}
