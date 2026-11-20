"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const { test } = require("node:test");
const rollout = require("../src/lib/rollout");
const { collectLocalUsage } = require("./local-collect.cjs");
const { createAntigravityReadView } = require("./antigravity-read-view.cjs");

const HOUR = "2026-11-12T12:00:00.000Z";
const lines = (values) => values.map((value) => JSON.stringify(value)).join("\n") + "\n";
const timestamp = (minute) => `2026-11-12T12:${String(minute).padStart(2, "0")}:00Z`;
const selection = (step, model) => ({ type: "USER_SETTINGS_CHANGE", step_index: step,
  created_at: timestamp(step), content: `changed setting \`Model Selection\` from None to ${model}.` });
const planner = (step) => ({ type: "PLANNER_RESPONSE", step_index: step,
  created_at: timestamp(step), content: "fixture-conversation-body-not-for-cache" });

function vi(value) {
  const bytes = [];
  do { const byte = value & 0x7f; value = Math.floor(value / 128); bytes.push(byte | (value ? 0x80 : 0)); } while (value);
  return Buffer.from(bytes);
}
const field = (number, value) => typeof value === "number"
  ? Buffer.concat([vi(number * 8), vi(value)])
  : Buffer.concat([vi(number * 8 + 2), vi(Buffer.byteLength(value)), Buffer.from(value)]);
function proto(model, step, input, cache, output, reasoning, displayName) {
  return field(1, Buffer.concat([field(19, model), ...(displayName ? [field(21, displayName)] : []), field(4, Buffer.concat([
    field(2, input), field(5, cache), field(3, output), field(9, output - reasoning), field(10, reasoning),
  ])), field(20, Buffer.concat([field(1, "last_step_index"), field(2, String(step - 1))]))]));
}

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "lite-carbon-attribution-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const gemini = path.join(root, ".gemini");
  const transcript = path.join(gemini, "antigravity/brain/session-a/.system_generated/logs/transcript.jsonl");
  const dbPath = path.join(gemini, "antigravity/conversations/session-a.db");
  await fs.mkdir(path.dirname(transcript), { recursive: true });
  await fs.mkdir(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)");
  const insert = db.prepare("INSERT INTO gen_metadata VALUES (?, ?)");
  insert.run(1, proto("gemini-pro-orchestrator", 1, 100, 900, 70, 20));
  insert.run(2, proto("gemini-flash-worker-agy", 2, 10, 90, 20, 5));
  insert.run(4, proto("gemini-pro-orchestrator", 4, 20, 180, 30, 10));
  insert.run(5, proto("gemini-flash-worker-agy", 5, 3, 27, 10, 2));
  insert.run(7, proto("gemini-4-carbon", 7, 30, 270, 40, 5));
  db.close();
  await fs.writeFile(transcript, lines([
    selection(0, "Orchestrator (Carbon)"), planner(1), planner(2),
    selection(3, "Orchestrator (Argon)"), planner(4), planner(5),
    selection(6, "Gemini 4 Carbon (High)"), planner(7),
  ]));
  const stateDir = path.join(root, "state");
  const env = { HOME: root, GEMINI_HOME: gemini, TOKENTRACKER_OMP_AGENT_DIR: path.join(root, "no-omp") };
  const statePath = path.join(stateDir, "antigravity.json");
  return { transcript, dbPath, statePath, collect: (parsers) => collectLocalUsage({ stateDir, env, parsers }),
    saved: async () => JSON.parse(await fs.readFile(statePath, "utf8")) };
}
const tokens = (result, model) => result.rows.find((row) => row.model === model && row.hour_start === HOUR)?.total_tokens;
const total = (rows, field = "total_tokens") => rows.reduce((sum, row) => sum + (row[field] || 0), 0);

test("无设置事件的 planner 按逐次生成显示名补价，worker 独立统计", async (t) => {
  const f = await fixture(t);
  await fs.writeFile(f.transcript, lines([planner(1), planner(2), planner(4), planner(5), planner(7)]));
  const previous = await f.collect();
  assert.equal(tokens(previous, "gemini-pro-orchestrator"), 1300);
  const db = new DatabaseSync(f.dbPath);
  const update = db.prepare("UPDATE gen_metadata SET data = ? WHERE idx = ?");
  update.run(proto("gemini-pro-orchestrator", 1, 100, 900, 70, 20, "Orchestrator (Carbon)"), 1);
  update.run(proto("gemini-pro-orchestrator", 4, 20, 180, 30, 10, "Orchestrator (Argon)"), 4);
  db.close();
  const migrated = await f.collect();
  assert.deepEqual(migrated.warnings, []);
  assert.equal(tokens(migrated, "gemini-pro-orchestrator"), 0);
  assert.equal(tokens(migrated, "gemini-4-carbon"), 1410);
  assert.equal(tokens(migrated, "gemini-4-argon"), 230);
  assert.equal(tokens(migrated, "gemini-4-hydrogen"), 160);
  assert.deepEqual((await f.collect()).rows, migrated.rows);
});

