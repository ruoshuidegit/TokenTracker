"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { DatabaseSync } = require("node:sqlite");
const { createLitePricing } = require("./lite-pricing.cjs");
const { processQueue } = require("./queue-store.cjs");

const NOVEMBER = "2026-11-15T00:00:00Z";
const DECEMBER = "2026-12-01T00:00:00Z";
const usage = (model, extra = {}) => ({ source: "antigravity", model, hour_start: NOVEMBER,
  input_tokens: 1_000_000, cached_input_tokens: 2_000_000, cache_creation_input_tokens: 0,
  output_tokens: 300_000, reasoning_output_tokens: 100_000, total_tokens: 3_400_000,
  billable_total_tokens: 3_400_000, ...extra });
const close = (actual, expected, message) => assert.ok(Math.abs(actual - expected) < 1e-10,
  `${message || "费用"}: ${actual} != ${expected}`);

test("Carbon、Hydrogen 的输入、缓存读取和含推理输出分别按官方价格计费", () => {
  const pricing = createLitePricing();
  for (const [model, rates, cost] of [
    ["gemini-4-carbon", [2, 0.1, 10], 6.2],
    ["gemini-4-carbon-high", [2, 0.1, 10], 6.2],
    ["GEMINI-4-CARBON-MEDIUM", [2, 0.1, 10], 6.2],
    ["gemini-4-hydrogen", [1.5, 0.075, 7.5], 4.65],
    ["gemini-4-hydrogen-medium", [1.5, 0.075, 7.5], 4.65],
    ["gemini-4-hydrogen-xhigh", [1.5, 0.075, 7.5], 4.65],
    ["gemini-4-neon", [3, 0.15, 15], 9.3],
    ["gemini-4-neon-low", [3, 0.15, 15], 9.3],
    ["gemini-4-neon-medium", [3, 0.15, 15], 9.3],
    ["GEMINI-4-NEON-HIGH", [3, 0.15, 15], 9.3],
    ["gemini-4-neon-xhigh", [3, 0.15, 15], 9.3],
    ["gemini-4-neon-extra", [3, 0.15, 15], 9.3],
    ["Gemini 4 Neon", [3, 0.15, 15], 9.3],
    ["gemini-pro-orchestrator-neon", [3, 0.15, 15], 9.3],
  ]) {
    const row = usage(model);
    const before = structuredClone(row);
    const info = pricing.getModelPricingInfo(model, { source: row.source, hourStart: row.hour_start });
    assert.equal(info.status, "priced", model);
    assert.deepEqual([info.input, info.cache_read, info.output], rates, model);
    close(pricing.computeRowCost(row), cost, model);
    assert.deepEqual(row, before);
  }
});

test("按 UTC 用量日期区分优惠期，12 月价格不会倒灌 11 月历史，Hydrogen 维持自己的费率", () => {
  const pricing = createLitePricing();
  for (const model of ["gemini-4-carbon", "gemini-4-argon"]) {
    for (const [date, cost, input] of [[DECEMBER, 12.4, 4], ["2026-11-30T23:30:00Z", 6.2, 2],
      [DECEMBER, 12.4, 4], [NOVEMBER, 6.2, 2]]) {
      const row = usage(model, { hour_start: date });
      close(pricing.computeRowCost(row), cost, `${model} ${date}`);
      assert.equal(pricing.getModelPricingInfo(model, { source: row.source, hourStart: date }).input, input);
    }
  }
  close(pricing.computeRowCost(usage("gemini-4-hydrogen", { hour_start: DECEMBER })), 4.65);
  close(pricing.computeRowCost(usage("gemini-4-hydrogen")), 4.65);
  close(pricing.computeRowCost(usage("gemini-4-neon", { hour_start: DECEMBER })), 9.3);
  close(pricing.computeRowCost(usage("gemini-4-neon")), 9.3);
  assert.throws(() => pricing.computeRowCost(usage("gemini-4-carbon", { hour_start: "invalid-date" })), /计价日期/);
});

