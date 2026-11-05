#!/usr/bin/env bash
# Contract tests for the Claude supervisor state-claim Stop check, including
# tracked hook wiring, worker scope, same-turn evidence and the 200ms budget.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-state-claim)
python3 - "$ROOT" "$LAB" <<'PY'
import json
import hashlib
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
activity = lab / "activity.sh"
activity.write_text('#!/usr/bin/env bash\nprintf \'%s\\n\' \'{"readable":true,"lanes":3,"target":10,"free_lanes":7}\'\n')
activity_read = f"bash {activity} --machine-json {primary}"


def tool(command, ident="read", error=False):
    return [
        {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": ident, "name": "Bash", "input": {"command": command}}]}},
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": ident, "content": "OK", "is_error": error}]}},
    ]


def check(label, message, commands=(), expected=2, rows=None, active=False, path=None, hook=False, extra_env=None, extra_payload=None, named_claim=None, capacity_read=True, expected_hint="State claim needs a same-turn read"):
    records = [user] if rows is None else list(rows)
    if capacity_read:
        records.extend(tool(activity_read, ident="activity"))
    for command in commands:
        records.extend(tool(command))
    transcript.write_text("".join(json.dumps(row) + "\n" for row in records))
    payload = {"hook_event_name": "Stop", "session_id": "fixture", "stop_hook_active": active,
               "transcript_path": str(path or transcript), "last_assistant_message": message}
    payload.update(extra_payload or {})
    env = dict(os.environ, FM_ROOT_OVERRIDE=str(primary), FM_HOME=str(primary),
               FM_STATE_OVERRIDE=str(primary / "state"), FM_CONFIG_OVERRIDE=str(primary / "config"),
               CLAUDE_PROJECT_DIR=str(primary), GH_HOST="github.com")
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
        assert expected_hint in result.stderr, (label, result.stderr)
        if named_claim:
            assert named_claim in result.stderr, (label, result.stderr)
        assert not result.stdout, (label, result.stdout)
    else:
        assert not result.stdout and not result.stderr, (label, result.stdout, result.stderr)
    print(f"ok - {label} ({elapsed:.1f}ms)")
    return elapsed


# Claude can append harness text to the same user row as a tool result.
reminder = {"type": "text", "text": "<system-reminder>Read current capacity.</system-reminder>"}
for extra_text in (reminder, {"type": "text", "text": "Hook feedback: continue working."}):
    capacity = tool(activity_read, ident="activity")
    capacity[1]["message"]["content"].append(extra_text)
    check("capacity result with harness text counts: " + extra_text["text"],
          "There are 7 free lanes.", rows=[user, *capacity], capacity_read=False, expected=0)
    later = tool("printf OK", ident="later")
    later[1]["message"]["content"].append(extra_text)
    check("later harness result preserves completed capacity: " + extra_text["text"],
          "There are 7 free lanes.", rows=[user, *tool(activity_read), *later],
          capacity_read=False, expected=0)
    failed = tool(activity_read, ident="failed", error=True)
    failed[1]["message"]["content"].append(extra_text)
    check("failed capacity with harness text does not count: " + extra_text["text"],
          "There are 7 free lanes.", rows=[user, *failed], capacity_read=False)
for human in (user, {"type": "user", "message": {"content": [
        {"type": "text", "text": "Report current state again."}]}}):
    check("human text resets completed capacity: " + repr(human), "There are 7 free lanes.",
          rows=[user, *tool(activity_read), human], capacity_read=False)
    call, result = tool(activity_read)
    check("human text resets pending capacity: " + repr(human), "There are 7 free lanes.",
          rows=[user, call, human, result], capacity_read=False)
# Claude Code 2.1.318 writes Stop hook feedback as an isMeta string user row in
# the same turn (MAIN 593af4e3 row 889). This guard's own refusal must not wipe
# an earlier read; any other feedback (a watcher rewake) or a human row resets.
own_refusal = ("Stop hook feedback:\n[command hook 2]: State claim needs a same-turn read (deploy): "
               "The site is deployed.\nRead activity.sh successfully in this turn.\n")
rewake = "Stop hook feedback:\n[command hook 2]: TURN WOULD END BLIND - SUPERVISION IS OFF\n"
for label, feedback, expected in (
        ("own refusal feedback keeps capacity read",
         {"type": "user", "isMeta": True, "message": {"role": "user", "content": own_refusal}}, 0),
        ("own reply-shape feedback keeps capacity read",
         {"type": "user", "isMeta": True, "message": {"role": "user", "content":
          "Stop hook feedback:\n[command hook 2]: Reply shape: too long. This check blocks only once.\n"}}, 0),
        ("rewake feedback resets capacity read",
         {"type": "user", "isMeta": True, "message": {"role": "user", "content": rewake}}, 2),
        ("own refusal combined with rewake resets capacity read",
         {"type": "user", "isMeta": True, "message": {"role": "user", "content":
          own_refusal + rewake.removeprefix("Stop hook feedback:\n")}}, 2),
        ("human row quoting refusal text resets capacity read",
         {"type": "user", "message": {"role": "user", "content": own_refusal}}, 2)):
    check(label, "There are 7 free lanes.", rows=[user, *tool(activity_read), feedback],
          capacity_read=False, expected=expected)
# Current Claude headers name the full tracked Stop command (row 7192).
stop_command = next(h["command"] for group in json.loads((root / ".claude/settings.json").read_text())["hooks"]["Stop"]
                    for h in group["hooks"] if "fm-turnend-guard.sh" in h.get("command", ""))
check("own refusal under tracked hook header keeps capacity read", "There are 7 free lanes.",
      rows=[user, *tool(activity_read), {"type": "user", "isMeta": True, "message": {"role": "user", "content":
            f"Stop hook feedback:\n[{stop_command}]: State claim needs a same-turn read (deploy): The site is deployed.\n"}}],
      capacity_read=False, expected=0, hook=True)
# A Bash result reports only the last pipeline/chain stage, so a piped or
# chained read cannot prove activity.sh succeeded. The refusal must say so,
# or the agent repeats the same refused read (MAIN 593af4e3, 2026-11-04).
saved = lab / "activity-saved.txt"
for command in (f"{activity_read} | awk '/lanes/' | sort | uniq -c",
                f"{activity_read} > {saved}; echo rc=$?"):
    check("piped or chained capacity read names standalone form: " + command,
          "There are 7 free lanes.", [command], capacity_read=False,
          expected_hint="as its own Bash command")
check("standalone capacity read redirected to a file counts", "There are 7 free lanes.",
      [f"{activity_read} > {saved}"], capacity_read=False, expected=0)


check("planted queue claim without read blocks and names claim", "PR https://github.com/example/repo/pull/9 is in the queue.",
      named_claim="PR https://github.com/example/repo/pull/9 is in the queue.")
check("matching PR read passes", "PR https://github.com/example/repo/pull/9 is merged.",
      ["gh-axi pr view 9 --repo example/repo"], expected=0)
for reader in ("gh", "gh-axi"):
    command = f"{reader} pr list --state merged --repo example/repo --json number --jq length"
    check(f"aggregate merged count accepts {reader} list", "12 PRs merged in the last hour.",
          [command], expected=0)
    check(f"hook aggregate merged count accepts {reader} list", "12 PRs merged in the last hour.",
          [command], hook=True, expected=0)
check("aggregate merged count without a forge read blocks", "12 PRs merged in the last hour.")
check("aggregate merged count accepts any forge read", "12 PRs merged in the last hour.",
      ["gh pr view 9"], expected=0)
check("list count does not prove a named PR", "PR 9 is merged.",
      ["gh pr list --state merged --json number --jq length"])
for reader in ("gh", "gh-axi"):
    for limit in ("--limit 9", "-L 9", "--limit=9", "-L9"):
        for invocation in (reader, f"env GH_HOST=github.com bash /fixture/{reader}",
                           f"{reader} --repo example/repo --hostname github.com"):
            command = f"{invocation} pr list --state merged {limit} --json number --jq length"
            check(f"numeric list option cannot identify a PR: {command}", "PR 9 is merged.", [command])
            check(f"numeric list option still permits aggregate evidence: {command}",
                  "12 PRs merged in the last hour.", [command], expected=0)
    command = f"{reader} pr list --search 'https://github.com/example/repo/pull/9'"
    check(f"list search URL cannot identify a PR: {reader}", "#9 merged.", [command])
    check(f"list search cannot prove a URL claim: {reader}",
          "https://github.com/example/repo/pull/9 merged.", [command])
    check(f"list and direct read permit a named claim: {reader}", "PR 9 is merged.",
          [f"{reader} pr list --limit 9; {reader} pr view 9"], expected=0)
    check(f"list cannot fill a missing coordinated PR read: {reader}", "PRs 9 and 10 are merged.",
          [f"{reader} pr list --limit 9", f"{reader} pr checks 10"])
for reading in ("read it live", "read live"):
    check(f"{reading} is a reading adverb, not deployment",
          f"I just {reading}: https://github.com/example/repo/pull/9 merged.",
          ["gh pr view 9"], expected=0)
    check(f"{reading} does not exempt an unsupported PR claim",
          f"I just {reading}: https://github.com/example/repo/pull/9 merged.")
    check(f"{reading} does not exempt a deployment assertion",
          f"I {reading}: the site is live.", ["gh pr view 9"])
for opening, closing in (("'", "'"), ('"', '"'), ("‘", "’"), ("“", "”")):
    for message, matching, unrelated in (
        (f"PR {opening}#9{closing} is merged.", "gh pr view 9", "gh pr view 10"),
        (f"PR {opening}9{closing} is merged.", "gh pr view 9", "gh pr view 10"),
        (f"The site {opening}https://one.example{closing} is live.",
         "curl https://one.example/health", "curl https://other.example/health"),
        (f"{opening}Lane alpha{closing} is running.",
         "bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"),
        (f"The {opening}alpha lane{closing} is running.",
         "bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"),
        (f"PR 9 is {opening}merged{closing}.", "gh pr view 9", "gh pr view 10"),
        (f"The site is {opening}live{closing}.", "curl https://one.example/health", "gh pr view 9"),
        (f"Lane alpha is {opening}running{closing}.",
         "bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"),
        (f"{opening}PR 9 merged{closing}.", "gh pr view 9", "gh pr view 10"),
    ):
        check(f"short quoted assertion requires a read: {message}", message)
        check(f"short quoted assertion rejects unrelated read: {message}", message, [unrelated])
        check(f"short quoted assertion accepts matching read: {message}", message, [matching], expected=0)
    check(f"quoted earlier state report is not a claim: {opening}",
          f"The guard blocked {opening}PR 9 is merged.{closing} earlier.", expected=0)
    check(f"quoted state does not exempt an assertion: {opening}",
          f"Earlier I said {opening}the site is live{closing}; PR 9 is merged.")
    check(f"quoted identifiers do not require their own reads: {opening}",
          f"Earlier I said {opening}PR 10 is merged{closing}; PR 9 is merged.",
          ["gh pr view 9"], expected=0)
    check(f"quoted clauses and sentences are not claims: {opening}",
          f"The earlier message was {opening}The site is live; PR 9 is merged.\nThe lane is running.{closing}",
          expected=0)
    for contraction in ("I've", "I’ve"):
        report = f"The guard blocked {opening}{contraction} checked: PR 9 is merged.{closing} earlier."
        check(f"quoted contraction remains historical: {opening} {contraction}", report, expected=0)
        check(f"quoted contraction retains a later assertion: {opening} {contraction}",
              f"{report} PR 10 is merged.", ["gh pr view 9"])
        check(f"quoted contraction allows a supported later assertion: {opening} {contraction}",
              f"{report} PR 10 is merged.", ["gh pr view 10"], expected=0)
        check(f"quoted contraction preserves multiline reports: {opening} {contraction}",
              f"The guard blocked {opening}{contraction} checked: PR 9 is merged.\nThe site is live.{closing}",
              expected=0)
for contraction in ("I've", "I’ve"):
    check(f"contraction outside quotes remains text: {contraction}", f"{contraction} checked: PR 9 is merged.")
check("wrong PR read does not count", "PR 9 is merged.", ["gh-axi pr view 10"])
check("PR id embedded in repository name does not count", "PR 9 is merged.", ["gh-axi pr view 10 --repo example/repo9"])
check("separate reads cover multiple PR claims", "PR 9 and PR 10 are merged.",
      ["gh-axi pr view 9", "gh-axi pr view 10"], expected=0)
check("shorthand PR references all require reads", "PR 2775 and #2776 are queued.", ["gh pr view 2775"])
check("shorthand PR references pass with both reads", "PR 2775 and #2776 are queued.",
      ["gh pr view 2775", "gh pr view 2776"], expected=0)
check("bare coordinated PR numbers require reads", "PRs 9 and 10 are merged.", ["gh pr view 9"])
check("bare coordinated PR numbers pass with both reads", "PRs 9 and 10 are merged.",
      ["gh pr view 9", "gh pr view 10"], expected=0)
pr_reads = ["gh pr view 2775", "gh pr view 2776", "gh pr view 2777"]
for listed in ("2775, 2776, and 2777", "2775, 2776, AND 2777", "2775, 2776, & 2777",
               "#2775, #2776, and #2777", "2775, 2776 and 2777"):
    message = f"PRs {listed} are queued."
    for missing in range(3):
        check(f"PR list requires item {missing + 1}: {listed}", message,
              pr_reads[:missing] + pr_reads[missing + 1:])
    check(f"PR list passes with every read: {listed}", message, pr_reads, expected=0)
check("repository identity remains outside the heuristic", "PR https://github.com/other/repo/pull/9 is merged.",
      ["gh pr view 9 --repo example/repo --json title"], expected=0)
check("PR URL host must match the read", "PR https://forge.example/example/repo/pull/9 is merged.",
      ["gh pr view 9"])
check("explicit PR read host matches its claim", "PR https://forge.example/example/repo/pull/9 is merged.",
      ["gh --hostname forge.example pr view 9"], expected=0)
check("short merged reply without a subject passes", "Merged.", expected=0)
check("terse PR-number status blocks", "#9 merged.")
check("non-resource merge is not a state claim", "I merged the duplicate JSON entries.", expected=0)
check("non-resource live adjective is not a state claim", "The live regression passed.", expected=0)
check("inline-code status still names a claim", "PR 9 is `merged`.", named_claim="PR 9 is merged.")
check("last read at passes", "PR 9 was in the queue, last read at 12:00 UTC.", expected=0)
check("unreadable transcript steps aside", "The deploy is live.", path=lab / "absent", expected=0)
check("another hook continuation still gets checked", "The deploy is live.", active=True)
check("own repeated message is exempt once", "The deploy is live.", active=True, expected=0)
check("consumed exemption does not excuse a later watcher continuation", "The deploy is live.", active=True)
check("changed unsupported claim is checked", "PR 9 is merged.", active=True)
check("other session cannot use the previous block", "PR 9 is merged.", active=True,
      extra_payload={"session_id": "other-session"})
check("new user turn is checked again", "PR 9 is merged.")
check("own PR continuation passes", "PR 9 is merged.", active=True, expected=0)
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
check("different URL host does not cover a site claim", "The site https://site.example is live.",
      ["curl https://docs.example/health"])
check("same URL host covers a site claim", "https://site.example is live.",
      ["curl https://site.example/health"], expected=0)
check("PR number in deployment prose does not change read family", "The site is deployed for PR 9.",
      ["curl https://site.example/health"], expected=0)
check("every claimed URL host requires a read", "The sites https://one.example and https://two.example are deployed.",
      ["curl https://one.example/health"])
check("separate host reads cover both site claims", "The sites https://one.example and https://two.example are deployed.",
      ["curl https://one.example/health", "curl https://two.example/health"], expected=0)
check("deploy write does not count", "The deploy is live.", ["curl -X POST https://service.example/deploy"])
check("compact deploy write does not count", "The deploy is live.", ["curl -XPOST https://service.example/deploy"])
check("long deploy write does not count", "The deploy is live.", ["curl --request=POST https://service.example/deploy"])
check("compact data write does not count", "The deploy is live.", ["curl -dvalue https://service.example/deploy"])
check("global repository flag read passes", "PR 9 is merged.", ["gh-axi --repo example/repo pr view 9"], expected=0)
check("PR API read passes", "PR 9 is merged.", ["gh api repos/example/repo/pulls/9"], expected=0)
check("PR API method read passes", "PR 9 is merged.", ["gh api --method GET repos/example/repo/pulls/9"], expected=0)
check("PR API write does not count", "PR 9 is merged.", ["gh api --method PATCH repos/example/repo/pulls/9"])
check("lane read passes", "The worker lane is running.", ["bash bin/fm-crew-state.sh lane-a"], expected=0)
for command in ("fm-crew-state lane-a", "bash bin/fm-crew-state lane-a"):
    check("unsupported extensionless helper does not count: " + command, "Lane lane-a is running.", [command])
check("lane status without read blocks", "The worker lane is running.")
check("different lane name does not cover a lane claim", "Lane lane-b is running.", ["bash bin/fm-crew-state.sh lane-a"])
check("same lane name covers a lane claim", "Lane lane-b is running.", ["bash bin/fm-crew-state.sh lane-b"], expected=0)
check("hyphenated lane name alone requires a matching read", "lane-b is running.", ["bash bin/fm-crew-state.sh lane-a"])
check("lane name substring is not a match", "Lane alpha is running.", ["bash bin/fm-crew-state.sh alpha-extra"])
check("every listed lane name requires a read", "Lanes alpha and beta are running.", ["bash bin/fm-crew-state.sh alpha"])
check("separate reads cover listed lane names", "Lanes alpha and beta are running.",
      ["bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"], expected=0)
for listed in ("alpha, beta, and gamma", "alpha, beta, AND gamma", "alpha, beta, & gamma",
               "alpha, beta and gamma"):
    for message in (f"Lanes {listed} are running.", f"The {listed} lanes are running."):
        for prefix in ("bash bin/fm-crew-state.sh", "bash /fixture/fm-crew-state.sh"):
            reads = [f"{prefix} {name}" for name in ("alpha", "beta", "gamma")]
            for missing in range(3):
                check(f"lane list requires item {missing + 1}: {message} via {prefix}", message,
                      reads[:missing] + reads[missing + 1:])
            check(f"lane list passes with every read: {message} via {prefix}", message, reads, expected=0)
for subject in ("lane", "worker", "crew", "scout", "mate", "task", "supervisor", "watcher", "agent"):
    for message in (f"The alpha {subject} is running.", f"The {subject} alpha is running."):
        check(f"{subject} name requires its own read: {message}", message, ["bash bin/fm-crew-state.sh beta"])
        check(f"{subject} name passes with its own read: {message}", message,
              ["bash bin/fm-crew-state.sh alpha"], expected=0)
for message in ("Lane alpha and worker beta are running.", "The alpha lane and beta worker are running."):
    check(f"coordinated lane subjects retain each name: {message}", message, ["bash bin/fm-crew-state.sh alpha"])
    check(f"coordinated lane subjects accept both reads: {message}", message,
          ["bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"], expected=0)
for opening, closing in (("`", "`"), ("*", "*"), ("**", "**"), ("***", "***"),
                         ("_", "_"), ("__", "__"), ("___", "___"), ("**`", "`**"), ("__**", "**__")):
    for message, matching, unrelated in (
        (f"PR {opening}9{closing} is merged.", "gh pr view 9", "gh pr view 10"),
        (f"{opening}#9{closing} is merged.", "gh pr view 9", "gh pr view 10"),
        (f"Lane {opening}alpha{closing} is running.", "bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"),
        (f"The {opening}alpha{closing} lane is running.", "bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta"),
        (f"The site {opening}https://site.example{closing} is live.", "curl https://site.example/health", "curl https://other.example/health"),
    ):
        check(f"formatted identifier rejects unrelated read: {message}", message, [unrelated])
        check(f"formatted identifier accepts matching read: {message}", message, [matching], expected=0)
for name in ("alpha_beta", "lane_alpha"):
    for message in (f"Lane {name} is running.", f"The {name} lane is running.", f"Lane __{name}__ is running."):
        check(f"underscores inside an identifier remain significant: {message}", message,
              ["bash bin/fm-crew-state.sh " + name.replace("_", "")])
        check(f"underscores inside an identifier retain matching reads: {message}", message,
              [f"bash bin/fm-crew-state.sh {name}"], expected=0)
for name in ("the-alpha", "our-alpha", "still.alpha", "agent-beta"):
    for message in (f"Lane {name} is running.", f"The {name} lane is running."):
        check(f"generic word prefixes retain the full identifier: {message}", message,
              ["bash bin/fm-crew-state.sh beta"])
        check(f"generic word prefixes retain matching reads: {message}", message,
              [f"bash bin/fm-crew-state.sh {name}"], expected=0)
check("generic worker-lane plural remains unnamed", "Both worker lanes are running.",
      ["bash bin/fm-crew-state.sh lane-a"], expected=0)
for subject in ("lanes", "workers", "crews", "scouts", "mates", "tasks", "supervisors", "watchers", "agents"):
    check(f"plural {subject} report requires a read", f"Both {subject} are running.")
    check(f"plural {subject} report passes with a read", f"Both {subject} are running.",
          ["bash bin/fm-crew-state.sh lane-a"], expected=0)
for subject in ("deploy", "deployment", "release", "site"):
    check(f"{subject} subject requires a read", f"The {subject} is live.")
check("qualified sentence does not excuse a second claim", "PR 9 merged, last read at noon. The deploy is live.")
check("negation is not a claim", "The deploy is not live.", expected=0)
check("future state is not a claim", "The deploy will be live after the check.", expected=0)
check("negation cannot excuse a later PR claim", "The deploy is not live, but PR 2775 is queued.",
      named_claim="The deploy is not live, but PR 2775 is queued.")
check("question cannot excuse an earlier assertion", "PR 2775 is queued; can you check?")
check("event timing does not qualify live state", "The site is live before tonight's event.")
for message in ("PR 9 will be queued and merged.", "PR 9 is not queued and merged.",
                "Is PR 9 queued and merged?", "The site will be deployed and live.",
                "The site is not deployed and live.", "Is the site deployed and live?",
                "PR 9 will be queued, merged.", "Is the site deployed, and live?",
                "The lane should be ready and running.", "The lane is not ready and running.",
                "Is the lane ready and running?"):
    check(f"coordinated non-assertion passes: {message}", message, expected=0)
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
                    f"{reader} &"):
        check(f"{label} compound command is not execution evidence: {command!r}", message,
              rows=[user, *tool(command, error=True)])
    check(f"{label} separate completed read still counts after skipped read", message,
          [f"false && {reader}", reader], expected=0)
    check(f"{label} surrounding whitespace preserves a direct read", message,
          [f"\n {reader}\n"], expected=0)
    check(f"{label} environment prefix preserves a direct read", message,
          [f"FM_TEST_READER=1 env {reader}"], expected=0)
    for command in (f"{reader} | cat", f"printf input | {reader}", f"{reader} > output",
                    f"{reader} || true", f"printf ready; {reader}"):
        check(f"{label} unconditional read segment counts: {command}", message, [command], expected=0)
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
check("secondmate supported second Stop allows and closes busy", "The lane is running.",
      ["bash bin/fm-crew-state.sh lane-a"], hook=True, active=True, expected=0)