test("同半小时切换 Carbon 与 Argon，planner 分别归属，Hydrogen worker 独立合并", async (t) => {
  const f = await fixture(t);
  const first = await f.collect();
  assert.deepEqual(first.warnings, []);
  assert.equal(tokens(first, "gemini-4-carbon"), 1410);
  assert.equal(tokens(first, "gemini-4-argon"), 230);
  assert.equal(tokens(first, "gemini-4-hydrogen"), 160);
  assert.equal(tokens(first, "gemini-pro-orchestrator"), 0);
  assert.equal(tokens(first, "gemini-flash-worker-agy"), 0);
  assert.equal(total(first.rows.filter((row) => row.model.includes("carbon"))), 1410);
  assert.equal(total(first.rows.filter((row) => row.model.includes("argon"))), 230);
  assert.ok(first.rows.filter((row) => row.pricing_model).every((row) => row.model === row.pricing_model));
  const saved = await f.saved();
  for (const field of ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]) {
    assert.equal(total(saved.rows, field), total(saved.attributed_rows, field));
  }
  assert.equal(JSON.stringify(saved).includes("fixture-conversation-body-not-for-cache"), false);
  assert.equal(JSON.stringify(saved).includes("changed setting"), false);
  const { processQueue } = require("./queue-store.cjs");
  const snapshot = await processQueue({ queuePath: path.join(path.dirname(f.statePath), "no-queue.jsonl"),
    databasePath: path.join(path.dirname(f.statePath), "usage.sqlite"), collection: first,
    now: new Date("2026-11-15T00:00:00Z") });
  for (const [model, cost] of [["gemini-4-carbon", 0.001477], ["gemini-4-argon", 0.000358],
    ["gemini-4-hydrogen", 0.000253275]]) {
    const summary = snapshot.models.find((row) => row.model === model);
    assert.ok(Math.abs(summary.cost_usd - cost) < 1e-12, model);
    assert.equal(summary.unpriced_tokens, 0);
  }
});

test("Neon 专用 backend 与通用 planner 独立归 Neon，旧 v3 缓存回填且 Hydrogen 不混入", async (t) => {
  const f = await fixture(t);
  await f.collect();
  const db = new DatabaseSync(f.dbPath);
  const insert = db.prepare("INSERT INTO gen_metadata VALUES (?, ?)");
  insert.run(9, proto("gemini-pro-orchestrator-neon", 9, 5, 45, 10, 2));
  insert.run(10, proto("gemini-flash-worker-agy", 10, 3, 27, 10, 2));
  insert.run(12, proto("gemini-pro-orchestrator", 12, 7, 63, 20, 5));
  insert.run(13, proto("gemini-4-neon", 13, 11, 99, 30, 5));
  db.close();
  await fs.appendFile(f.transcript, lines([
    selection(8, "Orchestrator (Argon)"), planner(9), planner(10),
    selection(11, "Orchestrator (Neon)"), planner(12), planner(13),
  ]));
  const current = await f.collect();
  assert.deepEqual(current.warnings, []);
  assert.equal(tokens(current, "gemini-4-neon"), 290);
  assert.equal(tokens(current, "gemini-4-carbon"), 1410);
  assert.equal(tokens(current, "gemini-4-argon"), 230);
  assert.equal(tokens(current, "gemini-4-hydrogen"), 200);

  const saved = await f.saved();
  const fields = ["input_tokens", "output_tokens", "cached_input_tokens", "cache_creation_input_tokens",
    "reasoning_output_tokens", "total_tokens", "billable_total_tokens"];
  saved.model_attribution.version = 3;
  for (const cache of Object.values(saved.model_attribution.files)) {
    const stamp = JSON.parse(cache.fingerprint);
    stamp[0] = 3;
    cache.fingerprint = JSON.stringify(stamp);
    cache.rows = cache.rows.filter((allocation) => {
      if (allocation.family !== "neon" || allocation.model === "gemini-flash-worker-agy") return true;
      const raw = saved.attributed_rows.find((row) => row.model === allocation.model);
      const neon = saved.attributed_rows.find((row) => row.model === "gemini-4-neon");
      for (const field of fields) { raw[field] += allocation[field]; neon[field] -= allocation[field]; }
      return false;
    });
  }
  await fs.writeFile(f.statePath, JSON.stringify(saved));
  const migrated = await f.collect();
  assert.deepEqual(migrated.warnings, []);
  assert.deepEqual(migrated.rows, current.rows);
  assert.equal((await f.saved()).model_attribution.version, 5);
  assert.deepEqual((await f.collect()).rows, current.rows);
  for (const field of fields) assert.equal(total(saved.rows, field), total(migrated.rows, field), field);

  const { processQueue } = require("./queue-store.cjs");
  const snapshot = await processQueue({ queuePath: path.join(path.dirname(f.statePath), "no-queue.jsonl"),
    databasePath: path.join(path.dirname(f.statePath), "usage.sqlite"), collection: migrated,
    now: new Date("2026-11-20T00:00:00Z") });
  const neon = snapshot.models.find((row) => row.model === "gemini-4-neon");
  assert.equal(neon.tokens, 290);
  assert.equal(neon.unpriced_tokens, 0);
  assert.ok(Math.abs(neon.cost_usd - 0.00100005) < 1e-12);

  const content = await fs.readFile(f.transcript, "utf8");
  await fs.writeFile(f.transcript, lines(content.trim().split("\n").map(JSON.parse)
    .filter((event) => event.type !== "USER_SETTINGS_CHANGE")));
  const withoutSelection = await f.collect();
  assert.deepEqual(withoutSelection.warnings, []);
  assert.equal(tokens(withoutSelection, "gemini-4-neon"), 200);
  assert.equal(tokens(withoutSelection, "gemini-4-hydrogen"), 200);
  assert.equal(tokens(withoutSelection, "gemini-pro-orchestrator"), 1390);
});

