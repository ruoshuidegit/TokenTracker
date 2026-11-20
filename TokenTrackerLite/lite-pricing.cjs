"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { createRequire } = require("node:module");
const { compileFunction } = require("node:vm");
const defaultOverrides = require("./lite-pricing.json");

// 只补本次核实过的精确版本及装饰后缀，原始模型名仍用于数据库主键与展示。
function buildAliases(overrides) {
  const aliases = new Map(Object.entries(overrides.aliases || {}));
  for (const [model, efforts] of Object.entries(overrides.model_efforts || {})) {
    aliases.set(model, model);
    aliases.set(model.replaceAll("-", " "), model);
    for (const effort of efforts) aliases.set(`${model}-${effort}`, model);
  }
  for (const [model, value] of Object.entries(overrides.legacy_attribution || {})) aliases.set(model, value.model);
  for (const version of overrides.fable_versions || []) {
    const canonical = `claude-fable-${version}`;
    if (!Object.hasOwn(overrides.exact || {}, canonical)) throw new Error("Lite 版本别名缺少对应价格");
    for (const prefix of ["claude-fable-", "fable-"]) {
      for (const spelling of [version, version.replace("-", ".")]) {
        for (const suffix of overrides.fable_suffixes || [""]) aliases.set(`${prefix}${spelling}${suffix}`, canonical);
      }
    }
  }
  return aliases;
}

function createLitePricing({ upstreamPath = require.resolve("../src/lib/pricing"), overrides = defaultOverrides } = {}) {
  const source = fs.readFileSync(upstreamPath, "utf8");
  const upstreamRequire = createRequire(upstreamPath);
  const originalCurated = upstreamRequire("./curated-overrides.json");
  const configuration = structuredClone(overrides);
  const longContextModels = new Set(configuration.long_context_models || []);
  // 补齐新型号的上下文标记，长上下文与 Fast / Ultrafast 仍统一走原公式。
  // 只扩展本实例的私有函数；上游原生识别的型号不会再叠加一遍。
  const contextExtension = `
const liteOriginalRowSubsetContext = rowSubsetContext;
rowSubsetContext = function(row, reasoningIncludedInOutput) {
  const context = liteOriginalRowSubsetContext(row, reasoningIncludedInOutput);
  context.usesOpenAILongContextTier ||= liteLongContextModels.has(String(row?.model || "").toLowerCase());
  return context;
};
`;
  // 单独加载原公式，并给它一份内存价目表。既不改上游文件，也不污染共享
  // require 缓存；原版 pricing 及测试注入的实例都保留自己的负缓存和修订号。
  const changes = (configuration.rate_changes || []).map((change) => {
    const timestamp = Date.parse(change.effective_from);
    if (!Number.isFinite(timestamp)) throw new Error("模型调价生效日期无效");
    return { ...change, timestamp };
  }).sort((left, right) => left.timestamp - right.timestamp);
  const editions = new Map();
  const pricingAt = (value) => {
    const timestamp = value == null ? Date.now() : Date.parse(value);
    if (!Number.isFinite(timestamp)) throw new Error("用量计价日期无效");
    const edition = changes.filter((change) => change.timestamp <= timestamp).length;
    if (!editions.has(edition)) {
      const curated = structuredClone(originalCurated);
      Object.assign(curated.exact, configuration.exact);
      for (const [source, values] of Object.entries(configuration.source_exact || {})) {
        curated.source_exact ||= {};
        curated.source_exact[source] = { ...curated.source_exact[source], ...values };
      }
      for (const change of changes.slice(0, edition)) Object.assign(curated.exact, change.exact);
      const isolatedModule = { exports: {} };
      const isolatedRequire = (specifier) => specifier === "./curated-overrides.json" ? curated : upstreamRequire(specifier);
      isolatedRequire.resolve = upstreamRequire.resolve;
      compileFunction(source + contextExtension,
        ["require", "module", "exports", "__dirname", "__filename", "liteLongContextModels"], { filename: upstreamPath })(
        isolatedRequire, isolatedModule, isolatedModule.exports, path.dirname(upstreamPath), upstreamPath, longContextModels,
      );
      editions.set(edition, isolatedModule.exports);
    }
    return editions.get(edition);
  };
  const aliases = buildAliases(configuration);
  const normalizeModel = (model) => {
    if (typeof model !== "string") return model;
    const lower = model.trim().toLowerCase();
    const alias = aliases.get(lower);
    if (alias) return alias;
    // 未核实的新版本或计费档位不能被上游的包含匹配误套为现有版本。
    if (/^(?:claude-)?fable-\d+[.-]\d+(?:-|$)/.test(lower)) return "__lite_unpriced_fable_variant__";
    if (/^gemini-4-(carbon|hydrogen|neon)-/.test(lower)) return "__lite_unpriced_gemini_variant__";
    return model;
  };
  const resolveRowModel = (row) => {
    const legacy = typeof row?.model === "string" && configuration.legacy_attribution?.[row.model.trim().toLowerCase()];
    if (legacy && (!row.pricing_model || row.pricing_model === legacy.backend)) return legacy.model;
    return normalizeModel(row?.pricing_model || row?.model);
  };
  // 价格或公式变化会使旧汇总失效，只重读小型统计队列，不接触原始会话。
  const policy = createHash("sha256").update(source).update(JSON.stringify(originalCurated))
    .update(JSON.stringify(configuration)).update(fs.readFileSync(__filename));
  for (const filename of ["matcher.js", "seed-snapshot.json"]) {
    policy.update(fs.readFileSync(path.join(path.dirname(upstreamPath), filename)));
  }

  return Object.freeze({
    policyVersion: `lite-pricing-${policy.digest("hex")}`,
    resolveRowModel,
    getModelPricingInfo(model, options) {
      return pricingAt(options?.hourStart).getModelPricingInfo(normalizeModel(model), options);
    },
    computeRowCost(row) {
      const model = resolveRowModel(row);
      let priced = model === row?.model ? row : { ...row, model };
      // OMP 的部分 Gemini 记录中，output 已含 reasoning；原始 total 校验和
      // 能证明这一点时只计费一次，展示用的原始计数保持不变。
      const parts = ["input_tokens", "cached_input_tokens", "cache_creation_input_tokens", "output_tokens"]
        .reduce((sum, field) => sum + Number(row[field] || 0), 0);
      if (row.source === "omp" && /^gemini-(?:4-(carbon|argon|hydrogen|neon)|3\.8-flash)$/.test(model) &&
          row.reasoning_output_tokens > 0 && row.output_tokens >= row.reasoning_output_tokens &&
          row.total_tokens === parts) priced = { ...priced, reasoning_output_tokens: 0 };
      return pricingAt(row.hour_start).computeRowCost(priced);
    },
  });
}

let defaultPricing;
function getDefaultPricing() {
  defaultPricing ||= createLitePricing();
  return defaultPricing;
}

module.exports = { createLitePricing, getDefaultPricing };