assert (lab / "verdict").read_text().strip() == "idle"
(linked / ".fm-secondmate-home").unlink()
check("ship and scout worktree is exempt", "The deploy is live.", hook=True, expected=0)

primary = lab / "primary"
capacity_phrases = (
    "Laptop 8 live of 8, admission no.",
    "Laptop 3 live of 10.",
    "PC has 2 free of 8.",
    "PC: 3 working, 7 available.",
    "Laptop: 3 of 10 occupied.",
    "Server: 3/10 live.",
    "3 lanes are working.",
    "Three lanes are working.",
    "Seats are full.",
    "Slots are available.",
    "Capacity is 8.",
    "Admission no.",
    "Admission yes.",
    "No room.",
    "3 free.",
    "N live of M.",
    "lane-b is running.",
    "Lane alpha and worker beta are running.",
    "The alpha lane and beta worker are running.",
    "Lane alpha is not running.",
    "0 free seats.",
)
for message in capacity_phrases:
    check("21-case capacity replay blocks without activity: " + message, message, capacity_read=False)
    check("21-case capacity replay blocks repeated Stop: " + message, message,
          capacity_read=False, active=True)
    check("21-case capacity replay accepts activity and named reads: " + message, message,
          ["bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta",
           "bash bin/fm-crew-state.sh lane-b"], expected=0)