test("旧缓存原地回填归属，刷新和新进程读取均不重复扣减，未变化时复用归属缓存", async (t) => {
  const f = await fixture(t);
  await f.collect();
  const legacy = await f.saved();
  delete legacy.attributed_rows;
  delete legacy.model_attribution;
  await fs.writeFile(f.statePath, JSON.stringify(legacy));
  let reads = 0;
  const parsers = { ...rollout, readAntigravityConversationDb(file) {
    reads += 1; return rollout.readAntigravityConversationDb(file);
  } };
  const migrated = await f.collect(parsers);
  assert.equal(reads, 1);
  assert.equal(tokens(migrated, "gemini-4-carbon"), 1410);
  assert.equal(tokens(migrated, "gemini-4-argon"), 230);
  assert.equal(tokens(migrated, "gemini-4-hydrogen"), 160);
  const repeated = await f.collect(parsers);
  assert.equal(reads, 1);
  assert.deepEqual(repeated.rows, migrated.rows);
  const { spawnSync } = require("node:child_process");
  const saved = await f.saved();
  const child = spawnSync(process.execPath, ["--no-warnings", "-e",
    "require(process.argv[1]).collectLocalUsage(JSON.parse(process.argv[2])).then(v=>process.stdout.write(JSON.stringify(v)))",
    path.join(__dirname, "local-collect.cjs"), JSON.stringify({ stateDir: path.dirname(f.statePath),
      env: { HOME: path.dirname(path.dirname(f.statePath)), GEMINI_HOME: path.dirname(path.dirname(path.dirname(f.dbPath))),
        TOKENTRACKER_OMP_AGENT_DIR: path.join(path.dirname(f.statePath), "no-omp") } })], { encoding: "utf8" });
  assert.equal(child.status, 0);
  assert.deepEqual(JSON.parse(child.stdout).rows, repeated.rows);
  assert.deepEqual((await f.saved()).rows, saved.rows);
});

test("元数据晚到、失败重试与末行尚未写完均保留完整旧快照，成功后只迁移新增用量", async (t) => {
  const f = await fixture(t);
  const original = await f.collect();
  await fs.appendFile(f.transcript, lines([selection(8, "Orchestrator (Carbon)"), planner(9)]));
  const db = new DatabaseSync(f.dbPath);
  db.prepare("INSERT INTO gen_metadata VALUES (?, ?)").run(9, proto("gemini-pro-orchestrator", 9, 5, 45, 10, 2));
  db.close();
  const saved = await fs.readFile(f.statePath, "utf8");
  const failed = await f.collect({ ...rollout, readAntigravityConversationDb: () => null });
  assert.deepEqual(failed.rows, original.rows);
  assert.equal(failed.warnings.length, 1);
  assert.equal(await fs.readFile(f.statePath, "utf8"), saved);
  const recovered = await f.collect();
  assert.deepEqual(recovered.warnings, []);
  assert.equal(tokens(recovered, "gemini-4-carbon"), 1470);
  assert.equal(tokens(recovered, "gemini-4-argon"), 230);
  assert.equal(tokens(recovered, "gemini-4-hydrogen"), 160);
  await fs.appendFile(f.transcript, '{"type":"PLANNER_RESPONSE"');
  assert.deepEqual((await f.collect()).rows, recovered.rows);
});

