"""Drive the tracked Claude Stop hook command (.claude/settings.json -> fm-turnend-guard.sh
--claude --state-claims) in a disposable primary home, once with the branch bin/ and once with
a copy of bin/ whose state-claim guard is the base commit's. Prints one line per scenario.
Round 3 adds Stop-hook-feedback rows (isMeta string rows, real 2.1.318 shape) for commit b3ea705d."""
import json, os, shutil, subprocess, sys
from pathlib import Path

root, lab, base_guard = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
base_bin = lab / "base-bin"
shutil.copytree(root / "bin", base_bin, symlinks=True)
shutil.copy(base_guard, base_bin / "fm-state-claim-guard.py")
activity = lab / "activity.sh"
activity.write_text('#!/usr/bin/env bash\necho \'{"free_lanes":7}\'\n')
activity.chmod(0o755)
read_cmd = f"bash {activity} --machine-json"
settings = json.loads((root / ".claude/settings.json").read_text())
hook = next(h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]
            if "fm-turnend-guard.sh" in h.get("command", ""))
print("tracked Stop hook command:", hook)

human = {"type": "user", "message": {"role": "user", "content": "How many lanes are free?"}}
reminder = {"type": "text", "text": "<system-reminder>The task tools haven't been used recently.</system-reminder>"}
hook_text = {"type": "text", "text": "PostToolUse hook additional context: keep going."}


def call(ident, cmd=read_cmd):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": ident, "name": "Bash", "input": {"command": cmd}}]}}


def result(ident, *extra, error=False):
    return {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": ident, "content": "{\"free_lanes\":7}", "is_error": error}, *extra]}}


def meta(text):
    return {"type": "user", "isMeta": True, "message": {"role": "user", "content": text}}


OWN_PR = ('Stop hook feedback:\n[python3 "/tmp/lab/record.py"]: State claim needs a same-turn read (PR): PR #12 is merged.\n'
          "Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.\n")
OWN_SHAPE = "Stop hook feedback:\n[command hook 2]: Reply shape: too long. This check blocks only once.\n"
OWN_CAP_TRACKED = f"Stop hook feedback:\n[{hook}]: State claim needs a same-turn read (capacity): There are 7 free lanes.\nRun activity.sh ...\n"
OTHER = ("Stop hook feedback:\n[command hook 2]: TURN WOULD END BLIND - SUPERVISION IS OFF\n"
         "11 task(s) in flight, but no live watcher holds this home lock (last beat: 319s ago).\n")

scenarios = [
    ("activity read, result row carries system-reminder text", [human, call("a"), result("a", reminder)], 0),
    ("activity read, result row carries hook text", [human, call("a"), result("a", hook_text)], 0),
    ("activity read, then a later unrelated result row with reminder", [human, call("a"), result("a"), call("b", "printf ok"), result("b", reminder)], 0),
    ("plain activity read, no extra text (control)", [human, call("a"), result("a")], 0),
    ("ADVERSARIAL failed (is_error) activity read with reminder", [human, call("a"), result("a", reminder, error=True)], 2),
    ("ADVERSARIAL human string message after completed read", [human, call("a"), result("a"), human], 2),
    ("ADVERSARIAL human text-block message after completed read", [human, call("a"), result("a"),
        {"type": "user", "message": {"content": [{"type": "text", "text": "And now?"}]}}], 2),
    ("ADVERSARIAL human message between tool_use and its result", [human, call("a"), human, result("a", reminder)], 2),
    ("ADVERSARIAL no read at all", [human], 2),
    ("own PR refusal feedback row after read keeps capacity read", [human, call("a"), result("a"), meta(OWN_PR)], 0),
    ("own reply-shape feedback row after read keeps capacity read", [human, call("a"), result("a"), meta(OWN_SHAPE)], 0),
    ("own capacity refusal (header = tracked command) after read keeps read", [human, call("a"), result("a"), meta(OWN_CAP_TRACKED)], 0),
    ("ADVERSARIAL own refusal feedback but no read in turn", [human, meta(OWN_PR)], 2),
    ("ADVERSARIAL other hook feedback (real supervision rewake text) resets read", [human, call("a"), result("a"), meta(OTHER)], 2),
    ("ADVERSARIAL own refusal + other hook in one feedback row resets read", [human, call("a"), result("a"), meta(OWN_PR + OTHER.removeprefix("Stop hook feedback:\n"))], 2),
    ("ADVERSARIAL non-meta human row forging own refusal text resets read", [human, call("a"), result("a"), {"type": "user", "message": {"role": "user", "content": OWN_PR}}], 2),
    ("ADVERSARIAL read before previous human turn, own feedback in this turn", [human, call("a"), result("a"), human, meta(OWN_PR)], 2),
    ("ADVERSARIAL own feedback row then a human row", [human, call("a"), result("a"), meta(OWN_PR), human], 2),
]

for label, rows, expected in scenarios:
    out = {}
    for build, bindir in (("base", base_bin), ("branch", root / "bin")):
        home = lab / f"home-{build}"
        if not home.exists():
            home.mkdir()
            subprocess.run(["git", "init", "-q", str(home)], check=True)
            (home / "AGENTS.md").touch()
            (home / "state").mkdir()
            (home / "bin").symlink_to(bindir, target_is_directory=True)
        transcript = home / "transcript.jsonl"
        transcript.write_text("".join(json.dumps(r) + "\n" for r in rows))
        payload = {"hook_event_name": "Stop", "session_id": "lab", "stop_hook_active": False,
                   "transcript_path": str(transcript), "cwd": str(home),
                   "last_assistant_message": "There are 7 free lanes."}
        env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "CLAUDE"))}
        env.update(FM_ROOT_OVERRIDE=str(home), FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / "state"),
                   FM_CONFIG_OVERRIDE=str(home / "config"), CLAUDE_PROJECT_DIR=str(home))
        p = subprocess.run(["sh", "-c", hook], input=json.dumps(payload), text=True, capture_output=True,
                           env=env, cwd=home, timeout=20)
        out[build] = (p.returncode, p.stderr.strip().splitlines()[0][:70] if p.stderr.strip() else "")
    verdict = "PASS" if out["branch"][0] == expected else "FAIL"
    print(f"{verdict} | {label} | expected branch rc={expected} | base rc={out['base'][0]} | branch rc={out['branch'][0]} {out['branch'][1]!r}")