for assertion in ("PC has 2 free", "2 seats are available", "3 slots are occupied",
                  "Admission no", "No room", "lane-b is running",
                  "Lane alpha and worker beta are running"):
    crew_reads = ["bash bin/fm-crew-state.sh alpha", "bash bin/fm-crew-state.sh beta",
                  "bash bin/fm-crew-state.sh lane-b"]
    for separator in ("; ", ". ", "! ", ", "):
        message = assertion + separator + "should I fill them?"
        check("trailing question cannot exempt capacity: " + message, message,
              crew_reads, capacity_read=False)
        check("repeated trailing question cannot exempt capacity: " + message, message,
              crew_reads, capacity_read=False, active=True)
        check("supported assertion can precede a question: " + message, message, crew_reads, expected=0)
    check("leading question cannot exempt capacity: " + assertion, "Should I fill them? " + assertion + ".",
          crew_reads, capacity_read=False)
for question in ("how many lanes are free?", "How many seats are available?",
                 "Are slots occupied?", "Is admission no?", "Is there no room?",
                 "Is lane-b running?", "Are lane alpha and worker beta running?"):
    for prefix in ("", "👉 ", "- ", "+ ", "* ", "1. ", "1) ", "• ", "  - 👉 ", "👉 - "):
        check("pure capacity question needs no activity: " + prefix + question, prefix + question,
              capacity_read=False, expected=0)