test("旧 v2 编排缓存升级后按实际子模型重分，Hydrogen 不再混入 Carbon 或 Argon", async (t) => {
  const f = await fixture(t);
  const first = await f.collect();
  const saved = await f.saved();
  saved.model_attribution.version = 2;
  const oldRows = new Map(saved.rows.map((row) => [row.model, { ...row }]));
  for (const value of Object.values(saved.model_attribution.files)) {
    const stamp = JSON.parse(value.fingerprint);
    stamp[0] = 2;
    value.fingerprint = JSON.stringify(stamp);
    for (const { family, ...row } of value.rows) {
      const original = oldRows.get(row.model);
      for (const field of ["input_tokens", "cached_input_tokens", "cache_creation_input_tokens", "output_tokens",
        "reasoning_output_tokens", "total_tokens", "billable_total_tokens"]) original[field] -= row[field];
      oldRows.set(`${row.model}-${family}`, { ...row, model: `${row.model}-${family}`, pricing_model: row.model });
    }
  }
  saved.attributed_rows = [...oldRows.values()];
  await fs.writeFile(f.statePath, JSON.stringify(saved));
  let reads = 0;
  const upgraded = await f.collect({ ...rollout, readAntigravityConversationDb(file) {
    reads += 1; return rollout.readAntigravityConversationDb(file);
  } });
  assert.deepEqual(upgraded.warnings, []);
  assert.equal(reads, 1);
  assert.deepEqual(upgraded.rows, first.rows);
  assert.equal(tokens(upgraded, "gemini-4-carbon"), 1410);
  assert.equal(tokens(upgraded, "gemini-4-argon"), 230);
  assert.equal(tokens(upgraded, "gemini-4-hydrogen"), 160);
});

test("独立 Hydrogen 或缺少模型选择记录的 worker 都归 Hydrogen，未知 planner 不猜测型号", async (t) => {
  const f = await fixture(t);
  const content = await fs.readFile(f.transcript, "utf8");
  await fs.writeFile(f.transcript, lines(content.trim().split("\n").map(JSON.parse)
    .filter((event) => event.type !== "USER_SETTINGS_CHANGE")));
  const first = await f.collect();
  assert.deepEqual(first.warnings, []);
  assert.equal(tokens(first, "gemini-4-hydrogen"), 160);
  assert.equal(tokens(first, "gemini-pro-orchestrator"), 1300);
  assert.equal(tokens(first, "gemini-4-carbon"), 340);
  await fs.writeFile(f.transcript, lines([selection(0, "Gemini 4 Hydrogen (Medium)"),
    ...content.trim().split("\n").map(JSON.parse).filter((event) => event.type !== "USER_SETTINGS_CHANGE")]));
  const second = await f.collect();
  assert.deepEqual(second.warnings, []);
  assert.equal(tokens(second, "gemini-4-hydrogen"), 160);
  assert.equal(tokens(second, "gemini-pro-orchestrator"), 1300);
});

test("统计后日志追加且 SQLite 更新时，归属使用同一轮读视图，下轮补齐且不重计", async (t) => {
  const f = await fixture(t);
  const view = createAntigravityReadView();
  let changed = false;
  const parsers = { ...view, async parseAntigravityIncremental(options) {
    const result = await view.parseAntigravityIncremental(options);
    if (!changed) {
      changed = true;
      const db = new DatabaseSync(f.dbPath);
      db.prepare("UPDATE gen_metadata SET data = ? WHERE idx = 1")
        .run(proto("gemini-pro-orchestrator", 1, 200, 900, 70, 20));
      db.prepare("INSERT INTO gen_metadata VALUES (?, ?)")
        .run(9, proto("gemini-pro-orchestrator", 9, 5, 45, 10, 2));
      db.close();
      await fs.appendFile(f.transcript, lines([selection(8, "Orchestrator (Carbon)"), planner(9)]));
    }
    return result;
  } };
  const first = await f.collect(parsers);
  assert.deepEqual(first.warnings, []);
  assert.equal(tokens(first, "gemini-4-carbon"), 1410);
  assert.equal(tokens(first, "gemini-4-argon"), 230);
  assert.equal(tokens(first, "gemini-4-hydrogen"), 160);
  const second = await f.collect(parsers);
  assert.deepEqual(second.warnings, []);
  assert.equal(tokens(second, "gemini-4-carbon"), 1570);
  assert.equal(tokens(second, "gemini-4-argon"), 230);
  assert.equal(tokens(second, "gemini-4-hydrogen"), 160);
  assert.deepEqual((await f.collect(parsers)).rows, second.rows);
});

