"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const rollout = require("../src/lib/rollout");
const { collectLocalUsage } = require("./local-collect.cjs");

const HOUR = "2026-11-12T12:00:00.000Z";
const EARLIER_HOUR = "2026-11-12T11:30:00.000Z";
const timestamp = Date.parse("2026-11-12T12:10:00.000Z");
const lines = (...values) => values.map((value) => JSON.stringify(value)).join("\n") + "\n";
const usage = (source, tokens, extra = {}) => ({ source, model: "gpt-5", hour_start: HOUR,
  input_tokens: tokens, output_tokens: 0, cached_input_tokens: 0, cache_creation_input_tokens: 0,
  reasoning_output_tokens: 0, total_tokens: tokens, ...extra });
const bucket = (result, source, model = "gpt-5", hour = HOUR) => result.rows.find((row) =>
  row.source === source && row.model === model && row.hour_start === hour);

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "tokentracker-lite-collect-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const home = path.join(directory, "home");
  const env = { HOME: home, GEMINI_HOME: path.join(home, ".gemini"), OMP_HOME: path.join(home, ".omp") };
  const stateDir = path.join(directory, "state");
  const brain = path.join(env.GEMINI_HOME, "antigravity", "brain");
  const sessions = path.join(env.OMP_HOME, "agent", "sessions");
  await fs.mkdir(brain, { recursive: true });
  await fs.mkdir(sessions, { recursive: true });
  // 仅供 mock discovery 使用；真实 OMP resolver 只读取 sessions 的项目子目录。
  await fs.writeFile(path.join(sessions, "fixture.jsonl"), "");
  return { directory, env, stateDir, brain, sessions,
    collect: (options = {}) => collectLocalUsage({ stateDir, env, ...options }),
    state: (source) => path.join(stateDir, `${source}.json`) };
}

async function appendSnapshots(queuePath, ...rows) {
  await fs.mkdir(path.dirname(queuePath), { recursive: true });
  await fs.appendFile(queuePath, lines(...rows));
}

function mockParsers(f, overrides = {}) {
  return { ...rollout,
    listAntigravityTranscriptsWithStatus: async () => ({ files: [path.join(f.brain, "fixture", "transcript.jsonl")], complete: true }),
    resolveOmpAgentDir: () => path.join(f.env.OMP_HOME, "agent"),
    resolveOmpSessionFiles: () => [path.join(f.sessions, "fixture.jsonl")],
    resolveOmpSubagentFiles: () => [],
    parseAntigravityIncremental: async () => ({}),
    parseOmpIncremental: async () => ({}),
    ...overrides };
}

function header(id) {
  return { type: "session", id, timestamp: new Date(timestamp).toISOString() };
}

function ompMessage(id, input, output, extra = {}) {
  return { type: "message", id, parentId: "fixture-parent", timestamp: new Date(timestamp).toISOString(),
    message: { role: "assistant", provider: "openai", model: "gpt-5", timestamp,
      usage: { input, output, cacheRead: 0, cacheWrite: 0, reasoningTokens: 0,
        totalTokens: input + output }, ...extra } };
}

async function ompFiles(f) {
  const cwd = path.join(f.sessions, "--fixture-project--");
  const main = path.join(cwd, "main.jsonl");
  const child = path.join(cwd, "main", "AgentA.jsonl");
  const advisor = path.join(cwd, "main", "review", "Advisor.jsonl");
  const orca = path.join(cwd, "orca-session.jsonl");
  await fs.mkdir(path.dirname(advisor), { recursive: true });
  await fs.writeFile(main, lines(header("main"), ompMessage("main-1", 10, 5)));
  await fs.writeFile(child, lines(header("child"), ompMessage("child-1", 100, 20,
    { provider: "anthropic", model: "claude-sonnet-4-5" })));
  await fs.writeFile(advisor, lines(header("advisor"), ompMessage("advisor-1", 6, 4)));
  // Orca 复用 OMP 的 sessions 目录与消息格式，不应另造来源而重复记账。
  await fs.writeFile(orca, lines(header("orca"), ompMessage("orca-1", 40, 10)));
  return { main, child, advisor, orca };
}