for prefix in ("👉 ", "- ", "+ ", "* ", "1. ", "1) ", "• ", "  - 👉 ", "👉 - "):
    message = prefix + "PC has 2 free; should I fill them?"
    check("presentation cannot exempt an assertion: " + prefix, message, capacity_read=False)
    check("presentation cannot exempt repeated assertion: " + prefix, message, capacity_read=False, active=True)
    check("supported formatted assertion passes: " + prefix, message, expected=0)
for records in ([user, *tool(activity_read, error=True)],
                [user, *tool(activity_read), user],
                [user, tool(activity_read)[0]],
                [user, *tool("printf 'check-wake: activity.sh read completed'")]):
    check("capacity needs a completed successful current-turn read", capacity_phrases[0],
          rows=records, capacity_read=False)
alias = lab / "activity-alias.sh"
alias.symlink_to(activity)
for command in (str(activity), f"bash {activity}", f"bash {alias}", "bash ./activity.sh"):
    check("21-case capacity reader spelling: " + command, capacity_phrases[0], [command],
          capacity_read=False, expected=0, extra_payload={"cwd": str(lab)})

bad_state = lab / "state-file"
bad_state.write_text("not a directory\n")
directory_state = lab / "marker-directory"
directory_state.mkdir()
directory_marker = directory_state / (".state-claim-" + hashlib.sha256(b"fixture").hexdigest() + ".blocked")
directory_marker.mkdir()
for state in (bad_state, directory_state):
    for active in (False, True):
        check("marker I/O cannot allow unsupported capacity", capacity_phrases[0],
              capacity_read=False, active=active, extra_env={"FM_STATE_OVERRIDE": str(state)})
        check("marker I/O cannot block supported capacity", capacity_phrases[0],
              expected=0, active=active, extra_env={"FM_STATE_OVERRIDE": str(state)})
