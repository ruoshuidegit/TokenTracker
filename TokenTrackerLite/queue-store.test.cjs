"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { processQueue } = require("./queue-store.cjs");
const { createLitePricing, getDefaultPricing } = require("./lite-pricing.cjs");
const liteOverrides = require("./lite-pricing.json");

const pricing = require(process.env.TOKENTRACKER_TEST_PRICING_DIR || "../src/lib/pricing");
const NOW = new Date("2026-11-10T12:00:00.000Z");
const row = (tokens = 100, extra = {}) => ({ source: "codex", model: "gpt-5", hour_start: "2026-11-10T00:00:00.000Z",
  input_tokens: tokens, output_tokens: 0, cached_input_tokens: 0, cache_creation_input_tokens: 0,
  reasoning_output_tokens: 0, total_tokens: tokens, ...extra });
const lines = (...rows) => rows.map((value) => JSON.stringify(value)).join("\n") + "\n";

async function fixture(t, initial) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "tokentracker-lite-test-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const queuePath = path.join(directory, "queue.jsonl");
  const databasePath = path.join(directory, "lite", "usage.sqlite");
  if (initial !== undefined) await fs.writeFile(queuePath, initial);
  return { queuePath, databasePath, read: (options = {}) => processQueue({ queuePath, databasePath, now: NOW, pricing, ...options }) };
}

test("按桶最后快照覆盖，更新、减少与零值撤销不重复累计", async (t) => {
  const f = await fixture(t, lines(row(100), row(120), row(80, { model: "gpt-5-mini" })));
  let snapshot = await f.read();
  assert.equal(snapshot.all.tokens, 200);
  assert.equal(snapshot.stats.bucket_count, 2);
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.stats.rows_processed, 3);
  const appended = lines(row(30), row(0, { model: "gpt-5-mini" }));
  await fs.appendFile(f.queuePath, appended);
  snapshot = await f.read();
  assert.equal(snapshot.all.tokens, 30);
  assert.equal(snapshot.stats.rebuild, false);
  assert.equal(snapshot.stats.bytes_read, Buffer.byteLength(appended));
  assert.equal(snapshot.models.length, 1);
  const unchanged = await f.read();
  assert.equal(unchanged.stats.bytes_read, 0);
  assert.equal(unchanged.stats.rows_processed, 0);
  assert.equal(unchanged.stats.rebuild, false);
});

test("控制记录不作为用量，损坏记录明确警告", async (t) => {
  const f = await fixture(t, lines(row(15), row(999, { kind: "account_session_state" }),
    row(999, { kind: "account_sync_watermark" }), row(20, { kind: "future_usage_kind", model: "gpt-5-mini" }),
    { kind: "future_control" }) + "{invalid}\n");
  const snapshot = await f.read();
  assert.equal(snapshot.all.tokens, 35);
  assert.equal(snapshot.stats.bucket_count, 2);
  assert.match(snapshot.warning, /1 条无效用量记录/);
  assert.match((await f.read()).warning, /1 条无效用量记录/);
});

test("不完整尾行不提交，补全后恰好读取一次", async (t) => {
  const complete = lines(row(10));
  const partial = JSON.stringify(row(25, { model: "gpt-5-mini" }));
  const cut = Math.floor(partial.length / 2);
  const f = await fixture(t, complete + partial.slice(0, cut));
  assert.equal((await f.read()).all.tokens, 10);
  const waiting = await f.read();
  assert.equal(waiting.stats.bytes_read, 0);
  assert.match(waiting.warning, /末条记录尚未写完/);
  await fs.appendFile(f.queuePath, partial.slice(cut) + "\n");
  const result = await f.read();
  assert.equal(result.all.tokens, 35);
  assert.equal(result.stats.rows_processed, 1);
  assert.equal(result.stats.bytes_read, Buffer.byteLength(partial + "\n"));
});

