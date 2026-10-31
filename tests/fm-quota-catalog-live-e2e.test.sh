#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_QUOTA_CATALOG_LIVE_E2E python3 jq
unset FM_QUOTA_MODEL_CATALOG_FILE FM_TEST_SEAM
: "${FM_QUOTA_CATALOG_LIVE_CASES:?Set FM_QUOTA_CATALOG_LIVE_CASES to independently captured native model cases; see docs/verification/runtime-backends.md}"
python3 - "$ROOT" "$FM_QUOTA_CATALOG_LIVE_CASES" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as handle:
    cases = json.load(handle)
adapters = "claude codex opencode pi pi-signed grok kimi cursor omp agy gemini muse rovo devin commandcode polytoken".split()
checked = 0
missing = []
failures = []
for harness in adapters:
    executable = shutil.which("cursor-agent" if harness == "cursor" else harness)
    if not executable:
        print(f"skip - {harness}: executable absent on PATH", flush=True)
        continue
    selected = [c for c in cases if c["harness"] == harness]
    if not selected:
        missing.append(harness)
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