config = lab / "reply-config"
config.mkdir()
(config / "reply-shape").write_text("ask-first\n")
check("reply-shape marker failure cannot allow capacity", "PC has 2 free. Can you approve?",
      capacity_read=False, extra_env={"FM_STATE_OVERRIDE": str(bad_state), "FM_CONFIG_OVERRIDE": str(config)},
      expected_hint="Reply shape:")
timings = [check(f"budget sample {i}", "PR 9 is merged.", hook=True) for i in range(5)]
assert max(timings) < 200, f"guard exceeded 200ms: {timings}"
print(f"ok - full synchronous hook worst time {max(timings):.1f}ms < 200ms")

# Reply-shape policy is opt-in per home; these cases exercise the executable,
# including the tracked Stop registration, without rewriting owner rules.
(primary / "config").mkdir(exist_ok=True)
reply_config = primary / "config/reply-shape"
reply_failures = []
reply_times = []


def reply_check(label, message, expected, rules="ask-first\npacific-times\npr-urls\n",
                active=False, hook=False, path=None, payload_extra=None):
    reply_config.write_text(rules)
    transcript.write_text(json.dumps(user) + "\n")
    payload = {"hook_event_name": "Stop", "session_id": "reply-fixture", "stop_hook_active": active,
               "transcript_path": str(path or transcript), "last_assistant_message": message}
    payload.update(payload_extra or {})
    env = dict(os.environ, FM_ROOT_OVERRIDE=str(primary), FM_HOME=str(primary),
               FM_STATE_OVERRIDE=str(primary / "state"), FM_CONFIG_OVERRIDE=str(primary / "config"),
               CLAUDE_PROJECT_DIR=str(primary))
    args = ["python3", str(module)]
    if hook:
        settings = json.loads((root / ".claude/settings.json").read_text())
        command = next(h["command"] for group in settings["hooks"]["Stop"] for h in group["hooks"]
                       if "fm-turnend-guard.sh" in h.get("command", ""))
        args = ["sh", "-c", command]
    start = time.perf_counter()
    result = subprocess.run(args, input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=3)
    reply_times.append((time.perf_counter() - start) * 1000)
    passed = result.returncode == expected and not result.stdout
    if expected == 2:
        passed = passed and "Reply shape" in result.stderr
    else:
        passed = passed and not result.stderr
    print(f"{'ok' if passed else 'not ok'} - reply {label}: expected {expected}, got {result.returncode}")
    if not passed:
        reply_failures.append((label, result.returncode, result.stderr))


