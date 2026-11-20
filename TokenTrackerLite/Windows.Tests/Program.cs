using System.Text.Json;
using TokenTrackerLite;

if (args.Contains("--live"))
{
    var liveKey = ApiBilling.ValidateKey(Console.ReadLine() ?? "");
    var result = await ApiClient.Fetch(liveKey, null, CancellationToken.None);
    Console.WriteLine(JsonSerializer.Serialize(new { todayLowerBoundUSD = result.TodayUSD,
        weeklyUsedUSD = result.Plan?.UsedUSD, weeklyRemainingUSD = result.Plan?.RemainingUSD,
        accountBalanceUSD = result.AccountBalanceUSD, accountError = result.AccountError }));
    return;
}
const string key = "sk-test-only-not-a-real-credential";
var start = DateTimeOffset.FromUnixTimeSeconds(1794326400);
object Row(string id, int seconds, int quota, bool subscription = false, long? subscriptionId = null, long? planId = null) => new {
    request_id = id, created_at = start.ToUnixTimeSeconds() + seconds, type = 2, quota,
    other = JsonSerializer.Serialize(new { billing_source = subscription ? "subscription" : "wallet",
        subscription_plan_title = "月用无忧", subscription_id = subscriptionId, subscription_plan_id = planId, subscription_used = 6_375_000,
        subscription_remain = 8_000_000, subscription_total = 14_375_000 }) };
ApiSnapshot Parse(object[] rows, ApiSnapshot? previous = null, DateTimeOffset? at = null, string credential = key, string currency = "USD", int used = 50_000_000,
    decimal? walletQuota = null, string? account = null, string? subscriptions = null, string? balance = null) =>
    ApiBilling.Parse(JsonSerializer.Serialize(new { code = true, data = new { name = "测试监控", total_used = used,
            total_available = 999_999_999, expires_at = start.AddDays(60).ToUnixTimeSeconds(), user_quota = new { total_available = walletQuota } } }),
        JsonSerializer.Serialize(new { success = true, data = rows }),
        JsonSerializer.Serialize(new { success = true, data = new { quota_per_unit = 500000, quota_display_type = currency } }),
        credential, previous, at ?? start.AddHours(10), account, subscriptions, balance);
void Check(bool value, string name) { if (!value) throw new Exception(name); }
var a = Row("a", 100, 500000, true, 41); var b = Row("b", 200, 250000); var c = Row("c", 300, 125000);
var first = Parse([b, a]);
Check(first.TodayUSD == 1.5m && !first.TodayComplete && first.RecordedPlan?.UsedUSD == 12.75m && first.RecordedPlan.RemainingUSD == 16m && first.PlanError == null,
    "套餐金额取最新消费记录，今日消费单独累计");
var rolled = Parse([c, b], first);
Check(rolled.TodayUSD == 1.75m && rolled.TodayRecords.Count == 3, "窗口滚动不能减少或重复计费");
var restored = JsonSerializer.Deserialize<ApiSnapshot>(JsonSerializer.Serialize(rolled));
Check(Parse([c, b], restored).TodayUSD == 1.75m, "缓存恢复去重");
Check(Parse([c, Row("b", 200, 100000)], rolled).TodayUSD == 1.45m, "账单修正");
var complete = Parse([a, Row("old", -1, 100000)]);
Check(complete.TodayComplete && complete.TodayUSD == 1m, "必须过滤昨天记录");
Check(Parse([b, a], complete).TodayComplete && !Parse([c], complete).TodayComplete, "连续轮询及断档判定");
var next = Parse([Row("next", 86410, 75000), b], rolled, start.AddDays(1).AddMinutes(1));
Check(next.TodayUSD == .15m && next.TodayComplete && next.TodayRecords.Count == 1, "北京时间跨日");
Check(next.LastConversationAt == start.AddSeconds(86410) && !ApiRefreshPolicy.NeedsTrigger(next, start.AddDays(1).AddMinutes(1)), "跨午夜的成功消费仍抑制补发");
Check(Parse([c], rolled, credential: key + "-changed").TodayUSD == .25m, "切换密钥必须隔离缓存");
Check(Parse([], used: 0).TodayComplete && Parse([b]).Plan == null, "空账单和钱包账单不得伪造套餐余额");
Check(Parse([a], used: 500000).TodayComplete, "当日新密钥完整账单");
try { Parse([a], currency: "CNY"); throw new Exception("必须拒绝错误计费单位"); }
catch (InvalidDataException) { Check(true, "错误单位已拒绝"); }
Check(first.AccountBalanceUSD == null && first.PlanExpiresAt == null, "令牌额度、令牌到期不得冒充账户与套餐");
Check(Parse([a], walletQuota: 6_250_000m).AccountBalanceUSD == 12.5m, "嵌套账户充值余额按平台单位转换");
Check(Parse([a], walletQuota: 0).AccountBalanceUSD == 0, "真实零余额必须显示零");
var account = JsonSerializer.Serialize(new { success = true, data = new { quota = 12_345_000, username = "账户测试" } });
object Subscription(long id, long end, string status = "active", long planId = 3) => new {
    subscription = new { id, plan_id = planId, status, end_time = end, amount_total = 14_375_000, amount_used = 6_375_000 } };
var end = start.AddDays(30).ToUnixTimeSeconds();
string Subscriptions(params object[] subscriptions) => JsonSerializer.Serialize(new { success = true, data = new { subscriptions, all_subscriptions = subscriptions } });
var single = Parse([a], account: account, subscriptions: Subscriptions(Subscription(41, end)));
Check(single.AccountBalanceUSD == 24.69m && single.AccountName == "账户测试" && single.PlanExpiresAt == DateTimeOffset.FromUnixTimeSeconds(end), "官方账户余额与单一套餐到期");
Check(Parse([Row("no-id", 100, 500000, true)], account: account, subscriptions: Subscriptions(Subscription(41, end), Subscription(42, end + 86400))).PlanExpiresAt == null,
    "多套餐且无实例ID不得猜到期时间");
var exact = Parse([Row("specific", 100, 500000, true, 42)], account: account,
    subscriptions: Subscriptions(Subscription(41, end), Subscription(42, end + 86400)));
Check(exact.PlanExpiresAt == DateTimeOffset.FromUnixTimeSeconds(end + 86400), "按扣费日志的订阅实例ID选择到期时间");
Check(Parse([Row("missing", 100, 500000, true, 99)], account: account, subscriptions: Subscriptions(Subscription(41, end))).PlanExpiresAt == null,
    "日志指定实例缺失时不能冒用其他套餐");
var expired = start.AddDays(-1).ToUnixTimeSeconds();
Check(Parse([Row("expired", 100, 500000, true, 42)], account: account,
    subscriptions: Subscriptions(Subscription(42, expired, "expired"))).PlanExpiresAt == DateTimeOffset.FromUnixTimeSeconds(expired), "允许显示已到期的对应订阅");