test("原子替换、截断、同大小改写重建，删除旧桶", async (t) => {
  const f = await fixture(t, lines(row(11), row(22, { model: "gpt-5-mini" })));
  await f.read();
  const replacement = f.queuePath + ".new";
  await fs.writeFile(replacement, lines(row(33)));
  await fs.rename(replacement, f.queuePath);
  let snapshot = await f.read();
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.all.tokens, 33);
  assert.equal(snapshot.stats.bucket_count, 1);
  await fs.truncate(f.queuePath, 0);
  snapshot = await f.read();
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.all.tokens, 0);
  await fs.writeFile(f.queuePath, lines(row(44)));
  await f.read();
  const before = await fs.stat(f.queuePath);
  await fs.writeFile(f.queuePath, lines(row(55)));
  await fs.utimes(f.queuePath, before.atime, new Date(before.mtimeMs + 1000));
  snapshot = await f.read();
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.all.tokens, 55);
});

test("缺失队列返回上次汇总，首次缺失返回零", async (t) => {
  const f = await fixture(t);
  let snapshot = await f.read();
  assert.equal(snapshot.queue_present, false);
  assert.equal(snapshot.all.tokens, 0);
  assert.equal(snapshot.queue_updated_at, null);
  await fs.writeFile(f.queuePath, lines(row(77)));
  const previous = await f.read();
  await fs.unlink(f.queuePath);
  snapshot = await f.read();
  assert.equal(snapshot.queue_present, false);
  assert.equal(snapshot.all.tokens, 77);
  assert.equal(snapshot.queue_updated_at, previous.queue_updated_at);
});

test("本地采集按来源和半小时整组覆盖，不与旧模型归属或旧队列重复相加", async (t) => {
  const legacyHour = "2026-11-09T00:00:00.000Z";
  const f = await fixture(t, lines(row(1000), row(100, { source: "antigravity", model: "old-model" }),
    row(200, { source: "omp", hour_start: "2026-11-10T08:00:00+08:00" }), row(50, { source: "omp", hour_start: legacyHour })));
  const collection = { sources: ["antigravity", "omp"], rows: [
    row(150, { source: "antigravity", model: "new-model" }), row(0, { source: "omp" }),
  ], warnings: [], updatedAt: NOW.toISOString() };
  const first = await f.read({ collection });
  assert.equal(first.all.tokens, 1200);
  assert.equal(first.stats.collected_bucket_count, 2);
  assert.equal(first.models.some((model) => model.model === "old-model"), false);
  await fs.appendFile(f.queuePath, lines(row(900, { source: "antigravity", model: "old-model" }),
    row(700, { source: "omp" }), row(2000)));
  const refreshed = await f.read({ collection });
  assert.equal(refreshed.all.tokens, 2200);
  assert.equal((await f.read()).all.tokens, 2200, "重启或共享队列追加不能恢复被覆盖的旧计数");
  await fs.writeFile(f.queuePath, lines(row(3000)));
  assert.equal((await f.read({ collection })).all.tokens, 3150, "原队列重建不擦除本地采集层");
});

test("无原版队列也可独立汇总本地采集，失败来源保留上次已确认结果", async (t) => {
  const f = await fixture(t);
  const collection = { sources: ["omp"], rows: [row(160, { source: "omp" })], warnings: [], updatedAt: NOW.toISOString() };
  const first = await f.read({ collection });
  assert.equal(first.queue_present, true);
  assert.equal(first.all.tokens, 160);
  assert.equal(first.queue_updated_at, NOW.toISOString());
  const retained = await f.read({ collection: { sources: [], rows: [], warnings: ["OMP采集缓存无法读取"] } });
  assert.equal(retained.all.tokens, 160);
  assert.match(retained.warning, /OMP采集缓存无法读取/);
  await assert.rejects(f.read({ collection: { ...collection, rows: [row(999, { source: "unexpected" })] } }), /本地采集用量格式无效/);
  assert.equal((await f.read()).all.tokens, 160, "无效新数据必须回滚本地覆盖层");
});

