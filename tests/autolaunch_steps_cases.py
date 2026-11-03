"""Step-pass executable fixtures, invoked by fm-autolaunch.test.sh.

Task storage and inbox deduplication are real; only admission, agent liveness,
spawn/control, and the private walk dispatcher cross fixture boundaries.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()


class Steps(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fm-step-pass-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for d in ("state", "config", "data/owner", "projects/proj", "fake"):
            (self.home / d).mkdir(parents=True)
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_TEST_SEAM="1")
        for name in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            self.env.pop(name, None)
        self.env["FM_QUOTA_SNAPSHOT_FILE"] = str(ROOT / "tests/fixtures/quota-axi-healthy.json")
        self.write(".tasks.toml", '[tasks]\nadapter = "markdown"\nfile = "data/backlog.md"\n')
        self.write("data/backlog.md", "## In flight\n- [ ] owner - slice (repo: proj) (kind: ship)\n  SLICE: id=demo role=owner\n  TESTER TASK: special-tester\n  TESTER RULE: new\n  TESTER PATHS: tests/risk.py\n## Queued\n## Done\n")
        self.write("config/autolaunch-steps", "act owner\n")
        self.write("config/crew-dispatch.json", '{"shared_quota":true,"default":[{"harness":"codex","model":"gpt-5.5"},{"harness":"claude","model":"opus"}]}')
        self.write("data/owner/brief.md", "Delivery contract: mode=direct-PR\nShip branch: fm/owner\n")
        self.write("data/owner/autolaunch-prep", "project=proj\nkind=ship\nmode=direct-PR\nyolo=off\n")
        self.write("data/owner/prep.md", "REVISION: r1\nCUT: 1\nWALK ID: demo\nWALK LIST: screen-a,screen-b\nWALK BRIEF: data/walk-briefs/demo.md\nWALK BOT: Walker\nWALK PROJECT: proj\nWALK TARGET: test\nTESTER PATHS: tests/risk.py\nTESTER RULE: new\nRISKS: edge-case\n")
        self.write("data/walk-briefs/demo.md", "Walk screen-a and screen-b, light and dark.\n")
        self.meta("owner", "gpt-5.5", "s1.1.1")
        self.write("fake/free", "20")
        self.write("fake/agent-owner", "dead")
        self.tool("capacity", 'n=$(cat "$FM_HOME/fake/free"); echo "capacity: free_lanes=$n reason=ok"; [ "$n" -gt 0 ]')
        self.tool("agent", 'cat "$FM_HOME/fake/agent-$1" 2>/dev/null || echo dead')
        self.tool("spawn", '''id=$1; model=; harness=; shift
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model=$2; shift;; --harness) harness=$2; shift;; esac; shift
done
printf '%s\n' "spawn $id $model" >> "$FM_HOME/fake/effects"
printf 'harness=%s\nmodel=%s\nspawn_gen=s2.%s.1\nkind=scout\n' "$harness" "$model" "$$" > "$FM_HOME/state/$id.meta"
echo alive > "$FM_HOME/fake/agent-$id"
''')
        self.tool("control", '''id=$1
printf 'relaunch %s\n' "$id" >> "$FM_HOME/fake/effects"
printf 'spawn_gen=s3.%s.1\n' "$$" >> "$FM_HOME/state/$id.meta"
echo alive > "$FM_HOME/fake/agent-$id"
''')
        self.tool("send", '''id=$1; shift
[ "$1" != --one-way ] || shift
. "$STEP_ROOT/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "$FM_HOME/state" "$id" "$*" '' "$FM_SEND_REQUEST_ID"
''')
        self.tool("walk", '''key=; bot=; project=; target=; while [ "$#" -gt 0 ]; do
  case "$1" in --once-key) key=$2; shift;; --bot) bot=$2; shift;; --project) project=$2; shift;; --target) target=$2; shift;; esac; shift
done
[ "$bot" = Walker ] && [ "$project" = proj ] && [ "$target" = test ] || exit 2
mkdir -p "$FM_HOME/data/grok-dispatch/once/$key"
if [ ! -f "$FM_HOME/data/grok-dispatch/once/$key/sent" ]; then
  echo sent > "$FM_HOME/data/grok-dispatch/once/$key/sent"
  echo "walk $key" >> "$FM_HOME/fake/effects"
fi
''')
        for seam, exe in (("CAPACITY", "capacity"), ("SPAWN", "spawn"), ("STEPS_AGENT", "agent"), ("STEPS_CONTROL", "control"), ("STEPS_SEND", "send"), ("STEPS_WALK", "walk")):
            self.env[f"FM_AUTOLAUNCH_{seam}_BIN"] = str(self.home / "fake" / exe)
        self.env["STEP_ROOT"] = str(ROOT)
        self.env["FM_AUTOLAUNCH_STEPS_NOW"] = "2000000000"

    def write(self, path, value):
        p = self.home / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(value)
        return p

    def tool(self, name, body):
        self.write("fake/" + name, "#!/usr/bin/env bash\nset -eu\n" + body).chmod(0o700)

    def meta(self, task, model, gen):
        self.write(f"state/{task}.meta", f"kind=ship\nharness=codex\nmodel={model}\nspawn_gen={gen}\nmode=direct-PR\nbranch=fm/owner\nproject={self.home}/projects/proj\n")

    def append_status(self, task, value):
        with (self.home / f"state/{task}.status").open("a") as f:
            f.write(value + "\n")

    def run_pass(self, stop="", dry=False):
        env = dict(self.env, FM_AUTOLAUNCH_STEPS_STOP=stop)
        return subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch.sh"), "--steps-only"] + (["--dry-run"] if dry else []), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)

    def rows(self):
        p = self.home / "data/owner/slice-steps.log"
        return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []

    def seed(self, step, key, **fields):
        row = dict(at=1, generation=1, step=step, owner="owner", trigger=key, receipt="completed", **fields)
        p = self.home / "data/owner/slice-steps.log"
        with p.open("a") as f:
            f.write(json.dumps(row) + "\n")

    def effects(self, prefix):
        p = self.home / "fake/effects"
        return [s for s in p.read_text().splitlines() if s.startswith(prefix)] if p.exists() else []

    def completed(self, effect):
        return [r for r in self.rows() if r.get("receipt") == "completed" and r.get("effect", {}).get("kind") == effect]

    def prepare_effect(self, kind):
        if kind in ("file-tester", "launch-tester"):
            self.append_status("owner", "working [at=2]: prep ready data/owner/prep.md r1")
        elif kind in ("relaunch-owner", "note-owner"):
            self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
            self.meta("special-tester", "opus", "st.1.1")
            self.append_status("special-tester", "done [at=3]: tests-ready none revision=r1 walk-list=screen-a,screen-b checks=existing")
            if kind == "note-owner":
                self.write("fake/agent-owner", "alive")
        elif kind == "cut-delivery":
            self.seed("build", "tests-ready:none@r1", revision="r1")
            self.write("data/owner/prep.md", (self.home / "data/owner/prep.md").read_text().replace("REVISION: r1", "REVISION: r2"))
            self.append_status("owner", "working [at=4]: cut ready data/owner/prep.md r2 walk_changed=no risk_changed=no")
        elif kind in ("file-review", "launch-review"):
            self.seed("build", "tests-ready:none@r1", revision="r1")
            with (self.home / "state/owner.meta").open("a") as f:
                f.write("pr=https://github.com/example/proj/pull/1\npr_head=abc\n")
            self.append_status("owner", "working [at=5]: pr-ready head=abc checks=started")
        elif kind == "walk-request":
            self.seed("deployed", "deploy:1", release="abc", deployed_at=10)
            self.write("data/x-board-summary.json", json.dumps(dict(written_at=2000000000, interval_seconds=600, checkpoints=[dict(id="daily-1", at=20, kind="daily")])) )

    def test_effect_crashes_converge_and_completed_replay_is_silent(self):
        for kind in ("file-tester", "launch-tester", "relaunch-owner", "note-owner", "cut-delivery", "walk-request", "file-review", "launch-review"):
            for boundary in ("before", "after"):
                for repeat in range(2):
                    with self.subTest(kind=kind, boundary=boundary, repeat=repeat):
                        self.setUp()
                        self.prepare_effect(kind)
                        crashed = self.run_pass(f"{boundary}:{kind}")
                        self.assertNotEqual(crashed.returncode, 0, crashed.stdout)
                        result = self.run_pass()
                        self.assertEqual(result.returncode, 0, result.stdout)
                        self.assertEqual(len(self.completed(kind)), 1, self.rows())
                        before = (self.home / "data/owner/slice-steps.log").read_bytes()
                        effects = self.effects("")
                        result = self.run_pass()
                        self.assertEqual(result.returncode, 0, result.stdout)
                        self.assertEqual(self.effects(""), effects)
                        self.assertEqual((self.home / "data/owner/slice-steps.log").read_bytes(), before)
                        if kind.startswith("launch-"):
                            target = "special-tester" if kind == "launch-tester" else "owner-review-1-1"
                            self.assertEqual(len(self.effects("spawn " + target)), 1)
                        if kind in ("relaunch-owner", "cut-delivery"):
                            self.assertEqual(len(self.effects("relaunch owner")), 1)
                        if kind == "walk-request":
                            self.assertEqual(self.effects("walk "), ["walk demo@abc.a1"])
                        if kind.startswith("file-"):
                            target = "special-tester" if kind == "file-tester" else "owner-review-1-1"
                            backlog = (self.home / "data/backlog.md").read_text()
                            self.assertEqual(backlog.count("- [ ] " + target + " -"), 1)
                        if kind == "note-owner":
                            self.assertEqual(len(list((self.home / "state/owner.inbox").glob("*.msg"))), 1)
                            self.assertEqual(self.effects("relaunch owner"), [])

    def test_later_steps_do_not_reconsume_historical_prep_or_review_triggers(self):
        self.seed("deployed", "deploy:earlier", release="abcdef0", deployed_at=10)
        self.append_status("owner", "working [at=2]: prep ready data/owner/prep.md r1")
        self.append_status("owner", "working [at=3]: pr-ready head=abc checks=started")
        with (self.home / "state/owner.meta").open("a") as f:
            f.write("pr=https://github.com/example/proj/pull/1\n")
        for _ in range(2):
            result = self.run_pass()
            self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.effects(""), [])
        self.assertEqual(len(self.rows()), 1)

    def test_engine_usage_never_executes_a_step(self):
        self.prepare_effect("launch-tester")
        for repeat in range(2):
            for args, code in ((["--help"], 0), (["typo"], 1), (["run", "unexpected"], 1)):
                with self.subTest(repeat=repeat, args=args):
                    result = subprocess.run(["python3", str(ROOT / "bin/fm-autolaunch-steps.py")] + args,
                                            env=self.env, text=True, capture_output=True, timeout=20)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual(self.effects(""), [])
                    self.assertEqual(self.rows(), [])

    def test_same_model_tester_is_refused(self):
        self.prepare_effect("launch-tester")
        self.write("config/crew-dispatch.json", '{"shared_quota":true,"default":{"harness":"codex","model":"gpt-5.5"}}')
        r = self.run_pass()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(self.effects("spawn special-tester"), [])
        self.assertFalse(any(x["step"] == "tests" and x["receipt"] == "completed" for x in self.rows()))

    def test_named_tester_lookup_and_pairing(self):
        self.prepare_effect("launch-tester")
        r = self.run_pass()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(len(self.effects("spawn special-tester opus")), 1)
        self.assertFalse((self.home / "data/owner-tester").exists())
        brief = (self.home / "data/special-tester/brief.md").read_text()
        self.assertIn(str(self.home / "state/special-tester.status"), brief)
        self.assertIn("fm-status-append.sh", brief)
        pairing = [r for r in self.rows() if r["step"] == "tests" and r["receipt"] == "completed"][-1]
        self.assertEqual(pairing["builder_model"], "gpt-5.5")
        self.assertEqual(pairing["tester_model"], "opus")

    def test_qualified_existing_tester_is_continued_on_the_same_task(self):
        for live in (False, True):
            with self.subTest(live=live):
                self.setUp()
                self.prepare_effect("launch-tester")
                backlog = (self.home / "data/backlog.md").read_text().replace("TESTER TASK: special-tester", "TESTER TASK: main:special-tester").replace("SLICE: id=demo role=owner", "SLICE: main/demo | visible result | role=owner")
                self.write("data/backlog.md", backlog)
                self.meta("special-tester", "opus", "st.1.1")
                self.write("fake/agent-special-tester", "alive" if live else "dead")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects("spawn special-tester"), [])
                self.assertEqual(self.effects("relaunch special-tester"), [] if live else ["relaunch special-tester"])
                if live:
                    self.assertEqual(len(list((self.home / "state/special-tester.inbox").glob("*.msg"))), 1)
                self.assertEqual(len(self.completed("launch-tester")), 1)
                body = subprocess.run([str(ROOT / "bin/fm-tasks-axi.sh"), "show", "special-tester", "--full"], env=self.env, text=True, capture_output=True).stdout
                self.assertIn("main/demo | visible result | role=tester owner=main:owner", body)

    def test_no_lane_pending_retries_once(self):
        self.prepare_effect("relaunch-owner")
        self.write("fake/free", "0")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertTrue(any(r.get("reason") == "relaunch-due" and r["receipt"] == "pending" for r in self.rows()))
        self.write("fake/free", "1")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.effects("relaunch owner")), 1)

    def walk_only_cut(self, live=False):
        self.prepare_effect("cut-delivery")
        if live:
            self.write("fake/agent-owner", "alive")
        self.meta("special-tester", "opus", "st.1.1")
        self.write("fake/agent-special-tester", "dead")
        self.write("data/owner/prep.md", (self.home / "data/owner/prep.md").read_text().replace("REVISION: r1", "REVISION: r2").replace("screen-a,screen-b", "screen-a,screen-b,screen-c"))
        self.write("state/owner.status", "working [at=4]: cut ready data/owner/prep.md r2 walk_changed=yes risk_changed=no\n")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.effects("relaunch special-tester")), 1)
        self.assertEqual(self.effects("relaunch owner"), [])
        self.append_status("special-tester", "done [at=3]: tests-ready none revision=r1 walk-list=screen-a,screen-b checks=existing")
        self.run_pass()
        self.assertEqual(self.effects("relaunch owner"), [])
        self.append_status("special-tester", "done [at=5]: tests-ready none revision=r2 walk-list=screen-a,screen-b,screen-c checks=existing")
        self.run_pass(); self.run_pass()
        if live:
            self.assertEqual(self.effects("relaunch owner"), [])
            self.assertEqual(len(list((self.home / "state/owner.inbox").glob("*.msg"))), 1)
        else:
            self.assertEqual(len(self.effects("relaunch owner")), 1)
        self.assertEqual(len(self.effects("relaunch special-tester")), 1)

    def test_walk_only_cut_returns_to_same_tester_before_owner(self):
        for live in (False, True):
            for repeat in range(2):
                with self.subTest(live=live, repeat=repeat):
                    self.setUp()
                    self.walk_only_cut(live)

    def test_observe_and_absent_are_noops(self):
        self.prepare_effect("launch-tester")
        for setting in ("observe owner\n", "off\n", None):
            p = self.home / "config/autolaunch-steps"
            if setting is None:
                p.unlink()
            else:
                p.write_text(setting)
            before = sorted(str(p.relative_to(self.home)) for p in self.home.rglob("*"))
            r = self.run_pass()
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertEqual(sorted(str(p.relative_to(self.home)) for p in self.home.rglob("*")), before)
            self.assertEqual(self.rows(), [])

    def test_no_mistakes_files_no_reviewer(self):
        self.prepare_effect("file-review")
        with (self.home / "state/owner.meta").open("a") as f:
            f.write("mode=no-mistakes\n")
        self.run_pass(); self.run_pass()
        self.assertEqual(self.effects("spawn owner-review"), [])
        self.assertFalse((self.home / "data/owner-review-1-1").exists())

    def test_fix_head_keeps_review_round(self):
        self.prepare_effect("file-review")
        self.run_pass()
        self.append_status("owner", "working [at=7]: pr-ready head=def checks=started")
        self.append_status("owner-review-1-1", "done [at=6]: review-ready reviewed_head=abc finding=bug-1 review=https://github.com/example/proj/pull/1#review-1")
        self.run_pass(); self.run_pass()
        self.assertEqual(len(self.effects("spawn owner-review-1-1")), 1)
        self.assertFalse((self.home / "data/owner-review-1-2").exists())

    def test_green_review_records_a_wait_without_routing_a_none_finding(self):
        self.prepare_effect("file-review")
        self.assertEqual(self.run_pass().returncode, 0)
        self.append_status("owner-review-1-1", "done [at=7]: review-ready reviewed_head=abc finding=none review=https://github.com/example/proj/pull/1#review-1")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.effects("relaunch owner"), [])
        self.assertTrue(any(r["step"] == "queue" and r["receipt"] == "completed" for r in self.rows()))

    def test_merge_deploy_checkpoint_and_complete_walk(self):
        self.seed("queue", "review:green", reviewed_head="abc")
        self.write("state/owner.pr-poll-merge-notified", "provider=github\nhost=github.com\npath=example/proj\nnumber=1\n")
        with (self.home / "state/owner.meta").open("a") as f:
            f.write("pr=https://github.com/example/proj/pull/1\n")
        subprocess.run(["git", "init", "-q", str(self.home / "projects/proj")], check=True)
        git = ["git", "-C", str(self.home / "projects/proj")]
        subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "base"], check=True)
        sha = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
        self.append_status("owner", "working [at=5]: merged commit=" + sha)
        summary = dict(written_at=2000000000, interval_seconds=600,
                       deploys=[dict(id="d1", release=sha, at=10, live_check="passed")],
                       checkpoints=[dict(id="day1", at=20, kind="daily")])
        self.write("data/x-board-summary.json", json.dumps(summary))
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.effects("walk demo@")), 1)
        self.assertTrue(any(r["step"] == "walk" and r.get("obligation") for r in self.rows()))
        summary["walk_results"] = [dict(walk_owner="main", walk="demo", release=sha, attempt=1, assignment="demo@" + sha + ".a1", report_sha256="f" * 64, complete=True, steps=[dict(id="screen-a", result="green"), dict(id="screen-b", result="green")])]
        self.write("data/x-board-summary.json", json.dumps(summary))
        self.run_pass(); self.run_pass()
        self.assertEqual(self.rows()[-1]["step"], "done")

    def test_missed_daily_checkpoint_catches_up(self):
        self.seed("deployed", "deploy:1", release="abc", deployed_at=10)
        self.write("data/x-board-summary.json", json.dumps(dict(written_at=2000000000, interval_seconds=600, daily_due=[dict(date="2033-05-18", at=30)])))
        self.run_pass(); self.run_pass()
        self.assertEqual(len(self.effects("walk demo@abc")), 1)
        self.assertTrue(any(r["trigger"].startswith("checkpoint:catchup:") for r in self.rows()))

    def test_unusable_attempt_retries_with_new_once_key_then_owned_failure(self):
        self.prepare_effect("walk-request")
        self.run_pass()
        summary = dict(written_at=2000000000, interval_seconds=600, walk_attempts=[dict(walk_owner="main", walk="demo", release="abc", attempt=1, outcome="gap", reason="walk-filing: gap: incomplete")])
        self.write("data/x-board-summary.json", json.dumps(summary))
        self.run_pass(); self.run_pass()
        self.assertEqual(self.effects("walk "), ["walk demo@abc.a1", "walk demo@abc.a2"])
        summary["walk_attempts"].append(dict(walk_owner="main", walk="demo", release="abc", attempt=2, outcome="gap", reason="walk-filing: gap: incomplete"))
        self.write("data/x-board-summary.json", json.dumps(summary))
        self.run_pass(); self.run_pass()
        self.assertTrue(any(r.get("failure") == "walk-machinery:demo@abc" for r in self.rows()))
        self.assertEqual(self.effects("relaunch owner"), [])

    def test_stale_carrier_leaves_obligation_open_and_reports_once(self):
        self.prepare_effect("walk-request")
        self.run_pass()
        self.write("data/x-board-summary.json", json.dumps(dict(written_at=1, interval_seconds=600)))
        self.run_pass(); self.run_pass()
        self.assertEqual(len([r for r in self.rows() if r.get("reason") == "carrier-stale"]), 1)
        self.assertFalse(any(r["step"] == "done" for r in self.rows()))

    def test_generation_never_revives_previous_runtime(self):
        self.seed("done", "walk-green:demo@abc")
        self.append_status("owner", "working [at=30]: generation ready 2 source=new-ask branch=fm/owner-g2")
        self.run_pass(); self.run_pass()
        self.assertEqual(self.effects("relaunch owner"), [])
        self.assertEqual(len([r for r in self.rows() if r["step"] == "generation" and r["generation"] == 2]), 1)
        self.assertIn("spawn_gen=s1.1.1", (self.home / "state/owner.meta").read_text())

    def test_recorded_pr_uses_required_checks_and_merge_facts_without_status_phrase(self):
        for required, conclusion in ((True, "FAILURE"), (False, "FAILURE"), (True, "SUCCESS")):
            with self.subTest(required=required, conclusion=conclusion):
                self.setUp()
                self.seed("build", "tests-ready:none@r1", revision="r1")
                with (self.home / "state/owner.meta").open("a") as f:
                    f.write("pr=https://github.com/example/proj/pull/1\npr_head=old\n")
                value = dict(headRefOid="abc", isDraft=False, state="OPEN", mergeCommit=None,
                             commits=dict(nodes=[dict(commit=dict(statusCheckRollup=dict(contexts=dict(nodes=[
                                 dict(__typename="CheckRun", isRequired=required, status="COMPLETED", conclusion=conclusion)
                             ]))))]))
                self.tool("pr", "cat \"$FM_HOME/fake/pr.json\"\n")
                self.write("fake/pr.json", base64.b64encode(json.dumps(value).encode()).decode())
                self.env["FM_AUTOLAUNCH_STEPS_PR_BIN"] = str(self.home / "fake/pr")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(self.effects("relaunch owner")), int(required and conclusion == "FAILURE"))
                self.assertEqual(len(self.effects("spawn owner-review-1-1")), 1)
                self.write("state/owner.pr-poll-merge-notified", "provider=github\nhost=github.com\npath=example/proj\nnumber=1\n")
                value["state"] = "MERGED"
                value["mergeCommit"] = dict(oid="b" * 40)
                self.write("fake/pr.json", base64.b64encode(json.dumps(value).encode()).decode())
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertTrue(any(row["trigger"] == "merge:" + "b" * 40 for row in self.rows()))

    def test_pipeline_review_gate_is_the_round_and_never_files_a_reviewer(self):
        self.seed("build", "tests-ready:none@r1", revision="r1")
        with (self.home / "state/owner.meta").open("a") as f:
            f.write("mode=no-mistakes\n")
        self.write("fake/agent-owner", "alive")
        self.tool("nm", 'cat "$FM_HOME/fake/nm.toon"\n')
        self.write("fake/nm.toon", "run:\n  id: RUN1\n  head: abc\nsteps[1]{name,status}:\n  review,awaiting_review\ngate:\n  step: review\nfindings[1]{id,severity,file,line,description,authority}:\n  BUG1,fix,app.py,1,Handle missing value,automatic\n")
        self.env["FM_AUTOLAUNCH_STEPS_NM_BIN"] = str(self.home / "fake/nm")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(r.get("pipeline_run") == "RUN1" and r["step"] == "review" for r in self.rows()))
        self.assertEqual(len(list((self.home / "state/owner.inbox").glob("*.msg"))), 1)
        self.assertFalse((self.home / "data/owner-review-1-1").exists())
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(list((self.home / "state/owner.inbox").glob("*.msg"))), 1)

    def test_c2_does_not_alarm_for_a_trigger_newer_than_last_completed_pass(self):
        self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
        self.meta("special-tester", "opus", "st.1.1")
        self.write("state/autolaunch-steps.pass", json.dumps(dict(at=100, owners=["owner"])))
        self.append_status("special-tester", "done [at=101]: tests-ready none revision=r1 walk-list=screen-a,screen-b checks=existing")
        def check():
            return subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch-check.sh")], env=self.env,
                                  text=True, capture_output=True, timeout=20).stdout
        self.assertEqual(check(), "")
        self.write("state/autolaunch-steps.pass", json.dumps(dict(at=102, owners=["owner"])))
        self.assertIn("trigger without receipt", check())

    def test_handled_inbox_receipt_still_deduplicates(self):
        self.prepare_effect("note-owner")
        self.assertNotEqual(self.run_pass("after:note-owner").returncode, 0)
        inbox = self.home / "state/owner.inbox"
        handled = inbox / "handled"
        handled.mkdir(exist_ok=True)
        record = next(inbox.glob("*.msg"))
        record.rename(handled / record.name)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(list(handled.glob("*.msg"))), 1)
        self.assertEqual(list(inbox.glob("*.msg")), [])
        self.assertEqual(len(self.completed("note-owner")), 1)

    def test_c2_reasonless_pending_one_episode_then_clear(self):
        self.prepare_effect("relaunch-owner")
        self.run_pass("before:relaunch-owner")
        # A completed pass with a failed consumer must remain observable to C2.
        self.write("state/autolaunch-steps.pass", json.dumps(dict(at=2000000000, owners=["owner"])))
        env = dict(self.env, FM_AUTOLAUNCH_CHECK_NOW="2000000001")
        def check():
            return subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch-check.sh")], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20).stdout
        self.assertIn("RED", check())
        self.assertEqual(check(), "")
        self.run_pass()
        self.assertEqual(check(), "")
        self.assertFalse((self.home / "state/.autolaunch-check.red").exists())


if __name__ == "__main__":
    unittest.main()