Check(Parse([Row("no-id", 100, 500000, true)], account: account, subscriptions: Subscriptions(Subscription(42, expired, "expired"))).PlanExpiresAt == DateTimeOffset.FromUnixTimeSeconds(expired),
    "唯一已过期套餐显示已到期");
Check(Parse([Row("no-id", 100, 500000, true)], account: account, subscriptions: Subscriptions(Subscription(41, expired), Subscription(42, end))).PlanExpiresAt == DateTimeOffset.FromUnixTimeSeconds(end),
    "active状态但时间过期的套餐不能阻挡唯一有效套餐");
Check(Parse([Row("plan", 100, 500000, true, planId: 8)], account: account,
    subscriptions: Subscriptions(Subscription(41, end), Subscription(42, end + 86400, planId: 8))).PlanExpiresAt == DateTimeOffset.FromUnixTimeSeconds(end + 86400),
    "无实例ID时使用唯一定义ID后备匹配");
Check(Parse([a], account: account, subscriptions: "not-json").AccountBalanceUSD == 24.69m, "订阅响应异常不影响充值余额");
Check(Parse([a], account: "{\"success\":false}", subscriptions: Subscriptions(Subscription(41, end))).TodayUSD == first.TodayUSD - .5m,
    "账户接口失败不影响密钥用量");
Check(Parse([a], account: "not-json", walletQuota: 500000).AccountBalanceUSD == 1m, "账户信息不可用仍可采用明确的user_quota字段");
Check(Parse([a], single, credential: key + "-changed").AccountBalanceUSD == null && Parse([a], single).PlanExpiresAt == null,
    "账户字段不能沿用上一密钥或上次会话");
var legacy = JsonSerializer.SerializeToNode(first)!.AsObject();
legacy.Remove("AccountBalanceUSD"); legacy.Remove("PlanExpiresAt"); legacy.Remove("AccountName"); legacy.Remove("AccountError");
legacy.Remove("Cycle");
Check(JsonSerializer.Deserialize<ApiSnapshot>(legacy.ToJsonString()) is { Valid: true, AccountBalanceUSD: null, PlanExpiresAt: null, Cycle: null }, "旧缓存兼容");
string Balance(decimal amount, string currency = "USD") => JsonSerializer.Serialize(new { success = true, data = new {
    balance = amount, currency, used = 987.6543m, token_remaining = 50000000, token_unlimited = true } });
var charged = Parse([b, a], balance: Balance(103.4m));
Check(charged.AccountBalanceUSD == 103.4m && charged.AccountError == null && charged.TodayUSD == first.TodayUSD && charged.RecordedPlan?.RemainingUSD == 16m,
    "充值余额已是USD，不得当令牌额度或套餐剩余再换算");
Check(Parse([a], balance: Balance(0)).AccountBalanceUSD == 0 && Parse([a], balance: Balance(-2.5m)).AccountBalanceUSD == -2.5m,
    "真实零余额和负余额均须保留");
foreach (var brokenBalance in new[] { Balance(100, "CNY"), "{\"success\":true,\"data\":{\"balance\":\"103.4\",\"currency\":\"USD\"}}",
    "{\"success\":true,\"data\":{\"currency\":\"USD\",\"token_remaining\":500000}}", "{\"success\":false}", "not-json" })
{
    var degraded = Parse([b, a], balance: brokenBalance);
    Check(degraded.AccountBalanceUSD == null && degraded.AccountError != null && degraded.TodayUSD == first.TodayUSD && degraded.RecordedPlan?.RemainingUSD == 16m,
        "余额币种、字段或接口失败不能影响原有三卡，也不能挪用其他额度");
}
var stale = Parse([b, a], charged, balance: "{\"success\":false}");
Check(stale.AccountBalanceUSD == 103.4m && stale.AccountError?.Contains("上次查询") == true, "失败时标注并保留同密钥最近充值余额");
Check(Parse([Row("next-balance", 86410, 75000)], charged, start.AddDays(1).AddMinutes(1), balance: "not-json").AccountBalanceUSD == 103.4m,
    "余额缓存跨日有效，今日用量仍按北京时间切日");
Check(Parse([a], charged, credential: key + "-changed", balance: "not-json").AccountBalanceUSD == null,
    "切换密钥不能继承另一密钥的余额缓存");
Check(Parse([a], stale, balance: Balance(99.2m)).AccountBalanceUSD == 99.2m && Parse([a], stale, balance: Balance(99.2m)).AccountError == null,
    "余额恢复后替换旧值并清除错误提示");
object PlanRow(string id, int seconds, decimal used, decimal remain, object? subscription = null, long displayId = 1, int type = 2) => new {
    id = displayId, request_id = id, created_at = start.ToUnixTimeSeconds() + seconds, type, quota = 0,
    other = JsonSerializer.Serialize(new { billing_source = "subscription", subscription_id = subscription ?? "example-subscription",
        subscription_total = 14_375_000, subscription_used = used, subscription_remain = remain }) };
var latest = Parse([a, PlanRow("new", 400, 7_000_000, 6_000_000)], first);
Check(latest.RecordedPlan is { UsedUSD: 14m, RemainingUSD: 12m } && latest.RecordedPlan.RecordedAt == start.AddSeconds(400),
    "最新套餐记录及原始时间，剩余直接采用服务端字段");
var noNewRecord = Parse([PlanRow("new", 400, 7_000_000, 6_000_000)], latest, start.AddHours(11));
Check(noNewRecord.RecordedPlan?.RecordedAt == latest.RecordedPlan?.RecordedAt && noNewRecord.FetchedAt > latest.FetchedAt,
    "查询时间更新，记录时间不变");
var absent = Parse([b], latest, start.AddDays(1));
Check(absent.RecordedPlan?.RemainingUSD == 12m && absent.RecordedPlan.RecordedAt == latest.RecordedPlan?.RecordedAt && absent.PlanError != null,
    "日志窗口缺失套餐字段时跨日保留原始记录时间");
Check(Parse([b], latest, credential: key + "-other").RecordedPlan == null, "不同Key不得继承套餐记录");
Check(Parse([a], latest).RecordedPlan?.RemainingUSD == 12m, "接口倒退不覆盖新记录");
Check(Parse([PlanRow("zero", 500, 1, 0)], latest).RecordedPlan?.RemainingUSD == 0, "零剩余不能按总额减已用重算");
Check(Parse([PlanRow("low", 500, 1, 1, displayId: 2), PlanRow("high", 500, 2, 2, displayId: 3)]).RecordedPlan?.RemainingUSD == 2m / 500000,
    "同秒选更大的日志ID");
foreach (var row in new[] { PlanRow("future", 36301, 0, 1), PlanRow("failed", 600, 0, 1, type: 5),
    PlanRow("missing-id", 600, 0, 1, subscription: ""), PlanRow("bad", 600, -1, 1) })
    Check(Parse([row], latest).RecordedPlan?.RecordedAt == latest.RecordedPlan?.RecordedAt, "无效记录不能覆盖上次有效套餐");
