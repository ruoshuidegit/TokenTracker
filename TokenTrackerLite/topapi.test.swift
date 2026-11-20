import Foundation

@main struct TopAPITests {
    static func main() throws {
        let key = "sk-test-only-not-a-real-credential"
        let start = Date(timeIntervalSince1970: 1794326400)
        let now = start.addingTimeInterval(36000)
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        func log(_ id: String, _ seconds: Double, _ quota: Int, subscription: Bool = false,
                 subscriptionID: Int? = 1, planID: Int? = nil) throws -> [String: Any] {
            var metadata: [String: Any] = subscription
                ? ["billing_source": "subscription", "subscription_plan_title": "月用无忧", "subscription_used": 6_375_000, "subscription_remain": 8_000_000, "subscription_total": 14_375_000]
                : ["billing_source": "wallet"]
            metadata["subscription_id"] = subscriptionID
            metadata["subscription_plan_id"] = planID
            return ["request_id": id, "created_at": start.timeIntervalSince1970 + seconds, "type": 2, "quota": quota,
                    "other": String(data: try json(metadata), encoding: .utf8)!]
        }
        func parse(_ rows: [[String: Any]], previous: TopAPISnapshot? = nil, date: Date? = nil,
                   credential: String? = nil, currency: String = "USD", used: Int = 50_000_000,
                   account: TopAPIAccountData? = nil, userQuota: Double? = nil,
                   balanceData: Data? = nil, balanceFailure: String? = nil) throws -> TopAPISnapshot {
            var usage: [String: Any] = ["name": "测试监控", "total_used": used,
                "total_available": 999_999_999, "expires_at": now.addingTimeInterval(60).timeIntervalSince1970]
            if let userQuota = userQuota { usage["user_quota"] = ["total_available": userQuota] }
            return try TopAPISnapshot.parse(usage: json(["code": true, "data": usage]),
                logs: json(["success": true, "data": rows]),
                status: json(["success": true, "data": ["quota_per_unit": 500000, "quota_display_type": currency]]),
                key: credential ?? key, previous: previous, now: date ?? now, account: account,
                balanceData: balanceData, balanceFailure: balanceFailure)
        }
        func subscription(_ id: Int, end: Date, status: String = "active", planID: Int = 1) -> [String: Any] {
            ["subscription": ["id": id, "plan_id": planID, "status": status, "end_time": end.timeIntervalSince1970,
                              "amount_total": 14_375_000, "amount_used": 6_375_000]]
        }
        func account(_ quota: Double, active: [[String: Any]], all: [[String: Any]] = []) throws -> TopAPIAccountData {
            TopAPIAccountData(account: try json(["success": true, "data": ["quota": quota, "display_name": "测试账户"]]),
                subscriptions: try json(["success": true, "data": ["subscriptions": active, "all_subscriptions": all]]))
        }
        func close(_ actual: Double, _ expected: Double) { precondition(abs(actual - expected) < 1e-9) }
        let a = try log("a", 100, 500000, subscription: true)
        let b = try log("b", 200, 250000)
        let c = try log("c", 300, 125000)
        let first = try parse([b, a])
        close(first.todayUSD, 1.5); close(first.cumulativeUSD, 100)
        close(first.recordedPlan!.usedUSD, 12.75); close(first.recordedPlan!.remainingUSD, 16)
        precondition(first.recordedPlan?.recordedAt == start.addingTimeInterval(100) && first.planError == nil)
        precondition(!first.todayComplete && first.dayStart == start)

        let rolled = try parse([c, b], previous: first)
        close(rolled.todayUSD, 1.75)
        precondition(rolled.todayRecords.count == 3 && !rolled.todayComplete)
        // 窗口滚动、重复轮询和缓存恢复均不能重复计费。
        let restored = try JSONDecoder().decode(TopAPISnapshot.self, from: JSONEncoder().encode(rolled))
        close(try parse([c, b], previous: restored).todayUSD, 1.75)
        let correction = try log("b", 200, 100000)
        close(try parse([c, correction], previous: rolled).todayUSD, 1.45)

        let old = try log("yesterday", -1, 900000)
        let complete = try parse([a, old])
        precondition(complete.todayComplete)
        close(complete.todayUSD, 1)
        let continued = try parse([b, a], previous: complete)
        precondition(continued.todayComplete)
        // 轮询中断到完全失去重叠记录时，必须降级为下限。
        let gap = try parse([c], previous: complete)
        precondition(!gap.todayComplete)

        let tomorrow = start.addingTimeInterval(86400 + 60)
        let next = try log("tomorrow", 86400 + 10, 75000)
        let newDay = try parse([next, b], previous: rolled, date: tomorrow)
        close(newDay.todayUSD, 0.15)
        precondition(newDay.todayComplete && newDay.todayRecords.count == 1)
        precondition(newDay.lastConversationAt == start.addingTimeInterval(86410) && !TopAPIRefreshPolicy.needsTrigger(newDay, at: tomorrow), "跨北京时间午夜的成功消费仍抑制补发")
        close(try parse([c], previous: rolled, credential: key + "-changed").todayUSD, 0.25)

        let empty = try parse([], used: 0)
        close(empty.todayUSD, 0); precondition(empty.todayComplete && empty.plan == nil)
        let walletOnly = try parse([b])
        let newKeyToday = try parse([a], used: 500000)
        precondition(walletOnly.plan == nil && newKeyToday.todayComplete)
        // 账户充值余额、套餐额度、密钥额度互相独立；密钥到期不能作为套餐到期。
        precondition(first.accountBalanceUSD == nil && first.planExpiresAt == nil)
        let expiry = now.addingTimeInterval(86400 * 7)
        precondition(TopAPIPlan.remainingDaysText(until: expiry, now: now) == "7 天")
        precondition(TopAPIPlan.remainingDaysText(until: now.addingTimeInterval(86401), now: now) == "2 天")
        precondition(TopAPIPlan.remainingDaysText(until: now.addingTimeInterval(86399), now: now) == "不足 1 天")
        precondition(TopAPIPlan.remainingDaysText(until: now, now: now) == "已到期")
        precondition(TopAPIPlan.remainingDaysText(until: now.addingTimeInterval(-1), now: now) == "已到期")
        let one = subscription(1, end: expiry)
        let withAccount = try parse([b, a], account: account(1_250_000, active: [one]))
        close(withAccount.accountBalanceUSD!, 2.5)
        close(withAccount.plan!.remainingUSD, 16)
        precondition(withAccount.planExpiresAt == expiry && withAccount.accountName == "测试账户")
        close(try parse([a], account: account(0, active: [one])).accountBalanceUSD!, 0)
        close(try parse([a], account: account(-250_000, active: [one])).accountBalanceUSD!, -0.5)
        close(try parse([a], userQuota: 3_000_000).accountBalanceUSD!, 6)
        func wallet(_ value: Any, currency: String = "USD") throws -> Data {
            try json(["success": true, "data": ["balance": value, "currency": currency,
                "used": 22.947912, "token_remaining": -14.100948, "token_unlimited": true]])
        }
        let funded = try parse([a, b], balanceData: wallet(103.4))
        close(funded.accountBalanceUSD!, 103.4)
        precondition(funded.recordedPlan?.remainingUSD == 16, "充值余额不能覆盖套餐记录金额")
        precondition(funded.planExpiresAt == nil && funded.balanceError == nil)
        close(try parse([a], balanceData: wallet(0)).accountBalanceUSD!, 0)
        close(try parse([a], balanceData: wallet(-0.5)).accountBalanceUSD!, -0.5)
        for bad in [try wallet("103.4"), try wallet(100, currency: "CNY"), try json(["success": false]), Data("not-json".utf8)] {
            let unavailable = try parse([a, b], balanceData: bad)
            close(unavailable.todayUSD, 1.5)
            precondition(unavailable.accountBalanceUSD == nil && unavailable.balanceError != nil)
            let cached = try parse([a, b], previous: funded, balanceData: bad)
            close(cached.accountBalanceUSD!, 103.4)
            precondition(cached.balanceError != nil)
        }
        let balanceTimeout = try parse([a], previous: funded, balanceFailure: "充值余额暂时无法更新")
        precondition(balanceTimeout.accountBalanceUSD == 103.4 && balanceTimeout.balanceError != nil)
        let otherKeyBalance = try parse([a], previous: funded, credential: key + "-new", balanceFailure: "充值余额暂时无法更新")
        precondition(otherKeyBalance.accountBalanceUSD == nil)
        let nextDayBalance = try parse([next], previous: funded, date: tomorrow, balanceFailure: "充值余额暂时无法更新")
        precondition(nextDayBalance.accountBalanceUSD == 103.4 && nextDayBalance.todayRecords.count == 1)
        // 多套餐只选账单对应的订阅实例，含历史过期记录；无法关联时不猜日期。
        let other = subscription(2, end: expiry.addingTimeInterval(86400))
        let identified = try log("identified", 100, 500000, subscription: true, subscriptionID: 2)
        let matched = try parse([identified], account: account(0, active: [one, other]))
        precondition(matched.planExpiresAt == expiry.addingTimeInterval(86400))
        let ambiguous = try parse([log("no-id", 100, 500000, subscription: true, subscriptionID: nil)], account: account(0, active: [one, other]))
        precondition(ambiguous.planExpiresAt == nil && ambiguous.accountError != nil)
        let expired = now.addingTimeInterval(-86400)
        let historical = subscription(2, end: expired, status: "expired")
        let expiredPlan = try parse([identified], account: account(0, active: [one], all: [one, historical]))
        precondition(expiredPlan.planExpiresAt == expired)
        let missingID = try log("missing", 100, 500000, subscription: true, subscriptionID: 9)
        let missingPlan = try parse([missingID], account: account(0, active: [one]))
        precondition(missingPlan.planExpiresAt == nil)
        let unknownExpiry = subscription(1, end: Date(timeIntervalSince1970: 0))
        let unknownPlan = try parse([a], account: account(0, active: [unknownExpiry]))
        precondition(unknownPlan.planExpiresAt == nil)
        // 账户接口失败不得中断原有用量卡片。
        let denied = TopAPIAccountData(account: try json(["success": false]), subscriptions: try json(["success": false]))
        let partial = try parse([b, a], account: denied)
        close(partial.todayUSD, 1.5)
        precondition(partial.recordedPlan?.remainingUSD == 16 && partial.planError == nil && partial.accountBalanceUSD == nil && partial.planExpiresAt == nil && partial.accountError != nil)
        // 新旧缓存都能读取，新字段不会使已有用量缓存失效。
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        for field in ["accountBalanceUSD", "planExpiresAt", "accountName", "accountError", "balanceError", "cycle"] { legacy.removeValue(forKey: field) }
        let legacySnapshot = try JSONDecoder().decode(TopAPISnapshot.self, from: json(legacy))
        precondition(legacySnapshot.valid && legacySnapshot.accountBalanceUSD == nil && legacySnapshot.cycle == nil)
        let accountRestored = try JSONDecoder().decode(TopAPISnapshot.self, from: JSONEncoder().encode(withAccount))
        precondition(accountRestored.valid && accountRestored.planExpiresAt == expiry && accountRestored.accountBalanceUSD == 2.5)

        func planRow(_ id: String, _ seconds: Double, used: Double, remain: Double,
                     subscription: Any = "example-subscription", displayID: Int = 1, type: Int = 2) throws -> [String: Any] {
            ["id": displayID, "request_id": id, "created_at": start.timeIntervalSince1970 + seconds,
             "type": type, "quota": 0, "other": String(data: try json(["billing_source": "subscription",
                "subscription_id": subscription, "subscription_used": used, "subscription_remain": remain,
                "subscription_total": 14_375_000]), encoding: .utf8)!]
        }
        let latest = try parse([a, planRow("new", 400, used: 7_000_000, remain: 6_000_000)], previous: first)
        close(latest.recordedPlan!.usedUSD, 14); close(latest.recordedPlan!.remainingUSD, 12)
        precondition(latest.recordedPlan?.recordedAt == start.addingTimeInterval(400), "选择最新有效记录，剩余直接采用服务端字段")
        let unchanged = try parse([planRow("new", 400, used: 7_000_000, remain: 6_000_000)], previous: latest, date: now.addingTimeInterval(10))
        precondition(unchanged.recordedPlan?.recordedAt == latest.recordedPlan?.recordedAt && unchanged.fetchedAt > latest.fetchedAt)
        let absent = try parse([b], previous: latest, date: tomorrow)
        close(absent.recordedPlan!.remainingUSD, 12)
        precondition(absent.recordedPlan?.recordedAt == latest.recordedPlan?.recordedAt && absent.planError != nil, "窗口缺少记录时跨日保留原时间")
        let otherKeyPlan = try parse([b], previous: latest, credential: key + "-other")
        precondition(otherKeyPlan.recordedPlan == nil)
        close(try parse([a], previous: latest).recordedPlan!.remainingUSD, 12)
        let zero = try parse([planRow("zero", 500, used: 1, remain: 0)], previous: latest)
        close(zero.recordedPlan!.remainingUSD, 0)
        let tie = try parse([planRow("lower", 600, used: 2, remain: 2, displayID: 2),
                             planRow("higher", 600, used: 3, remain: 3, displayID: 3)])
        close(tie.recordedPlan!.remainingUSD, 3.0 / 500000)
        for row in [try planRow("future", 36000 + 301, used: 0, remain: 14_375_000),
                    try planRow("failed", 600, used: 0, remain: 14_375_000, type: 5),
                    try planRow("missing-id", 600, used: 0, remain: 14_375_000, subscription: ""),
                    try planRow("bad", 600, used: -1, remain: 1)] {
            let filtered = try parse([row], previous: latest)
            precondition(filtered.recordedPlan?.recordedAt == latest.recordedPlan?.recordedAt)
        }
        var legacyPlan = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest)) as! [String: Any]
        legacyPlan.removeValue(forKey: "planSource")
        let oldPlan = try JSONDecoder().decode(TopAPISnapshot.self, from: json(legacyPlan))
        close(try parse([], previous: oldPlan).recordedPlan!.remainingUSD, 12)
        var accountQuery = latest
        accountQuery.planSource = "subscription"
        let isolated = try parse([], previous: accountQuery)
        precondition(isolated.recordedPlan == nil, "账号查询时间不能冒充消费记录时间")

        func cycleRow(_ id: String, _ seconds: Double, used: Double, consumed: Double? = nil,
                      total: Double = 1_000_000, subscription: Int? = 1, plan: Int? = 1,
                      title: String? = "周期套餐") throws -> [String: Any] {
            var meta: [String: Any] = ["billing_source": "subscription", "subscription_used": used,
                "subscription_remain": max(0, total - used), "subscription_total": total]
            meta["subscription_plan_title"] = title
            meta["subscription_id"] = subscription
            meta["subscription_plan_id"] = plan
            meta["subscription_consumed"] = consumed
            return ["request_id": id, "created_at": start.timeIntervalSince1970 + seconds, "type": 2,
                "quota": max(0, consumed ?? 0), "other": String(data: try json(meta), encoding: .utf8)!]
        }
        func cycleParse(_ rows: [[String: Any]], _ previous: TopAPISnapshot? = nil,
                        at seconds: Double, credential: String = key) throws -> TopAPISnapshot {
            try parse(rows, previous: previous, date: start.addingTimeInterval(seconds), credential: credential)
        }
        func checkWeek(_ snapshot: TopAPISnapshot, _ week: Int, _ name: String) {
            precondition(snapshot.valid && snapshot.cycle?.week == week, name)
        }
        let historicalFull = try cycleRow("historical-full", 10, used: 100_000, consumed: 100_000)
        let baselineRow = try cycleRow("baseline", 100, used: 500_000)
        let baseline = try cycleParse([baselineRow, historicalFull], at: 200)
        checkWeek(baseline, 1, "第一次只建立当前周基准，不回放历史重置")
        checkWeek(try cycleParse([baselineRow, historicalFull], baseline, at: 201), 1, "重复刷新不能增加周数")
        let cycleRestored = try JSONDecoder().decode(TopAPISnapshot.self, from: JSONEncoder().encode(baseline))
        checkWeek(try cycleParse([baselineRow], cycleRestored, at: 86401), 1, "重启和跨日保留周数")
        let resetTime: Double = 604900
        let exactFull = try cycleRow("exact-full", resetTime, used: 0)
        let week2 = try cycleParse([exactFull, baselineRow], baseline, at: resetTime + 1)
        checkWeek(week2, 2, "用量归零且额度恢复满额进入下一周")
        let afterFull = try cycleRow("after-full", resetTime + 2, used: 100_000, consumed: 100_000)
        let afterFullSnapshot = try cycleParse([afterFull, exactFull], week2, at: resetTime + 3)
        checkWeek(afterFullSnapshot, 2, "满额后第一笔不能再次计周")
        precondition(afterFullSnapshot.cycle?.lastResetEventID == "exact-full")
        let largeFirst = try cycleRow("large-first", resetTime, used: 750_000, consumed: 750_000)
        let chargedReset = try cycleParse([largeFirst, baselineRow], baseline, at: resetTime + 1)
        checkWeek(chargedReset, 2, "首笔扣费大于上周末用量仍可还原消费前满额")
        let afterCharge = try cycleRow("after-charge", resetTime + 2, used: 800_000, consumed: 50_000)
        let spentAfterReset = try cycleParse([afterCharge, largeFirst], chargedReset, at: resetTime + 3)
        var duplicateReset = largeFirst; duplicateReset["created_at"] = start.timeIntervalSince1970 + resetTime + 10
        duplicateReset["id"] = 999
        checkWeek(try cycleParse([duplicateReset, afterCharge], spentAfterReset, at: resetTime + 11), 2,
                  "同一请求重复写入或展示ID重编号不能再次计周")
        var evictedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spentAfterReset)) as! [String: Any]
        var evictedCycle = evictedJSON["cycle"] as! [String: Any]
        evictedCycle["seenRequestIDs"] = ["after-charge"]
        evictedJSON["cycle"] = evictedCycle
        let evictedSnapshot = try JSONDecoder().decode(TopAPISnapshot.self, from: json(evictedJSON))
        let retainedReset = try cycleParse([duplicateReset], evictedSnapshot, at: resetTime + 11)
        checkWeek(retainedReset, 2, "恢复事件滚出去重窗口后仍由独立标记阻止重播")
        precondition(retainedReset.cycle?.lastRequestID == "after-charge" && retainedReset.cycle?.usedQuota == 800_000)
        let nearFullWithoutEvidence = try cycleRow("near-full", resetTime, used: 1)
        checkWeek(try cycleParse([nearFullWithoutEvidence], baseline, at: resetTime + 1), 1,
                  "缺消费元数据时不把四舍五入后满额视为重置")
        let refund = try cycleRow("partial-refund", 200, used: 200_000)
        checkWeek(try cycleParse([refund], baseline, at: 201), 1, "普通回升未恢复满额不能增加周数")
        let capChange = try cycleRow("cap-change", resetTime, used: 0, total: 2_000_000)
        checkWeek(try cycleParse([capChange], baseline, at: resetTime + 1), 1, "提额满额只换基准")
        let changedSub = try cycleRow("other-sub", resetTime + 1, used: 0, subscription: 2)
        checkWeek(try cycleParse([changedSub], chargedReset, at: resetTime + 2), 1, "换订阅从第1周重新计数")
        let changedPlan = try cycleRow("other-plan", resetTime + 1, used: 0, plan: 2)
        checkWeek(try cycleParse([changedPlan], chargedReset, at: resetTime + 2), 1, "换套餐不能继承旧周数")
        let otherKey = try cycleParse([largeFirst], chargedReset, at: resetTime + 2, credential: key + "-different")
        checkWeek(otherKey, 1, "切换密钥隔离四周周期")
        precondition(otherKey.cycle?.lastResetAt == nil)
        let oldUnseenFull = try cycleRow("old-unseen", 50, used: 0)
        let stale = try cycleParse([oldUnseenFull], baseline, at: 300)
        checkWeek(stale, 1, "旧快照不能倒退基准或增加周数")
        precondition(stale.cycle?.lastRequestID == "baseline")
        let sameSecondFull = try cycleRow("same-second-full", 100, used: 100_000, consumed: 100_000)
        let tied = try cycleParse([sameSecondFull, baselineRow], baseline, at: 201)
        checkWeek(tied, 2, "同秒由同一响应的稳定请求锚点确认新事件")
        checkWeek(try cycleParse([baselineRow, sameSecondFull], baseline, at: 201), 1, "同秒锚点之后的旧事件不能计周")
        checkWeek(try cycleParse([sameSecondFull], baseline, at: 201), 1, "同秒缺少锚点不推断顺序")
        let tiedSpend = try cycleRow("same-second-spend", 100, used: 200_000, consumed: 100_000)
        let tiedMany = try cycleParse([tiedSpend, sameSecondFull, baselineRow], baseline, at: 201)
        checkWeek(tiedMany, 2, "同秒多笔按响应顺序处理且只计一次满额恢复")
        precondition(tiedMany.cycle?.lastRequestID == "same-second-spend")
        let resetAgain = try cycleRow("second-reset", resetTime * 2, used: 50_000, consumed: 50_000)
        let thirdCycle = try cycleParse([resetAgain, afterCharge, largeFirst, baselineRow], baseline, at: resetTime * 2 + 1)
        checkWeek(thirdCycle, 3,
                  "一次刷新回放多个新的恢复记录")
        let missingSubRow = try cycleRow("missing-sub", resetTime * 2 + 10, used: 200_000, subscription: nil)
        let missingSubCycle = try cycleParse([missingSubRow], thirdCycle, at: resetTime * 2 + 11)
        checkWeek(missingSubCycle, 3, "暂缺订阅ID保留已知上下文")
        precondition(missingSubCycle.cycle?.subscriptionID == 1)
        checkWeek(try cycleParse([cycleRow("changed-after-missing", resetTime * 2 + 20, used: 0, subscription: 2)],
                                missingSubCycle, at: resetTime * 2 + 21), 1, "暂缺字段后仍能识别真实换订阅")
        let anotherPackage = try cycleRow("other-package-interleaved", resetTime * 2 + 10, used: 0, subscription: 2)
        let currentPackage = try cycleRow("current-package-latest", resetTime * 2 + 20, used: 700_000)
        checkWeek(try cycleParse([currentPackage, anotherPackage, resetAgain], thirdCycle, at: resetTime * 2 + 21), 3,
                  "其他套餐夹在本轮日志中不能清空当前套餐周数")
        let duplicateOld = try cycleRow("corrected-request", 200, used: 100_000, consumed: 100_000)
        let duplicateCorrected = try cycleRow("corrected-request", 300, used: 200_000, consumed: 100_000)
        let correctedCycle = try cycleParse([duplicateCorrected, duplicateOld, baselineRow], baseline, at: 301)
        checkWeek(correctedCycle, 1, "同请求多份快照只采用最新版本，不回放旧满额元数据")
        precondition(correctedCycle.cycle?.usedQuota == 200_000)
        for other in ["{\"billing_source\":\"wallet\"}", "{broken-metadata"] {
            var newest = try cycleRow("corrected-source", 300, used: 200_000, consumed: 100_000)
            newest["other"] = other
            newest["quota"] = 200_000
            let obsoleteFull = try cycleRow("corrected-source", 200, used: 100_000, consumed: 100_000)
            let correctedSource = try cycleParse([newest, obsoleteFull, baselineRow], baseline, at: 301)
            checkWeek(correctedSource, 1, "先去重消费日志，再筛套餐信息，不能复活已被钱包或坏元数据修正的旧满额记录")
            close(correctedSource.todayUSD, baseline.todayUSD + 0.4)
            precondition(correctedSource.cycle?.lastRequestID == "baseline")
        }
        let unknownIdentity = try cycleRow("unknown-identity", resetTime + 10, used: 0,
                                          subscription: nil, plan: nil, title: nil)
        let retainedIdentity = try cycleParse([unknownIdentity], chargedReset, at: resetTime + 11)
        checkWeek(retainedIdentity, 2, "身份信息不足时保留已有周数，不误判换套餐或满额恢复")
        precondition(retainedIdentity.cycle?.subscriptionID == 1 && retainedIdentity.cycle?.planID == 1)
        precondition(retainedIdentity.cycle?.lastRequestID == "large-first")
        let noTitle = try cycleRow("known-ids-missing-title", resetTime + 20, used: 800_000, title: nil)
        let retainedTitle = try cycleParse([noTitle], retainedIdentity, at: resetTime + 21)
        checkWeek(retainedTitle, 2, "同身份缺标题不丢周数")
        precondition(retainedTitle.cycle?.title == "周期套餐")
        checkWeek(try cycleParse([cycleRow("new-sub-after-unknown", resetTime + 30, used: 0, subscription: 2)],
                                retainedIdentity, at: resetTime + 31), 1, "低身份记录不能擦掉之后识别新订阅所需的旧ID")
        let firstUnknown = try cycleParse([unknownIdentity], at: resetTime + 11)
        precondition(firstUnknown.cycle == nil)
        let longPrefix = String(repeating: "长", count: 40)
        let longTitleCycle = try cycleParse([cycleRow("long-title-a", 100, used: 500_000, subscription: nil, plan: nil,
                                                    title: longPrefix + "甲")], at: 101)
        checkWeek(try cycleParse([cycleRow("long-title-b", 200, used: 0, subscription: nil, plan: nil,
                                          title: longPrefix + "乙")], longTitleCycle, at: 201), 1,
                  "后备身份不因卡片标题截断而碰撞")
        var looping = baseline
        for (index, expected) in [2, 3, 4, 1, 2].enumerated() {
            let time = Double(index + 1) * 604800 + 100
            let row = try cycleRow("loop-\(index)", time, used: 100_000, consumed: 100_000)
            looping = try cycleParse([row], looping, at: time + 1)
            checkWeek(looping, expected, "周数按1→2→3→4→1循环")
            let restored = try JSONDecoder().decode(TopAPISnapshot.self, from: JSONEncoder().encode(looping))
            checkWeek(try cycleParse([row], restored, at: time + 2), expected, "缓存恢复不会重复增加周数")
        }
        checkWeek(try cycleParse([], looping, at: 604800 * 6), 2, "日志暂缺保留已检测周期")
        checkWeek(try cycleParse([b], looping, at: 604800 * 6), 2, "钱包账单不能推进套餐周期")
        let iso = ISO8601DateFormatter()
        let calibrationDate = iso.date(from: "2026-11-12T23:30:00+08:00")!
        var calibratedSnapshot = baseline
        calibratedSnapshot.cycle = try baseline.cycle!.calibrated(week: 1, day: 4, on: calibrationDate)
        let calibratedCycle = calibratedSnapshot.cycle!
        precondition(calibratedCycle.weekStartedAt == iso.date(from: "2026-11-09T00:00:00+08:00"))
        precondition(calibratedCycle.dayNumber(at: calibrationDate) == 4)
        precondition(calibratedCycle.dayNumber(at: iso.date(from: "2026-11-13T00:00:00+08:00")!) == 5)
        precondition(calibratedCycle.dayNumber(at: iso.date(from: "2026-11-16T00:00:00+08:00")!) == 8 && calibratedCycle.week == 1)
        precondition(calibratedCycle.remainingDays(at: calibrationDate) == 25)
        precondition(calibratedCycle.remainingDays(at: iso.date(from: "2026-11-12T23:59:59+08:00")!) == 25)
        precondition(calibratedCycle.remainingDays(at: iso.date(from: "2026-11-13T00:00:00+08:00")!) == 24)
        let expectedEnd = iso.date(from: "2026-12-06T00:00:00+08:00")!
        precondition(calibratedCycle.estimatedEndDate(at: calibrationDate) == expectedEnd)
        precondition(calibratedCycle.estimatedEndDate(at: iso.date(from: "2026-11-13T00:00:00+08:00")!) == expectedEnd)
        precondition(calibratedCycle.estimatedEndDate(at: iso.date(from: "2026-12-07T00:00:00+08:00")!) == expectedEnd)
        precondition(calibratedCycle.estimatedEndDate(at: iso.date(from: "2026-11-08T23:59:59+08:00")!) == nil)
        let secondWeek = try calibratedCycle.calibrated(week: 2, day: 1, on: calibrationDate)
        let lastDay = try calibratedCycle.calibrated(week: 4, day: 7, on: calibrationDate)
        precondition(secondWeek.remainingDays(at: calibrationDate) == 21 && lastDay.remainingDays(at: calibrationDate) == 1)
        precondition(lastDay.estimatedEndDate(at: calibrationDate) == iso.date(from: "2026-11-12T00:00:00+08:00"))
        precondition(lastDay.remainingDays(at: iso.date(from: "2026-11-13T00:00:00+08:00")!) == 0)
        precondition(calibratedCycle.remainingDays(at: iso.date(from: "2026-12-07T00:00:00+08:00")!) == 0 && calibratedCycle.week == 1)
        precondition(calibratedCycle.remainingDays(at: iso.date(from: "2026-11-08T23:59:59+08:00")!) == nil)
        precondition(calibratedCycle.remainingDays(at: Date(timeIntervalSince1970: .infinity)) == nil)
        var invalidRemainingCycle = calibratedCycle; invalidRemainingCycle.week = 5
        precondition(invalidRemainingCycle.remainingDays(at: calibrationDate) == nil)
        let fourthWeekSnapshot: TopAPISnapshot = {
            var snapshot = calibratedSnapshot
            snapshot.cycle = lastDay
            return snapshot
        }()
        let newCycle = try cycleParse([exactFull, baselineRow], fourthWeekSnapshot, at: resetTime + 1)
        checkWeek(newCycle, 1, "第4周满额恢复后新一轮从第1周开始")
        precondition(newCycle.cycle?.remainingDays(at: start.addingTimeInterval(resetTime + 1)) == 28)
        let newCycleStart = newCycle.cycle!.weekStartedAt!
        precondition(newCycle.cycle?.estimatedEndDate(at: start.addingTimeInterval(resetTime + 1)) == newCycleStart.addingTimeInterval(27 * 86400))
        precondition(calibratedCycle.lastRequestID == baseline.cycle?.lastRequestID && calibratedCycle.seenRequestIDs == baseline.cycle?.seenRequestIDs)
        let calibratedRestored = try JSONDecoder().decode(TopAPISnapshot.self, from: JSONEncoder().encode(calibratedSnapshot))
        precondition(calibratedRestored.cycle?.dayNumber(at: calibrationDate) == 4)
        precondition(calibratedRestored.cycle?.remainingDays(at: calibrationDate) == 25)
        let calibrationRefresh = try cycleParse([baselineRow], calibratedRestored, at: 201)
        precondition(calibrationRefresh.cycle?.weekStartedAt == calibratedCycle.weekStartedAt)
        let afterCalibrationReset = try cycleParse([exactFull, baselineRow], calibratedSnapshot, at: resetTime + 1)
        checkWeek(afterCalibrationReset, 2, "校准后检测满额仍正常进入下一周")
        precondition(afterCalibrationReset.cycle?.dayNumber(at: start.addingTimeInterval(resetTime + 1)) == 1)
        let calibrationNewSub = try cycleParse([changedSub], calibratedSnapshot, at: resetTime + 2)
        precondition(calibrationNewSub.cycle?.weekStartedAt == nil)
        let calibrationCap = try cycleParse([capChange], calibratedSnapshot, at: resetTime + 1)
        precondition(calibrationCap.cycle?.weekStartedAt == calibratedCycle.weekStartedAt)
        precondition(legacySnapshot.cycle == nil && baseline.cycle?.weekStartedAt == nil)
        precondition(baseline.cycle?.remainingDays(at: calibrationDate) == nil)
        precondition(baseline.cycle?.estimatedEndDate(at: calibrationDate) == nil)
        var invalidCalibrations = 0
        do { _ = try calibratedCycle.calibrated(week: 0, day: 4, on: calibrationDate); preconditionFailure("必须校验周数") }
        catch TopAPIFailure.invalidCycle { invalidCalibrations += 1 }
        do { _ = try calibratedCycle.calibrated(week: 1, day: 8, on: calibrationDate); preconditionFailure("必须校验天数") }
        catch TopAPIFailure.invalidCycle { invalidCalibrations += 1 }
        precondition(invalidCalibrations == 2)
        var expectedFailures = 0
        do { _ = try parse([a], currency: "CNY"); preconditionFailure("必须拒绝不匹配的货币") }
        catch TopAPIFailure.invalidResponse { expectedFailures += 1 }
        var broken = a; broken.removeValue(forKey: "request_id")
        do { _ = try parse([broken]); preconditionFailure("不能累积无稳定 ID 的账单") }
        catch TopAPIFailure.invalidResponse { expectedFailures += 1 }
        do { _ = try TopAPICredential.validated("not-an-api-key"); preconditionFailure("必须校验密钥") }
        catch TopAPIFailure.invalidKey { expectedFailures += 1 }
        precondition(expectedFailures == 3)
        print("API 监控验证通过：四周循环、28天剩余估算、周/日校准、北京时间跨日、恢复满额归第1天、缓存与身份隔离、充值余额")
    }
}