test("真实 OMP 主代理、子代理和共目录 Orca 增量采集，重启不重计", async (t) => {
  const f = await fixture(t);
  const files = await ompFiles(f);
  const first = await f.collect();
  assert.deepEqual(first.warnings, []);
  assert.ok(first.sources.includes("omp"));
  assert.equal(bucket(first, "omp").total_tokens, 75);
  assert.equal(bucket(first, "omp", "claude-sonnet-4-5").total_tokens, 120);
  assert.equal(first.rows.filter((row) => row.source === "omp").length, 2);
  assert.ok(first.rows.every((row) => row.source !== "orca"));
  assert.deepEqual((await f.collect()).rows, first.rows);

  const appended = JSON.stringify(ompMessage("main-2", 7, 3));
  const cut = Math.floor(appended.length / 2);
  await fs.appendFile(files.main, appended.slice(0, cut));
  assert.equal(bucket(await f.collect(), "omp").total_tokens, 75);
  await fs.appendFile(files.main, appended.slice(cut) + "\n");
  const changed = await f.collect();
  assert.equal(bucket(changed, "omp").total_tokens, 85);
  assert.equal(bucket(changed, "omp", "claude-sonnet-4-5").total_tokens, 120);

  const child = spawnSync(process.execPath, ["--no-warnings", "-e",
    "require(process.argv[1]).collectLocalUsage({stateDir:process.argv[2],env:JSON.parse(process.argv[3])}).then(value=>process.stdout.write(JSON.stringify(value))).catch(()=>process.exitCode=1)",
    path.join(__dirname, "local-collect.cjs"), f.stateDir, JSON.stringify(f.env)], { encoding: "utf8" });
  assert.equal(child.status, 0, child.stderr);
  assert.deepEqual(JSON.parse(child.stdout).rows, changed.rows);
});

test("累计桶取最后快照，减少和零值保留，未变化的历史桶不丢失", async (t) => {
  const f = await fixture(t);
  const parsers = mockParsers(f, { async parseOmpIncremental({ queuePath, cursors }) {
    if (!cursors.seeded) {
      await appendSnapshots(queuePath, usage("omp", 10, { hour_start: EARLIER_HOUR }),
        usage("omp", 100), usage("omp", 40), usage("omp", 0, { content: "fixture-content-not-for-cache" }));
      cursors.seeded = true;
    }
  } });
  const first = await f.collect({ parsers });
  assert.equal(bucket(first, "omp").total_tokens, 0);
  assert.equal(bucket(first, "omp", "gpt-5", EARLIER_HOUR).total_tokens, 10);
  assert.equal(first.rows.filter((row) => row.source === "omp").length, 2);
  assert.equal(JSON.stringify(first.rows).includes("fixture-content-not-for-cache"), false);
  assert.deepEqual((await f.collect({ parsers })).rows, first.rows);
  const saved = JSON.parse(await fs.readFile(f.state("omp"), "utf8"));
  assert.equal(saved.cursors.seeded, true);
  assert.equal(saved.rows.find((row) => row.hour_start === HOUR).total_tokens, 0);
});

test("单来源部分写入后失败回滚游标与用量，另一来源继续，警告不泄露详情", async (t) => {
  const f = await fixture(t);
  let phase = 1;
  const receivedCursors = [];
  const parsers = mockParsers(f, {
    async parseAntigravityIncremental({ queuePath, cursors }) {
      receivedCursors.push(cursors.marker);
      if (phase === 1) {
        cursors.marker = "committed";
        await appendSnapshots(queuePath, usage("antigravity", 20));
      } else {
        cursors.marker = "uncommitted";
        await appendSnapshots(queuePath, usage("antigravity", 999));
        throw new Error(`sensitive-fixture-error-${phase} /private/fixture/location`);
      }
    },
    async parseOmpIncremental({ queuePath, cursors }) {
      cursors.marker = phase;
      await appendSnapshots(queuePath, usage("omp", phase * 100));
    },
  });
  await f.collect({ parsers });
  const committed = await fs.readFile(f.state("antigravity"), "utf8");
  phase = 2;
  const failed = await f.collect({ parsers });
  assert.equal(bucket(failed, "antigravity").total_tokens, 20);
  assert.equal(bucket(failed, "omp").total_tokens, 200);
  assert.deepEqual(failed.warnings, ["反重力本地采集未完成，保留上次结果并稍后重试"]);
  assert.equal(await fs.readFile(f.state("antigravity"), "utf8"), committed);
  assert.equal(JSON.stringify(failed).includes("sensitive-fixture-error"), false);
  assert.equal(JSON.stringify(failed).includes("/private/fixture/location"), false);
  phase = 3;
  const repeated = await f.collect({ parsers });
  assert.deepEqual(repeated.warnings, failed.warnings);
  assert.equal(bucket(repeated, "omp").total_tokens, 300);
  assert.deepEqual(receivedCursors, [undefined, "committed", "committed"]);
  assert.equal(await fs.readFile(f.state("antigravity"), "utf8"), committed);
  assert.deepEqual((await fs.readdir(f.stateDir)).sort(), ["antigravity.json", "omp.json"]);
});

