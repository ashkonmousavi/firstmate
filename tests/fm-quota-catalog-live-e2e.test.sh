#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_QUOTA_CATALOG_LIVE_E2E python3 jq
unset FM_QUOTA_MODEL_CATALOG_FILE FM_TEST_SEAM
TMP_ROOT=$(fm_test_tmproot fm-quota-catalog-live)
python3 - "$ROOT" "${FM_QUOTA_CATALOG_LIVE_CASES:-}" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
cases = []
if sys.argv[2]:
    with open(sys.argv[2], encoding="utf-8") as handle:
        cases = json.load(handle)
lab = Path(sys.argv[3])
for harness in ("pi", "pi-signed"):
    executable = shutil.which(harness)
    if not executable or any(c["harness"] == harness for c in cases):
        continue
    version = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=15, check=True).stdout.strip().splitlines()[0]
    home = lab / harness
    agent = home / ".pi/agent"
    agent.mkdir(parents=True)
    (agent / "models.json").write_text(json.dumps({"providers":{"fm-quota-live":{
        "baseUrl":"http://127.0.0.1:9/v1", "apiKey":"synthetic-no-request", "api":"openai-completions",
        "models":[{"id":"quota-a", "name":"Quota A", "reasoning":False, "input":["text"],
                   "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                   "contextWindow":32768,"maxTokens":4096}]}}}))
    (agent / "settings.json").write_text(json.dumps({"defaultProvider":"fm-quota-live", "defaultModel":"quota-a"}))
    for model in ("", "fm-quota-live/quota-a"):
        cases.append({"harness":harness, "name":"isolated native model configuration", "version":version,
                      "oracle_source":"Pi custom provider models.json and defaultProvider/defaultModel settings contract",
                      "cwd":str(home), "model":model, "env":{"HOME":str(home),"PI_CODING_AGENT_DIR":str(agent)},
                      "expected":{"model":"fm-quota-live/quota-a", "provider":"fm-quota-live"}})
executable = shutil.which("agy")
if executable and not any(c["harness"] == "agy" for c in cases):
    version = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=15, check=True).stdout.strip().splitlines()[0]
    listing = subprocess.run([executable, "models"], capture_output=True, text=True, timeout=20, check=True).stdout
    rows = [line.split("\t", 1) for line in listing.splitlines() if "\t" in line]
    assert rows, f"agy {version}: native model listing has no tab-separated rows"
    model, label = rows[0]
    home = lab / "agy"
    config = home / ".gemini/antigravity-cli"
    config.mkdir(parents=True)
    (config / "settings.json").write_text(json.dumps({"model":label}))
    for requested in ("", model, label):
        cases.append({"harness":"agy", "name":"native catalog label and saved model", "version":version,
                      "oracle_source":"agy models tab-separated ID/label and saved settings model contract",
                      "cwd":str(home), "model":requested, "env":{"HOME":str(home)},
                      "expected":{"model":model, "provider":""}})
adapters = "claude codex opencode pi pi-signed grok kimi cursor omp agy gemini muse rovo devin commandcode polytoken".split()
checked = 0
missing = []
failures = []
for harness in adapters:
    executable = shutil.which("cursor-agent" if harness == "cursor" else harness)
    if not executable:
        print(f"skip - {harness}: executable absent on PATH", flush=True)
        continue
    version = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=15, check=True).stdout.strip().splitlines()[0]
    print(f"native - {harness} {version}", flush=True)
    selected = [c for c in cases if c["harness"] == harness]
    if not selected:
        missing.append(f"{harness} {version}")
        continue
    if harness != "polytoken":
        assert any(not c.get("model") or c["model"] == "default" for c in selected), f"{harness}: missing default case"
    assert any(c.get("model") and c["model"] != "default" for c in selected), f"{harness}: missing explicit-model case"
    version = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=15, check=True).stdout.strip().splitlines()[0]
    for case in selected:
        assert case["oracle_source"], f"{harness}: missing independent native catalog/config/session evidence"
        assert case["version"] == version, f"{harness}: stale oracle ({case['version']} vs {version})"
        env = dict(os.environ, **case.get("env", {}))
        env.pop("FM_QUOTA_MODEL_CATALOG_FILE", None)
        env.pop("FM_TEST_SEAM", None)
        run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                              executable, case.get("model", ""), case["cwd"], json.dumps(case.get("context", {}))],
                             env=env, capture_output=True, text=True, timeout=25)
        actual = json.loads(run.stdout)
        expected = case["expected"]
        assert set(expected) == {"model", "provider"} and expected["model"], f"{harness}: incomplete model/provider oracle"
        if run.returncode or any(actual.get(k) != v for k, v in expected.items()):
            failures.append(f"{harness} {version} {case['name']}: expected {expected}, got {actual}")
            continue
        checked += 1
        print(f"ok - {harness} {version} {case['name']}: {actual}", flush=True)
assert not failures, "\n".join(failures)
assert not missing, "installed adapters lack native oracle cases: " + ", ".join(missing)
assert checked, "no real harness catalog case was checked"
print(f"ok - {checked} native catalog cases checked on {sys.platform}")
PY
