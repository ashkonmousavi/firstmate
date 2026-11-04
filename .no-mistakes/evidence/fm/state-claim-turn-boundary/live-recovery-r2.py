"""Round 2 live check of commit 9eb6c746 (capacity refusal hint). Real Claude Code runs a
piped fixture activity read (the shape of the 2026-11-04 MAIN rejections), is blocked by the
real tracked Stop hook, and is told to follow the hook's instructions. Run with the branch
bin/ and with a bin/ copy carrying the base guard (old hint). Recovery = a later Stop exits 0
after a standalone fixture read. Prints Stop rcs, Bash commands Claude ran, first stderr."""
import json, os, shutil, subprocess, sys
from pathlib import Path

root, lab, base_guard = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
version = subprocess.check_output(["claude", "--version"], text=True).strip()
settings = json.loads((root / ".claude" / "settings.json").read_text())
tracked = next(h for g in settings["hooks"]["Stop"] for h in g["hooks"] if "fm-turnend-guard.sh" in h.get("command", ""))
base_bin = lab / "base-bin-live"
shutil.copytree(root / "bin", base_bin, symlinks=True)
shutil.copy(base_guard, base_bin / "fm-state-claim-guard.py")
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
cmd = f"bash {fixture} | head -5"
for build, bindir in (("base", base_bin), ("branch", root / "bin")):
    for trial in (1, 2):
        home = lab / f"{build}-{trial}"
        (home / ".claude").mkdir(parents=True)
        (home / "state").mkdir()
        (home / "bin").symlink_to(bindir, target_is_directory=True)
        (home / "AGENTS.md").touch()
        subprocess.run(["git", "init", "-q", str(home)], check=True)
        (home / ".claude" / "settings.json").write_text(json.dumps(
            {"hooks": {"Stop": [{"hooks": [dict(tracked, command=f'python3 "{recorder}"')]}]}}))
        prompt = (f"This is an isolated Stop-hook regression. First use Bash to run exactly: {cmd} . "
                  "Then reply exactly: There are 7 free lanes. If a Stop hook blocks your reply, do what the "
                  "hook message tells you (you may run Bash again), then reply exactly: There are 7 free lanes.")
        env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_STATE_OVERRIDE=str(home / "state"),
                   FM_CONFIG_OVERRIDE=str(home / "config"), CLAIM_TRACKED_COMMAND=tracked["command"],
                   CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false", CLAUDE_CODE_SEND_FEEDBACK="0")
        env.pop("CLAUDECODE", None)
        args = ["claude", "-p", prompt, "--dangerously-skip-permissions", "--model", "haiku", "--effort", "low",
                "--setting-sources", "project,local", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--settings", '{"feedbackDrafts":"off"}', "--system-prompt", "Follow the regression prompt exactly.",
                "--tools", "Bash", "--output-format", "stream-json", "--verbose", "--max-turns", "12"]
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
        recovered = bool(rcs) and rcs[-1] == 0 and 2 in rcs
        print(f"{version} {build} trial {trial}: claude rc={r.returncode} stop rcs={rcs} recovered={recovered}")
        print(f"  bash commands: {bash_cmds}")
        print(f"  first block stderr: {(events[0]['stderr'].strip() if events and events[0]['rc'] else '')!r}")
        sys.stdout.flush()
