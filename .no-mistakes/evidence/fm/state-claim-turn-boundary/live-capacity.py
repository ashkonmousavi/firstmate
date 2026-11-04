"""Live Claude Code capacity-claim check in disposable homes (modelled on
tests/fm-state-claim-guard-live-e2e.test.sh). The real tracked Stop hook runs through a
recorder. Variant 'bare' runs the fixture activity read alone; variant 'piped' pipes it
through head, the shape seen in the 2026-11-04 22:12-22:20Z MAIN rejections. Afterwards the
real on-disk transcript is scanned for user rows that mix tool_result and text blocks."""
import json, os, subprocess, sys
from pathlib import Path

root, lab = Path(sys.argv[1]), Path(sys.argv[2])
version = subprocess.check_output(["claude", "--version"], text=True).strip()
settings = json.loads((root / ".claude/settings.json").read_text())
tracked = next(h for g in settings["hooks"]["Stop"] for h in g["hooks"] if "fm-turnend-guard.sh" in h.get("command", ""))
recorder = lab / "record.py"
recorder.write_text('''import json, os, pathlib, subprocess, sys
payload = sys.stdin.read()
p = subprocess.run(["sh", "-c", os.environ["CLAIM_TRACKED_COMMAND"]], input=payload, text=True, capture_output=True)
with (pathlib.Path(os.environ["FM_HOME"]) / "stop-events.jsonl").open("a") as f:
    f.write(json.dumps({"payload": json.loads(payload), "rc": p.returncode, "stderr": p.stderr}) + "\\n")
sys.stdout.write(p.stdout); sys.stderr.write(p.stderr); sys.exit(p.returncode)
''')
fixture_dir = lab / "skills"
fixture_dir.mkdir()
fixture = fixture_dir / "activity.sh"
fixture.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FM_HOME/read-events"\necho "free lanes: 7"\n')
fixture.chmod(0o755)
for name, cmd in (("bare", f"bash {fixture}"), ("piped", f"bash {fixture} | head -5")):
    home = lab / name
    (home / ".claude").mkdir(parents=True)
    (home / "state").mkdir()
    (home / "bin").symlink_to(root / "bin", target_is_directory=True)
    (home / "AGENTS.md").touch()
    subprocess.run(["git", "init", "-q", str(home)], check=True)
    (home / ".claude/settings.json").write_text(json.dumps({"hooks": {"Stop": [{"hooks": [dict(tracked, command=f'python3 "{recorder}"')]}]}}))
    prompt = (f"This is an isolated Stop-hook regression. First use Bash to run exactly: {cmd} . "
              "Then reply exactly: There are 7 free lanes. If a Stop hook blocks the reply, repeat exactly "
              "There are 7 free lanes. and do not run any more tools.")
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_STATE_OVERRIDE=str(home / "state"),
               FM_CONFIG_OVERRIDE=str(home / "config"), CLAIM_TRACKED_COMMAND=tracked["command"],
               CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false", CLAUDE_CODE_SEND_FEEDBACK="0")
    env.pop("CLAUDECODE", None)
    args = ["claude", "-p", prompt, "--dangerously-skip-permissions", "--model", "haiku", "--effort", "low",
            "--setting-sources", "project,local", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--settings", '{"feedbackDrafts":"off"}', "--system-prompt", "Follow the regression prompt exactly.",
            "--tools", "Bash", "--output-format", "stream-json", "--verbose"]
    r = subprocess.run(args, cwd=home, env=env, capture_output=True, text=True, timeout=240)
    events = [json.loads(l) for l in (home / "stop-events.jsonl").read_text().splitlines()] if (home / "stop-events.jsonl").exists() else []
    reads = (home / "read-events").read_text().count("\n") if (home / "read-events").exists() else 0
    tpath = events[0]["payload"]["transcript_path"] if events else None
    mixed = shapes = 0
    attach = set()
    if tpath:
        for line in Path(tpath).read_text().splitlines():
            row = json.loads(line)
            if row.get("type") == "attachment":
                attach.add(str((row.get("attachment") or {}).get("type")))
            c = row.get("message", {}).get("content") if isinstance(row.get("message"), dict) else None
            if row.get("type") == "user" and isinstance(c, list):
                kinds = {b.get("type") for b in c if isinstance(b, dict)}
                shapes += "tool_result" in kinds
                mixed += {"tool_result", "text"} <= kinds
    print(f"{version} {name}: claude rc={r.returncode} fixture reads={reads} stop rcs={[e['rc'] for e in events]} "
          f"first stderr={(events[0]['stderr'].strip()[:90] if events else '')!r} "
          f"| transcript tool_result rows={shapes} mixed tool_result+text rows={mixed} attachment rows={sorted(attach)} "
          f"| last message={(events[-1]['payload']['last_assistant_message'].strip() if events else '')!r}")