valid_ask = "👉 **Choose** A) continue or B) defer, because checks passed; by 10:00 PT, otherwise continue."
reply_check("late ask", "The report is ready.\n" + valid_ask, 2)
reply_check("bold lettered first-line ask", valid_ask + "\nThe report is ready.", 0)
reply_check("bold answer letters", "👉 **A** continue or **B** defer?", 0)
reply_check("should-I direct question", "Should I continue?", 2)
reply_check("address can follow ask marker", "👉 Captain, **choose** A) continue or B) defer?", 0)
reply_check("unmarked direct question", "Can you approve this?", 2)
reply_check("unmarked imperative ask", "Please choose A or B.", 2)
reply_check("unbolded ask", "👉 Choose A) continue or B) defer?", 2)
reply_check("ask lacks one-letter answer", "👉 **Choose** continue or defer?", 2)
reply_check("leading blank is not first line", "\n" + valid_ask, 2)
reply_check("no ask needs no marker", "The report is ready.", 0)
reply_check("quoted ask is evidence", '> Earlier: 👉 **Choose** A) continue?\nThe report is ready.', 0)
for opening, closing in (("'", "'"), ('"', '"'), ("‘", "’"), ("“", "”")):
    for record in ("Meet at 18:00 UTC.", "Can you approve this change?",
                   "PR 9 needs review.", "MR 9 needs review."):
        reply_check("quoted record " + opening + record,
                    f"The log says {opening}{record}{closing}", 0)
    reply_check("quoted record does not exempt current UTC " + opening,
                f"The log says {opening}Meet at 18:00 UTC.{closing} Meet at 19:00 UTC.", 2)
    reply_check("quoted record does not exempt current PR " + opening,
                f"The log says {opening}PR 9 needs review.{closing} PR 10 needs review.", 2)
    reply_check("multiline quoted record " + opening,
                f"{opening}Can you approve this change?\nMeet at 18:00 UTC. PR 9 needs review.{closing}", 0)
    reply_check("multiline quote cannot promote a late ask " + opening,
                f"{opening}Can you approve this change?\nMeet at 18:00 UTC.{closing}{valid_ask}", 2)
    for short in ("18:00 UTC", "Can you", "PR 9", "MR 9"):
        reply_check("short quote remains checked " + opening + short,
                    f"The log says {opening}{short}{closing}", 2)
    for contraction in ("I've", "I’ve"):
        reply_check("quoted contraction " + opening + contraction,
                    f"The log says {opening}{contraction} checked: PR 9 needs review at 18:00 UTC.{closing}", 0)