test("旧编排缓存按实际 planner / Hydrogen 计价，缺少选择信息的 planner 保持未定价", () => {
  const pricing = createLitePricing();
  for (const [model, backend, actual, cost] of [
    ["gemini-pro-orchestrator-carbon", "gemini-pro-orchestrator", "gemini-4-carbon", 6.2],
    ["gemini-pro-orchestrator-argon", "gemini-pro-orchestrator", "gemini-4-argon", 6.2],
    ["gemini-pro-orchestrator-neon", "gemini-pro-orchestrator", "gemini-4-neon", 9.3],
    ["gemini-pro-orchestrator-neon", "gemini-pro-orchestrator-neon", "gemini-4-neon", 9.3],
    ["gemini-flash-worker-agy-carbon", "gemini-flash-worker-agy", "gemini-4-hydrogen", 4.65],
    ["gemini-flash-worker-agy-argon", "gemini-flash-worker-agy", "gemini-4-hydrogen", 4.65],
    ["gemini-flash-worker-agy-neon", "gemini-flash-worker-agy", "gemini-4-hydrogen", 4.65],
  ]) {
    const row = usage(model, { pricing_model: backend });
    assert.equal(pricing.resolveRowModel(row), actual);
    close(pricing.computeRowCost(row), cost, model);
  }
  close(pricing.computeRowCost(usage("gemini-flash-worker-agy")), 4.65);
  assert.equal(pricing.getModelPricingInfo("gemini-pro-orchestrator", { source: "antigravity" }).status, "unpriced");
  assert.equal(pricing.getModelPricingInfo("gemini-4-carbon-fast", { source: "antigravity" }).status, "unpriced");
  assert.equal(pricing.getModelPricingInfo("gemini-4-hydrogen-new-sku", { source: "antigravity" }).status, "unpriced");
  assert.equal(pricing.getModelPricingInfo("gemini-4-neon-new-sku", { source: "antigravity" }).status, "unpriced");
});

test("OMP 的 output 已包含推理时不重复收费，独立推理字段仍正常计价", () => {
  const pricing = createLitePricing();
  for (const [model, cost] of [["gemini-4-carbon-high", 6.2], ["gemini-4-hydrogen-medium", 4.65],
    ["gemini-4-neon-xhigh", 9.3]]) {
    const included = usage(model, { source: "omp", output_tokens: 400_000 });
    const excluded = usage(model, { source: "omp" });
    const before = structuredClone(included);
    close(pricing.computeRowCost(included), cost, model);
    close(pricing.computeRowCost(excluded), cost, model);
    assert.deepEqual(included, before);
  }
  close(pricing.computeRowCost(usage("gemini-4-carbon-high", { source: "omp", input_tokens: 15632,
    cached_input_tokens: 0, output_tokens: 288, reasoning_output_tokens: 254,
    total_tokens: 15920, billable_total_tokens: 15920 })), 0.034144);
  assert.equal(pricing.computeRowCost(usage("gemini-4-carbon", { source: "lmstudio" })), 0);
  assert.equal(pricing.computeRowCost(usage("gemini-4-hydrogen", { source: "pi-github-copilot" })), 0);
  assert.equal(pricing.computeRowCost(usage("gemini-4-neon", { source: "lmstudio" })), 0);
});

test("已有 Neon backend 历史重新计价并与 OMP 变体合并，Hydrogen 保持独立且刷新不重计", async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "lite-neon-reprice-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const options = { queuePath: path.join(directory, "missing-queue.jsonl"),
    databasePath: path.join(directory, "usage.sqlite"), now: new Date(NOVEMBER) };
  const rows = [usage("gemini-pro-orchestrator-neon"),
    usage("gemini-4-neon-xhigh", { source: "omp", output_tokens: 400_000 }),
    usage("gemini-flash-worker-agy-neon")];
  const before = await processQueue({ ...options, pricing: { policyVersion: "before-neon",
    getModelPricingInfo: () => ({ status: "unpriced" }), computeRowCost: () => 0 },
    collection: { rows, sources: ["antigravity", "omp"], warnings: [] } });
  const after = await processQueue({ ...options, pricing: createLitePricing() });
  assert.equal(after.all.tokens, before.all.tokens);
  const neon = after.models.find((row) => row.model === "gemini-4-neon");
  assert.equal(neon.tokens, 6_800_000);
  assert.equal(neon.unpriced_tokens, 0);
  close(neon.cost_usd, 18.6);
  const hydrogen = after.models.find((row) => row.model === "gemini-4-hydrogen");
  assert.equal(hydrogen.tokens, 3_400_000);
  close(hydrogen.cost_usd, 4.65);
  assert.deepEqual((await processQueue({ ...options, pricing: createLitePricing() })).all, after.all);
});

test("Hydrogen tiered 与 Flash 内部变体使用各自价格，调价按用量日期且未知 SKU 仍待定价", () => {
  const pricing = createLitePricing();
  for (const model of ["gemini-4-hydrogen-tiered", "gemini-4-hydrogen-tiered-high", "gemini-4-hydrogen-tiered-xhigh"]) {
    assert.equal(pricing.getModelPricingInfo(model, { source: "antigravity" }).status, "priced");
    close(pricing.computeRowCost(usage(model)), 4.65);
    close(pricing.computeRowCost(usage(model, { source: "omp", output_tokens: 400_000 })), 4.65);
  }
  for (const model of ["gemini-3.8-flash-tiered", "gemini-3.8-flash-n"]) {
    close(pricing.computeRowCost(usage(model)), 2.4);
    close(pricing.computeRowCost(usage(model, { source: "omp", output_tokens: 400_000 })), 2.4);
    close(pricing.computeRowCost(usage(model, { hour_start: "2027-01-01T00:00:00Z" })), 4.8);
    close(pricing.computeRowCost(usage(model)), 2.4);
  }
  for (const model of ["gemini-4-hydrogen-tiered-new-sku", "codex-auto-review", "unknown", "gemini-pro-orchestrator"]) {
    assert.equal(pricing.getModelPricingInfo(model, { source: "antigravity" }).status, "unpriced", model);
  }
});