test("未写完的 parser 队列不提交，即使 parser 正常返回也保留旧状态", async (t) => {
  const f = await fixture(t);
  let broken = false;
  const parsers = mockParsers(f, { async parseOmpIncremental({ queuePath, cursors }) {
    cursors.committed = !broken;
    await appendSnapshots(queuePath, usage("omp", broken ? 999 : 35));
    if (broken) await fs.appendFile(queuePath, "{\"source\":\"omp\"");
  } });
  await f.collect({ parsers });
  const before = await fs.readFile(f.state("omp"), "utf8");
  broken = true;
  const result = await f.collect({ parsers });
  assert.equal(bucket(result, "omp").total_tokens, 35);
  assert.deepEqual(result.warnings, ["OMP（含 Orca）本地采集未完成，保留上次结果并稍后重试"]);
  assert.equal(await fs.readFile(f.state("omp"), "utf8"), before);
});

test("安装目录暂缺保留来源缓存，不将既有用量提交为空", async (t) => {
  const f = await fixture(t);
  const parsers = mockParsers(f, {
    parseAntigravityIncremental: ({ queuePath }) => appendSnapshots(queuePath, usage("antigravity", 45)),
    parseOmpIncremental: ({ queuePath }) => appendSnapshots(queuePath, usage("omp", 80)),
  });
  const initial = await f.collect({ parsers });
  const before = await Promise.all(["antigravity", "omp"].map((source) => fs.readFile(f.state(source), "utf8")));
  await fs.rename(f.env.GEMINI_HOME, f.env.GEMINI_HOME + ".unavailable");
  await fs.rename(f.env.OMP_HOME, f.env.OMP_HOME + ".unavailable");
  const result = await f.collect();
  assert.deepEqual(result.rows, initial.rows);
  assert.deepEqual(result.sources, ["antigravity", "omp"]);
  assert.equal(result.updatedAt, initial.updatedAt);
  assert.deepEqual(await Promise.all(["antigravity", "omp"].map((source) => fs.readFile(f.state(source), "utf8"))), before);
});

test("损坏来源缓存不发布空覆盖，健康来源仍可提交新快照", async (t) => {
  const f = await fixture(t);
  let tokens = 10;
  const parsers = mockParsers(f, {
    parseAntigravityIncremental: ({ queuePath }) => appendSnapshots(queuePath, usage("antigravity", 50)),
    parseOmpIncremental: ({ queuePath }) => appendSnapshots(queuePath, usage("omp", tokens)),
  });
  await f.collect({ parsers });
  await fs.writeFile(f.state("antigravity"), "sensitive-fixture-broken-cache");
  tokens = 20;
  const result = await f.collect({ parsers });
  assert.deepEqual(result.sources, ["omp"]);
  assert.equal(bucket(result, "antigravity"), undefined);
  assert.equal(bucket(result, "omp").total_tokens, 20);
  assert.deepEqual(result.warnings, ["反重力采集缓存无法读取，保留已显示的统计"]);
  assert.equal(JSON.stringify(result).includes("sensitive-fixture-broken-cache"), false);
});

test("反重力首次读取不完整时不提交来源，健康 OMP 仍可回填", async (t) => {
  for (const reason of ["sqlite", "inventory"]) {
    const f = await fixture(t);
    let parsed = false;
    const parsers = mockParsers(f, {
      listAntigravityTranscriptsWithStatus: async () => ({ files: [path.join(f.brain, "fixture", "transcript.jsonl")],
        complete: reason !== "inventory" }),
      async parseAntigravityIncremental({ queuePath, cursors, inventoryComplete }) {
        parsed = true;
        assert.equal(inventoryComplete, reason !== "inventory");
        cursors.files = { "fixture-ag": { lastLine: 1, dbReadOk: reason !== "sqlite" } };
        await appendSnapshots(queuePath, usage("antigravity", 999));
      },
      parseOmpIncremental: ({ queuePath }) => appendSnapshots(queuePath, usage("omp", 31)),
    });
    const result = await f.collect({ parsers });
    assert.equal(parsed, true);
    assert.deepEqual(result.sources, ["omp"]);
    assert.equal(bucket(result, "antigravity"), undefined);
    assert.equal(bucket(result, "omp").total_tokens, 31);
    assert.deepEqual(result.warnings, ["反重力本地采集未完成，保留上次结果并稍后重试"]);
    await assert.rejects(fs.readFile(f.state("antigravity")), { code: "ENOENT" });
    assert.deepEqual((await fs.readdir(f.stateDir)).sort(), ["omp.json"]);
  }
});