test("读取期间被替换会回滚，下一次成功后才公布新快照", async (t) => {
  const f = await fixture(t, lines(row(10)));
  await f.read();
  await fs.appendFile(f.queuePath, lines(row(20)));
  let replaced = false;
  const mutatingPricing = { ...pricing, computeRowCost(value) {
    if (!replaced) {
      const syncFs = require("node:fs");
      const replacement = f.queuePath + ".new";
      syncFs.writeFileSync(replacement, lines(row(35, { model: "gpt-5-mini" })));
      syncFs.renameSync(replacement, f.queuePath);
      replaced = true;
    }
    return pricing.computeRowCost(value);
  } };
  await assert.rejects(f.read({ pricing: mutatingPricing }), /读取期间队列已被替换或改写/);
  const snapshot = await f.read();
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.all.tokens, 35);
  assert.equal(snapshot.stats.bucket_count, 1);
});

test("遵守本地日/月边界，时区改变会重建", async (t) => {
  const previousTZ = process.env.TZ;
  t.after(() => { if (previousTZ === undefined) delete process.env.TZ; else process.env.TZ = previousTZ; });
  process.env.TZ = "Asia/Shanghai";
  const f = await fixture(t, lines(row(100, { hour_start: "2026-10-31T17:00:00.000Z" }),
    row(200, { hour_start: "2026-11-09T17:00:00.000Z" }), row(300, { hour_start: "2026-11-09T15:00:00.000Z" })));
  let snapshot = await f.read();
  assert.equal(snapshot.today.tokens, 200);
  assert.equal(snapshot.month.tokens, 600);
  assert.equal(snapshot.days.length, 7);
  assert.deepEqual(snapshot.days.at(-1), { day: "2026-11-10", tokens: 200, cost_usd: snapshot.today.cost_usd });
  process.env.TZ = "UTC";
  snapshot = await f.read();
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.today.tokens, 0);
  assert.equal(snapshot.month.tokens, 500);
  assert.equal(snapshot.all.tokens, 600);
});

test("旧Codex与Cursor修正、billable零值、离线费用及未定价模型", async (t) => {
  const legacy = row(1000, { cached_input_tokens: 800, output_tokens: 100, total_tokens: 1100 });
  const f = await fixture(t, lines(legacy, row(200, { source: "cursor", billable_total_tokens: 0 }),
    row(90, { source: "antigravity", billable_total_tokens: 0 }), row(70, { model: "unknown-lite-test-model" }),
    row(5, { model: "gpt-5-mini", billable_total_tokens: 0 })));
  const snapshot = await f.read();
  assert.equal(snapshot.all.tokens, 1460);
  assert.equal(snapshot.all.input_tokens, 565);
  assert.equal(snapshot.all.cached_input_tokens, 800);
  assert.equal(snapshot.all.unpriced_tokens, 70);
  const expected = pricing.computeRowCost({ ...legacy, input_tokens: 200 }) +
    pricing.computeRowCost(row(200, { source: "cursor" })) + pricing.computeRowCost(row(90, { source: "antigravity" })) +
    pricing.computeRowCost(row(5, { model: "gpt-5-mini" }));
  assert.ok(Math.abs(snapshot.all.cost_usd - expected) < 1e-10);
});

test("自定义Claude后端仅标记未知部分，免费来源与权威费用不误标", async (t) => {
  const mixed = row(100, { source: "claude", model: "claude-sonnet-4-5", backend_usage: [
    { backend: "custom", input_tokens: 40, total_tokens: 40 },
    { backend: "anthropic", input_tokens: 60, total_tokens: 60 },
  ] });
  const exact = row(20, { source: "grok", model: "unknown-lite-exact-model", total_cost_usd: 1.25 });
  const f = await fixture(t, lines(mixed, exact, row(50, { source: "lmstudio", model: "local-test-model" })));
  const snapshot = await f.read();
  assert.equal(snapshot.all.tokens, 170);
  assert.equal(snapshot.all.unpriced_tokens, 40);
  assert.ok(Math.abs(snapshot.all.cost_usd - pricing.computeRowCost(mixed) - 1.25) < 1e-10);
});