reply_check("fenced record may use UTC", "```text\nrecord=2026-11-03T18:00:00Z\n```\nThe report is ready.", 0)
reply_check("inline record may use UTC", "The record contains `2026-11-03T18:00:00Z`.", 0)
for stamp in ("18:00 UTC", "18:00Z", "2026-11-03T18:00:00Z", "2026-11-03T18:00:00+00:00", "18:00 GMT", "UTC 18:00"):
    reply_check("UTC clock " + stamp, "Last read at " + stamp + ".", 2)
for stamp in ("10:00 PT", "10:00 PST", "11:00 PDT", "10:00 Pacific", "10:00"):
    reply_check("local clock " + stamp, "Last read at " + stamp + ".", 0)
# Fresh-reader counterexamples and siblings use the same public Stop seam.
for stamp in (
    "6pm UTC", "6 PM utc", "6 p.m. U.T.C.", "6:30 p.m. UTC", "six pm UTC",
    "six thirty PM UTC", "six o'clock UTC", "six o’clock UTC", "half past six UTC",
    "quarter to seven UTC", "noon UTC", "midnight GMT", "eighteen hundred Zulu",
    "six Coordinated Universal Time", "six Greenwich Mean Time", "six U T C",
    "UTC six pm", "UTC noon", "U.T.C. 6pm", "GMT midnight",
    "6pm +00:00", "6pm +0000", "6pm +00", "six pm -00:00", "noon +00",
    "18:00+00", "18:00-0000", "18:00 UTC+0", "18:00 GMT +00:00",
    "6pm UTC-08:00", "06:00:00.123Z", "2026-11-03T060000Z",
):
    reply_check("UTC spelling " + stamp, "Meet at " + stamp + ".", 2)
for stamp in ("6pm PT", "six pm Pacific", "noon PST", "midnight PDT", "6 p.m."):
    reply_check("local spelling " + stamp, "Meet at " + stamp + ".", 0)
reply_check("UTC word without clock", "Records may use UTC.", 0)
reply_check("unrelated URL cannot cover named pull", "PR 9 needs review. https://github.com/example/repo/pull/10", 2)
reply_check("named pull has URL", "PR 9 needs review.\nhttps://github.com/example/repo/pull/9", 0)
reply_check("bare named pull", "PR 9 needs review.", 2)
reply_check("coordinated pull list needs every URL", "PRs 9 and 10 need review.\nhttps://github.com/example/repo/pull/9", 2)
reply_check("coordinated pull list covered", "PRs 9 and 10 need review.\nhttps://github.com/example/repo/pull/9\nhttps://github.com/example/repo/pull/10", 0)
reply_check("HTTP pull URL is insufficient", "PR 9 needs review.\nhttp://github.com/example/repo/pull/9", 2)
for reference in ("Pull request 12", "pull requests #12", "PULL REQUEST #12", "pull-request 12",
                  "PR#12", "MR 12", "MR !12", "MRs !12", "Merge request !12", "merge requests 12"):
    reply_check("named reference needs link " + reference.split()[0], reference + " is ready for review.", 2)
