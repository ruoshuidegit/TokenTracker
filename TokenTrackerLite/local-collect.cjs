"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { openLock, writeFileAtomic } = require("../src/lib/fs");
const { normalizeRow } = require("./queue-store.cjs");

const SOURCES = ["antigravity", "omp"];
const LABELS = { antigravity: "反重力", omp: "OMP（含 Orca）" };
const ROW_FIELDS = ["source", "model", "hour_start", "input_tokens", "output_tokens", "cached_input_tokens",
  "cache_creation_input_tokens", "reasoning_output_tokens", "total_tokens", "billable_total_tokens"];
const key = (row) => JSON.stringify([row.source, row.model, row.hour_start]);

function usageRow(value, source) {
  const row = normalizeRow(value);
  if (!row || row.source !== source) throw new Error("本地采集快照格式无效");
  // 缓存仅保留用量字段，原始会话正文不会写入 Lite 数据目录。
  return { ...Object.fromEntries(ROW_FIELDS.map((field) => [field, row[field]])),
    ...(row.pricing_model ? { pricing_model: row.pricing_model } : {}) };
}

async function loadState(file, source) {
  let raw;
  try { raw = await fs.readFile(file, "utf8"); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  const state = JSON.parse(raw);
  if (state.schema_version !== 1 || !state.cursors || typeof state.cursors !== "object" ||
      Array.isArray(state.cursors) || !Array.isArray(state.rows) || !Number.isFinite(Date.parse(state.updated_at))) {
    throw new Error("本地采集缓存格式无效");
  }
  state.rows = state.rows.map((row) => usageRow(row, source));
  if (state.attributed_rows !== undefined) {
    if (!Array.isArray(state.attributed_rows)) throw new Error("本地模型归属缓存格式无效");
    state.attributed_rows = state.attributed_rows.map((row) => usageRow(row, source));
  }
  return state;
}

async function isDirectory(directory) {
  try { return (await fs.stat(directory)).isDirectory(); }
  catch (error) { if (error.code === "ENOENT" || error.code === "ENOTDIR") return false; throw error; }
}

async function antigravityFiles(parsers, env, cursors) {
  const home = env.HOME || os.homedir();
  const geminiHome = env.GEMINI_HOME || path.join(home, ".gemini");
  const { resolveInstallPaths } = require("../src/lib/install-resolver");
  const installs = resolveInstallPaths({ nativeValue: geminiHome, wslDir: ".gemini" }, env);
  const roots = [...new Set(Object.values(installs).filter(Boolean))];
  const known = new Set(Object.keys(cursors.files || {}));
  const inventories = [];
  for (const root of roots) {
    inventories.push(await parsers.listAntigravityTranscriptsWithStatus(root, known));
  }
  const available = (await Promise.all(roots.flatMap((root) => ["antigravity", "antigravity-ide", "antigravity-cli"]
    .map((name) => isDirectory(path.join(root, name, "brain")))))).some(Boolean);
  return { files: [...new Set(inventories.flatMap((item) => item.files))],
    complete: available && inventories.every((item) => item.complete), available };
}

async function collectLocalUsage({ stateDir, env = process.env, parsers } = {}) {
  if (!stateDir) throw new Error("缺少本地采集缓存目录");
  const directory = path.resolve(stateDir);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const warnings = [];
  const states = new Map();
  const lock = await openLock(path.join(directory, "collector.lock"), { quietIfLocked: true });
  try {
    for (const source of SOURCES) {
      const file = path.join(directory, `${source}.json`);
      let previous;
      try { previous = await loadState(file, source); }
      catch { warnings.push(`${LABELS[source]}采集缓存无法读取，保留已显示的统计`); continue; }
      if (previous) states.set(source, previous);
      if (!lock) continue;
      let temporary;
      try {
        parsers ||= require("./antigravity-read-view.cjs").createAntigravityReadView();
        const cursors = structuredClone(previous?.cursors || {});
        temporary = await fs.mkdtemp(path.join(directory, ".collect-"));
        const queuePath = path.join(temporary, "queue.jsonl");
        if (source === "antigravity") {
          const inventory = await antigravityFiles(parsers, env, cursors);
          if (!inventory.available) continue; // 整个安装目录暂缺时保留原缓存与历史。
          const { ATTRIBUTION_VERSION } = require("./antigravity-attribution.cjs");
          await parsers.parseAntigravityIncremental({ sessionFiles: inventory.files, cursors, queuePath,
            inventoryComplete: inventory.complete, source,
            refreshUsageView: previous?.model_attribution?.version !== ATTRIBUTION_VERSION });
          if (!inventory.complete || Object.values(cursors.files || {}).some((item) => item.dbReadOk === false)) {
            // 部分会话暂锁时不能把不完整总量提升为权威层，尤其首次回填会覆盖旧队列的完整历史。
            throw new Error("反重力记录未完整读取");
          }
        } else {
          const agentDir = parsers.resolveOmpAgentDir(env);
          const sessionsDir = agentDir && path.join(agentDir, "sessions");
          if (!sessionsDir || !await isDirectory(sessionsDir)) continue;
          // 原解析器的发现函数会略过不可读目录；权威回填前先确认目录清单完整。
          await fs.readdir(sessionsDir, { recursive: true });
          const sessionFiles = parsers.resolveOmpSessionFiles(env);
          const subagentFiles = parsers.resolveOmpSubagentFiles(env);
          for (const file of [...sessionFiles, ...subagentFiles]) {
            const handle = await fs.open(file, "r");
            await handle.close();
          }
          await parsers.parseOmpIncremental({ sessionFiles, subagentFiles, cursors, queuePath, env });
        }
        let output = "";
        try { output = await fs.readFile(queuePath, "utf8"); }
        catch (error) { if (error.code !== "ENOENT") throw error; }
        if (output && !output.endsWith("\n")) throw new Error("采集快照未写完");
        const rows = new Map((previous?.rows || []).map((row) => [key(row), row]));
        for (const line of output.split("\n").filter(Boolean)) {
          const row = usageRow(JSON.parse(line), source);
          rows.set(key(row), row); // parser 输出累计桶快照，减少或归零同样必须覆盖。
        }
        if (!previous && rows.size === 0) continue; // 空安装不能擦除汇总库中仍保留的采集历史。
        const state = { schema_version: 1, cursors, rows: [...rows.values()], updated_at: new Date().toISOString() };
        if (source === "antigravity") {
          const attributed = await require("./antigravity-attribution.cjs").attributeAntigravityUsage({
            rows: state.rows, cursors, cache: previous?.model_attribution, parsers });
          state.attributed_rows = attributed.rows;
          state.model_attribution = attributed.cache;
        }
        // 游标和用量同一次原子提交，意外退出不会只前进游标而丢失用量。
        await writeFileAtomic(file, JSON.stringify(state) + "\n", { mode: 0o600 });
        states.set(source, state);
      } catch {
        warnings.push(`${LABELS[source]}本地采集未完成，保留上次结果并稍后重试`);
      } finally {
        if (temporary) await fs.rm(temporary, { recursive: true, force: true });
      }
    }
    if (!lock) warnings.push("本地采集正在运行，显示上次已完成的结果");
  } finally {
    if (lock) await lock.release();
  }
  return { rows: [...states.values()].flatMap((state) => state.attributed_rows || state.rows), warnings,
    updatedAt: [...states.values()].map((state) => state.updated_at).sort().at(-1) || null,
    // 缓存无法读取的来源不提交空结果，避免擦除汇总库中上次已确认的用量。
    sources: [...states.keys()] };
}

module.exports = { collectLocalUsage };
