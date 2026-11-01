#!/usr/bin/env bash
# Opt-in real Claude Stop payload/transcript regression. Sends two small model
# prompts against an isolated primary home; no forge, deployment or fleet state
# is changed. The PR read executable is a fixture; the transcript is Claude's.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_STATE_CLAIM_LIVE claude python3
LAB=$(fm_test_tmproot fm-state-claim-live)
python3 - "$ROOT" "$LAB" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, lab = map(Path, sys.argv[1:])
version = subprocess.check_output(["claude", "--version"], text=True).strip()
settings = json.loads((root / ".claude/settings.json").read_text())
tracked = next(h for group in settings["hooks"]["Stop"] for h in group["hooks"]
               if "fm-turnend-guard.sh" in h.get("command", ""))
recorder = lab / "record.py"
recorder.write_text('''import json, os, pathlib, subprocess, sys
payload = sys.stdin.read()
p = subprocess.run(["sh", "-c", os.environ["CLAIM_TRACKED_COMMAND"]], input=payload, text=True, capture_output=True)
with (pathlib.Path(os.environ["FM_HOME"]) / "stop-events.jsonl").open("a") as f:
    f.write(json.dumps({"payload": json.loads(payload), "rc": p.returncode, "stderr": p.stderr}) + "\\n")
sys.stdout.write(p.stdout)
sys.stderr.write(p.stderr)
sys.exit(p.returncode)
''')
read = lab / "gh-axi"
read.write_text('#!/usr/bin/env bash\nprintf "state: MERGED\\n"\n')
read.chmod(0o755)

for name in ("no-read", "read"):
    home = lab / name
    (home / ".claude").mkdir(parents=True)
    (home / "state").mkdir()
    (home / "bin").symlink_to(root / "bin", target_is_directory=True)
    (home / "AGENTS.md").touch()
    subprocess.run(["git", "init", "-q", str(home)], check=True)
    hook = dict(tracked, command=f'python3 "{recorder}"')
    (home / ".claude/settings.json").write_text(json.dumps({"hooks": {"Stop": [{"hooks": [hook]}]}}))
    prompt = ("This is an isolated Stop-hook regression. Do not call any tools. Reply exactly: PR 9 is merged. "
              "If a Stop hook blocks the reply, repeat exactly PR 9 is merged. Do not correct or qualify it; "
              "the test must check the one-block loop guard.")
    if name == "read":
        prompt = (f"This is an isolated Stop-hook regression. First use Bash to run exactly: {read} pr view 9. "
                  "Then reply exactly: PR 9 is merged. The command is a local fixture that makes no network request.")
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_STATE_OVERRIDE=str(home / "state"),
               FM_CONFIG_OVERRIDE=str(home / "config"), CLAIM_TRACKED_COMMAND=tracked["command"],
               CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false", CLAUDE_CODE_SEND_FEEDBACK="0")
    env.pop("CLAUDECODE", None)
    args = ["claude", "-p", prompt, "--dangerously-skip-permissions", "--model", "haiku", "--effort", "low",
            "--setting-sources", "project,local", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--settings", '{"feedbackDrafts":"off"}', "--system-prompt", "Follow the regression prompt exactly.",
            "--tools", "Bash", "--output-format", "stream-json", "--verbose"]
    result = subprocess.run(args, cwd=home, env=env, capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, f"{version} {name}: Claude failed: {result.stderr[-2000:]}"
    stream = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    assert any(r.get("type") == "result" and not r.get("is_error") for r in stream), f"{version} {name}: no successful model result"
    events = [json.loads(line) for line in (home / "stop-events.jsonl").read_text().splitlines()]
    expected = [2, 0] if name == "no-read" else [0]
    assert [e["rc"] for e in events] == expected, f"{version} {name}: {events}"
    assert events[0]["payload"]["stop_hook_active"] is False, f"{version}: first Stop is not inactive"
    assert "merged" in events[0]["payload"]["last_assistant_message"].lower(), f"{version}: missing claim text"
    if name == "no-read":
        assert events[1]["payload"]["stop_hook_active"] is True, f"{version}: missing continuation marker"
        assert "State claim needs a same-turn read" in events[0]["stderr"], f"{version}: wrong blocking reason"
    print(f"ok - {version} real Stop {name}: exits {','.join(map(str, expected))}")
print(f"ok - {version} state-claim live guard checked 2 sessions")
PY