test("未改动的旧 v3 会话升级时也取得共享读视图，并发追加不会导致迁移警告", async (t) => {
  const f = await fixture(t);
  const baseline = await f.collect();
  const saved = await f.saved();
  saved.model_attribution.version = 3;
  for (const cache of Object.values(saved.model_attribution.files)) {
    const stamp = JSON.parse(cache.fingerprint);
    stamp[0] = 3;
    cache.fingerprint = JSON.stringify(stamp);
  }
  await fs.writeFile(f.statePath, JSON.stringify(saved));
  const view = createAntigravityReadView();
  let changed = false;
  const parsers = { ...view, async parseAntigravityIncremental(options) {
    if (!changed) assert.equal(options.refreshUsageView, true);
    const result = await view.parseAntigravityIncremental(options);
    if (!changed) {
      changed = true;
      const db = new DatabaseSync(f.dbPath);
      db.prepare("INSERT INTO gen_metadata VALUES (?, ?)")
        .run(9, proto("gemini-pro-orchestrator-neon", 9, 5, 45, 10, 2));
      db.close();
      await fs.appendFile(f.transcript, lines([selection(8, "Orchestrator (Neon)"), planner(9)]));
    }
    return result;
  } };
  const first = await f.collect(parsers);
  assert.deepEqual(first.warnings, []);
  assert.deepEqual(first.rows, baseline.rows);
  const second = await f.collect(parsers);
  assert.deepEqual(second.warnings, []);
  assert.equal(tokens(second, "gemini-4-neon"), 60);
  assert.equal(tokens(second, "gemini-4-hydrogen"), 160);
  assert.equal(tokens(second, "gemini-4-carbon"), 1410);
  assert.equal(tokens(second, "gemini-4-argon"), 230);
  assert.deepEqual((await f.collect(parsers)).rows, second.rows);
});

test("日志恰在读取中追加时重新获取完整读视图，旧游标不前进且新增用量只计一次", async (t) => {
  const f = await fixture(t);
  const originalRead = fs.readFile;
  let changed = false;
  t.mock.method(fs, "readFile", async (file, ...args) => {
    const bytes = await originalRead(file, ...args);
    if (file === f.transcript && !changed) {
      changed = true;
      const db = new DatabaseSync(f.dbPath);
      db.prepare("INSERT INTO gen_metadata VALUES (?, ?)")
        .run(9, proto("gemini-pro-orchestrator", 9, 5, 45, 10, 2));
      db.close();
      await fs.appendFile(f.transcript, lines([selection(8, "Orchestrator (Carbon)"), planner(9)]));
    }
    return bytes;
  });
  const first = await f.collect();
  assert.equal(changed, true);
  assert.deepEqual(first.warnings, []);
  assert.equal(tokens(first, "gemini-4-carbon"), 1470);
  assert.equal(tokens(first, "gemini-4-argon"), 230);
  assert.equal(tokens(first, "gemini-4-hydrogen"), 160);
  assert.deepEqual((await f.collect()).rows, first.rows);
});

test("日志持续改写无法取得完整读视图时仍告警，已提交数据和游标保持不变", async (t) => {
  const f = await fixture(t);
  const first = await f.collect();
  const saved = await fs.readFile(f.statePath, "utf8");
  await fs.appendFile(f.transcript, lines([selection(8, "Orchestrator (Carbon)")]));
  const originalRead = fs.readFile;
  let reads = 0;
  t.mock.method(fs, "readFile", async (file, ...args) => {
    const bytes = await originalRead(file, ...args);
    if (file === f.transcript) {
      reads += 1;
      await fs.appendFile(f.transcript, lines([selection(8 + reads, "Orchestrator (Carbon)")]));
    }
    return bytes;
  });
  const result = await f.collect();
  assert.equal(reads, 3);
  assert.deepEqual(result.warnings, ["反重力本地采集未完成，保留上次结果并稍后重试"]);
  assert.deepEqual(result.rows, first.rows);
  assert.equal(await fs.readFile(f.statePath, "utf8"), saved);
});