test("GPT-6.2 Astra 与 Sol 分别计价，Codex 推理不重复收费，未记录上下文档位时不按桶总量猜测", () => {
  const pricing = createLitePricing();
  for (const [model, rates, standard, withCacheWrite] of [
    ["gpt-6.2-astra", [8, 0.4, 40, 10], 24.8, 34.8],
    ["gpt-6.2-sol", [2, 0.1, 10, 2.5], 6.2, 8.7],
  ]) {
    const row = usage(model, { source: "codex", output_tokens: 400_000 });
    const info = pricing.getModelPricingInfo(model, { source: row.source });
    assert.deepEqual([info.input, info.cache_read, info.output, info.cache_write], rates);
    assert.equal(info.priority_multiplier, 2);
    assert.equal(info.ultrafast_multiplier, 3);
    close(pricing.computeRowCost(row), standard);
    close(pricing.computeRowCost({ ...row, model: `${model}-xhigh` }), standard);
    close(pricing.computeRowCost({ ...row, cache_creation_input_tokens: 1_000_000, total_tokens: 4_400_000 }), withCacheWrite);
  }
});

test("GPT-6.2 的长上下文、Fast、Ultrafast 交集只加价一次，优惠截止使用太平洋时间", () => {
  const pricing = createLitePricing();
  for (const [model, divisor] of [["gpt-6.2-astra", 1], ["gpt-6.2-sol", 4]]) {
    const row = usage(model, { source: "codex", output_tokens: 400_000,
      priority_input_tokens: 100_000, priority_cached_input_tokens: 200_000, priority_output_tokens: 40_000,
      ultrafast_input_tokens: 200_000, ultrafast_cached_input_tokens: 400_000, ultrafast_output_tokens: 80_000,
      long_context_input_tokens: 300_000, long_context_cached_input_tokens: 600_000, long_context_output_tokens: 120_000,
      priority_long_context_input_tokens: 50_000, priority_long_context_cached_input_tokens: 100_000,
      priority_long_context_output_tokens: 20_000, ultrafast_long_context_input_tokens: 100_000,
      ultrafast_long_context_cached_input_tokens: 200_000, ultrafast_long_context_output_tokens: 40_000 });
    const before = structuredClone(row);
    close(pricing.computeRowCost(row), 46.44 / divisor);
    close(pricing.computeRowCost({ ...row, hour_start: "2027-03-01T07:30:00Z" }), 46.44 / divisor);
    close(pricing.computeRowCost({ ...row, hour_start: "2027-03-01T08:00:00Z" }), 66.36 / divisor);
    close(pricing.computeRowCost(row), 46.44 / divisor);
    assert.deepEqual(row, before);
  }
});

test("本机 oMLX 精确来源与型号按本地推理计零 API 费用，不污染其他来源和上游价目", () => {
  const upstream = require("../src/lib/pricing");
  const model = "Qwen3.8-27B-Uncensored-oQ4e-mtp";
  const before = upstream.getModelPricingInfo(model, { source: "pi-omlx" });
  const astraBefore = upstream.getModelPricingInfo("gpt-6.2-astra", { source: "codex" });
  const pricing = createLitePricing();
  assert.equal(pricing.getModelPricingInfo(model, { source: "pi-omlx" }).status, "free");
  close(pricing.computeRowCost(usage(model, { source: "pi-omlx" })), 0);
  assert.equal(pricing.getModelPricingInfo(model, { source: "codex" }).status, "unpriced");
  assert.equal(pricing.getModelPricingInfo("other-model", { source: "pi-omlx" }).status, "unpriced");
  assert.deepEqual(upstream.getModelPricingInfo(model, { source: "pi-omlx" }), before);
  assert.deepEqual(upstream.getModelPricingInfo("gpt-6.2-astra", { source: "codex" }), astraBefore);
});

