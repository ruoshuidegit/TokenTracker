#!/usr/bin/env node
"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { DatabaseSync } = require("node:sqlite");
const { getDefaultPricing } = require("./lite-pricing.cjs");

const SCHEMA_VERSION = 1;
const NORMALIZATION_VERSION = 2;
const CHUNK_BYTES = 64 * 1024;
const MAX_LINE_BYTES = 1024 * 1024;
const TOKEN_FIELDS = ["input_tokens", "output_tokens", "cached_input_tokens", "cache_creation_input_tokens", "reasoning_output_tokens"];
const utf8 = new TextDecoder("utf-8", { fatal: true });

function counter(value, fallback = 0) {
  if (value === undefined || value === null) return fallback;
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) throw new Error("用量计数格式无效");
  return number;
}

function normalizeRow(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      value.kind === "account_session_state" || value.kind === "account_sync_watermark") return null;
  if (typeof value.hour_start !== "string" || !Number.isFinite(Date.parse(value.hour_start))) return null;
  const row = { ...value, hour_start: new Date(value.hour_start).toISOString(), source: String(value.source || ""), model: String(value.model || "") };
  if (row.source.length > 100 || row.model.length > 200) throw new Error("用量标识格式无效");
  if (row.pricing_model !== undefined && (typeof row.pricing_model !== "string" ||
      !row.pricing_model.trim() || row.pricing_model.length > 200)) throw new Error("计价模型格式无效");
  for (const key of Object.keys(row)) {
    if (key.endsWith("_tokens")) row[key] = counter(row[key]);
  }
  for (const key of TOKEN_FIELDS) row[key] = counter(row[key]);
  row.total_tokens = counter(row.total_tokens);
  if ((row.source === "codex" || row.source === "every-code") && row.cached_input_tokens > 0 &&
      row.input_tokens >= row.cached_input_tokens && row.total_tokens === row.input_tokens + row.output_tokens) {
    row.input_tokens -= row.cached_input_tokens;
  }
  const source = row.source.toLowerCase();
  if ((source === "cursor" || source === "antigravity") && row.total_tokens > 0 &&
      Number(row.billable_total_tokens || 0) < row.total_tokens) row.billable_total_tokens = row.total_tokens;
  row.billable_total_tokens = counter(row.billable_total_tokens, row.total_tokens);
  return row;
}

