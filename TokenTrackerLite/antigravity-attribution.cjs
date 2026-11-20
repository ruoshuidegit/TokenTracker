"use strict";

const fs = require("node:fs/promises");
const { createHash } = require("node:crypto");

const VERSION = 5;
const INTERNAL_MODELS = new Set(["gemini-pro-orchestrator", "gemini-pro-orchestrator-neon", "gemini-flash-worker-agy"]);
const FIELDS = ["input_tokens", "output_tokens", "cached_input_tokens", "cache_creation_input_tokens",
  "reasoning_output_tokens", "total_tokens", "billable_total_tokens"];
const key = (row) => JSON.stringify([row.source, row.model, row.hour_start]);

function fingerprint(cursor) {
  return JSON.stringify([VERSION, cursor.transcriptHash, cursor.lastLine, cursor.baselineLine,
    cursor.extractorRevision, ...Object.keys(cursor).filter((name) => name.startsWith("db")).sort()
      .map((name) => [name, cursor[name]])]);
}

function selectedModel(content) {
  if (typeof content !== "string") return null;
  // Carbon / Argon / Neon 是编排模式的型号，不是可以丢弃的思考强度后缀。
  return content.match(/changed setting `Model Selection` from .*? to ([^`\n]+?)\.(?:\s+|$)/i)?.[1] || null;
}

function turnUsage(info) {
  const reasoning = info.reasoningOutput || 0;
  const output = info.textOutput > 0 ? info.textOutput : Math.max(0, (info.outputTokens || 0) - reasoning);
  const total = (info.uncachedInput || 0) + (info.cachedInput || 0) + output + reasoning;
  return { input_tokens: info.uncachedInput || 0, output_tokens: output,
    cached_input_tokens: info.cachedInput || 0, cache_creation_input_tokens: 0,
    reasoning_output_tokens: reasoning, total_tokens: total, billable_total_tokens: total };
}

async function checkDatabase(dbPath, cursor) {
  for (const [suffix, prefix] of [["", "db"], ["-wal", "dbWal"], ["-journal", "dbJournal"]]) {
    let stat;
    try { stat = await fs.stat(`${dbPath}${suffix}`); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    if ((stat?.ino || 0) !== cursor[`${prefix}Inode`] ||
        (stat?.mtimeMs || 0) !== cursor[`${prefix}MtimeMs`] ||
        (stat?.size || 0) !== cursor[`${prefix}Size`]) {
      throw new Error("反重力模型归属读取期间数据库发生变化");
    }
  }
}

async function fileAllocations(file, cursor, parsers) {
  const view = parsers.readAntigravityUsageView?.(file);
  const bytes = view ? view.bytes : await fs.readFile(file);
  if (createHash("sha256").update(bytes).digest("hex") !== cursor.transcriptHash) {
    throw new Error("反重力模型归属读取期间记录发生变化");
  }
  const dbPath = parsers.resolveAntigravityDbPath(file);
  let steps;
  if (view) {
    // 复用统计用量时读取的 SQLite 快照；之后追加的记录留给下轮采集。
    steps = view.steps;
  } else {
    await checkDatabase(dbPath, cursor);
    steps = parsers.readAntigravityConversationDb(dbPath);
    await checkDatabase(dbPath, cursor);
  }
  if (!steps) throw new Error("反重力模型归属元数据未完整读取");
  const lines = bytes.toString("utf8").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const allocations = new Map();
  let selection = null;
  for (let index = 0; index < Math.min(cursor.lastLine, lines.length); index += 1) {
    const event = JSON.parse(lines[index]);
    if (event.type === "USER_INPUT" || event.type === "USER_SETTINGS_CHANGE") {
      selection = selectedModel(event.content) || selection;
    }
    if (event.type !== "PLANNER_RESPONSE" || index < (cursor.baselineLine || 0)) continue;
    const info = steps.get(event.step_index);
    const model = info?.model?.trim().toLowerCase();
    // Neon 专用 backend 优先使用明确型号；通用 planner 依选择归属，worker 独立归 Hydrogen。
    if (!info?.hasUsageMetadata || !INTERNAL_MODELS.has(model)) continue;
    // 每次生成的型号可覆盖会话选择；未写入显示名的旧记录仍沿用选择事件。
    const generatedFamily = /^Orchestrator \((Carbon|Argon|Neon)\)$/i.exec(info.modelDisplayName || "")?.[1].toLowerCase();
    const family = generatedFamily || ["carbon", "argon", "neon", "hydrogen"].find((name) => selection?.toLowerCase().includes(name));
    if (model === "gemini-pro-orchestrator" && !["carbon", "argon", "neon"].includes(family)) continue;
    const timestamp = Date.parse(event.created_at);
    if (!Number.isFinite(timestamp)) continue;
    const hour = new Date(Math.floor(timestamp / 1_800_000) * 1_800_000).toISOString();
    const row = { source: "antigravity", model,
      family: model === "gemini-pro-orchestrator-neon" ? "neon" : family || "hydrogen",
      hour_start: hour, ...turnUsage(info) };
    const rowKey = JSON.stringify([key(row), row.family]);
    const previous = allocations.get(rowKey);
    if (previous) {
      for (const field of FIELDS) previous[field] += row[field];
    } else allocations.set(rowKey, row);
  }
  return [...allocations.values()];
}

async function attributeAntigravityUsage({ rows, cursors, cache, parsers }) {
  const files = {};
  const allocations = [];
  for (const [file, cursor] of Object.entries(cursors.files || {})) {
    if (cursor.usageSource !== "sqlite" || !Object.values(cursor.contributions || {})
      .some((contribution) => INTERNAL_MODELS.has(contribution.model))) continue;
    const stamp = fingerprint(cursor);
    const previous = cache?.version === VERSION && cache.files?.[file];
    const attributed = previous?.fingerprint === stamp && Array.isArray(previous.rows)
      ? previous.rows : await fileAllocations(file, cursor, parsers);
    files[file] = { fingerprint: stamp, rows: attributed };
    allocations.push(...attributed);
  }
  // 原始桶与游标保留在采集缓存中。每次从原始用量派生，重启或重复刷新不会再次扣减。
  const mapped = new Map(rows.map((row) => [key(row), { ...row }]));
  for (const allocation of allocations) {
    const original = mapped.get(key(allocation));
    if (!original) throw new Error("反重力模型归属缺少原始用量桶");
    const { family, ...usage } = allocation;
    const model = allocation.model === "gemini-flash-worker-agy" ? "gemini-4-hydrogen" : `gemini-4-${family}`;
    const moved = { ...usage, model, pricing_model: model };
    const movedKey = key(moved);
    const target = mapped.get(movedKey) || { ...moved, ...Object.fromEntries(FIELDS.map((field) => [field, 0])) };
    for (const field of FIELDS) {
      const amount = allocation[field];
      if (!Number.isSafeInteger(amount) || amount < 0 || original[field] < amount) {
        throw new Error("反重力模型归属与原始用量不一致");
      }
      original[field] -= amount;
      target[field] += amount;
    }
    mapped.set(movedKey, target);
  }
  return { rows: [...mapped.values()], cache: { version: VERSION, files } };
}

module.exports = { attributeAntigravityUsage, ATTRIBUTION_VERSION: VERSION };