test("历史待定价和部分费用重新计算，队列加速计数与保留采集桶均生效且 Token 不变", async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "lite-pending-prices-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const queuePath = path.join(directory, "queue.jsonl");
  const astra = usage("gpt-6.2-astra", { source: "codex", output_tokens: 400_000,
    ultrafast_input_tokens: 1_000_000, ultrafast_cached_input_tokens: 2_000_000, ultrafast_output_tokens: 400_000 });
  await fs.writeFile(queuePath, JSON.stringify(astra) + "\n");
  const options = { queuePath, databasePath: path.join(directory, "usage.sqlite"), now: new Date(NOVEMBER) };
  const before = await processQueue({ ...options, pricing: { policyVersion: "before-pending-prices",
    getModelPricingInfo: () => ({ status: "unpriced" }), computeRowCost: () => 0 }, collection: {
      sources: ["antigravity"], rows: [usage("gemini-4-hydrogen-tiered"), usage("gemini-3.8-flash-n")], warnings: [],
    } });
  assert.equal(before.all.unpriced_tokens, 10_200_000);
  const pricing = createLitePricing();
  const after = await processQueue({ ...options, pricing });
  assert.equal(after.all.tokens, before.all.tokens);
  assert.equal(after.all.unpriced_tokens, 0);
  close(after.all.cost_usd, 81.45);
  close(after.models.find((row) => row.model === "gpt-6.2-astra").cost_usd, 74.4);
  const hydrogen = after.models.find((row) => row.model === "gemini-4-hydrogen");
  assert.equal(hydrogen.unpriced_tokens, 0);
  close(hydrogen.cost_usd, 4.65);
  assert.deepEqual((await processQueue({ ...options, pricing })).all, after.all);
});

test("已有汇总在队列和采集缓存暂缺时仍可重算费用，历史 Token 和原始型号保留", async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "lite-gemini-pricing-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const rows = [
    usage("gemini-pro-orchestrator-carbon", { pricing_model: "gemini-pro-orchestrator" }),
    usage("gemini-flash-worker-agy-carbon", { pricing_model: "gemini-flash-worker-agy" }),
    usage("gemini-flash-worker-agy-argon", { pricing_model: "gemini-flash-worker-agy" }),
    usage("gemini-4-carbon-high", { source: "omp", output_tokens: 400_000 }),
  ];
  const options = { queuePath: path.join(directory, "missing-queue.jsonl"),
    databasePath: path.join(directory, "usage.sqlite"), now: new Date(NOVEMBER) };
  const oldPricing = { policyVersion: "before-gemini-pricing", getModelPricingInfo: () => ({ status: "unpriced" }),
    computeRowCost: () => 0 };
  const before = await processQueue({ ...options, pricing: oldPricing,
    collection: { rows, sources: ["antigravity", "omp"], warnings: [] } });
  assert.equal(before.all.cost_usd, 0);
  assert.equal(before.all.unpriced_tokens, 13_600_000);
  const pricing = createLitePricing();
  const after = await processQueue({ ...options, pricing });
  for (const field of ["tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"]) {
    assert.equal(after.all[field], before.all[field], field);
  }
  close(after.all.cost_usd, 21.7);
  assert.equal(after.all.unpriced_tokens, 0);
  const carbon = after.models.find((row) => row.model === "gemini-4-carbon");
  const hydrogen = after.models.find((row) => row.model === "gemini-4-hydrogen");
  assert.equal(carbon.tokens, 6_800_000);
  assert.equal(hydrogen.tokens, 6_800_000);
  close(carbon.cost_usd, 12.4);
  close(hydrogen.cost_usd, 9.3);
  assert.deepEqual((await processQueue({ ...options, pricing })).all, after.all);
  const db = new DatabaseSync(options.databasePath, { readOnly: true });
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM lite_collected_buckets").get().n, rows.length);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM lite_collected_buckets WHERE model LIKE '%worker-agy%'").get().n, 2);
  db.close();
});

test("队列中的历史 Carbon / Hydrogen 用量重算一次，后续刷新不重复累计", async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "lite-gemini-reprice-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const queuePath = path.join(directory, "queue.jsonl");
  const rows = [usage("gemini-4-carbon-high"), usage("gemini-4-hydrogen-medium")];
  await fs.writeFile(queuePath, rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
  const options = { queuePath, databasePath: path.join(directory, "usage.sqlite"), now: new Date(NOVEMBER) };
  const before = await processQueue({ ...options, pricing: { policyVersion: "old-gemini-prices",
    getModelPricingInfo: () => ({ status: "unpriced" }), computeRowCost: () => 0 } });
  const pricing = createLitePricing();
  const after = await processQueue({ ...options, pricing });
  assert.equal(after.stats.rebuild, true);
  assert.equal(after.all.tokens, before.all.tokens);
  close(after.all.cost_usd, 10.85);
  assert.equal(after.all.unpriced_tokens, 0);
  const repeated = await processQueue({ ...options, pricing });
  assert.equal(repeated.stats.rebuild, false);
  assert.equal(repeated.stats.bytes_read, 0);
  assert.deepEqual(repeated.all, after.all);
});