function localDay(value) {
  const date = value instanceof Date ? value : new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function fileState(stat) {
  return { dev: String(stat.dev), ino: String(stat.ino), size: Number(stat.size),
    mtime_ns: String(stat.mtimeNs), ctime_ns: String(stat.ctimeNs) };
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameSnapshot(left, right) {
  return sameIdentity(left, right) && left.size === right.size &&
    left.mtime_ns === right.mtime_ns && left.ctime_ns === right.ctime_ns;
}

async function* readChunks(file, start, end) {
  let offset = start;
  while (offset < end) {
    const buffer = Buffer.allocUnsafe(Math.min(CHUNK_BYTES, end - offset));
    const { bytesRead } = await file.read(buffer, 0, buffer.length, offset);
    if (!bytesRead) throw new Error("读取期间队列已被截断，将在下次刷新重试");
    offset += bytesRead;
    yield buffer.subarray(0, bytesRead);
  }
}

function rowPrice(row, pricing) {
  // 兼容旧编排缓存，按实际子模型查价，不将 Hydrogen 套用 Carbon / Argon 的价格。
  const model = pricing.resolveRowModel?.(row) || row.pricing_model || row.model;
  row = { ...row, model, pricing_model: model };
  const tokens = row.billable_total_tokens;
  const info = pricing.getModelPricingInfo(row.model, { source: row.source, hourStart: row.hour_start });
  const exact = (row.source === "grok" || row.source === "cline") && Number(row.total_cost_usd) > 0;
  let unpriced = !exact && info.status === "unpriced" ? tokens : 0;
  if (!exact && info.status !== "unpriced" && row.source === "claude" && Array.isArray(row.backend_usage)) {
    unpriced = Math.min(tokens, row.backend_usage.reduce((sum, part) =>
      sum + (part?.backend === "custom" ? counter(part.total_tokens) : 0), 0));
  }
  const cost = pricing.computeRowCost(row);
  if (!Number.isFinite(cost) || cost < 0) throw new Error("离线费用计算失败");
  return { cost, unpriced };
}

function repriceCollected(database, pricing) {
  const rows = database.prepare(`SELECT source, model, hour_start, tokens AS total_tokens,
    tokens AS billable_total_tokens, ${TOKEN_FIELDS.join(", ")} FROM lite_collected_buckets`).all();
  const update = database.prepare(`UPDATE lite_collected_buckets SET cost_usd = ?, unpriced_tokens = ?
    WHERE source = ? AND model = ? AND hour_start = ?`);
  for (const row of rows) {
    const price = rowPrice(row, pricing);
    update.run(price.cost, price.unpriced, row.source, row.model, row.hour_start);
  }
}

function initializeDatabase(database) {
  database.exec(`
    PRAGMA busy_timeout = 5000;
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS lite_state (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS lite_buckets (
      source TEXT NOT NULL, model TEXT NOT NULL, hour_start TEXT NOT NULL, day TEXT NOT NULL,
      tokens INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
      cached_input_tokens INTEGER NOT NULL, cache_creation_input_tokens INTEGER NOT NULL,
      reasoning_output_tokens INTEGER NOT NULL, cost_usd REAL NOT NULL, unpriced_tokens INTEGER NOT NULL,
      PRIMARY KEY(source, model, hour_start)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS lite_buckets_day ON lite_buckets(day);
    CREATE TABLE IF NOT EXISTS lite_collected_buckets (
      source TEXT NOT NULL, model TEXT NOT NULL, hour_start TEXT NOT NULL, day TEXT NOT NULL,
      tokens INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
      cached_input_tokens INTEGER NOT NULL, cache_creation_input_tokens INTEGER NOT NULL,
      reasoning_output_tokens INTEGER NOT NULL, cost_usd REAL NOT NULL, unpriced_tokens INTEGER NOT NULL,
      PRIMARY KEY(source, model, hour_start)
    ) WITHOUT ROWID;
    CREATE VIEW IF NOT EXISTS lite_effective_buckets AS
      SELECT * FROM lite_collected_buckets
      UNION ALL SELECT b.* FROM lite_buckets b WHERE NOT EXISTS (
        SELECT 1 FROM lite_collected_buckets local
        WHERE local.source = b.source AND local.hour_start = b.hour_start
      );
  `);
}

function summarize(database, { now, queuePresent, state, stats, warnings, collection }) {
  const sum = `COALESCE(SUM(tokens), 0) AS tokens, ${TOKEN_FIELDS.map((field) => `COALESCE(SUM(${field}), 0) AS ${field}`).join(", ")},
    COALESCE(SUM(cost_usd), 0) AS cost_usd, COALESCE(SUM(unpriced_tokens), 0) AS unpriced_tokens`;
  const today = localDay(now);
  const month = today.slice(0, 7);
  const aggregate = (where = "", parameters = []) => ({ ...database.prepare(`SELECT ${sum} FROM lite_effective_buckets ${where}`).get(...parameters) });
  const days = [];
  for (let offset = 6; offset >= 0; offset -= 1) {
    const date = new Date(now);
    date.setDate(date.getDate() - offset);
    const day = localDay(date);
    const totals = database.prepare("SELECT COALESCE(SUM(tokens), 0) AS tokens, COALESCE(SUM(cost_usd), 0) AS cost_usd FROM lite_effective_buckets WHERE day = ?").get(day);
    days.push({ day, ...totals });
  }
  const models = database.prepare(`WITH classified AS (
      SELECT CASE WHEN instr(lower(model), 'hydrogen') > 0 OR lower(model) IN
        ('gemini-flash-worker-agy', 'gemini-flash-worker-agy-carbon', 'gemini-flash-worker-agy-argon', 'gemini-flash-worker-agy-neon')
          THEN 'gemini-4-hydrogen'
        WHEN instr(lower(model), 'neon') > 0 THEN 'gemini-4-neon'
        WHEN instr(lower(model), 'carbon') > 0 THEN 'gemini-4-carbon'
        WHEN instr(lower(model), 'argon') > 0 THEN 'gemini-4-argon' ELSE model END AS model,
        source, tokens, cost_usd, unpriced_tokens FROM lite_effective_buckets WHERE day >= ? AND day < ?
    ), monthly AS (
      SELECT model, CASE WHEN model IN ('gemini-4-carbon', 'gemini-4-argon', 'gemini-4-hydrogen', 'gemini-4-neon')
        THEN 'all' ELSE source END AS source, tokens, cost_usd, unpriced_tokens FROM classified
    ) SELECT model, source, SUM(tokens) AS tokens, SUM(cost_usd) AS cost_usd, SUM(unpriced_tokens) AS unpriced_tokens
    FROM monthly GROUP BY model, source HAVING SUM(tokens) > 0
    ORDER BY tokens DESC, model, source LIMIT 5`).all(`${month}-01`, nextMonth(now)).map((row) => ({ ...row }));
  return {
    schema_version: SCHEMA_VERSION,
    generated_at: now.toISOString(),
    queue_updated_at: [state?.queue_updated_at, collection?.updatedAt].filter(Boolean).sort().at(-1) || null,
    queue_present: queuePresent || database.prepare("SELECT COUNT(*) AS count FROM lite_collected_buckets").get().count > 0,
    stats: { ...stats, bucket_count: database.prepare("SELECT COUNT(*) AS count FROM lite_effective_buckets").get().count,
      collected_bucket_count: database.prepare("SELECT COUNT(*) AS count FROM lite_collected_buckets").get().count },
    today: aggregate("WHERE day = ?", [today]),
    month: aggregate("WHERE day >= ? AND day < ?", [`${month}-01`, nextMonth(now)]),
    all: aggregate(), models, days,
    ...(warnings.length ? { warning: warnings.join("；") } : {}),
  };
}

function nextMonth(now) {
  const next = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  return localDay(next);
}

async function processQueue({ queuePath, databasePath, now = new Date(), pricing, collection } = {}) {
  if (!queuePath || !databasePath || !Number.isFinite(now.getTime())) throw new Error("采集参数无效");
  const queue = path.resolve(queuePath);
  const store = path.resolve(databasePath);
  if (queue === store || store === ":memory:") throw new Error("Lite 数据库必须使用独立文件");
  pricing ||= getDefaultPricing();
  const pricingPolicyVersion = pricing.policyVersion || "injected-pricing-v1";
  await fs.mkdir(path.dirname(store), { recursive: true, mode: 0o700 });
  const database = new DatabaseSync(store);
  let file;
  let transaction = false;
  const stats = { bytes_read: 0, rows_processed: 0, rebuild: false };
  const warnings = [...(collection?.warnings || [])];
  try {
    await fs.chmod(store, 0o600);
    initializeDatabase(database);
    database.exec("BEGIN IMMEDIATE");
    transaction = true;
    let saved = null;
    const storedState = database.prepare("SELECT value FROM lite_state WHERE id = 1").get();
    if (storedState) {
      try { saved = JSON.parse(storedState.value); } catch { throw new Error("Lite 增量状态损坏"); }
    }
    const saveState = database.prepare("INSERT INTO lite_state VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET value=excluded.value");
    // 暂时读不到采集缓存时，也可用已入库的原始计数重算历史费用。
    if (saved?.collected_pricing_policy_version !== pricingPolicyVersion) repriceCollected(database, pricing);
    if (collection) {
      const sources = collection.sources || ["antigravity", "omp"];
      if (sources.some((source) => source !== "antigravity" && source !== "omp")) throw new Error("本地采集来源无效");
      const remove = database.prepare("DELETE FROM lite_collected_buckets WHERE source = ?");
      for (const source of sources) remove.run(source);
      const localInsert = database.prepare("INSERT INTO lite_collected_buckets VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
      for (const value of collection.rows) {
        const row = normalizeRow(value);
        if (!row || !sources.includes(row.source)) throw new Error("本地采集用量格式无效");
        const price = rowPrice(row, pricing);
        localInsert.run(row.source, row.model, row.hour_start, localDay(row.hour_start), row.billable_total_tokens,
          ...TOKEN_FIELDS.map((field) => row[field]), price.cost, price.unpriced);
      }
    }
    try { file = await fs.open(queue, "r"); }
    catch (error) {
      if (error.code !== "ENOENT") throw error;
      warnings.push("尚未找到原版采集队列，显示本地采集及已保存的数据");
      saveState.run(JSON.stringify({ ...saved, collected_pricing_policy_version: pricingPolicyVersion }));
      const snapshot = summarize(database, { now, queuePresent: false, state: saved, stats, warnings, collection });
      database.exec("COMMIT");
      transaction = false;
      return snapshot;
    }
    const rawBefore = await file.stat({ bigint: true });
    if (!rawBefore.isFile() || rawBefore.size > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("采集队列格式无效");
    const before = fileState(rawBefore);
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const queueKey = createHash("sha256").update(queue).digest("hex");
    const compatible = saved?.schema_version === SCHEMA_VERSION && saved.normalization_version === NORMALIZATION_VERSION && saved.pricing_policy_version === pricingPolicyVersion &&
      saved.queue_key === queueKey && saved.timezone === timezone &&
      Number.isSafeInteger(saved.offset) && saved.offset >= 0 && saved.offset <= saved.size;
    const unchanged = compatible && sameSnapshot(saved, before);
    const append = compatible && sameIdentity(saved, before) && before.size > saved.size;
    stats.rebuild = !unchanged && !append;
    let offset = unchanged || append ? saved.offset : 0;
    if (stats.rebuild) database.exec("DELETE FROM lite_buckets");
    const insert = database.prepare(`INSERT INTO lite_buckets VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source, model, hour_start) DO UPDATE SET day=excluded.day, tokens=excluded.tokens,
      input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens, cached_input_tokens=excluded.cached_input_tokens,
      cache_creation_input_tokens=excluded.cache_creation_input_tokens, reasoning_output_tokens=excluded.reasoning_output_tokens,
      cost_usd=excluded.cost_usd, unpriced_tokens=excluded.unpriced_tokens`);
    let malformed = 0;
    if (!unchanged && offset < before.size) {
      let carry = Buffer.alloc(0);
      for await (const chunk of readChunks(file, offset, before.size)) {
        stats.bytes_read += chunk.length;
        const data = carry.length ? Buffer.concat([carry, chunk]) : chunk;
        let start = 0;
        let end;
        while ((end = data.indexOf(10, start)) >= 0) {
          const length = end - start;
          if (length > MAX_LINE_BYTES) throw new Error("采集队列单条记录过大");
          if (length > 0) {
            stats.rows_processed += 1;
            let value;
            try { value = JSON.parse(utf8.decode(data.subarray(start, end))); }
            catch { malformed += 1; }
            if (value !== undefined) {
              let row;
              try { row = normalizeRow(value); } catch { malformed += 1; }
              if (row) {
                const price = rowPrice(row, pricing);
                insert.run(row.source, row.model, row.hour_start, localDay(row.hour_start), row.billable_total_tokens,
                  ...TOKEN_FIELDS.map((field) => row[field]), price.cost, price.unpriced);
              }
            }
          }
          offset += length + 1;
          start = end + 1;
        }
        carry = Buffer.from(data.subarray(start));
        if (carry.length > MAX_LINE_BYTES) throw new Error("采集队列单条记录过大");
      }
      if (carry.length) warnings.push("队列末条记录尚未写完，等待下次读取");
    } else if (offset < before.size) {
      warnings.push("队列末条记录尚未写完，等待下次读取");
    }
    const malformedRows = (stats.rebuild ? 0 : Number(saved.malformed_rows || 0)) + malformed;
    if (malformedRows) warnings.push(`发现 ${malformedRows} 条无效用量记录，未计入汇总`);
    const after = fileState(await file.stat({ bigint: true }));
    const current = fileState(await fs.stat(queue, { bigint: true }));
    if (!sameIdentity(before, after) || !sameIdentity(after, current) || after.size < before.size || current.size < before.size ||
        (after.size === before.size && !sameSnapshot(before, after)) || (current.size === before.size && !sameSnapshot(before, current))) {
      throw new Error("读取期间队列已被替换或改写，将在下次刷新重试");
    }
    const state = { ...before, offset, queue_key: queueKey, timezone, malformed_rows: malformedRows, schema_version: SCHEMA_VERSION,
      normalization_version: NORMALIZATION_VERSION,
      pricing_policy_version: pricingPolicyVersion,
      collected_pricing_policy_version: pricingPolicyVersion,
      queue_updated_at: new Date(Number(rawBefore.mtimeMs)).toISOString() };
    saveState.run(JSON.stringify(state));
    const snapshot = summarize(database, { now, queuePresent: true, state, stats, warnings, collection });
    database.exec("COMMIT");
    transaction = false;
    return snapshot;
  } finally {
    if (transaction) database.exec("ROLLBACK");
    await file?.close();
    database.close();
  }
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const option = argv[index];
    const value = argv[index + 1];
    if (!["--queue", "--database", "--collect-state-dir"].includes(option) || !value || value.startsWith("--") || Object.hasOwn(options, option)) {
      throw new Error("用法：queue-store.cjs --queue <采集队列> --database <Lite数据库> [--collect-state-dir <本地采集目录>]");
    }
    options[option] = value;
  }
  return { queuePath: options["--queue"], databasePath: options["--database"], collectStateDir: options["--collect-state-dir"] };
}

if (require.main === module) {
  Promise.resolve().then(async () => {
    const options = parseArguments(process.argv.slice(2));
    if (options.collectStateDir) {
      options.collection = await require("./local-collect.cjs").collectLocalUsage({ stateDir: options.collectStateDir });
    }
    return processQueue(options);
  }).then((snapshot) => {
    process.stdout.write(`${JSON.stringify(snapshot)}\n`);
  }).catch(() => {
    process.stderr.write("Lite 用量读取失败，请检查采集队列、独立数据库权限或稍后重试。\n");
    process.exitCode = 1;
  });
}

module.exports = { processQueue, normalizeRow };
