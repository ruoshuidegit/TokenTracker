# API-Top 余额查询与套餐剩余天数逻辑

以下内容对应当前仓库 `TokenTrackerLite` 的实现。账户余额通过平台接口查询；套餐剩余天数由本机按 **4 周、共 28 天**估算，**包含今天**。

## 1. 查询账户余额

### 请求

```http
GET https://api-top.com/api/usage/balance
Authorization: Bearer <API_KEY>
Accept: application/json
User-Agent: cc-switch/1.0
```

使用已经设置的环境变量 `API_KEY` 查询：

```bash
curl --fail-with-body --silent --show-error \
  'https://api-top.com/api/usage/balance' \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Accept: application/json' \
  -H 'User-Agent: cc-switch/1.0'
```

### 取值

响应结构示例，金额使用截图中的数值：

```json
{
  "success": true,
  "data": {
    "balance": 103.4,
    "currency": "USD"
  }
}
```

处理规则：

1. 校验响应成功：`success === true` 或 `code === true`。
2. 校验 `data.currency === "USD"`，且 `data.balance` 为有限数值。
3. 直接读取 `data.balance`，保留零余额和负余额。
4. 显示时保留四位小数，例如 `103.4` 显示为 `$103.4000`。

这个接口的 `balance` 已经是美元金额，不能再除以 `quota_per_unit`。账户充值余额、密钥额度和套餐剩余额度各自独立，不能使用 `token_remaining` 或密钥顶层的 `total_available` 代替账户余额。

### 余额查询失败时

当前实现还支持其他账户钱包数据，取值优先级为：

```text
/api/usage/balance 的 data.balance
    ↓ 无有效结果
传入的账户资料 quota ÷ quota_per_unit（如果提供了这份资料）
    ↓ 无有效结果
/api/usage/token/ 的 data.user_quota.total_available ÷ quota_per_unit
    ↓ 无有效结果且本次余额查询失败
同一 API Key 的上次有效账户余额
    ↓ 无缓存
显示「—」
```

其中 `quota_per_unit` 来自无需认证的 `GET https://api-top.com/api/status`，要求大于零且 `quota_display_type` 为 `USD`。`/api/usage/token/` 使用与余额请求相同的 Bearer 认证。

使用缓存时标注「上次查询结果」；更换 API Key 后不能沿用另一把 Key 的余额。上述账户资料是解析器的可选输入，当前查询客户端不会自动发起账户资料请求。

## 2. 套餐剩余天数

### 需要保存的状态

| 字段 | 含义 |
| --- | --- |
| `week` | 当前为第几周，范围为 1～4 |
| `weekStartedAt` | 当前这一周的起算日期，以北京时间零点表示 |
| `now` | 当前时间 |

所有日期差按 **北京时间 `Asia/Shanghai` 的日历日期**计算，跨北京时间零点后天数变化。

### 计算公式

```text
本周天数 day = 北京时间今天与 weekStartedAt 的日期差 + 1

本周期已经过去的天数 elapsed = (week - 1) × 7 + (day - 1)

剩余天数 remainingDays = max(0, 28 - elapsed)

预计到期日期 estimatedEndDate
    = weekStartedAt + [27 - (week - 1) × 7] 个日历日
```

`weekStartedAt` 表示当前周起算日，不一定是星期一。预计到期日期表示这个 28 天周期的最后一天。

边界规则：

- 第 1 周第 1 天剩余 28 天；第 4 周第 7 天剩余 1 天。
- 到期日期的次日归零；归零以后，预计到期日期仍保持原值。
- 缺少有效周期、尚无起算日期，或者起算日期在未来时，显示「—」，不生成预计到期日期。
- 日期经过七天不会自动增加 `week`；没有新的满额恢复证据时继续按原起算日期倒数，界面可显示「等待满额恢复」。

### 截图中的计算

```text
当前北京时间日期：2026-11-13
当前周数：第 1 周
当前周起算日期：2026-11-09

day = 4 + 1 = 5
elapsed = (1 - 1) × 7 + (5 - 1) = 4
remainingDays = 28 - 4 = 24 天

estimatedEndDate = 2026-11-09 + 27 天 = 2026-12-06
```

因此截图显示「第 1 / 4 周」「第 5 天」「24 天」「预计到期：2026-12-06」。

## 3. 周数与起算日期怎么确定

### 数据来源

```http
GET https://api-top.com/api/log/token
Authorization: Bearer <API_KEY>
Accept: application/json
```

只使用 `type === 2` 的消费日志；将日志的 `other` 字符串解析为 JSON，筛选 `billing_source === "subscription"`，读取：

```text
subscription_id / subscription_plan_id / subscription_plan_title
subscription_total
subscription_used
subscription_remain
subscription_consumed（可选，用于还原首笔扣费前的满额状态）
```

首次读取时，以最新有效套餐快照建立第 1 周基准，不追算历史周数，也不假设购买日期。此时 `weekStartedAt` 尚未知，需要人工校准或等待后续检测到满额恢复，才能显示剩余天数。

### 满额恢复判定

以下计算均使用日志中的原始 quota，误差容忍值为 **0.5 个原始 quota 单位**，不是 0.5 美元。

```text
epsilon = 0.5

直接满额：
    abs(subscription_used) <= epsilon
    且 abs(subscription_remain - subscription_total) <= epsilon

或者，首笔请求扣费前为满额：
    subscription_consumed 是有限数值且 > 0
    且 abs(subscription_used - subscription_consumed) <= epsilon
    且 abs(subscription_remain + subscription_consumed - subscription_total) <= epsilon
```

只有同一套餐的新日志、套餐总额度未变化、之前确实存在消费，并且满足上述满额判定时，才推进周数：

```text
week = week % 4 + 1                 // 1 → 2 → 3 → 4 → 1
weekStartedAt = 恢复日志所在日期的北京时间零点
```

“总额度未变化”指前后 `subscription_total` 差的绝对值不超过 `0.5`；“之前确实存在消费”指旧快照 `usedQuota > 0.5` 且 `remainingQuota < totalQuota - 0.5`。

日志按稳定的 `request_id` 去重，并结合时间戳判断新旧；同秒日志使用同一响应中的相对位置判断，避免刷新或重启造成重复推进。套餐总额度变化只更新额度基准，不当作新的一周；更换 API Key 或检测到新的套餐身份时重新建立基准。

### 人工校准

如果已知某个北京时间日期对应「第 W 周第 D 天」，则：

```text
week = W                           // W 为 1～4
weekStartedAt = 该日期北京时间零点 - (D - 1) 天   // D 为 1～7
```

例如，2026-11-13 校准为第 1 周第 5 天，得到 `weekStartedAt = 2026-11-09 00:00:00 +08:00`。

## 4. 实现位置

- [余额接口请求与解析（macOS）](../TokenTrackerLite/TopAPI.swift)：`TopAPIClient.fetch`、`TopAPISnapshot.parse`。
- [周数、校准、剩余天数和预计到期日期（macOS）](../TokenTrackerLite/TopAPICycle.swift)：`TopAPIWeekCycle`。
- [截图卡片展示（macOS）](../TokenTrackerLite/TokenTrackerLite.swift)：余额、套餐周期及套餐剩余天数卡片。
- [对应 Windows 实现](../TokenTrackerLite/Windows/ApiBilling.cs)：`RemainingCycleDays`、`CycleEstimatedEndDate`、`CalibrateCycle`。

当前卡片使用本地周期推算预计到期日期。即使数据模型另有 `planExpiresAt`，也不将它用于这张剩余天数卡片；密钥的 `expires_at` 同样不能作为套餐到期时间。
