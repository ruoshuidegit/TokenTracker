using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TokenTrackerLite;

public sealed record DailyRecord(string Id, DateTimeOffset RecordedAt, decimal CostUSD);
public sealed record PlanSnapshot(string Title, decimal UsedUSD, decimal RemainingUSD, decimal TotalUSD, DateTimeOffset RecordedAt, string? RequestID = null);
public sealed record CycleState(int Week, long? SubscriptionID, long? PlanID, string Title,
    decimal TotalQuota, decimal UsedQuota, decimal RemainingQuota, DateTimeOffset LastRecordedAt, string LastRequestId,
    DateTimeOffset? LastResetAt = null, string? LastResetEventID = null, List<string>? SeenRequestIds = null,
    DateTimeOffset? WeekStartedAt = null)
{
    public bool Valid => Week is >= 1 and <= 4 && TotalQuota > 0 && UsedQuota >= 0 && RemainingQuota >= 0 &&
        LastRecordedAt > DateTimeOffset.UnixEpoch && LastRequestId != null &&
        (WeekStartedAt == null || WeekStartedAt > DateTimeOffset.UnixEpoch) &&
        (SeenRequestIds == null || SeenRequestIds.All(id => !string.IsNullOrEmpty(id) && id.Length <= 256));
}
public sealed record ApiSnapshot(int SchemaVersion, string KeyFingerprint, string KeyName, DateTimeOffset DayStart,
    decimal TodayUSD, bool TodayComplete, List<DailyRecord> TodayRecords, decimal CumulativeUSD,
    DateTimeOffset FetchedAt, PlanSnapshot? Plan, decimal? AccountBalanceUSD = null,
    DateTimeOffset? PlanExpiresAt = null, string? AccountName = null, string? AccountError = null, CycleState? Cycle = null,
    string? PlanSource = null, string? PlanError = null, DateTimeOffset? LastTriggerAt = null, DateTimeOffset? LastConversationAt = null)
{
    public PlanSnapshot? RecordedPlan => PlanSource is null or "consumption_log" ? Plan : null;
    public bool Valid => SchemaVersion == 1 && TodayUSD >= 0 && CumulativeUSD >= 0 && TodayRecords != null &&
        TodayRecords.Select(x => x.Id).Distinct().Count() == TodayRecords.Count &&
        TodayRecords.All(x => !string.IsNullOrEmpty(x.Id) && x.CostUSD >= 0 && x.RecordedAt >= DayStart && x.RecordedAt < DayStart.AddDays(1)) &&
        (Plan == null || (Plan.TotalUSD > 0 && Plan.UsedUSD >= 0 && Plan.RecordedAt > DateTimeOffset.UnixEpoch)) && (Cycle?.Valid ?? true);
}

