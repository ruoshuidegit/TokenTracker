#!/usr/bin/env python3
"""用独立临时数据验证 .app 的运行时、增量统计和快照，不触碰真实队列。"""

import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


APP = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent / "dist/TokenTracker Lite.app"
EXECUTABLE = APP / "Contents/MacOS/TokenTrackerLite"
NODE = APP / "Contents/Resources/node"


def verify():
    dependencies = subprocess.check_output(["otool", "-L", str(NODE)], text=True)
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency and not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise RuntimeError("应用运行时仍依赖外部动态库")
    with tempfile.TemporaryDirectory(prefix="tokentracker-lite-bundle-") as directory:
        root = Path(directory)
        queue = root / "queue.jsonl"
        row = {
            "source": "codex", "model": "gpt-5", "hour_start": "2026-11-10T01:00:00Z",
            "input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 100,
            "total_tokens": 1100, "billable_total_tokens": 1100,
        }
        queue.write_text(json.dumps(row) + "\n")
        command = [str(EXECUTABLE), "--snapshot-once", "--queue", str(queue),
                   "--database", str(root / "usage.sqlite"), "--snapshot", str(root / "snapshot.json")]

        def read(arguments=command, env=None):
            result = subprocess.run(arguments, cwd=root, env=env, capture_output=True, text=True, timeout=30, check=True)
            return json.loads(result.stdout)

        first = read()
        assert first["all"]["tokens"] == 1100
        assert first["all"]["input_tokens"] == 200
        assert first["all"]["cost_usd"] > 0
        assert first["stats"]["rebuild"]
        second = read()
        assert second["all"] == first["all"]
        assert second["stats"]["bytes_read"] == 0
        row.update(input_tokens=0, cached_input_tokens=0, output_tokens=0,
                   total_tokens=0, billable_total_tokens=0)
        with queue.open("a") as output:
            output.write(json.dumps(row) + "\n")
        third = read()
        assert third["all"]["tokens"] == 0
        assert third["all"]["cost_usd"] == 0
        assert not third["stats"]["rebuild"]
        fable = {
            "source": "omp", "model": "claude-fable-5-2", "hour_start": "2026-11-10T02:00:00Z",
            "input_tokens": 1_000_000, "cached_input_tokens": 1_000_000,
            "cache_creation_input_tokens": 500_000, "output_tokens": 1_000_000,
            "total_tokens": 3_500_000, "billable_total_tokens": 3_500_000,
        }
        with queue.open("a") as output:
            output.write(json.dumps(fable) + "\n")
        fourth = read()
        assert fourth["all"]["tokens"] == 3_500_000
        assert abs(fourth["all"]["cost_usd"] - 53.2) < 1e-9
        assert fourth["all"]["unpriced_tokens"] == 0
        assert (root / "snapshot.json").is_file()
        agent = root / "omp-agent"
        sessions = agent / "sessions/example"
        sessions.mkdir(parents=True)
        def message(identity, tokens):
            return {"type": "message", "id": identity, "timestamp": "2026-11-10T03:00:00Z",
                    "message": {"role": "assistant", "model": "gpt-5", "timestamp": "2026-11-10T03:00:00Z",
                                "usage": {"input": tokens, "output": 0, "totalTokens": tokens}}}
        (sessions / "main.jsonl").write_text(json.dumps(message("bundle-main", 40)) + "\n")
        (sessions / "main").mkdir()
        (sessions / "main/sub.jsonl").write_text(json.dumps(message("bundle-orca-sub", 60)) + "\n")
        # 同时存在的原队列旧值必须被完整本地时间桶覆盖，不能重复相加。
        old = dict(fable, model="old-model", hour_start="2026-11-10T03:00:00Z", input_tokens=999,
                   cached_input_tokens=0, cache_creation_input_tokens=0, output_tokens=0,
                   total_tokens=999, billable_total_tokens=999)
        with queue.open("a") as output:
            output.write(json.dumps(old) + "\n")
        isolated_env = dict(os.environ, HOME=str(root), GEMINI_HOME=str(root / "gemini"),
                            TOKENTRACKER_OMP_AGENT_DIR=str(agent))
        brain = root / "gemini/antigravity/brain/bundle-carbon/.system_generated/logs"
        brain.mkdir(parents=True)
        (brain / "transcript.jsonl").write_text("\n".join(json.dumps(value) for value in [
            {"type": "USER_SETTINGS_CHANGE", "step_index": 0, "created_at": "2026-11-10T03:00:00Z",
             "content": "changed setting `Model Selection` from None to Orchestrator (Carbon)."},
            {"type": "PLANNER_RESPONSE", "step_index": 1, "created_at": "2026-11-10T03:01:00Z"},
            {"type": "PLANNER_RESPONSE", "step_index": 2, "created_at": "2026-11-10T03:02:00Z"},
            {"type": "USER_SETTINGS_CHANGE", "step_index": 3, "created_at": "2026-11-10T03:03:00Z",
             "content": "changed setting `Model Selection` from Orchestrator (Carbon) to Orchestrator (Argon)."},
            {"type": "PLANNER_RESPONSE", "step_index": 4, "created_at": "2026-11-10T03:04:00Z"},
            {"type": "PLANNER_RESPONSE", "step_index": 5, "created_at": "2026-11-10T03:05:00Z"},
            {"type": "USER_SETTINGS_CHANGE", "step_index": 6, "created_at": "2026-11-10T03:06:00Z",
             "content": "changed setting `Model Selection` from Orchestrator (Argon) to Orchestrator (Neon)."},
            {"type": "PLANNER_RESPONSE", "step_index": 7, "created_at": "2026-11-10T03:07:00Z"},
            {"type": "PLANNER_RESPONSE", "step_index": 8, "created_at": "2026-11-10T03:08:00Z"},
            {"type": "PLANNER_RESPONSE", "step_index": 9, "created_at": "2026-11-10T03:09:00Z"},
        ]) + "\n")

        def varint(number):
            output = bytearray()
            while number > 127:
                output.append((number & 127) | 128)
                number >>= 7
            output.append(number)
            return bytes(output)

        def field(number, value):
            if isinstance(value, int):
                return varint(number * 8) + varint(value)
            value = value.encode() if isinstance(value, str) else value
            return varint(number * 8 + 2) + varint(len(value)) + value

        def metadata(model, step, input_tokens, cache, output_tokens, reasoning):
            return field(1, field(19, model) + field(4, field(2, input_tokens) + field(5, cache)
                         + field(3, output_tokens) + field(9, output_tokens - reasoning) + field(10, reasoning))
                         + field(20, field(1, "last_step_index") + field(2, str(step - 1))))

        conversations = root / "gemini/antigravity/conversations"
        conversations.mkdir(parents=True)
        with sqlite3.connect(conversations / "bundle-carbon.db") as db:
            db.execute("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            db.executemany("INSERT INTO gen_metadata VALUES (?, ?)", [
                (1, metadata("gemini-pro-orchestrator", 1, 100, 900, 70, 20)),
                (2, metadata("gemini-flash-worker-agy", 2, 10, 90, 20, 5)),
                (4, metadata("gemini-pro-orchestrator", 4, 20, 180, 30, 10)),
                (5, metadata("gemini-flash-worker-agy", 5, 3, 27, 10, 2)),
                (7, metadata("gemini-pro-orchestrator-neon", 7, 70, 630, 100, 20)),
                (8, metadata("gemini-flash-worker-agy", 8, 5, 45, 10, 2)),
                (9, metadata("gemini-pro-orchestrator", 9, 20, 180, 30, 10)),
            ])
        collecting = command + ["--collect-state-dir", str(root / "collector")]
        collected = read(collecting, isolated_env)
        assert not collected.get("warning"), collected.get("warning")
        assert collected["all"]["tokens"] == 3_502_650
        assert collected["stats"]["collected_bucket_count"] == 8
        carbon = next(model for model in collected["models"] if model["model"] == "gemini-4-carbon")
        assert carbon["tokens"] == 1070
        assert carbon["unpriced_tokens"] == 0
        assert abs(carbon["cost_usd"] - 0.00099) < 1e-12
        argon = next(model for model in collected["models"] if model["model"] == "gemini-4-argon")
        assert argon["tokens"] == 230
        assert argon["unpriced_tokens"] == 0
        assert abs(argon["cost_usd"] - 0.000358) < 1e-12
        hydrogen = next(model for model in collected["models"] if model["model"] == "gemini-4-hydrogen")
        assert hydrogen["tokens"] == 220
        assert hydrogen["unpriced_tokens"] == 0
        assert abs(hydrogen["cost_usd"] - 0.00033915) < 1e-12
        neon = next(model for model in collected["models"] if model["model"] == "gemini-4-neon")
        assert neon["tokens"] == 1030
        assert neon["unpriced_tokens"] == 0
        assert abs(neon["cost_usd"] - 0.0023415) < 1e-12
        repeated = read(collecting, isolated_env)
        assert not repeated.get("warning"), repeated.get("warning")
        assert repeated["all"] == collected["all"]
        astra = dict(row, source="codex", model="gpt-6.2-astra", hour_start="2026-11-10T05:00:00Z",
                     input_tokens=1_000_000, cached_input_tokens=2_000_000, output_tokens=400_000,
                     reasoning_output_tokens=100_000, total_tokens=3_400_000, billable_total_tokens=3_400_000)
        for prefix in ["long_context_", "ultrafast_", "ultrafast_long_context_"]:
            for name in ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"]:
                astra[prefix + name] = astra[name]
        with queue.open("a") as output:
            output.write(json.dumps(astra) + "\n")
        with sqlite3.connect(conversations / "bundle-carbon.db") as db:
            db.execute("INSERT INTO gen_metadata VALUES (?, ?)",
                       (10, metadata("gemini-4-hydrogen-tiered", 10, 1_000_000, 2_000_000, 400_000, 100_000)))
        with (brain / "transcript.jsonl").open("a") as output:
            output.write(json.dumps({"type": "PLANNER_RESPONSE", "step_index": 10,
                                     "created_at": "2026-11-10T03:10:00Z"}) + "\n")
        repriced = read(collecting, isolated_env)
        assert not repriced.get("warning"), repriced.get("warning")
        assert repriced["all"]["tokens"] == collected["all"]["tokens"] + 6_800_000
        assert repriced["all"]["unpriced_tokens"] == 0
        assert abs(repriced["all"]["cost_usd"] - collected["all"]["cost_usd"] - 129.45) < 1e-9
        astra_price = next(model for model in repriced["models"] if model["model"] == "gpt-6.2-astra")
        assert astra_price["unpriced_tokens"] == 0
        assert abs(astra_price["cost_usd"] - 124.8) < 1e-9
        hydrogen_price = next(model for model in repriced["models"] if model["model"] == "gemini-4-hydrogen")
        assert hydrogen_price["unpriced_tokens"] == 0
        assert abs(hydrogen_price["cost_usd"] - 4.65033915) < 1e-9
        assert read(collecting, isolated_env)["all"] == repriced["all"]
    print("应用包验证通过：Gemini独立统计、Hydrogen tiered补价、GPT-6.2长上下文与加速档、独立采集、刷新/重启去重及费用快照")


if __name__ == "__main__":
    verify()
