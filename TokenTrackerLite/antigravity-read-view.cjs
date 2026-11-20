"use strict";

const fs = require("node:fs");
const promises = require("node:fs/promises");
const path = require("node:path");
const { createRequire } = require("node:module");
const { compileFunction } = require("node:vm");

function createAntigravityReadView() {
  const filename = require.resolve("../src/lib/rollout");
  const upstreamRequire = createRequire(filename);
  const reader = upstreamRequire("./sqlite-reader");
  const transcripts = new Map();
  const metadata = new Map();
  const fileKey = (file) => path.resolve(String(file));
  const isTranscript = (file) => typeof file === "string" && path.basename(file) === "transcript.jsonl" &&
    path.basename(path.dirname(file)) === "logs" && path.basename(path.dirname(path.dirname(file))) === ".system_generated";

  // 同一轮的用量和模型归属必须读取同一份数据；内存读视图不会写入会话正文。
  const readFile = async (file, options) => {
    if (!isTranscript(file)) return promises.readFile(file, options);
    const key = fileKey(file);
    if (!transcripts.has(key)) transcripts.set(key, await promises.readFile(file));
    const bytes = transcripts.get(key);
    const encoding = typeof options === "string" ? options : options?.encoding;
    return encoding ? bytes.toString(encoding) : Buffer.from(bytes);
  };
  const readSqliteJsonRows = (file, sql, options) => {
    if (sql !== "SELECT idx, quote(data) as hex FROM gen_metadata ORDER BY idx") {
      return reader.readSqliteJsonRows(file, sql, options);
    }
    const key = fileKey(file);
    if (!metadata.has(key)) metadata.set(key, reader.readSqliteJsonRows(file, sql, options));
    return metadata.get(key);
  };
  const isolatedModule = { exports: {} };
  const isolatedRequire = (specifier) => {
    if (specifier === "node:fs/promises") return { ...promises, readFile };
    if (specifier === "./sqlite-reader") return { ...reader, readSqliteJsonRows };
    return upstreamRequire(specifier);
  };
  isolatedRequire.resolve = upstreamRequire.resolve;
  compileFunction(fs.readFileSync(filename, "utf8"), ["require", "module", "exports", "__dirname", "__filename"],
    { filename })(isolatedRequire, isolatedModule, isolatedModule.exports, path.dirname(filename), filename);
  const parsers = isolatedModule.exports;
  return {
    ...parsers,
    async parseAntigravityIncremental(options) {
      // 活跃日志可能恰在单次读取中追加。仅对此一致性冲突重新取读视图，
      // 每次从已提交游标开始；权限、损坏或 SQLite 读取错误仍直接报错。
      for (let attempt = 0; attempt < 3; attempt += 1) {
        transcripts.clear();
        metadata.clear();
        const cursors = structuredClone(options.cursors);
        if (options.refreshUsageView) {
          // 归属算法升级时，未改动的会话也要重读元数据，供统计与归属共用。
          // 上游会完成贡献重算并恢复真实 extractorRevision，仅本轮私有游标失效。
          for (const cursor of Object.values(cursors.files || {})) cursor.extractorRevision = null;
        }
        try {
          const result = await parsers.parseAntigravityIncremental({ ...options, cursors });
          for (const field of Object.keys(options.cursors)) delete options.cursors[field];
          Object.assign(options.cursors, cursors);
          return result;
        } catch (error) {
          if (attempt === 2 || !error.message?.startsWith("Antigravity transcript changed while being read:")) throw error;
        }
      }
    },
    readAntigravityUsageView(file) {
      const dbPath = parsers.resolveAntigravityDbPath(file);
      if (!transcripts.has(fileKey(file)) || !dbPath || !metadata.has(fileKey(dbPath))) return null;
      return { bytes: transcripts.get(fileKey(file)), steps: parsers.readAntigravityConversationDb(dbPath) };
    },
  };
}

module.exports = { createAntigravityReadView };