var oldPlan = JsonSerializer.SerializeToNode(latest)!.AsObject(); oldPlan.Remove("PlanSource");
Check(Parse([], JsonSerializer.Deserialize<ApiSnapshot>(oldPlan.ToJsonString())).RecordedPlan?.RemainingUSD == 12m, "兼容旧版日志缓存");
Check(Parse([], latest with { PlanSource = "subscription" }).RecordedPlan == null, "账号查询时间不能冒充消费记录时间");

async Task<ApiSnapshot> FetchMock(bool failBalance, ApiSnapshot? previous = null, int? used = null, int seconds = 0)
{
    var paths = new List<string>();
    var row = JsonSerializer.SerializeToNode(used == null ? a : PlanRow("updated", 0, used.Value, 6_000_000, subscription: 41))!.AsObject();
    row["created_at"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 60 + seconds;
    var responseLogs = JsonSerializer.Serialize(new { success = true, data = new[] { row } });
    var handler = new ApiHandler(request => {
        var path = request.RequestUri!.AbsolutePath; paths.Add(path);
        Check(request.RequestUri.Scheme == "https" && request.RequestUri.Host == "api-top.com", "只请求固定平台");
        Check(path == "/api/status" ? request.Headers.Authorization == null : request.Headers.Authorization?.Parameter == key,
            "所有认证接口共用配置中的同一API Key");
        string body = path switch {
            "/api/usage/token/" => JsonSerializer.Serialize(new { code = true, data = new { name = "测试监控", total_used = 50000000 } }),
            "/api/log/token" => responseLogs,
            "/api/status" => "{\"success\":true,\"data\":{\"quota_per_unit\":500000,\"quota_display_type\":\"USD\"}}",
            "/api/usage/balance" => Balance(103.4m),
            _ => throw new Exception("出现非预期接口") };
        if (path == "/api/usage/balance") Check(request.Headers.UserAgent.ToString() == "cc-switch/1.0", "余额沿用官方CC Switch查询请求头");
        var code = path == "/api/usage/balance" && failBalance ? System.Net.HttpStatusCode.ServiceUnavailable : System.Net.HttpStatusCode.OK;
        Check(request.Headers.CacheControl?.NoCache == true, "每次查询重新请求接口响应");
        return new HttpResponseMessage(code) { Content = new StringContent(body) };
    });
    var result = await ApiClient.Fetch(key, previous, CancellationToken.None, transport: handler);
    Check(paths.Count == 4 && paths.Distinct().Count() == 4 && paths.Contains("/api/log/token"), "同Key四接口重新查询最新消费日志");
    return result;
}
var online = await FetchMock(false); var failed = await FetchMock(true);
Check(online.AccountBalanceUSD == 103.4m && online.TodayUSD == 1m && online.RecordedPlan?.RemainingUSD == 16m, "完整客户端同Key四接口请求");
Check(failed.AccountBalanceUSD == null && failed.AccountError != null && failed.TodayUSD == 1m && failed.RecordedPlan?.RemainingUSD == 16m,
    "充值余额HTTP错误不影响套餐记录更新");
var refreshed = await FetchMock(false, online, used: 7_000_000, seconds: 10);
Check(refreshed.RecordedPlan?.UsedUSD == 14m && refreshed.RecordedPlan.RemainingUSD == 12m && refreshed.RecordedPlan.RecordedAt > online.RecordedPlan!.RecordedAt,
    "再次刷新使用新响应的金额与记录时间");

var refreshNow = DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
async Task<(ApiSnapshot Snapshot, int Posts, int Reads, int Reserved)> RefreshMock(int age, bool allow = true,
    bool failPost = false, bool unchanged = false, bool failReserve = false, int delayedReads = 0,
    ApiSnapshot? previous = null, int? recentAge = null, int recentType = 2)
{
    var posts = 0; var reads = 0; var reserved = 0; var readsBeforePost = 0;
    var freshRequestId = "fresh-" + Guid.NewGuid().ToString("N");
    var handler = new ApiHandler(request => {
        var path = request.RequestUri!.AbsolutePath;
        Check(request.RequestUri.Host == "api-top.com" && request.RequestUri.Scheme == "https", "触发请求只能发往固定平台");
        Check(path == "/api/status" ? request.Headers.Authorization == null : request.Headers.Authorization?.Parameter == key,
            "触发对话和所有查询共用监控Key");
        object payload;
        var code = System.Net.HttpStatusCode.OK;
        if (request.Method == HttpMethod.Post)
        {
            Check(path == "/v1/chat/completions" && reserved == 1, "必须先持久化预留，再发收费请求");
            Check(reads > 0, "必须先检查消费记录，再决定是否触发对话");
            readsBeforePost = reads;
            posts++;
            using var body = JsonDocument.Parse(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
            Check(body.RootElement.GetProperty("model").GetString() == ApiRefreshPolicy.TriggerModel &&
                body.RootElement.GetProperty("max_tokens").GetInt32() == 16 &&
                body.RootElement.GetProperty("messages").GetArrayLength() == 1 && !body.RootElement.GetProperty("stream").GetBoolean(),
                "触发对话只有一个简短请求，最多16个输出Token");
            if (failPost) code = System.Net.HttpStatusCode.ServiceUnavailable;
            payload = new { choices = new[] { new { finish_reason = "stop" } } };
        }
        else if (path == "/api/log/token")
        {
            reads++;
            var updated = posts > 0 && !unchanged && reads - readsBeforePost > delayedReads;
            var logRows = new List<object> { new {
                id = updated ? 2 : 1, request_id = updated ? freshRequestId : "old", type = 2, quota = 100,
                created_at = (updated ? refreshNow : refreshNow.AddSeconds(-age)).ToUnixTimeSeconds(),
                other = JsonSerializer.Serialize(new { billing_source = "subscription", subscription_id = 1,
                    subscription_used = updated ? 1_500_000 : 1_000_000, subscription_remain = updated ? 3_500_000 : 4_000_000,
                    subscription_total = 5_000_000 }) } };
            if (recentAge is { } recent) logRows.Add(new { id = 3, request_id = "recent-wallet",
                created_at = refreshNow.AddSeconds(-recent).ToUnixTimeSeconds(), type = recentType, quota = 0,
                other = "{\"billing_source\":\"wallet\"}" });
            payload = new { success = true, data = logRows };
        }
        else payload = path switch {
            "/api/usage/token/" => new { code = true, data = new { name = "测试", total_used = 500000 } },
            "/api/status" => new { success = true, data = new { quota_per_unit = 500000, quota_display_type = "USD" } },
            "/api/usage/balance" => new { success = true, data = new { balance = 103.4m, currency = "USD" } },
            _ => throw new Exception("出现非预期接口")
        };
        return new HttpResponseMessage(code) { Content = new StringContent(JsonSerializer.Serialize(payload)) };
    });
    var result = await ApiClient.Refresh(key, previous, CancellationToken.None,
        _ => { if (failReserve) throw new IOException("模拟状态写入失败"); reserved++; return allow; },
        transport: handler, at: refreshNow, waitForLog: _ => Task.CompletedTask);
    return (result, posts, reads, reserved);
}
foreach (var age in new[] { 0, 1799, 1800 })
{
    var result = await RefreshMock(age);
    Check(result.Posts == 0 && result.Reserved == 0, "新快照和30分钟边界不发收费对话");
}
var refreshTriggered = await RefreshMock(1801);
Check(refreshTriggered.Posts == 1 && refreshTriggered.Reads == 2 && refreshTriggered.Snapshot.RecordedPlan?.RemainingUSD == 7m &&
    refreshTriggered.Snapshot.LastTriggerAt == refreshNow && refreshTriggered.Snapshot.PlanError == null, "过旧快照触发一次并重查新额度");
foreach (var recent in new[] { 0, 60, 1800 })
{
    var active = await RefreshMock(3600, recentAge: recent);
    Check(active.Posts == 0 && active.Reserved == 0 && active.Snapshot.LastConversationAt == refreshNow.AddSeconds(-recent),
        "30分钟内有成功消费时，即使套餐快照旧也不补发对话");
}
Check((await RefreshMock(3600, recentAge: 1801)).Posts == 1, "成功消费超过30分钟才允许补发");
Check((await RefreshMock(3600, recentAge: 60, recentType: 5)).Posts == 1, "失败日志不算近期成功对话");
Check((await RefreshMock(0, previous: refreshTriggered.Snapshot)).Posts == 0, "连续手动刷新不重复发送对话");
var refreshDenied = await RefreshMock(3600, allow: false);
Check(refreshDenied.Posts == 0 && refreshDenied.Snapshot.PlanError != null, "冷却期禁止重发");
var refreshFailed = await RefreshMock(3600, failPost: true);
Check(refreshFailed.Posts == 1 && refreshFailed.Reads == 1 && refreshFailed.Snapshot.LastTriggerAt == refreshNow &&
    refreshFailed.Snapshot.RecordedPlan?.RemainingUSD == 8m && refreshFailed.Snapshot.PlanError != null, "触发失败不重试，保留旧额度与触发时间");
var refreshDelayed = await RefreshMock(3600, delayedReads: 1);
Check(refreshDelayed.Posts == 1 && refreshDelayed.Reads == 3 && refreshDelayed.Snapshot.RecordedPlan?.RemainingUSD == 7m,
    "入账延迟只重复查询，不重复对话");
var refreshPending = await RefreshMock(3600, unchanged: true);
Check(refreshPending.Posts == 1 && refreshPending.Reads == 4 && refreshPending.Snapshot.PlanError != null, "未入库时有限查询并保留旧快照");
Check((await RefreshMock(3600, failReserve: true)).Posts == 0, "触发状态写入失败时不能收费");
var gateDirectory = Path.Combine(Path.GetTempPath(), "lite-trigger-test-" + Guid.NewGuid().ToString("N"));
try
{
    var gate = new ApiTriggerGate(gateDirectory);
    Check(gate.Reserve(key, refreshNow) && !new ApiTriggerGate(gateDirectory).Reserve(key, refreshNow.AddSeconds(1799)) &&
        gate.Reserve(key, refreshNow.AddSeconds(1800)) && gate.Reserve(key + "-other", refreshNow), "冷却跨重启、30分钟边界和按Key隔离");
    Check(!gate.Reserve(key, refreshNow.AddSeconds(1801)), "手动刷新同样受冷却保护");
    var file = Path.Combine(gateDirectory, "topapi-trigger-attempts.json");
    Check(!File.ReadAllText(file).Contains(key), "触发记录不能保存密钥原文");
    File.WriteAllText(file, "broken");
    try { gate.Reserve(key, refreshNow.AddHours(1)); throw new Exception("损坏状态不能继续收费"); }
    catch (JsonException) { Check(true, "损坏状态停止触发"); }
}
finally { if (Directory.Exists(gateDirectory)) Directory.Delete(gateDirectory, true); }

object CycleRow(string request, int seconds, decimal usedQuota, decimal remainingQuota, decimal totalQuota = 1000,
    decimal? consumed = null, long? subscriptionId = 41, long? planId = 3, long displayId = 1, string? title = "周期测试") => new {
    id = displayId, request_id = request, created_at = start.ToUnixTimeSeconds() + seconds, type = 2,
    quota = consumed ?? Math.Max(usedQuota, 1),
    other = JsonSerializer.Serialize(new { billing_source = "subscription", subscription_id = subscriptionId,
        subscription_plan_id = planId, subscription_plan_title = title, subscription_used = usedQuota,
        subscription_remain = remainingQuota, subscription_total = totalQuota, subscription_consumed = consumed }) };
void Week(ApiSnapshot data, int expected, string description) => Check(data.Cycle is { Valid: true } && data.Cycle.Week == expected, description);
var baseRow = CycleRow("cycle-base", 100, 400, 600);
var cycleBase = Parse([baseRow, CycleRow("historical-reset", 20, 10, 990, consumed: 10)]);
Week(cycleBase, 1, "首次只从最新有效套餐建第1周，不能追算历史重置");
Check(cycleBase.Cycle?.LastRequestId == "cycle-base" && cycleBase.Cycle.LastResetAt == null, "首次基准和原始quota保存");
Check(cycleBase.Cycle?.SeenRequestIds?.Contains("historical-reset") == true, "首次把响应中同套餐历史请求也标为已见");
var seededReplay = Parse([CycleRow("historical-reset", 300, 10, 990, consumed: 10, displayId: 999)], cycleBase);
Week(seededReplay, 1, "初始化已见的历史满额请求改展示id或时间也不能追算一周");
Check(seededReplay.Cycle?.LastRequestId == "cycle-base", "已见历史请求不能覆盖当前基准");
Week(Parse([baseRow], cycleBase), 1, "重复轮询不能升级周数");
var fullRow = CycleRow("direct-full", 200, 0, 1000);
var secondWeek = Parse([fullRow, baseRow], cycleBase);
Week(secondWeek, 2, "真实恢复满额进入第2周");
Check(secondWeek.Cycle?.LastResetAt == start.AddSeconds(200) && secondWeek.Cycle.LastResetEventID == "direct-full", "恢复事件标记持久化");
var chargeAfterFull = Parse([CycleRow("charge-after-full", 250, 20, 980, consumed: 20)], secondWeek);
Week(chargeAfterFull, 2, "直接满额后的首笔消费不能再多加一周");
Check(chargeAfterFull.Cycle?.LastResetAt == start.AddSeconds(200), "同一次恢复后的首笔消费不能改写恢复时间");
Check(chargeAfterFull.Cycle?.LastResetEventID == "direct-full", "普通首笔消费不能覆盖真正恢复事件标记");
var restart = JsonSerializer.Deserialize<ApiSnapshot>(JsonSerializer.Serialize(secondWeek))!;
Week(Parse([CycleRow("direct-full", 200, 0, 1000, displayId: 999), baseRow], restart), 2, "重启后不能因展示id重编号重复升级");
var afterSecond = Parse([CycleRow("second-consume", 250, 300, 700, consumed: 30)], secondWeek);
var replay = Parse([CycleRow("direct-full", 300, 0, 1000, displayId: 888)], afterSecond);
Week(replay, 2, "同一request_id重新出现不能当新恢复事件");
Check(replay.Cycle?.LastRequestId == "second-consume", "重复事件不能覆盖最新基准");
Week(Parse([CycleRow("next-day-full", 86410, 0, 1000)], cycleBase, start.AddDays(1).AddMinutes(1)), 2,
    "周期跨北京时间午夜保留，不跟随今日records清零");
Check(Parse([], secondWeek).Cycle == secondWeek.Cycle, "无套餐日志时保持已持久化周期");
var firstChargeBase = Parse([CycleRow("small-before", 100, 10, 990)]);
Week(Parse([CycleRow("large-first-charge", 200, 700, 300, consumed: 700)], firstChargeBase), 2,
    "新周首笔消费后used高于旧used仍可还原消费前满额");
var firstObservedFull = Parse([CycleRow("first-full-charge", 100, 20, 980, consumed: 20)]);
Week(firstObservedFull, 1, "首次观测首笔满额消费仍从第1周起算");
Check(firstObservedFull.Cycle?.LastResetEventID == "first-full-charge" && firstObservedFull.Cycle.LastResetAt == null,
    "初始满额候选只记事件标记，不伪造检测到的周切换时间");
Week(Parse([CycleRow("first-full-charge", 200, 20, 980, consumed: 20, displayId: 7)],
    Parse([CycleRow("first-later-use", 150, 200, 800)], firstObservedFull)), 1, "首次满额候选重播也不能升级");
var batch = Parse([CycleRow("batch-use", 300, 500, 500, consumed: 50),
    CycleRow("batch-reset-two", 400, 30, 970, consumed: 30), CycleRow("batch-reset-one", 200, 20, 980, consumed: 20)], cycleBase);
Week(batch, 3, "一轮返回多笔新日志时按时间顺序处理，不能漏掉中途恢复满额");
Check(batch.Cycle?.LastRequestId == "batch-reset-two", "乱序响应按时间水位保存最新事件");
var correctedCycle = Parse([CycleRow("corrected-cycle", 300, 200, 800), CycleRow("corrected-cycle", 200, 0, 1000)], cycleBase);
Week(correctedCycle, 1, "一响应同请求的最新修正版非满额时不能先按旧版满额升级");
Check(correctedCycle.Cycle?.UsedQuota == 200 && correctedCycle.Cycle.LastRecordedAt == start.AddSeconds(300), "周期只采用该请求最新快照");
Week(Parse([CycleRow("refund-partial", 200, 100, 900)], cycleBase), 1, "余额只部分回升不是恢复满额");
Week(Parse([CycleRow("missing-consumed", 200, 10, 990)], cycleBase), 1, "缺subscription_consumed不能借log.quota还原满额");
Week(Parse([CycleRow("other-settlement", 200, 250, 750, consumed: 150)], cycleBase), 1, "并发结算只下降用量不能当新周");
Week(Parse([CycleRow("raw-one-unit", 200, 1, 999)], cycleBase), 1, "原始quota差1仍不是满额，不比较四舍五入的美元");
Week(Parse([CycleRow("raw-tolerance", 200, .5m, 999.5m)], cycleBase), 2, "满额比较使用最多0.5原始quota容差");
var thirdWeek = cycleBase with { Cycle = cycleBase.Cycle! with { Week = 3 } };
var capChanged = Parse([CycleRow("cap-change", 200, 0, 2000, totalQuota: 2000)], thirdWeek);
Week(capChanged, 3, "同订阅额度上限变化只重建基准，不能升级周数");
Check(capChanged.Cycle?.TotalQuota == 2000 && capChanged.Cycle.LastResetAt == null, "额度变化保留周数并更新raw上限");
Week(Parse([CycleRow("new-cap-full", 400, 0, 2000, totalQuota: 2000)],
    Parse([CycleRow("new-cap-use", 300, 100, 1900, totalQuota: 2000)], capChanged)), 4, "上限变化后后续真实恢复仍能继续计周");
Week(Parse([CycleRow("old-full", 50, 0, 1000)], thirdWeek), 3, "倒退时间的旧日志不能升级或覆盖基准");
Week(Parse([CycleRow("new-reused-display-id", 200, 0, 1000, displayId: 1)], cycleBase), 2,
    "展示id重复不代表旧事件，稳定request_id和新时间才是依据");
Week(Parse([CycleRow("same-second-new", 100, 0, 1000), baseRow], cycleBase), 2, "同秒旧锚点仍在响应时接受锚点之前的新请求");
var sameSecondMissing = Parse([CycleRow("same-second-no-anchor", 100, 0, 1000)], cycleBase);
Week(sameSecondMissing, 1, "同秒且旧锚点缺失时保守不升级");
Check(sameSecondMissing.Cycle?.LastRequestId == "cycle-base", "同秒无锚点不能覆盖基准");
Week(Parse([CycleRow("same-second-no-anchor", 101, 0, 1000)], sameSecondMissing), 2, "后续明确更新的时间仍可推进");
Week(Parse([baseRow, CycleRow("same-second-older", 100, 0, 1000)], cycleBase), 1, "同秒排在锚点之后的旧事件不能推进");
var sameSecondBatch = Parse([CycleRow("same-second-after", 100, 200, 800, consumed: 25),
    CycleRow("same-second-reset", 100, 10, 990, consumed: 10), baseRow], cycleBase);
Week(sameSecondBatch, 2, "同秒多条新事件按响应相对顺序处理");
Check(sameSecondBatch.Cycle?.LastRequestId == "same-second-after" && sameSecondBatch.Cycle.UsedQuota == 200,
    "同秒后续消费也要保存最新基准");
Week(Parse([CycleRow("switch-key", 200, 0, 1000)], thirdWeek, credential: key + "-changed"), 1, "更换密钥从第1周起算");
Check(Parse([], thirdWeek, credential: key + "-changed").Cycle == null, "换密钥无套餐时清除旧周期");
Week(Parse([CycleRow("switch-sub", 200, 0, 1000, subscriptionId: 42)], thirdWeek), 1, "更换订阅实例从第1周起算");
Week(Parse([CycleRow("switch-plan", 200, 0, 1000, planId: 4)], thirdWeek), 1, "更换套餐定义从第1周起算");
var missingPlan = Parse([CycleRow("missing-plan", 200, 500, 500, planId: null)], thirdWeek);
Check(missingPlan.Cycle?.PlanID == 3, "暂缺身份字段时保留已知套餐定义");
Week(Parse([CycleRow("changed-after-missing", 300, 0, 1000, planId: 4)], missingPlan), 1, "身份字段暂缺不能掩盖后续换套餐");
var missingSub = Parse([CycleRow("missing-sub", 200, 500, 500, subscriptionId: null)], thirdWeek);
Week(missingSub, 3, "暂缺订阅实例但同套餐定义时不能丢失已有周数");
Check(missingSub.Cycle?.SubscriptionID == 41, "暂缺订阅实例时保留已知实例ID");
Week(Parse([CycleRow("changed-sub-after-missing", 300, 0, 1000, subscriptionId: 42)], missingSub), 1,
    "实例字段暂缺后遇到真正新实例才重建第1周");
var missingBoth = Parse([CycleRow("missing-both", 200, 500, 500, subscriptionId: null, planId: null)], thirdWeek);
Week(missingBoth, 3, "身份字段暂缺但完整标题一致时保守保留原周期");
Check(missingBoth.Cycle?.SubscriptionID == 41 && missingBoth.Cycle.PlanID == 3, "标题后备不能抹去已知实例和定义");
var missingIdentity = Parse([CycleRow("missing-identity-full", 300, 0, 1000, subscriptionId: null, planId: null, title: null)], secondWeek);
Week(missingIdentity, 2, "实例、定义、标题同时缺失的记录不能重置或增加当前周数");
Check(missingIdentity.Cycle?.SubscriptionID == 41 && missingIdentity.Cycle.PlanID == 3 && missingIdentity.Cycle.Title == "周期测试" &&
    missingIdentity.Cycle.LastRequestId == secondWeek.Cycle?.LastRequestId, "无身份记录保留已知身份和最后基准");
Week(Parse([CycleRow("real-new-sub-after-unknown", 400, 0, 1000, subscriptionId: 42)], missingIdentity), 1,
    "无身份记录之后真正更换实例仍重建第1周");
var missingTitle = Parse([CycleRow("known-ids-no-title", 300, 400, 600, title: null)], secondWeek);
Week(missingTitle, 2, "已知ID的消费日志缺标题仍保留周数");
Check(missingTitle.Cycle?.Title == "周期测试", "标题缺失不能用默认显示名覆盖已知身份标题");
var knownIdReset = Parse([CycleRow("known-ids-full-no-title", 400, 0, 1000, title: null)], missingTitle);
Week(knownIdReset, 3, "ID可确认的满额恢复不依赖显示标题");
Check(knownIdReset.Cycle?.Title == "周期测试", "ID可确认的恢复同样保留已知标题");
Check(Parse([CycleRow("first-no-identity", 100, 400, 600, subscriptionId: null, planId: null, title: null)]).Cycle == null,
    "首次完全无套餐身份时不能以默认显示名建立假周期");
var prefix = new string('长', 40);
var longTitle = Parse([CycleRow("title-first", 100, 400, 600, subscriptionId: null, planId: null, title: prefix + "甲")]);
Week(Parse([CycleRow("title-second", 200, 0, 1000, subscriptionId: null, planId: null, title: prefix + "乙")],
    longTitle with { Cycle = longTitle.Cycle! with { Week = 3 } }), 1, "标题后备身份不因UI截断碰撞");
Week(Parse([fullRow], thirdWeek with { Cycle = thirdWeek.Cycle! with { Week = 4 } }), 1, "第4周恢复满额后进入下一轮第1周");
var cycleless = thirdWeek with { Cycle = null };
Week(Parse([CycleRow("legacy-latest", 400, 20, 980, consumed: 20), fullRow, baseRow], cycleless), 1,
    "老缓存无Cycle时只建立最新基准，不按旧日志追算多周");
var many = Enumerable.Range(0, 1100).Reverse().Select(i => CycleRow("bounded-" + i, 200 + i, 200 + i % 500, 800 - i % 500)).ToArray();
var bounded = Parse(many, cycleBase);
Check(bounded.Cycle?.SeenRequestIds?.Count == 1024 && bounded.Cycle.LastRequestId == "bounded-1099", "持久去重集合有界且保留最新事件");
var rolledReset = Parse(many, chargeAfterFull);
Check(rolledReset.Cycle?.SeenRequestIds?.Contains("direct-full") == false && rolledReset.Cycle?.LastResetEventID == "direct-full",
    "恢复事件滚出去重窗口后仍保留专用恢复标记");
var oldResetReplay = Parse([CycleRow("direct-full", 1500, 0, 1000, displayId: 9999)], rolledReset);
Week(oldResetReplay, 2, "去重窗口滚动后重播真正恢复事件也不能重复升级");
Check(oldResetReplay.Cycle?.LastRequestId == "bounded-1099", "恢复事件重播不能改写当前基准");
var mixedSameLatest = Parse([CycleRow("active-latest", 500, 600, 400),
    CycleRow("other-package", 400, 30, 970, consumed: 30, subscriptionId: 42), CycleRow("active-intermediate", 300, 500, 500)], thirdWeek);
Week(mixedSameLatest, 3, "同Key多套餐混合日志只处理最新所属套餐，不被中途其他套餐重置");
Check(mixedSameLatest.Cycle?.SubscriptionID == 41 && mixedSameLatest.Cycle.LastRequestId == "active-latest", "混合套餐保存最新套餐基准");
Week(Parse([CycleRow("active-reset", 500, 20, 980, consumed: 20),
    CycleRow("other-full", 400, 30, 970, consumed: 30, subscriptionId: 42), CycleRow("active-before-reset", 300, 500, 500)], thirdWeek), 4,
    "多套餐混合时本套餐真正恢复仍按原周数升级");
var changedLatest = Parse([CycleRow("new-sub-latest", 500, 20, 980, consumed: 20, subscriptionId: 42),
    CycleRow("new-sub-use", 300, 500, 500, subscriptionId: 42), CycleRow("new-sub-historical-full", 200, 10, 990, consumed: 10, subscriptionId: 42)], thirdWeek);
Week(changedLatest, 1, "最新套餐改变时只以最新快照建第1周，不能追算新套餐历史恢复");
Check(changedLatest.Cycle?.LastRequestId == "new-sub-latest" && changedLatest.Cycle.SeenRequestIds?.Contains("new-sub-historical-full") == true,
    "新套餐初始化也记录本轮同套餐历史请求");
Week(Parse([CycleRow("old-other-package", 50, 0, 1000, subscriptionId: 42)], thirdWeek), 3, "旧时间的其他套餐不能覆盖当前新周期");

var calibrationNow = start.AddHours(10);
var calibrationBase = thirdWeek with { AccountBalanceUSD = 103.4m };
var calibrated = ApiBilling.CalibrateCycle(calibrationBase, 1, 4, calibrationNow);
var weekStart = ApiBilling.DayStart(calibrationNow).AddDays(-3);
Week(calibrated, 1, "用户声明当前第1周第4天时仅校准当前周期");
Check(calibrated.Cycle?.WeekStartedAt == weekStart && ApiBilling.DayNumber(calibrated.Cycle, calibrationNow) == 4,
    "第4天校准锚到北京时间前三天零点");
Check(calibrated.Cycle == (calibrationBase.Cycle! with { Week = 1, WeekStartedAt = weekStart }) &&
    (calibrated with { Cycle = calibrationBase.Cycle }) == calibrationBase && calibrated.AccountBalanceUSD == 103.4m,
    "校准不改实例、定义、原始quota、水位、去重、恢复标记或充值余额");
var calibratedRestart = JsonSerializer.Deserialize<ApiSnapshot>(JsonSerializer.Serialize(calibrated))!;
Check(calibratedRestart.Valid && calibratedRestart.Cycle?.WeekStartedAt == weekStart && ApiBilling.DayNumber(calibratedRestart.Cycle, calibrationNow) == 4,
    "重启缓存保留校准日期与第4天显示");
var regularAfterCalibration = Parse([CycleRow("calibrated-regular-use", 200, 500, 500)], calibrated);
Check(regularAfterCalibration.Cycle?.WeekStartedAt == weekStart && ApiBilling.DayNumber(regularAfterCalibration.Cycle, calibrationNow) == 4,
    "普通刷新保留校准日期");
var capAfterCalibration = Parse([CycleRow("calibrated-cap", 300, 0, 2000, totalQuota: 2000)], regularAfterCalibration);
Week(capAfterCalibration, 1, "额度上限变化不会改动校准周数");
Check(capAfterCalibration.Cycle?.WeekStartedAt == weekStart, "额度上限变化保留本周起算日期");
var midnightBefore = new DateTimeOffset(2026, 11, 12, 15, 59, 59, TimeSpan.Zero);
var crossMidnight = ApiBilling.CalibrateCycle(calibrationBase, 1, 4, midnightBefore);
Check(ApiBilling.DayNumber(crossMidnight.Cycle, midnightBefore) == 4 &&
    ApiBilling.DayNumber(crossMidnight.Cycle, midnightBefore.AddSeconds(1)) == 5,
    "本周天数按北京时间零点跨日，不依赖系统时区或满24小时");
var nextWeekReset = Parse([CycleRow("calibrated-next-full", 86410, 0, 1000)], calibrated, start.AddDays(1).AddMinutes(1));
Week(nextWeekReset, 2, "下次确认满额恢复才从第1周进入第2周");
Check(nextWeekReset.Cycle?.WeekStartedAt == start.AddDays(1) && ApiBilling.DayNumber(nextWeekReset.Cycle, start.AddDays(1).AddMinutes(1)) == 1,
    "新周恢复锚到来源记录的北京时间零点并显示第1天");
var noResetAfterSevenDays = Parse([CycleRow("calendar-only-use", 7 * 86400 + 100, 600, 400)], calibrated, start.AddDays(7).AddHours(10));
Week(noResetAfterSevenDays, 1, "经过7天也不能按日历擅自增加套餐周数");
Check(ApiBilling.DayNumber(noResetAfterSevenDays.Cycle, start.AddDays(7).AddHours(10)) == 11,
    "超过第7天保留真实日期差，由界面显示等待满额恢复");
var switchedAfterCalibration = Parse([CycleRow("calibrated-new-sub", 400, 0, 1000, subscriptionId: 42)], calibrated);
Week(switchedAfterCalibration, 1, "校准后更换订阅仍重新起算第1周");
Check(switchedAfterCalibration.Cycle?.WeekStartedAt == null && ApiBilling.DayNumber(switchedAfterCalibration.Cycle, calibrationNow) == null,
    "新订阅不能继承旧订阅的校准日期");
Check(Parse([CycleRow("calibrated-new-key", 400, 0, 1000)], calibrated, credential: key + "-changed").Cycle?.WeekStartedAt == null,
    "新密钥不能继承旧密钥的校准日期");
var oldCycleCache = JsonSerializer.SerializeToNode(secondWeek)!.AsObject();
oldCycleCache["Cycle"]!.AsObject().Remove("WeekStartedAt");
var restoredOldCycle = JsonSerializer.Deserialize<ApiSnapshot>(oldCycleCache.ToJsonString())!;
Check(restoredOldCycle.Valid && restoredOldCycle.Cycle?.Week == 2 && ApiBilling.DayNumber(restoredOldCycle.Cycle, calibrationNow) == null &&
    ApiBilling.DayNumber(null, calibrationNow) == null, "旧缓存无起算日期时兼容原周期且不虚构本周天数");
try { ApiBilling.CalibrateCycle(cycleless, 1, 4, calibrationNow); throw new Exception("无已知套餐周期不能校准"); }
catch (InvalidDataException error) { Check(error.Message.Contains("尚无可校准"), "未知周期须给出明确错误"); }
foreach (var (week, day) in new[] { (0, 4), (5, 4), (1, 0), (1, 8) })
{
    try { ApiBilling.CalibrateCycle(calibrationBase, week, day, calibrationNow); throw new Exception("必须拒绝越界周数或天数"); }
    catch (ArgumentOutOfRangeException) { Check(true, "非法周数或天数已拒绝"); }
}
Check(ApiBilling.RemainingCycleDays(calibrated.Cycle, calibrationNow) == 25, "第1周第4天按含今天口径剩余25天");
Check(ApiBilling.RemainingCycleDays(crossMidnight.Cycle, midnightBefore) == 25 &&
    ApiBilling.RemainingCycleDays(crossMidnight.Cycle, midnightBefore.AddSeconds(1)) == 24,
    "28天估算在北京时间跨零点从25变24");
Check(ApiBilling.RemainingCycleDays(ApiBilling.CalibrateCycle(calibrationBase, 2, 1, calibrationNow).Cycle, calibrationNow) == 21,
    "第2周第1天含今天剩余21天");
Check(ApiBilling.RemainingCycleDays(ApiBilling.CalibrateCycle(calibrationBase, 4, 7, calibrationNow).Cycle, calibrationNow) == 1,
    "第4周第7天含今天仍剩余1天");
Check(ApiBilling.RemainingCycleDays(calibrated.Cycle, calibrationNow.AddDays(25)) == 0,
    "周期第29天剩余归零，不产生负天数");
var fourthWeekStart = ApiBilling.CalibrateCycle(calibrationBase, 4, 7, calibrationNow);
var restartedCycle = Parse([CycleRow("remaining-days-next-cycle", 86410, 0, 1000)], fourthWeekStart, start.AddDays(1).AddMinutes(1));
Week(restartedCycle, 1, "第4周满额恢复后重新进入第1周");
Check(ApiBilling.RemainingCycleDays(restartedCycle.Cycle, start.AddDays(1).AddMinutes(1)) == 28,
    "新一轮第1周第1天含今天恢复28天");
Check(ApiBilling.RemainingCycleDays(null, calibrationNow) == null && ApiBilling.RemainingCycleDays(restoredOldCycle.Cycle, calibrationNow) == null,
    "未知周期或无校准起算日期不得虚构28天");
Check(ApiBilling.RemainingCycleDays(calibrated.Cycle! with { WeekStartedAt = ApiBilling.DayStart(calibrationNow).AddDays(1) }, calibrationNow) == null &&
    ApiBilling.RemainingCycleDays(calibrated.Cycle! with { Week = 5 }, calibrationNow) == null,
    "未来起算日期或非法周数不得生成剩余天数");
Check(ApiBilling.RemainingCycleDays(calibrated.Cycle, new DateTimeOffset(9999, 12, 31, 0, 0, 0, TimeSpan.FromHours(8))) == 0 && calibrated.Cycle?.Week == 1,
    "极端日期用long计算且不按日历篡改当前周数");
Check(ApiBilling.RemainingCycleDays(calibrated.Cycle, DateTimeOffset.MaxValue) == null &&
    ApiBilling.RemainingCycleDays(calibrated.Cycle, DateTimeOffset.MinValue) == null,
    "无法表示的北京时间日期须返回未知而不是抛错或造数");
var decemberSixth = new DateTimeOffset(2026, 12, 6, 0, 0, 0, TimeSpan.FromHours(8));
Check(ApiBilling.CycleEstimatedEndDate(crossMidnight.Cycle, midnightBefore) == decemberSixth,
    "第1周从11月9日起算的28天周期最后一天为12月6日");
Check(ApiBilling.CycleEstimatedEndDate(crossMidnight.Cycle, midnightBefore.AddSeconds(1)) == decemberSixth,
    "跨北京时间零点剩余天数下降，预计到期日期保持不变");
var finalCycleDay = ApiBilling.CalibrateCycle(calibrationBase, 4, 7, midnightBefore);
Check(ApiBilling.CycleEstimatedEndDate(finalCycleDay.Cycle, midnightBefore) == ApiBilling.DayStart(midnightBefore),
    "第4周第7天的预计到期日期就是当天");
var expiredAt = decemberSixth.AddDays(5).AddHours(10);
Check(ApiBilling.RemainingCycleDays(crossMidnight.Cycle, expiredAt) == 0 &&
    ApiBilling.CycleEstimatedEndDate(crossMidnight.Cycle, expiredAt) == decemberSixth,
    "周期过期归零后预计到期仍固定12月6日，不能每天漂移");
var nextEstimatedStart = midnightBefore.AddSeconds(1);
var nextEstimatedReset = Parse([CycleRow("estimated-next-cycle", (int)(nextEstimatedStart.ToUnixTimeSeconds() - start.ToUnixTimeSeconds()), 0, 1000)],
    finalCycleDay, nextEstimatedStart.AddMinutes(1));
Week(nextEstimatedReset, 1, "第4周满额后新周期重新进入第1周");
Check(ApiBilling.CycleEstimatedEndDate(nextEstimatedReset.Cycle, nextEstimatedStart.AddMinutes(1)) ==
    new DateTimeOffset(2026, 12, 10, 0, 0, 0, TimeSpan.FromHours(8)), "11月13日新周期的固定预计到期日变为12月10日");
Check(ApiBilling.CycleEstimatedEndDate(null, calibrationNow) == null &&
    ApiBilling.CycleEstimatedEndDate(restoredOldCycle.Cycle, calibrationNow) == null &&
    ApiBilling.CycleEstimatedEndDate(calibrated.Cycle! with { Week = 5 }, calibrationNow) == null &&
    ApiBilling.CycleEstimatedEndDate(calibrated.Cycle! with { WeekStartedAt = ApiBilling.DayStart(calibrationNow).AddDays(1) }, calibrationNow) == null,
    "无周期、无校准、非法周或未来起算日期都不能编造预计到期日");
var overflowingEndStart = new DateTimeOffset(9999, 12, 20, 0, 0, 0, TimeSpan.FromHours(8));
Check(ApiBilling.CycleEstimatedEndDate(calibrated.Cycle! with { WeekStartedAt = overflowingEndStart }, overflowingEndStart) == null &&
    ApiBilling.CycleEstimatedEndDate(calibrated.Cycle! with { WeekStartedAt = DateTimeOffset.MaxValue }, DateTimeOffset.MaxValue) == null,
    "极端起算日期的时区转换和AddDays溢出均返回未知");
var resourcesPath = Path.Combine(Path.GetTempPath(), "Lite 运行时 中文");
var fixtureQueue = Path.Combine(Path.GetTempPath(), "Lite 参数验证", "queue.jsonl");
var fixtureDatabase = Path.Combine(Path.GetTempPath(), "Lite 参数验证", "usage.sqlite");
var collectorState = Path.Combine(Path.GetTempPath(), "Lite 参数验证", "local-collector");
var passiveStart = LocalStatisticsWorker.CreateStartInfo(resourcesPath, fixtureQueue, fixtureDatabase);
Check(passiveStart.FileName == Path.Combine(resourcesPath, "node.exe") && passiveStart.ArgumentList.SequenceEqual(new[] {
    "--no-warnings", Path.Combine(resourcesPath, "TokenTrackerLite", "queue-store.cjs"), "--queue", fixtureQueue, "--database", fixtureDatabase }),
    "布局与普通worker验证默认不启用采集，中文和空格路径保持完整独立参数");
var collectingStart = LocalStatisticsWorker.CreateStartInfo(resourcesPath, fixtureQueue, fixtureDatabase, collectorState);
Check(collectingStart.ArgumentList.SequenceEqual(passiveStart.ArgumentList.Concat(new[] { "--collect-state-dir", collectorState })),
    "生产worker通过显式独立采集目录启用本地增量采集");
Check(!collectingStart.UseShellExecute && collectingStart.CreateNoWindow && collectingStart.RedirectStandardOutput &&
    collectingStart.RedirectStandardError && collectingStart.StandardOutputEncoding?.CodePage == 65001 && collectingStart.StandardErrorEncoding?.CodePage == 65001,
    "采集worker保持后台执行和UTF-8通信");
Check(!LocalStatisticsWorker.ShouldRefresh("same", "same", calibrationNow.AddSeconds(30), calibrationNow) &&
    !LocalStatisticsWorker.ShouldRefresh("same", "same", calibrationNow.AddSeconds(59), calibrationNow) &&
    LocalStatisticsWorker.ShouldRefresh("same", "same", calibrationNow.AddSeconds(60), calibrationNow),
    "共享队列不变也必须到60秒触发本地采集，30秒timer不能永远跳过");
Check(LocalStatisticsWorker.ShouldRefresh("changed", "same", calibrationNow.AddSeconds(1), calibrationNow) &&
    LocalStatisticsWorker.ShouldRefresh("same", "same", calibrationNow.AddSeconds(1), calibrationNow, force: true),
    "共享队列变化和用户强制刷新均可立即采集");
Console.WriteLine("Windows API 监控验证通过：同Key充值余额、四周循环、原始quota满额恢复、去重/重启/跨日、同秒锚点、切换隔离和旧缓存兼容");

sealed class ApiHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => Task.FromResult(respond(request));
}