test("Lite补价按核实版本区分缓存费率，只识别已知变体", () => {
  const lite = createLitePricing();
  const usage = row(10_000_000, { source: "omp", input_tokens: 1_000_000, output_tokens: 2_000_000,
    cached_input_tokens: 3_000_000, cache_creation_input_tokens: 4_000_000 });
  for (const [model, cost] of [["claude-fable-5-1", 160.75], ["claude-fable-5-1-thinking-xhigh", 160.75],
    ["claude-fable-5-1-thinking-high", 160.75], ["claude-fable-5-1-xhigh", 160.75],
    ["claude-fable-5-1-high", 160.75], ["claude-fable-5-1-max", 160.75],
    ["claude-fable-5-2", 128.6], ["claude-fable-5.2-thinking", 128.6],
    ["opus-5", 81.5], ["fable-5", 163]]) {
    const value = { ...usage, model };
    assert.equal(lite.getModelPricingInfo(model, { source: value.source }).status, "priced", model);
    assert.ok(Math.abs(lite.computeRowCost(value) - cost) < 1e-10, model);
    assert.equal(value.model, model);
  }
  for (const model of ["claude-fable-5-3", "claude-fable-5-10", "claude-fable-5-1-fast", "codex-auto-review", "unknown"])
    assert.equal(lite.getModelPricingInfo(model, { source: "cursor" }).status, "unpriced", model);
});

test("Lite价格实例不修改共享上游表、负缓存或其他实例", () => {
  const model = "claude-fable-5-1";
  const source = "omp";
  const upstreamBefore = pricing.getModelPricingInfo(model, { source });
  const curated = require("../src/lib/pricing/curated-overrides.json");
  const exactBefore = JSON.stringify(curated.exact[model]);
  const lite = createLitePricing();
  const custom = structuredClone(liteOverrides);
  custom.exact[model].input = 11;
  const other = createLitePricing({ overrides: custom });
  assert.equal(lite.getModelPricingInfo(model, { source }).input, 10);
  assert.equal(other.getModelPricingInfo(model, { source }).input, 11);
  assert.notEqual(lite.policyVersion, other.policyVersion);
  assert.deepEqual(pricing.getModelPricingInfo(model, { source }), upstreamBefore);
  assert.equal(JSON.stringify(curated.exact[model]), exactBefore);
});

test("补价保留来源保护、免费、权威费用和原公式的计费子集", async (t) => {
  const lite = getDefaultPricing();
  const mixed = row(100, { source: "claude", model: "claude-fable-5-1-thinking-xhigh", backend_usage: [
    { backend: "custom", input_tokens: 40, total_tokens: 40 },
    { backend: "anthropic", input_tokens: 40, total_tokens: 40 },
    { backend: "unknown", input_tokens: 20, total_tokens: 20 },
  ] });
  const f = await fixture(t, lines(mixed,
    row(50, { source: "lmstudio", model: "claude-fable-5-2" }),
    row(20, { source: "grok", model: "claude-fable-5-1", total_cost_usd: 1.25 })));
  const snapshot = await f.read({ pricing: lite });
  assert.equal(snapshot.all.unpriced_tokens, 40);
  assert.ok(Math.abs(snapshot.all.cost_usd - 1.2506) < 1e-10);
  assert.equal(lite.getModelPricingInfo(mixed.model, mixed).status, "unpriced");
  const tiered = row(10_000, { model: "gpt-6-astra", priority_input_tokens: 3000, priority_output_tokens: 50,
    input_tokens: 9000, output_tokens: 1000, long_context_input_tokens: 4000, long_context_output_tokens: 600 });
  assert.equal(lite.computeRowCost(tiered), pricing.computeRowCost(tiered));
});

