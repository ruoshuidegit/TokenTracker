import Foundation

struct TopAPICycleEvent {
    let requestID: String
    let recordedAt: Date
    let responseIndex: Int
    let subscriptionID: Int?
    let planID: Int?
    let title: String
    let totalQuota: Double
    let usedQuota: Double
    let remainingQuota: Double
    let consumedQuota: Double?

    var valid: Bool {
        (subscriptionID != nil || planID != nil || !title.isEmpty) &&
        !requestID.isEmpty && requestID.utf8.count <= 256 && recordedAt.timeIntervalSince1970.isFinite &&
        recordedAt.timeIntervalSince1970 > 0 && totalQuota.isFinite && totalQuota > 0 &&
        usedQuota.isFinite && usedQuota >= 0 && remainingQuota.isFinite && remainingQuota >= 0
    }

    var beginsFull: Bool {
        let epsilon = 0.5 // 原始 quota 的半个最小单位，仅吸收浮点误差。
        if abs(usedQuota) <= epsilon && abs(remainingQuota - totalQuota) <= epsilon { return true }
        guard let consumed = consumedQuota, consumed.isFinite, consumed > 0 else { return false }
        // 扣费快照不会停留在满额；还原第一笔请求扣费之前的额度。
        return abs(usedQuota - consumed) <= epsilon && abs(remainingQuota + consumed - totalQuota) <= epsilon
    }
}

struct TopAPIWeekCycle: Codable {
    var week: Int
    var subscriptionID: Int?
    var planID: Int?
    var title: String
    var totalQuota: Double
    var usedQuota: Double
    var remainingQuota: Double
    var lastRecordedAt: Date
    var lastRequestID: String
    var lastResetAt: Date?
    var lastResetEventID: String?
    var seenRequestIDs: [String]
    var weekStartedAt: Date? = nil

