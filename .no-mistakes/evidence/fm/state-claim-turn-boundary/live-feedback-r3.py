"""Round 3 live check of commit b3ea705d (the guard's own Stop feedback row is not a turn boundary).
Real Claude Code runs a standalone fixture activity.sh read, then replies with a PR claim that the
real tracked Stop hook refuses (PR family). Claude Code writes that refusal as an isMeta
'Stop hook feedback' user row. Claude is told to run no further commands and reply with a capacity
claim. HEAD must count the earlier read (Stop rcs [2, 0]); the parent guard (9eb6c746) wipes it on
the feedback row and refuses the capacity claim. Prints Stop rcs, Bash commands, stderr, and the
real feedback row(s) Claude wrote to its session transcript."""
import json, os, shutil, subprocess, sys
from pathlib import Path

root, lab, parent_guard = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
version = subprocess.check_output(["claude", "--version"], text=True).strip()
settings = json.loads((root / ".claude" / "settings.json").read_text())
tracked = next(h for g in settings["hooks"]["Stop"] for h in g["hooks"] if "fm-turnend-guard.sh" in h.get("command", ""))
parent_bin = lab / "parent-bin-live"
shutil.copytree(root / "bin", parent_bin, symlinks=True)
shutil.copy(parent_guard, parent_bin / "fm-state-claim-guard.py")
recorder = lab / "record.py"
recorder.write_text('''import json, os, pathlib, subprocess, sys
payload = sys.stdin.read()
p = subprocess.run(["sh", "-c", os.environ["CLAIM_TRACKED_COMMAND"]], input=payload, text=True, capture_output=True)
with (pathlib.Path(os.environ["FM_HOME"]) / "stop-events.jsonl").open("a") as f:
    f.write(json.dumps({"payload": json.loads(payload), "rc": p.returncode, "stderr": p.stderr}) + "\\n")
sys.stdout.write(p.stdout); sys.stderr.write(p.stderr); sys.exit(p.returncode)
''')
fixture_dir = lab / "skills"
fixture_dir.mkdir(exist_ok=True)
fixture = fixture_dir / "activity.sh"
fixture.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FM_HOME/read-events"\necho "free lanes: 7"\n')
fixture.chmod(0o755)
cmd = f"bash {fixture}"
for build, bindir in (("parent-9eb6c746", parent_bin), ("head-b3ea705d", root / "bin")):
    for trial in (1, 2):
        home = lab / f"{build}-{trial}"
        (home / ".claude").mkdir(parents=True)
        (home / "state").mkdir()
        (home / "bin").symlink_to(bindir, target_is_directory=True)
        (home / "AGENTS.md").write_text("")
        subprocess.run(["git", "init", "-q", str(home)], check=True)
        (home / ".claude" / "settings.json").write_text(json.dumps(
            {"hooks": {"Stop": [{"hooks": [dict(tracked, command=f'python3 "{recorder}"')]}]}}))
        prompt = (f"This is an isolated Stop-hook regression. First use Bash to run exactly: {cmd} . "
                  "Then reply exactly: PR #12 is merged. "
                  "If a Stop hook blocks that reply, do NOT run any command again; reply exactly: There are 7 free lanes. "
                  "If a Stop hook blocks that second reply too, reply exactly: There are 7 free lanes.")
        env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_STATE_OVERRIDE=str(home / "state"),
                   FM_CONFIG_OVERRIDE=str(home / "config"), CLAIM_TRACKED_COMMAND=tracked["command"],
                   CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false", CLAUDE_CODE_SEND_FEEDBACK="0")
        env.pop("CLAUDECODE", None)
        args = ["claude", "-p", prompt, "--dangerously-skip-permissions", "--model", "haiku", "--effort", "low",
                "--setting-sources", "project,local", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--settings", '{"feedbackDrafts":"off"}', "--system-prompt", "Follow the regression prompt exactly.",
                "--tools", "Bash", "--output-format", "stream-json", "--verbose", "--max-turns", "8"]
        r = subprocess.run(args, cwd=home, env=env, capture_output=True, text=True, timeout=300)
        ev_path = home / "stop-events.jsonl"
        events = [json.loads(l) for l in ev_path.read_text().splitlines()] if ev_path.exists() else []
        bash_cmds = []
        for line in r.stdout.splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") == "assistant":
                for b in ev.get("message", {}).get("content", []):
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        bash_cmds.append(b.get("input", {}).get("command", "").replace(str(fixture), "<fixture>"))
        rcs = [e["rc"] for e in events]
        replies = [e["payload"].get("last_assistant_message", "")[:60] for e in events]
        reads = len((home / "read-events").read_text().splitlines()) if (home / "read-events").exists() else 0
        print(f"{version} {build} trial {trial}: claude rc={r.returncode} stop rcs={rcs} fixture reads={reads}")
        print(f"  bash commands: {bash_cmds}")
        print(f"  stop replies: {replies}")
        for n, e in enumerate(events):
            if e["rc"]:
                print(f"  stop {n} stderr: {e['stderr'].strip().splitlines()[0][:110]!r}")
        tp = events[-1]["payload"].get("transcript_path") if events else None
        if tp and os.path.exists(tp):
            for l in open(tp):
                row = json.loads(l)
                c = row.get("message", {}).get("content") if isinstance(row.get("message"), dict) else None
                if row.get("type") == "user" and isinstance(c, str) and c.startswith("Stop hook feedback"):
                    print(f"  transcript feedback row: isMeta={row.get('isMeta')} content={c[:150]!r}")
        sys.stdout.flush()
