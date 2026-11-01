#!/usr/bin/env bash
# Contract tests for the Claude supervisor state-claim Stop check, including
# tracked hook wiring, worker scope, same-turn evidence and the 200ms budget.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-state-claim)
python3 - "$ROOT" "$LAB" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root, lab = map(Path, sys.argv[1:])
transcript = lab / "transcript.jsonl"
primary = lab / "primary"
primary.mkdir()
subprocess.run(["git", "init", "-q", str(primary)], check=True)
(primary / "AGENTS.md").touch()
(primary / "bin").symlink_to(root / "bin", target_is_directory=True)
(primary / "state").mkdir()
module = root / "bin/fm-state-claim-guard.py"
user = {"type": "user", "message": {"role": "user", "content": "Report current state."}}


def tool(command, ident="read", error=False):
    return [
        {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": ident, "name": "Bash", "input": {"command": command}}]}},
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": ident, "content": "OK", "is_error": error}]}},
    ]


def check(label, message, commands=(), expected=2, rows=None, active=False, path=None, hook=False, extra_env=None, extra_payload=None, named_claim=None):
    records = [user] if rows is None else list(rows)
    for command in commands:
        records.extend(tool(command))
    transcript.write_text("".join(json.dumps(row) + "\n" for row in records))
    payload = {"hook_event_name": "Stop", "session_id": "fixture", "stop_hook_active": active,
               "transcript_path": str(path or transcript), "last_assistant_message": message}
    payload.update(extra_payload or {})
    env = dict(os.environ, FM_ROOT_OVERRIDE=str(primary), FM_HOME=str(primary),
               FM_STATE_OVERRIDE=str(primary / "state"), FM_CONFIG_OVERRIDE=str(primary / "config"),
               CLAUDE_PROJECT_DIR=str(primary))
    env.update(extra_env or {})
    if hook:
        settings = json.loads((root / ".claude/settings.json").read_text())
        command = next(h["command"] for group in settings["hooks"]["Stop"] for h in group["hooks"]
                       if "fm-turnend-guard.sh" in h.get("command", ""))
        args = ["sh", "-c", command]
    else:
        args = ["python3", str(module)]
    start = time.perf_counter()
    result = subprocess.run(args, input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=3)
    elapsed = (time.perf_counter() - start) * 1000
    assert result.returncode == expected, (label, result.returncode, result.stdout, result.stderr)
    if expected == 2:
        assert "State claim needs a same-turn read" in result.stderr, (label, result.stderr)
        if named_claim:
            assert named_claim in result.stderr, (label, result.stderr)
        assert not result.stdout, (label, result.stdout)
    else:
        assert not result.stdout and not result.stderr, (label, result.stdout, result.stderr)
    print(f"ok - {label} ({elapsed:.1f}ms)")
    return elapsed


check("planted queue claim without read blocks and names claim", "PR https://github.com/example/repo/pull/9 is in the queue.",
      named_claim="PR https://github.com/example/repo/pull/9 is in the queue.")
check("matching PR read passes", "PR https://github.com/example/repo/pull/9 is merged.",
      ["gh-axi pr view 9 --repo example/repo"], expected=0)
check("wrong PR read does not count", "PR 9 is merged.", ["gh-axi pr view 10"])
check("PR id embedded in repository name does not count", "PR 9 is merged.", ["gh-axi pr view 10 --repo example/repo9"])
check("separate reads cover multiple PR claims", "PR 9 and PR 10 are merged.",
      ["gh-axi pr view 9", "gh-axi pr view 10"], expected=0)
check("short merged claim blocks", "Merged.")
check("inline-code status still names a claim", "PR 9 is `merged`.", named_claim="PR 9 is merged.")
check("last read at passes", "PR 9 was in the queue, last read at 12:00 UTC.", expected=0)
check("unreadable transcript steps aside", "The deploy is live.", path=lab / "absent", expected=0)
check("second block does not fire", "The deploy is live.", active=True, expected=0)
check("old turn read does not count", "PR 9 is merged.", rows=[user, *tool("gh-axi pr view 9"), user])
check("tool results do not start another turn", "PR 9 is merged.", ["gh pr checks 9 --repo example/repo"], expected=0)
check("wrong state family does not count", "The deploy is live.", ["gh-axi pr view 9"])
check("write commands do not count", "PR 9 is merged.", ["gh pr merge 9 --merge"])
check("echoed read text does not count", "PR 9 is merged.", ["echo 'gh-axi pr view 9'"])
check("completed nonzero checks read still counts", "PR 9 is in the queue.",
      rows=[user, *tool("gh pr checks 9", error=True)], expected=0)
check("heredoc example does not count", "PR 9 is merged.", ["cat <<'EOF'\ngh-axi pr view 9\nEOF"])
check("deploy URL read passes", "The deploy is live.", ["curl -fsS https://service.example/health"], expected=0)
check("curl fail-on-error read passes", "The deploy is deployed.", ["curl -f https://service.example/health"], expected=0)
check("deploy write does not count", "The deploy is live.", ["curl -X POST https://service.example/deploy"])
check("compact deploy write does not count", "The deploy is live.", ["curl -XPOST https://service.example/deploy"])
check("long deploy write does not count", "The deploy is live.", ["curl --request=POST https://service.example/deploy"])
check("compact data write does not count", "The deploy is live.", ["curl -dvalue https://service.example/deploy"])
check("global repository flag read passes", "PR 9 is merged.", ["gh-axi --repo example/repo pr view 9"], expected=0)
check("PR API read passes", "PR 9 is merged.", ["gh api repos/example/repo/pulls/9"], expected=0)
check("PR API method read passes", "PR 9 is merged.", ["gh api --method GET repos/example/repo/pulls/9"], expected=0)
check("PR API write does not count", "PR 9 is merged.", ["gh api --method PATCH repos/example/repo/pulls/9"])
check("lane read passes", "The worker lane is running.", ["bash bin/fm-crew-state.sh lane-a"], expected=0)
check("lane status without read blocks", "The worker lane is running.")
check("qualified sentence does not excuse a second claim", "PR 9 merged, last read at noon. The deploy is live.")
check("negation is not a claim", "The deploy is not live.", expected=0)
check("future state is not a claim", "The deploy will be live after the check.", expected=0)
check("negation cannot excuse a later PR claim", "The deploy is not live, but PR 2775 is queued.",
      named_claim="The deploy is not live, but PR 2775 is queued.")
check("question cannot excuse an earlier assertion", "PR 2775 is queued; can you check?")
check("event timing does not qualify live state", "The site is live before tonight's event.")
for label, assertion, negative, future, question in [
    ("PR", "PR 9 is merged", "PR 9 is not merged", "PR 9 would be merged", "Is PR 9 merged?"),
    ("deploy", "The site is live", "The site is not live", "The site will be live", "Is the site live?"),
    ("lane", "The lane is running", "The lane is not running", "The lane should be running", "Is the lane running?"),
]:
    check(f"{label} negation passes", negative + ".", expected=0)
    check(f"{label} future passes", future + ".", expected=0)
    check(f"{label} question passes", question, expected=0)
    check(f"{label} pending negation passes", negative.replace("not ", "not yet ") + ".", expected=0)
    for separator in (", but ", "; ", " and ", " — "):
        check(f"{label} negation stays in its clause {separator!r}", f"The check is not complete{separator}{assertion}.")
        check(f"{label} modal stays in its clause {separator!r}", f"The check will finish{separator}{assertion}.")
        check(f"{label} trailing question stays in its clause {separator!r}", f"{assertion}{separator}can you check?")
    check(f"{label} leading question stays in its clause", f"Can you check? {assertion}.")
for label, message, reader in [
    ("PR", "PR 2775 is merged.", "gh pr view 2775"),
    ("deploy", "The deploy is live.", "curl https://service.example/health"),
    ("lane", "The lane is running.", "bash bin/fm-crew-state.sh lane-a"),
]:
    for command in (f"cd /removed-worktree && {reader}", f"true || {reader}",
                    f"false &&\n{reader}", f"exit 0; {reader}",
                    f"if false; then {reader}; fi", f"if false\nthen\n{reader}\nfi",
                    f"false && ({reader})", f"false && echo skipped | {reader}",
                    f"{reader} &", f"{reader} >/removed-worktree/output"):
        check(f"{label} compound command is not execution evidence: {command!r}", message,
              rows=[user, *tool(command, error=True)])
    check(f"{label} separate completed read still counts after skipped read", message,
          [f"false && {reader}", reader], expected=0)
    check(f"{label} surrounding whitespace preserves a direct read", message,
          [f"\n {reader}\n"], expected=0)
    check(f"{label} environment prefix preserves a direct read", message,
          [f"FM_TEST_READER=1 env {reader}"], expected=0)
check("code example is not a claim", "Example: `PR 9 is merged`.\n```text\nThe deploy is live.\n```", expected=0)
check("live-check description is not a claim", "I added a live check and a running-time test.", expected=0)
check("latest payload wins over stale transcript text", "Implementation complete.",
      rows=[user, {"type": "assistant", "message": {"content": [{"type": "text", "text": "The deploy is live."}]}}], expected=0)
check("missing turn boundary steps aside", "The deploy is live.", rows=[], expected=0)
check("malformed transcript steps aside", "The deploy is live.", rows=["broken"], expected=0)
fifo = lab / "transcript-fifo"
os.mkfifo(fifo)
check("nonregular transcript steps aside without blocking", "The deploy is live.", path=fifo, expected=0)
check("tracked Stop hook blocks an idle MAIN claim", "PR 9 is merged.", hook=True)
check("tracked Stop hook allows a read", "PR 9 is merged.", ["gh-axi pr view 9"], hook=True, expected=0)
check("foreign compatibility hook stays inert", "The deploy is live.", hook=True, expected=0,
      extra_env={"GROK_AGENT": "1"})
check("Cursor compatibility hook stays inert", "The deploy is live.", hook=True, expected=0,
      extra_payload={"cursor_version": "fixture"})
pi_transcript = lab / ".pi/session.jsonl"
pi_transcript.parent.mkdir()
pi_transcript.write_text(json.dumps(user) + "\n")
check("Pi compatibility hook stays inert", "The deploy is live.", hook=True, path=pi_transcript, expected=0)

# A marked linked home is a secondmate; its Stop exit must keep its parent's
# busy record open. Removing only the marker gives the identical worker shape.
linked = lab / "linked"
subprocess.run(["git", "-C", str(primary), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "-qm", "fixture"], check=True)
# Tests alone may create isolated worktrees in their temporary fixture repo.
subprocess.run(["git", "-C", str(primary), "worktree", "add", "-q", "--detach", str(linked)], check=True)
(linked / "bin").symlink_to(root / "bin", target_is_directory=True)
(linked / "AGENTS.md").touch()
(linked / "state").mkdir()
(linked / ".fm-secondmate-home").write_text("mate-a\n")
writer = lab / "busy-writer"
writer.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$4" > "$2/verdict"\n')
writer.chmod(0o755)
(linked / ".fm-busy-stop").write_text(f"writer={writer}\nstate={lab}\nid=mate-a\ngen=1\n")
primary = linked
check("secondmate claim blocks", "The lane is running.", hook=True)
assert (lab / "verdict").read_text().strip() == "busy"
check("secondmate second Stop allows and closes busy", "The lane is running.", hook=True, active=True, expected=0)
assert (lab / "verdict").read_text().strip() == "idle"
(linked / ".fm-secondmate-home").unlink()
check("ship and scout worktree is exempt", "The deploy is live.", hook=True, expected=0)

primary = lab / "primary"
timings = [check(f"budget sample {i}", "PR 9 is merged.", hook=True) for i in range(5)]
assert max(timings) < 200, f"guard exceeded 200ms: {timings}"
print(f"ok - full synchronous hook worst time {max(timings):.1f}ms < 200ms")
PY