    private static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func dayNumber(at now: Date = Date()) -> Int? {
        guard let start = weekStartedAt else { return nil }
        let calendar = Self.beijingCalendar
        guard let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                     to: calendar.startOfDay(for: now)).day, elapsed >= 0 else { return nil }
        return elapsed + 1
    }

    func remainingDays(at now: Date = Date()) -> Int? {
        guard valid, now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0,
              let day = dayNumber(at: now), day > 0 else { return nil }
        // 含今天；只按日期倒数，不按日历增加周数。先截断过期日期，避免极端日期整数溢出。
        if day > 28 { return 0 }
        return max(0, 28 - (week - 1) * 7 - (day - 1))
    }

    func estimatedEndDate(at now: Date = Date()) -> Date? {
        guard remainingDays(at: now) != nil, let start = weekStartedAt else { return nil }
        let calendar = Self.beijingCalendar
        // 含今天的28天周期最后一天；剩余归零后也保留原预计日期。
        return calendar.date(byAdding: .day, value: 27 - (week - 1) * 7, to: calendar.startOfDay(for: start))
    }

    func calibrated(week: Int, day: Int, on date: Date = Date()) throws -> TopAPIWeekCycle {
        guard valid, (1...4).contains(week), (1...7).contains(day),
              date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0 else { throw TopAPIFailure.invalidCycle }
        let calendar = Self.beijingCalendar
        guard let start = calendar.date(byAdding: .day, value: 1 - day, to: calendar.startOfDay(for: date)) else {
            throw TopAPIFailure.invalidCycle
        }
        var calibrated = self
        calibrated.week = week
        calibrated.weekStartedAt = start
        return calibrated
    }

    var valid: Bool {
        (1...4).contains(week) && totalQuota.isFinite && totalQuota > 0 && usedQuota.isFinite && usedQuota >= 0 &&
        remainingQuota.isFinite && remainingQuota >= 0 && lastRecordedAt.timeIntervalSince1970.isFinite && lastRecordedAt.timeIntervalSince1970 > 0 &&
        !lastRequestID.isEmpty && lastRequestID.utf8.count <= 256 && seenRequestIDs.count <= 2048 &&
        seenRequestIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 } &&
        (lastResetAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? true) &&
        (weekStartedAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? true)
    }

    private func matches(_ event: TopAPICycleEvent) -> Bool {
        if let own = subscriptionID, let other = event.subscriptionID, own != other { return false }
        if let own = planID, let other = event.planID, own != other { return false }
        if subscriptionID != nil && event.subscriptionID != nil { return true }
        if planID != nil && event.planID != nil { return true }
        if title.isEmpty || event.title.isEmpty { return true }
        return title == event.title
    }

    private static func bounded(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(ids.filter { seen.insert($0).inserted }.prefix(2048))
    }

    private static func initial(_ event: TopAPICycleEvent, history: [TopAPICycleEvent]) -> TopAPIWeekCycle {
        var cycle = TopAPIWeekCycle(week: 1, subscriptionID: event.subscriptionID, planID: event.planID,
            title: event.title, totalQuota: event.totalQuota, usedQuota: event.usedQuota, remainingQuota: event.remainingQuota,
            lastRecordedAt: event.recordedAt, lastRequestID: event.requestID, lastResetAt: nil,
            lastResetEventID: event.beginsFull ? event.requestID : nil, seenRequestIDs: [])
        cycle.seenRequestIDs = bounded([event.requestID] + history.filter { cycle.matches($0) }.map { $0.requestID })
        return cycle
    }

    private func isNewer(_ event: TopAPICycleEvent, positions: [String: Int]) -> Bool {
        if event.requestID == lastRequestID || event.requestID == lastResetEventID || seenRequestIDs.contains(event.requestID) { return false }
        if event.recordedAt > lastRecordedAt { return true }
        guard event.recordedAt == lastRecordedAt, let anchor = positions[lastRequestID] else { return false }
        // 展示 log.id 每次重编号。仅用同一响应里稳定 request_id 的相对位置判断同秒的新事件。
        return event.responseIndex < anchor
    }

    static func update(previous: TopAPIWeekCycle?, events: [TopAPICycleEvent], positions: [String: Int]) -> TopAPIWeekCycle? {
        var uniqueRequests = Set<String>()
        let ordered = events.filter { $0.valid }.sorted {
            $0.recordedAt == $1.recordedAt ? $0.responseIndex < $1.responseIndex : $0.recordedAt > $1.recordedAt
        }.filter { uniqueRequests.insert($0.requestID).inserted }
        let previous = previous.flatMap { $0.valid ? $0 : nil }
        guard let latest = ordered.first else { return previous }
        guard var cycle = previous else { return initial(latest, history: ordered) }
        if !cycle.matches(latest) {
            return cycle.isNewer(latest, positions: positions) ? initial(latest, history: ordered) : cycle
        }
        var seen = Set(cycle.seenRequestIDs)
        let chronological = ordered.reversed()
        for event in chronological {
            guard cycle.matches(event), !seen.contains(event.requestID), cycle.isNewer(event, positions: positions) else { continue }
            let sameLimit = abs(cycle.totalQuota - event.totalQuota) <= 0.5
            let hadUsage = cycle.usedQuota > 0.5 && cycle.remainingQuota < cycle.totalQuota - 0.5
            if sameLimit && hadUsage && event.beginsFull && event.requestID != cycle.lastResetEventID {
                cycle.week = cycle.week % 4 + 1
                cycle.lastResetAt = event.recordedAt
                cycle.lastResetEventID = event.requestID
                cycle.weekStartedAt = beijingCalendar.startOfDay(for: event.recordedAt)
            } else if !sameLimit && event.beginsFull {
                // 套餐上限变化只重建基准，不把提额当作新的一周。
                cycle.lastResetEventID = event.requestID
            }
            cycle.subscriptionID = event.subscriptionID ?? cycle.subscriptionID
            cycle.planID = event.planID ?? cycle.planID
            if !event.title.isEmpty { cycle.title = event.title }
            cycle.totalQuota = event.totalQuota
            cycle.usedQuota = event.usedQuota
            cycle.remainingQuota = event.remainingQuota
            cycle.lastRecordedAt = event.recordedAt
            cycle.lastRequestID = event.requestID
            seen.insert(event.requestID)
        }
        cycle.seenRequestIDs = bounded([cycle.lastRequestID] + ordered.filter { cycle.matches($0) }.map { $0.requestID } + cycle.seenRequestIDs)
        return cycle
    }
}