test("价格策略改变时重算未变队列一次，原始模型主键与JSON版本保持不变", async (t) => {
  const model = "claude-fable-5.2-thinking";
  const text = lines(row(100, { source: "omp", model }));
  const f = await fixture(t, text);
  const old = await f.read({ pricing: { policyVersion: "before-fable-pricing",
    getModelPricingInfo: () => ({ status: "unpriced" }), computeRowCost: () => 0 } });
  assert.equal(old.all.unpriced_tokens, 100);
  assert.equal(old.all.cost_usd, 0);
  const lite = getDefaultPricing();
  let snapshot = await f.read({ pricing: lite });
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.stats.bytes_read, Buffer.byteLength(text));
  assert.equal(snapshot.all.unpriced_tokens, 0);
  assert.equal(snapshot.all.cost_usd, 0.0008);
  assert.equal(snapshot.schema_version, 1);
  assert.equal(snapshot.models[0].model, model);
  snapshot = await f.read({ pricing: lite });
  assert.equal(snapshot.stats.rebuild, false);
  assert.equal(snapshot.stats.bytes_read, 0);
  const updated = structuredClone(liteOverrides);
  updated.exact["claude-fable-5-2"].input = 9;
  snapshot = await f.read({ pricing: createLitePricing({ overrides: updated }) });
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.all.cost_usd, 0.0009);
  const { DatabaseSync } = require("node:sqlite");
  const database = new DatabaseSync(f.databasePath);
  const value = JSON.parse(database.prepare("SELECT value FROM lite_state WHERE id = 1").get().value);
  delete value.pricing_policy_version;
  database.prepare("UPDATE lite_state SET value = ? WHERE id = 1").run(JSON.stringify(value));
  database.close();
  snapshot = await f.read({ pricing: lite });
  assert.equal(snapshot.stats.rebuild, true);
  assert.equal(snapshot.all.cost_usd, 0.0008);
});

test("按本月排序前五模型，快照不包含队列内容或路径", async (t) => {
  const f = await fixture(t, lines(...Array.from({ length: 7 }, (_, index) => row((index + 1) * 10, { model: `model-${index}` })),
    row(999, { model: "old-model", hour_start: "2026-09-10T00:00:00.000Z", prompt: "private-content-for-test" })));
  const snapshot = await f.read();
  assert.deepEqual(snapshot.models.map((value) => value.model), ["model-6", "model-5", "model-4", "model-3", "model-2"]);
  assert.equal(snapshot.schema_version, 1);
  assert.equal(snapshot.generated_at, NOW.toISOString());
  const output = JSON.stringify(snapshot);
  assert.equal(output.includes(f.queuePath), false);
  assert.equal(output.includes("private-content-for-test"), false);
});

test("CLI 参数错误只输出中文摘要，不泄露路径或堆栈", () => {
  const result = spawnSync(process.execPath, ["--no-warnings", path.join(__dirname, "queue-store.cjs"), "--secret-path"], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /Lite 用量读取失败/);
  assert.equal(result.stderr.includes(__dirname), false);
  assert.equal(result.stderr.includes(" at "), false);
});