for reference, route in (("Pull request 12", "pull"), ("PR#12", "pulls"),
                         ("MR !12", "-/merge_requests"), ("Merge request 12", "merge_requests")):
    link = "https://forge.example/repo/" + route + "/12"
    reply_check("expanded reference linked " + route, reference + " is ready for review.\n" + link, 0)
    reply_check("expanded reference missing URL " + route,
                reference + ": URL unavailable in ready status or metadata.", 0)
reply_check("expanded list needs every URL", "Pull requests 12, 13 and 14 need review.\nhttps://forge.example/repo/pull/12", 2)
reply_check("merge list needs every URL", "MRs !12 and !13 need review.\nhttps://forge.example/repo/-/merge_requests/12", 2)
reply_check("merge list linked", "MRs !12 and !13 need review.\nhttps://forge.example/repo/-/merge_requests/12\nhttps://forge.example/repo/-/merge_requests/13", 0)
reply_check("HTTP merge link insufficient", "MR !12 needs review.\nhttp://forge.example/repo/-/merge_requests/12", 2)
reply_check("short issue reference is not assumed pull", "Issue #9 needs review.", 0)
reply_check("generic pull mention", "The fix needs a PR.", 0)
reply_check("unknown URL exception", "PR 9 needs review; URL unavailable in ready status or metadata.", 0)
for singular, plural, prefix, route in (("PR", "PRs", "", "pull"),
                                        ("Pull request", "Pull requests", "#", "pulls"),
                                        ("MR", "MRs", "!", "-/merge_requests"),
                                        ("Merge request", "Merge requests", "!", "merge_requests")):
    first, second = f"{singular} {prefix}9", f"{singular} {prefix}10"
    link = f"https://forge.example/repo/{route}/10"
    reply_check("disclosure cannot cross reference " + singular,
                f"{first} needs review; {second}: URL unavailable in ready status or metadata.\n{link}", 2)
    reply_check("forward disclosure cannot cross reference " + singular,
                f"URL unavailable for {second}; {first} needs review.\n{link}", 2)
    reply_check("forward disclosure overrides preceding reference " + singular,
                f"{first} needs review; URL unavailable for {second}.\n{link}", 2)
    reply_check("individual disclosures cover both references " + singular,
                f"{first}: URL unavailable; {second}: URL unavailable.", 0)
    for separator in (" and ", ", ", ", and ", " & "):
        references = f"{plural} {prefix}9{separator}{prefix}10"
        for message in (f"{references}: URL unavailable in ready status or metadata.",
                        f"URL unavailable for {references}."):
            reply_check("shared disclosure " + references, message, 0)
        reply_check("shared disclosure leaves another reference checked " + references,
                    f"{references}: URL unavailable. {singular} {prefix}11 needs review.", 2)
reply_check("PR disclosure does not exempt same-number MR",
            "PR 9: URL unavailable. MR 9 needs review.", 2)
reply_check("MR disclosure does not exempt same-number PR",
            "MR 9: URL unavailable. PR 9 needs review.", 2)
reply_check("inline pull identifier still checked", "PR `9` needs review.", 2)
reply_check("quoted pull identifier is evidence", '> PR 9 needs review.\nThe report is ready.', 0)
reply_check("tilde fenced record", "~~~text\nrecord=18:00 UTC\n~~~\nThe report is ready.", 0)
reply_check("legacy stock home opts out", "PR 9 needs review at 18:00 UTC.", 0, rules="")
reply_check("rule selection is independent", "PR 9 needs review at 18:00 UTC.", 2, rules="pacific-times\n")
reply_check("shape does not require transcript", "Last read at 18:00 UTC.", 2, path=lab / "absent")
reply_check("tracked hook checks shape", "Last read at 18:00 UTC.", 2, hook=True)
reply_check("own identical continuation passes once", "Last read at 18:00 UTC.", 0, active=True, hook=True)
reply_check("exemption consumed", "Last read at 18:00 UTC.", 2, active=True, hook=True)
reply_check("changed continuation checked", "Last read at 19:00 UTC.", 2, active=True)
reply_check("corrected continuation passes", "Last read at 11:00 PT.", 0, active=True)
reply_check("non-Stop payload inert", "Last read at 18:00 UTC.", 0, payload_extra={"hook_event_name": "SubagentStop"})
reply_check("foreign compatibility hook inert", "Last read at 18:00 UTC.", 0, hook=True,
            payload_extra={"cursor_version": "fixture"})
print(f"ok - reply samples worst time {max(reply_times):.1f}ms; existing five-sample hook budget above remains enforced")
# A malformed optional policy must not disable the existing claim guard.
reply_config.unlink()
os.mkfifo(reply_config)
check("FIFO reply config cannot hang or exempt a state claim", "The deploy is live.")
reply_config.unlink()
reply_config.write_text("x" * 5000)
check("oversized reply config cannot exempt a state claim", "The deploy is live.")
reply_config.unlink()
reply_config.write_text("")
assert not reply_failures, reply_failures
reply_config.unlink()
PY