test("首次两源均无用量时不发布空来源，明确的零值桶仍可提交", async (t) => {
  const f = await fixture(t);
  const empty = await f.collect({ parsers: mockParsers(f) });
  assert.deepEqual(empty.rows, []);
  assert.deepEqual(empty.sources, []);
  assert.deepEqual(empty.warnings, []);
  assert.equal(empty.updatedAt, null);
  assert.deepEqual(await fs.readdir(f.stateDir), []);

  const explicitZero = await f.collect({ parsers: mockParsers(f, {
    parseOmpIncremental: ({ queuePath }) => appendSnapshots(queuePath, usage("omp", 0)),
  }) });
  assert.deepEqual(explicitZero.sources, ["omp"]);
  assert.equal(explicitZero.rows.length, 1);
  assert.equal(bucket(explicitZero, "omp").total_tokens, 0);
  assert.ok(Number.isFinite(Date.parse(explicitZero.updatedAt)));
  assert.deepEqual(await fs.readdir(f.stateDir), ["omp.json"]);
});

test("每来源游标和桶原子存入版本化 JSON，状态文件权限为 0600", async (t) => {
  const f = await fixture(t);
  const parsers = mockParsers(f, {
    async parseAntigravityIncremental({ queuePath, cursors }) {
      cursors.files = { "fixture-ag": { lastLine: 1 } };
      await appendSnapshots(queuePath, usage("antigravity", 12));
    },
    async parseOmpIncremental({ queuePath, cursors }) {
      cursors.omp = { seenIds: ["fixture-omp"] };
      await appendSnapshots(queuePath, usage("omp", 34));
    },
  });
  const result = await f.collect({ parsers });
  assert.ok(Number.isFinite(Date.parse(result.updatedAt)));
  for (const source of ["antigravity", "omp"]) {
    const file = f.state(source);
    const state = JSON.parse(await fs.readFile(file, "utf8"));
    assert.equal(state.schema_version, 1);
    assert.equal(state.rows.length, 1);
    assert.equal(state.rows[0].source, source);
    assert.ok(Number.isFinite(Date.parse(state.updated_at)));
    assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
    assert.equal(state.rows[0].total_tokens, source === "omp" ? 34 : 12);
  }
  assert.equal(JSON.parse(await fs.readFile(f.state("antigravity"), "utf8")).cursors.files["fixture-ag"].lastLine, 1);
  assert.deepEqual(JSON.parse(await fs.readFile(f.state("omp"), "utf8")).cursors.omp.seenIds, ["fixture-omp"]);
  assert.deepEqual((await fs.readdir(f.stateDir)).sort(), ["antigravity.json", "omp.json"]);
});

test("并行采集返回已提交快照与固定警告，不重复调用 parser", { timeout: 5000 }, async (t) => {
  const f = await fixture(t);
  let tokens = 50;
  let hold = false;
  let calls = 0;
  let entered;
  let release;
  const started = new Promise((resolve) => { entered = resolve; });
  const blocked = new Promise((resolve) => { release = resolve; });
  const parsers = mockParsers(f, { async parseOmpIncremental({ queuePath }) {
    calls += 1;
    if (hold) { entered(); await blocked; }
    await appendSnapshots(queuePath, usage("omp", tokens));
  } });
  await f.collect({ parsers });
  hold = true;
  tokens = 75;
  const running = f.collect({ parsers });
  try {
    await started;
    const count = calls;
    const locked = await f.collect({ parsers });
    assert.equal(calls, count);
    assert.equal(bucket(locked, "omp").total_tokens, 50);
    assert.deepEqual(locked.warnings, ["本地采集正在运行，显示上次已完成的结果"]);
  } finally { release(); }
  assert.equal(bucket(await running, "omp").total_tokens, 75);
  assert.equal(bucket(await f.collect({ parsers }), "omp").total_tokens, 75);
  assert.deepEqual((await fs.readdir(f.stateDir)).sort(), ["omp.json"]);
});