test("Carbon 与 Argon 型号各自跨来源合并后排名，原始桶与总量保留", async (t) => {
  const f = await fixture(t, lines(
    row(50, { source: "antigravity", model: "gemini-4-carbon" }),
    row(40, { source: "omp", model: "gemini-4-carbon-high" }),
    row(30, { source: "omp", model: "custom-CARBON-preview" }),
    row(100, { source: "antigravity", model: "gemini-4-argon-trial" }),
    row(40, { source: "omp", model: "gemini-4-argon-high" }),
    row(30, { source: "omp", model: "custom-ARGON-preview" }),
    row(20, { model: "gpt-5" }),
    row(999, { model: "carbon-old-month", hour_start: "2026-10-20T00:00:00.000Z" }),
  ));
  const options = { pricing: getDefaultPricing() };
  const snapshot = await f.read(options);
  assert.equal(snapshot.models[0].model, "gemini-4-argon");
  assert.equal(snapshot.models[0].source, "all");
  assert.equal(snapshot.models[0].tokens, 170);
  assert.equal(snapshot.models[1].model, "gemini-4-carbon");
  assert.equal(snapshot.models[1].source, "all");
  assert.equal(snapshot.models[1].tokens, 120);
  assert.equal(snapshot.models[1].unpriced_tokens, 30);
  assert.equal(snapshot.month.tokens, 310);
  assert.equal(snapshot.all.tokens, 1309);
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(f.databasePath, { readOnly: true });
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM lite_buckets WHERE lower(model) LIKE '%carbon%'").get().n, 4);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM lite_buckets WHERE lower(model) LIKE '%argon%'").get().n, 3);
  db.close();
  assert.deepEqual((await f.read(options)).models, snapshot.models);
});

test("旧 Carbon / Argon 标签中的 worker 统一归 Hydrogen，仍按原始后端型号计价", async (t) => {
  const f = await fixture(t);
  const called = [];
  const customPricing = {
    getModelPricingInfo(model) { called.push(model); return { status: "priced" }; },
    computeRowCost(value) {
      assert.equal(value.model, "gemini-flash-worker-agy");
      return value.total_tokens / 1000;
    },
  };
  const snapshot = await f.read({ pricing: customPricing, collection: {
    sources: ["antigravity"], rows: [row(120, { source: "antigravity", model: "gemini-flash-worker-agy-carbon",
      pricing_model: "gemini-flash-worker-agy" }), row(80, { source: "antigravity", model: "gemini-flash-worker-agy-argon",
      pricing_model: "gemini-flash-worker-agy" })], warnings: [],
  } });
  assert.deepEqual(called, ["gemini-flash-worker-agy", "gemini-flash-worker-agy"]);
  assert.equal(snapshot.models[0].model, "gemini-4-hydrogen");
  assert.equal(snapshot.models[0].tokens, 200);
  assert.equal(snapshot.models[0].cost_usd, 0.2);
  assert.equal(snapshot.models[0].unpriced_tokens, 0);
  assert.equal(snapshot.models.length, 1);
});

test("Neon 内部型号、大小写和思考档位跨来源合并，worker 不计入 Neon", async (t) => {
  const f = await fixture(t, lines(
    row(100, { source: "antigravity", model: "gemini-pro-orchestrator-neon" }),
    row(60, { source: "omp", model: "gemini-4-neon" }),
    row(40, { source: "omp", model: "gemini-4-neon-xhigh" }),
    row(20, { source: "omp", model: "Gemini 4 Neon" }),
    row(30, { source: "omp", model: "custom-NEON-preview" }),
    row(80, { source: "antigravity", model: "gemini-flash-worker-agy-neon" }),
    row(10, { source: "omp", model: "gemini-4-hydrogen" }),
    row(45, { source: "antigravity", model: "gemini-4-carbon" }),
    row(35, { source: "antigravity", model: "gemini-4-argon" }),
  ));
  const snapshot = await f.read({ pricing: getDefaultPricing() });
  const neon = snapshot.models.find((row) => row.model === "gemini-4-neon");
  assert.equal(neon.source, "all");
  assert.equal(neon.tokens, 250);
  assert.equal(neon.unpriced_tokens, 30);
  assert.ok(Math.abs(neon.cost_usd - 0.00066) < 1e-12);
  assert.equal(snapshot.models.find((row) => row.model === "gemini-4-hydrogen").tokens, 90);
  assert.equal(snapshot.models.find((row) => row.model === "gemini-4-carbon").tokens, 45);
  assert.equal(snapshot.models.find((row) => row.model === "gemini-4-argon").tokens, 35);
  assert.equal(snapshot.month.tokens, 420);
  assert.deepEqual((await f.read({ pricing: getDefaultPricing() })).models, snapshot.models);
});