public static class ApiBilling
{
    public static string ValidateKey(string key)
    {
        key = key.Trim();
        if (key.Length is < 20 or > 256 || !key.StartsWith("sk-", StringComparison.Ordinal) ||
            key.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '-' or '_')))
            throw new InvalidDataException("密钥格式无效，请重新设置。");
        return key;
    }
    public static string Fingerprint(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant();
    public static DateTimeOffset DayStart(DateTimeOffset now) => new(now.ToOffset(TimeSpan.FromHours(8)).Date, TimeSpan.FromHours(8));
    public static string Money(decimal value) => "$" + value.ToString("F4", CultureInfo.InvariantCulture);
    public static string Time(DateTimeOffset value) => value.ToOffset(TimeSpan.FromHours(8)).ToString("MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    public static int? DayNumber(CycleState? cycle, DateTimeOffset? now = null) => cycle?.WeekStartedAt is { } start
        ? (DayStart(now ?? DateTimeOffset.UtcNow) - DayStart(start)).Days + 1 : null;
    public static int? RemainingCycleDays(CycleState? cycle, DateTimeOffset? now = null)
    {
        if (cycle is not { Valid: true }) return null;
        int? dayNumber;
        try { dayNumber = DayNumber(cycle, now); }
        catch (ArgumentOutOfRangeException) { return null; } // 无法表示的北京时间日期不能用于估算。
        if (dayNumber is not { } day || day < 1) return null;
        var elapsed = (cycle.Week - 1L) * 7 + day - 1L;
        return (int)Math.Max(0L, 28L - elapsed);
    }
    public static DateTimeOffset? CycleEstimatedEndDate(CycleState? cycle, DateTimeOffset? now = null)
    {
        if (cycle is not { Valid: true } || cycle.WeekStartedAt is not { } start || RemainingCycleDays(cycle, now) == null) return null;
        try { return DayStart(start).AddDays(27L - (cycle.Week - 1L) * 7); }
        catch (ArgumentOutOfRangeException) { return null; } // 周期结束日期超出可表示范围时保持未知。
    }
    public static ApiSnapshot CalibrateCycle(ApiSnapshot snapshot, int week, int day, DateTimeOffset now)
    {
        if (week is < 1 or > 4) throw new ArgumentOutOfRangeException(nameof(week), "套餐周数必须为1至4。");
        if (day is < 1 or > 7) throw new ArgumentOutOfRangeException(nameof(day), "本周天数必须为1至7。");
        if (snapshot?.Cycle is not { Valid: true } cycle) throw new InvalidDataException("尚无可校准的套餐周期，请先刷新API套餐账单。");
        if (!snapshot.Valid) throw new InvalidDataException("当前统计快照无效，无法校准套餐周期。");
        return snapshot with { Cycle = cycle with { Week = week, WeekStartedAt = DayStart(now).AddDays(1 - day) } };
    }
    private static JsonElement Envelope(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > 12 * 1024 * 1024) throw new InvalidDataException("平台账单格式异常。");
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        bool True(string field) => root.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.True;
        if (!True("success") && !True("code")) throw new InvalidDataException("平台未授权或查询失败，请检查 API Key。");
        return root.GetProperty("data").Clone();
    }
    private static decimal Number(JsonElement row, string key) => row.GetProperty(key).GetDecimal();
    private static JsonElement? Metadata(JsonElement row)
    {
        if (!row.TryGetProperty("other", out var field) || field.ValueKind != JsonValueKind.String) return null;
        try { using var document = JsonDocument.Parse(field.GetString()!); return document.RootElement.Clone(); }
        catch (JsonException) { return null; } // 元数据可缺省，金额解析仍须完整成功。
    }
    private static JsonElement? OptionalEnvelope(string? text)
    {
        if (text == null) return null;
        try { return Envelope(text); }
        catch (Exception ex) when (ex is JsonException or InvalidDataException or KeyNotFoundException or InvalidOperationException)
        { return null; } // 扩展账户字段缺失或格式异常不能影响原有密钥账单。
    }
    private static decimal? OptionalNumber(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object &&
        value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.Number && field.TryGetDecimal(out var number) ? number : null;
    private static long? OptionalId(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object &&
        value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.Number && field.TryGetInt64(out var number) && number > 0 ? number : null;
    private static string? OptionalString(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object &&
        value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    private sealed record CycleSource(long? SubscriptionID, long? PlanID, string? Title, decimal Total, decimal Used, decimal Remaining,
        decimal? Consumed, DateTimeOffset RecordedAt, string RequestId, int ResponseIndex)
    {
        private const decimal Tolerance = 0.5m;
        public bool Full => Math.Abs(Used) <= Tolerance && Math.Abs(Remaining - Total) <= Tolerance ||
            Consumed is > 0 && Math.Abs(Used - Consumed.Value) <= Tolerance && Math.Abs(Remaining + Consumed.Value - Total) <= Tolerance;
    }
    private static bool SameSubscription(CycleState state, CycleSource source)
    {
        if (state.SubscriptionID != null && source.SubscriptionID != null && state.SubscriptionID != source.SubscriptionID) return false;
        if (state.PlanID != null && source.PlanID != null && state.PlanID != source.PlanID) return false;
        if (state.SubscriptionID != null && source.SubscriptionID != null || state.PlanID != null && source.PlanID != null) return true;
        return source.Title != null && string.Equals(state.Title, source.Title, StringComparison.Ordinal);
    }
    private static CycleState Baseline(CycleSource source, int week = 1, CycleState? previous = null, bool markFull = false)
    {
        var seen = new List<string>(previous?.SeenRequestIds ?? []);
        if (!string.IsNullOrEmpty(source.RequestId) && !seen.Contains(source.RequestId, StringComparer.Ordinal)) seen.Add(source.RequestId);
        return new CycleState(week, source.SubscriptionID ?? previous?.SubscriptionID, source.PlanID ?? previous?.PlanID,
            source.Title ?? previous?.Title ?? "套餐", source.Total, source.Used, source.Remaining,
            source.RecordedAt, source.RequestId, previous?.LastResetAt,
            markFull && source.Full && source.RequestId.Length > 0 ? source.RequestId : previous?.LastResetEventID,
            seen.TakeLast(1024).ToList(), previous?.WeekStartedAt);
    }
    private static bool NewCycleEvent(CycleState state, CycleSource source, CycleSource[] sources)
    {
        if (source.RecordedAt < state.LastRecordedAt || source.RequestId.Length == 0 || source.RequestId == state.LastRequestId ||
            source.RequestId == state.LastResetEventID || state.SeenRequestIds?.Contains(source.RequestId, StringComparer.Ordinal) == true) return false;
        if (source.RecordedAt > state.LastRecordedAt) return true;
        var anchor = sources.FirstOrDefault(candidate => candidate.RequestId == state.LastRequestId && candidate.RecordedAt == state.LastRecordedAt);
        return anchor != null && source.ResponseIndex < anchor.ResponseIndex;
    }
    private static CycleState InitialCycle(CycleSource latest, CycleSource[] sources)
    {
        var initial = Baseline(latest, markFull: true);
        var seen = sources.Where(source => SameSubscription(initial, source) && source.RequestId.Length > 0)
            .Select(source => source.RequestId).Distinct(StringComparer.Ordinal).TakeLast(1024).ToList();
        return initial with { SeenRequestIds = seen };
    }
    private static CycleState? UpdateCycle(CycleState? previous, List<CycleSource> sources)
    {
        // 同一个请求的修正版覆盖旧快照，避免把旧版满额元数据先当作新周处理。
        var ordered = sources.OrderByDescending(source => source.RecordedAt).ThenBy(source => source.ResponseIndex)
            .GroupBy(source => (source.RequestId, MissingIndex: source.RequestId.Length == 0 ? source.ResponseIndex : -1))
            .Select(group => group.First()).OrderBy(source => source.RecordedAt).ThenByDescending(source => source.ResponseIndex).ToArray();
        if (ordered.LastOrDefault() is not { } latest) return previous;
        if (previous is not { Valid: true }) return InitialCycle(latest, ordered);
        if (!SameSubscription(previous, latest)) return NewCycleEvent(previous, latest, ordered) ? InitialCycle(latest, ordered) : previous;
        var state = previous;
        var target = Baseline(latest, previous: previous);
        foreach (var source in ordered.Where(source => SameSubscription(target, source)))
        {
            // token 日志 id 会重新编号，去重依赖 request_id；同秒只在旧锚点仍在响应数组时按 API 原序判定。
            if (!NewCycleEvent(state, source, ordered)) continue;
            if (Math.Abs(state.TotalQuota - source.Total) > 0.5m) { state = Baseline(source, state.Week, state, markFull: true); continue; }
            var reset = source.Full && state.UsedQuota > 0.5m && state.RemainingQuota < state.TotalQuota - 0.5m &&
                state.LastResetEventID != source.RequestId;
            var next = Baseline(source, reset ? state.Week % 4 + 1 : state.Week, state);
            state = reset ? next with { LastResetAt = source.RecordedAt, LastResetEventID = source.RequestId,
                WeekStartedAt = DayStart(source.RecordedAt) } : next;
        }
        return state;
    }
    private static DateTimeOffset? Expiration(string? text, long? subscriptionId, long? planId, DateTimeOffset now)
    {
        if (OptionalEnvelope(text) is not { ValueKind: JsonValueKind.Object } data) return null;
        var subscriptions = new Dictionary<long, JsonElement>();
        foreach (var name in new[] { "subscriptions", "all_subscriptions" })
        {
            if (!data.TryGetProperty(name, out var list) || list.ValueKind != JsonValueKind.Array) continue;
            foreach (var item in list.EnumerateArray())
                if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("subscription", out var row) && OptionalId(row, "id") is { } id)
                    subscriptions.TryAdd(id, row);
        }
        JsonElement? selected = null;
        if (subscriptionId is { } exact)
        {
            if (subscriptions.TryGetValue(exact, out var row)) selected = row;
        }
        else if (planId is { } definition)
        {
            var matching = subscriptions.Values.Where(row => OptionalId(row, "plan_id") == definition).ToArray();
            if (matching.Length == 1) selected = matching[0];
        }
        else
        {
            var active = subscriptions.Values.Where(row => OptionalString(row, "status") == "active" &&
                OptionalId(row, "end_time") > now.ToUnixTimeSeconds()).ToArray();
            if (active.Length == 1) selected = active[0];
            else if (subscriptions.Count == 1) selected = subscriptions.Values.First();
        }
        var seconds = selected is { } value ? OptionalId(value, "end_time") : null;
        return seconds is > 0 and <= 253402300799 ? DateTimeOffset.FromUnixTimeSeconds(seconds.Value) : null;
    }

    public static ApiSnapshot Parse(string usageText, string logsText, string statusText, string key,
        ApiSnapshot? previous = null, DateTimeOffset? at = null, string? accountText = null, string? subscriptionsText = null,
        string? balanceText = null)
    {
        var now = at ?? DateTimeOffset.UtcNow;
        var usage = Envelope(usageText); var logs = Envelope(logsText); var status = Envelope(statusText);
        var unit = Number(status, "quota_per_unit");
        if (unit <= 0 || status.GetProperty("quota_display_type").GetString() != "USD") throw new InvalidDataException("平台计费单位不匹配。");
        var cumulative = Number(usage, "total_used") / unit;
        if (cumulative < 0) throw new InvalidDataException("平台账单格式异常。");
        var day = DayStart(now); var fingerprint = Fingerprint(key);
        var previousBalance = previous is { Valid: true } && previous.KeyFingerprint == fingerprint ? previous.AccountBalanceUSD : null;
        var previousCycle = previous is { Valid: true } && previous.KeyFingerprint == fingerprint ? previous.Cycle : null;
        var previousPlan = previous is { Valid: true } && previous.KeyFingerprint == fingerprint ? previous.RecordedPlan : null;
        var previousTrigger = previous is { Valid: true } && previous.KeyFingerprint == fingerprint ? previous.LastTriggerAt : null;
        var lastConversation = previous is { Valid: true } && previous.KeyFingerprint == fingerprint ? previous.LastConversationAt : null;
        if (lastConversation > now.AddMinutes(5)) lastConversation = null;
        if (previous is not { Valid: true } || previous.KeyFingerprint != fingerprint || previous.DayStart != day) previous = null;
        var records = (previous?.TodayRecords ?? []).ToDictionary(x => x.Id, StringComparer.Ordinal);
        bool overlap = false, planIdentitySeen = false; DateTimeOffset? earliest = null; long? subscriptionId = null, planId = null;
        PlanSnapshot? latestPlan = null; long? latestLogId = null;
        var cycleSources = new List<CycleSource>();
        var cycleRequestIds = new HashSet<string>(StringComparer.Ordinal);
        var rows = logs.EnumerateArray().Select((row, index) => new { Row = row, ResponseIndex = index })
            .OrderByDescending(x => x.Row.GetProperty("created_at").GetDouble()).ThenBy(x => x.ResponseIndex).ToArray();
        foreach (var indexed in rows)
        {
            var row = indexed.Row;
            var seconds = row.GetProperty("created_at").GetDouble();
            if (!double.IsFinite(seconds) || seconds <= 0) throw new InvalidDataException("平台账单时间异常。");
            var date = DateTimeOffset.UnixEpoch.AddSeconds(seconds);
            if (earliest == null || date < earliest) earliest = date;
            var quota = Number(row, "quota");
            if (quota < 0) throw new InvalidDataException("平台账单金额异常。");
            if (row.GetProperty("type").GetInt32() != 2) continue;
            if (date <= now.AddMinutes(5) && (lastConversation == null || date > lastConversation)) lastConversation = date;
            var cycleRequestId = OptionalString(row, "request_id") ?? "";
            var newestCycleSnapshot = cycleRequestId.Length == 0 || cycleRequestIds.Add(cycleRequestId);
            if (date >= day && date < day.AddDays(1))
            {
                var id = row.GetProperty("request_id").GetString();
                if (string.IsNullOrEmpty(id) || id.Length > 256) throw new InvalidDataException("账单缺少稳定标识，无法累计今日使用。");
                overlap |= records.ContainsKey(id);
                records[id] = new DailyRecord(id, date, quota / unit);
            }
            if (Metadata(row) is JsonElement meta && OptionalString(meta, "billing_source") == "subscription" &&
                OptionalNumber(meta, "subscription_used") is { } usedQuota && usedQuota >= 0 &&
                OptionalNumber(meta, "subscription_remain") is { } remainQuota &&
                OptionalNumber(meta, "subscription_total") is { } totalQuota && totalQuota > 0)
            {
                var fullTitle = OptionalString(meta, "subscription_plan_title");
                if (string.IsNullOrWhiteSpace(fullTitle)) fullTitle = null;
                var sourceSubscription = OptionalId(meta, "subscription_id"); var sourcePlan = OptionalId(meta, "subscription_plan_id");
                var opaqueSubscription = OptionalString(meta, "subscription_id")?.Trim();
                var logId = OptionalId(row, "id");
                if (newestCycleSnapshot && date <= now.AddMinutes(5) &&
                    (sourceSubscription != null || opaqueSubscription is { Length: > 0 and <= 256 }) &&
                    (latestPlan == null || date > latestPlan.RecordedAt ||
                        date == latestPlan.RecordedAt && (logId ?? long.MinValue) > (latestLogId ?? long.MinValue)))
                {
                    latestPlan = new PlanSnapshot(fullTitle ?? "套餐", usedQuota / unit, remainQuota / unit, totalQuota / unit, date, cycleRequestId);
                    latestLogId = logId;
                }
                if (newestCycleSnapshot && remainQuota >= 0 && (sourceSubscription != null || sourcePlan != null || fullTitle != null))
                {
                    if (cycleRequestId.Length <= 256) cycleSources.Add(new CycleSource(sourceSubscription, sourcePlan, fullTitle, totalQuota, usedQuota,
                        remainQuota, OptionalNumber(meta, "subscription_consumed"), date, cycleRequestId, indexed.ResponseIndex));
                }
                if (!planIdentitySeen)
                {
                    subscriptionId = sourceSubscription; planId = sourcePlan;
                    planIdentitySeen = true;
                }
            }
        }
        var daily = records.Values.OrderBy(x => x.Id, StringComparer.Ordinal).ToList();
        var today = daily.Sum(x => x.CostUSD);
        bool complete = (earliest is not null ? earliest <= day : cumulative == 0) ||
            (previous?.TodayComplete == true && overlap) || Math.Abs(today - cumulative) < 0.5m / unit;
        var name = usage.GetProperty("name").GetString() ?? "";
        // 顶层 total_available 和 expires_at 分别属于令牌额度、令牌到期，不能用于账户卡片。
        decimal? balance = usage.TryGetProperty("user_quota", out var wallet) ? OptionalNumber(wallet, "total_available") / unit : null;
        string? accountName = null, accountError = null; DateTimeOffset? expiresAt = null;
        if (OptionalEnvelope(accountText) is { ValueKind: JsonValueKind.Object } account)
        {
            if (OptionalNumber(account, "quota") is { } accountQuota) balance = accountQuota / unit;
            accountName = OptionalString(account, "display_name") ?? OptionalString(account, "username") ?? "账户";
            accountName = accountName[..Math.Min(accountName.Length, 40)];
            expiresAt = Expiration(subscriptionsText, subscriptionId, planId, now);
        }
        if (balanceText != null)
        {
            // 官方 CC Switch 查询接口已返回美元，不能再除以 quota_per_unit。
            if (OptionalEnvelope(balanceText) is { ValueKind: JsonValueKind.Object } walletBalance &&
                OptionalString(walletBalance, "currency") == "USD" && OptionalNumber(walletBalance, "balance") is { } dollars)
                balance = dollars;
            else
            {
                balance = previousBalance;
                accountError = balance != null ? "充值余额暂时无法更新，当前显示上次查询余额。" : "充值余额暂时无法更新。";
            }
        }
        var cycle = UpdateCycle(previousCycle, cycleSources);
        var plan = latestPlan == null || previousPlan?.RecordedAt > latestPlan.RecordedAt ? previousPlan : latestPlan;
        if (plan != null && plan.RecordedAt <= now.AddMinutes(5) && (lastConversation == null || plan.RecordedAt > lastConversation))
            lastConversation = plan.RecordedAt;
        var planError = latestPlan == null ? plan == null ? "未查到套餐消费记录" : "未查到套餐新记录，保留上次记录" : null;
        var snapshot = new ApiSnapshot(1, fingerprint, name[..Math.Min(name.Length, 40)], day, today, complete, daily, cumulative, now, plan,
            balance, expiresAt, accountName, accountError, cycle, plan == null ? null : "consumption_log", planError, previousTrigger, lastConversation);
        return snapshot.Valid ? snapshot : throw new InvalidDataException("平台账单格式异常。");
    }
}

public static class ApiRefreshPolicy
{
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(30);
    public const string TriggerModel = "gpt-5.6-luna";
    public static bool NeedsTrigger(ApiSnapshot snapshot, DateTimeOffset now) =>
        snapshot.Valid && snapshot.RecordedPlan is { } plan && now - plan.RecordedAt > Interval &&
        !(snapshot.LastConversationAt is { } conversation && conversation <= now.AddMinutes(5) && now - conversation <= Interval);
}

public sealed class ApiTriggerGate(string directory)
{
    public bool Reserve(string key, DateTimeOffset now)
    {
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "topapi-trigger-attempts.json");
        using var held = new FileStream(file + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var attempts = File.Exists(file)
            ? JsonSerializer.Deserialize<Dictionary<string, DateTimeOffset>>(File.ReadAllText(file))
                ?? throw new InvalidDataException("触发状态格式异常。")
            : new Dictionary<string, DateTimeOffset>();
        var fingerprint = ApiBilling.Fingerprint(key);
        if (attempts.TryGetValue(fingerprint, out var previous) && now - previous < ApiRefreshPolicy.Interval) return false;
        attempts[fingerprint] = now;
        var temporary = file + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(attempts));
            File.Move(temporary, file, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return true;
    }
}

public static class ApiClient
{
    private static HttpClient CreateClient(HttpMessageHandler? transport) =>
        new(transport ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
            { Timeout = TimeSpan.FromSeconds(30), MaxResponseContentBufferSize = 12 * 1024 * 1024 };

    private static async Task<string> Send(HttpClient client, HttpRequestMessage request, CancellationToken token)
    {
        using var response = await client.SendAsync(request, token);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new InvalidDataException("平台未授权，请检查 API Key。");
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
            throw new InvalidDataException("查询过于频繁，请稍后手动刷新或等待下一轮自动刷新。");
        if (!response.IsSuccessStatusCode) throw new HttpRequestException("平台查询失败。");
        return await response.Content.ReadAsStringAsync(token);
    }

    public static async Task<ApiSnapshot> Fetch(string key, ApiSnapshot? previous, CancellationToken token,
        string? accountText = null, string? subscriptionsText = null, HttpMessageHandler? transport = null)
    {
        using var client = CreateClient(transport);
        return await Read(client, key, previous, token, accountText, subscriptionsText);
    }

    private static async Task<ApiSnapshot> Read(HttpClient client, string key, ApiSnapshot? previous, CancellationToken token,
        string? accountText = null, string? subscriptionsText = null)
    {
        async Task<string> Get(string path, bool authenticate = true, bool ccSwitch = false)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api-top.com" + path);
            request.Headers.Accept.ParseAdd("application/json");
            request.Headers.CacheControl = new() { NoCache = true };
            if (ccSwitch) request.Headers.UserAgent.ParseAdd("cc-switch/1.0");
            if (authenticate) request.Headers.Authorization = new("Bearer", key);
            return await Send(client, request, token);
        }
        async Task<string> Balance()
        {
            try { return await Get("/api/usage/balance", ccSwitch: true); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidDataException or OperationCanceledException)
            { return "{\"success\":false}"; } // 充值余额接口独立降级。
        }
        var usage = Get("/api/usage/token/"); var logs = Get("/api/log/token"); var status = Get("/api/status", false);
        var balance = Balance();
        await Task.WhenAll(usage, logs, status, balance);
        return ApiBilling.Parse(await usage, await logs, await status, key, previous, accountText: accountText,
            subscriptionsText: subscriptionsText, balanceText: await balance);
    }

    public static async Task<ApiSnapshot> Refresh(string key, ApiSnapshot? previous, CancellationToken token,
        Func<DateTimeOffset, bool> reserveTrigger, HttpMessageHandler? transport = null, DateTimeOffset? at = null,
        Func<CancellationToken, Task>? waitForLog = null)
    {
        using var client = CreateClient(transport);
        var fresh = await Read(client, key, previous, token);
        var now = at ?? DateTimeOffset.UtcNow;
        if (!ApiRefreshPolicy.NeedsTrigger(fresh, now)) return fresh;
        token.ThrowIfCancellationRequested();
        try
        {
            if (!reserveTrigger(now)) return fresh with { PlanError = "消费快照较旧，30分钟内不重复触发对话" };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        { return fresh with { PlanError = "无法保存触发状态，本次未发起对话" }; }
        fresh = fresh with { LastTriggerAt = now };
        try { await Trigger(client, key, token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidDataException or OperationCanceledException or JsonException)
        { return fresh with { PlanError = "快照触发对话失败，30分钟内不重复尝试" }; }
        var oldPlan = fresh.RecordedPlan;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (attempt > 0) await (waitForLog?.Invoke(token) ?? Task.Delay(1000, token));
            token.ThrowIfCancellationRequested();
            try
            {
                fresh = (await Read(client, key, fresh, token)) with { LastTriggerAt = now };
                if (fresh.RecordedPlan is { } plan && plan.RecordedAt.ToUnixTimeSeconds() >= now.ToUnixTimeSeconds() &&
                    (oldPlan == null || plan.RecordedAt > oldPlan.RecordedAt ||
                    plan.RecordedAt == oldPlan.RecordedAt && !string.IsNullOrEmpty(plan.RequestID) && plan.RequestID != oldPlan.RequestID) &&
                    !ApiRefreshPolicy.NeedsTrigger(fresh, now)) return fresh;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidDataException or OperationCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
            { fresh = fresh with { PlanError = "对话已触发，正在重新查询消费记录" }; }
        }
        return fresh with { PlanError = "已触发对话，暂未取得新消费记录，请稍后刷新" };
    }

    private static async Task Trigger(HttpClient client, string key, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api-top.com/v1/chat/completions");
        request.Headers.Authorization = new("Bearer", key);
        request.Headers.Accept.ParseAdd("application/json");
        request.Content = new StringContent(JsonSerializer.Serialize(new {
            model = ApiRefreshPolicy.TriggerModel, messages = new[] { new { role = "user", content = "Reply only OK." } },
            max_tokens = 16, stream = false }), Encoding.UTF8, "application/json");
        using var body = JsonDocument.Parse(await Send(client, request, token));
        if (body.RootElement.ValueKind != JsonValueKind.Object || body.RootElement.TryGetProperty("error", out _) ||
            !body.RootElement.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() == 0)
            throw new InvalidDataException("触发对话响应异常。");
    }
}
