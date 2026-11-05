"""Step-pass executable fixtures, invoked by fm-autolaunch.test.sh.

Task storage and inbox deduplication are real; only admission, agent liveness,
spawn/control, and the private walk dispatcher cross fixture boundaries.
"""
import base64
import hashlib
import json
import os
import shutil
import shlex
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
        for d in ("state", "config", "data/builder", "projects/proj", "fake"):
            (self.home / d).mkdir(parents=True)
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_TEST_SEAM="1")
        for name in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            self.env.pop(name, None)
        self.env["FM_QUOTA_SNAPSHOT_FILE"] = str(ROOT / "tests/fixtures/quota-axi-healthy.json")
        self.write(".tasks.toml", '[tasks]\nadapter = "markdown"\nfile = "data/backlog.md"\n')
        # The task ID is internal; literal "owner" would assert owner origin
        # when it is copied into generated child titles and references.
        self.write("data/backlog.md", "## In flight\n- [ ] builder - slice (repo: proj) (kind: ship)\n  SLICE: id=demo role=owner\n  TESTER TASK: special-tester\n  TESTER RULE: new\n  TESTER PATHS: tests/risk.py\n## Queued\n## Done\n")
        self.write("config/autolaunch-steps", "act builder\n")
        self.write("config/crew-dispatch.json", '{"shared_quota":true,"default":[{"harness":"codex","model":"gpt-5.5"},{"harness":"claude","model":"opus"}]}')
        self.write("data/builder/brief.md", "Delivery contract: mode=direct-PR\nShip branch: fm/builder\n")
        self.write("data/builder/autolaunch-prep", "project=proj\nkind=ship\nmode=direct-PR\nyolo=off\n")
        self.write("data/builder/prep.md", "REVISION: r1\nCUT: 1\nWALK ID: demo\nWALK LIST: screen-a,screen-b\nWALK BRIEF: data/walk-briefs/demo.md\nWALK BOT: Walker\nWALK PROJECT: proj\nWALK TARGET: test\nTESTER PATHS: tests/risk.py\nTESTER RULE: new\nRISKS: edge-case\n")
        self.write("data/walk-briefs/demo.md", "Walk screen-a and screen-b, light and dark.\n")
        self.meta("builder", "gpt-5.5", "s1.1.1")
        self.write("fake/free", "20")
        self.write("fake/agent-builder", "dead")
        self.tool("capacity", 'n=$(cat "$FM_HOME/fake/free"); echo "capacity: free_lanes=$n reason=ok"; [ "$n" -gt 0 ]')
        self.tool("agent", 'cat "$FM_HOME/fake/agent-$1" 2>/dev/null || echo dead')
        self.tool("spawn", '''id=$1; model=; harness=; shift
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model=$2; shift;; --harness) harness=$2; shift;; esac; shift
done
printf '%s\n' "$model" >> "$FM_HOME/fake/attempts"
if [ -f "$FM_HOME/fake/refuse-$model" ]; then
  echo "error: fm-spawn refuses explicit harness $harness: quota exhausted" >&2
  exit 1
fi
printf '%s\n' "spawn $id $model" >> "$FM_HOME/fake/effects"
printf 'harness=%s\nmodel=%s\nspawn_gen=s2.%s.1\nkind=scout\n' "$harness" "$model" "$$" > "$FM_HOME/state/$id.meta"
echo alive > "$FM_HOME/fake/agent-$id"
bash "$STEP_ROOT/bin/fm-tasks-axi.sh" start "$id" >/dev/null
if [ -n "${FM_SPAWN_STEP_ACTION:-}" ]; then
  python3 "$STEP_ROOT/bin/fm-autolaunch-steps.py" record-launch "$id" "$FM_SPAWN_STEP_ACTION" "s2.$$.1"
fi
''')
        self.tool("control", '''id=$1
cp "$FM_HOME/state/$id.meta" "$FM_HOME/state/$id.control-relaunch.meta-prior"
printf 'relaunch %s\n' "$id" >> "$FM_HOME/fake/effects"
printf 'spawn_gen=s3.%s.1\n' "$$" >> "$FM_HOME/state/$id.meta"
echo alive > "$FM_HOME/fake/agent-$id"
printf 'task=%s\nphase=complete\n' "$id" > "$FM_HOME/state/$id.control-relaunch"
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
        self.tool("teardown", '''[ "$#" -eq 3 ] && [ "$2" = --step-action ]
echo "teardown $1" >> "$FM_HOME/fake/effects"
[ ! -f "$FM_HOME/fake/teardown-refuse" ] || exit 1
python3 "$STEP_ROOT/bin/fm-autolaunch-steps.py" record-teardown "$1" "$3"
[ ! -f "$FM_HOME/fake/cleanup-before-remove" ] || exit 1
rm -f "$FM_HOME/state/$1.meta"
''')
        for seam, exe in (("CAPACITY", "capacity"), ("SPAWN", "spawn"), ("STEPS_AGENT", "agent"), ("STEPS_CONTROL", "control"), ("STEPS_SEND", "send"), ("STEPS_WALK", "walk"), ("STEPS_TEARDOWN", "teardown")):
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

    def meta(self, task, model, gen, harness="codex"):
        self.write(f"state/{task}.meta", f"kind=ship\nharness={harness}\nmodel={model}\nspawn_gen={gen}\nmode=direct-PR\nbranch=fm/builder\nworktree={self.home}/projects/proj\nproject={self.home}/projects/proj\n")
        role = "tester" if task == "special-tester" else "review" if task.startswith("builder-review-") else ""
        backlog = self.home / "data/backlog.md"
        if role and f"- [ ] {task} -" not in backlog.read_text():
            home_id = (self.home / ".fm-secondmate-home").read_text().strip() if (self.home / ".fm-secondmate-home").exists() else "main"
            owner_slice = backlog.read_text().split("SLICE: ", 1)[1].splitlines()[0]
            child_slice = owner_slice.replace("role=owner", f"role={role} builder={home_id}:builder")
            self.write("data/backlog.md", backlog.read_text().replace("## Queued", f"- [ ] {task} - {role} (repo: proj) (kind: scout)\n  SLICE: {child_slice}\n## Queued"))

    def closure_ready(self):
        project = self.home / "projects/proj"
        subprocess.run(["git", "-C", str(project), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(project), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "--allow-empty", "-qm", "landed"], check=True)
        release = subprocess.check_output(["git", "-C", str(project), "rev-parse", "HEAD"], text=True).strip()
        self.seed("merged", "merge:" + release, merge=release)
        self.seed("walk", "walk-green:proof", closure_ready=True, release=release, project=str(project),
                  revision="r1", walk="demo", walk_list="screen-a,screen-b", spawn_gen="s1.1.1",
                  report_sha256="a" * 64, last_walk="data/walk-auto-filing/walk-result-demo.md")

    def lease_other(self, task, mode):
        backlog = (self.home / "data/backlog.md").read_text()
        self.write("data/backlog.md", backlog.replace("## Queued", f"- [ ] {task} - other slice (repo: proj) (kind: ship)\n  SLICE: main/{task} | result | role=owner\n## Queued"))
        self.write("config/autolaunch-steps", f"act builder\n{mode} {task}\n")

    def append_status(self, task, value):
        with (self.home / f"state/{task}.status").open("a") as f:
            f.write(value + "\n")

    def run_pass(self, stop="", dry=False, ordinary=False):
        env = dict(self.env, FM_AUTOLAUNCH_STEPS_STOP=stop)
        return subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch.sh")] + ([] if ordinary else ["--steps-only"]) + (["--dry-run"] if dry else []), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)

    def rows(self):
        p = self.home / "data/builder/slice-steps.log"
        return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []

    def seed(self, step, key, receipt="completed", owner="builder", generation=1, **fields):
        row = dict(at=1, generation=generation, step=step, owner=owner, trigger=key, receipt=receipt, **fields)
        p = self.home / f"data/{owner}/slice-steps.log"
        with p.open("a") as f:
            f.write(json.dumps(row) + "\n")

    def effects(self, prefix):
        p = self.home / "fake/effects"
        return [s for s in p.read_text().splitlines() if s.startswith(prefix)] if p.exists() else []

    def completed(self, effect):
        return [r for r in self.rows() if r.get("receipt") == "completed" and r.get("effect", {}).get("kind") == effect]

    def prepare_effect(self, kind):
        if kind in ("file-tester", "launch-tester"):
            self.append_status("builder", "working [at=2]: prep ready data/builder/prep.md r1")
        elif kind in ("relaunch-owner", "note-owner"):
            self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
            self.meta("special-tester", "opus", "st.1.1")
            self.append_status("special-tester", "done [at=3]: tests-ready none revision=r1 walk-list=screen-a,screen-b checks=existing")
            if kind == "note-owner":
                self.write("fake/agent-builder", "alive")
        elif kind == "cut-delivery":
            self.seed("build", "tests-ready:none@r1", revision="r1")
            self.write("data/builder/prep.md", (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2"))
            self.append_status("builder", "working [at=4]: cut ready data/builder/prep.md r2 walk_changed=no risk_changed=no")
        elif kind in ("file-review", "launch-review"):
            self.seed("build", "tests-ready:none@r1", revision="r1")
            with (self.home / "state/builder.meta").open("a") as f:
                f.write("pr=https://github.com/example/proj/pull/1\npr_head=abc\n")
            self.append_status("builder", "working [at=5]: pr-ready head=abc checks=started")
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
                        before = (self.home / "data/builder/slice-steps.log").read_bytes()
                        effects = self.effects("")
                        result = self.run_pass()
                        self.assertEqual(result.returncode, 0, result.stdout)
                        self.assertEqual(self.effects(""), effects)
                        self.assertEqual((self.home / "data/builder/slice-steps.log").read_bytes(), before)
                        if kind.startswith("launch-"):
                            target = "special-tester" if kind == "launch-tester" else "builder-review-1-1"
                            self.assertEqual(len(self.effects("spawn " + target)), 1)
                        if kind in ("relaunch-owner", "cut-delivery"):
                            self.assertEqual(len(self.effects("relaunch builder")), 1)
                        if kind == "walk-request":
                            self.assertEqual(self.effects("walk "), ["walk demo@abc.a1"])
                        if kind.startswith("file-"):
                            target = "special-tester" if kind == "file-tester" else "builder-review-1-1"
                            backlog = (self.home / "data/backlog.md").read_text()
                            self.assertEqual(backlog.count("- [ ] " + target + " -"), 1)
                        if kind == "note-owner":
                            self.assertEqual(len(list((self.home / "state/builder.inbox").glob("*.msg"))), 1)
                            self.assertEqual(self.effects("relaunch builder"), [])

    def test_ordinary_pass_cannot_bypass_step_child_receipts(self):
        for role in ("tester", "review"):
            for lease in ("act", "observe", "off", "absent"):
                with self.subTest(role=role, lease=lease):
                    self.setUp()
                    self.prepare_effect("launch-" + role)
                    self.assertNotEqual(self.run_pass("before:launch-" + role).returncode, 0)
                    if lease == "absent":
                        (self.home / "config/autolaunch-steps").unlink()
                    else:
                        self.write("config/autolaunch-steps", lease + (" builder\n" if lease in ("act", "observe") else "\n"))
                    if lease == "act" and role == "tester":
                        self.write("config/crew-dispatch.json", '{"shared_quota":true,"default":{"harness":"codex","model":"gpt-5.5"}}')
                    elif lease == "act":
                        self.tool("capacity", '''if [ ! -f "$FM_HOME/fake/capacity-seen" ]; then
  touch "$FM_HOME/fake/capacity-seen"
  echo 'capacity: free_lanes=0 reason=full'
  exit 75
fi
echo 'capacity: free_lanes=20 reason=ok'
''')
                    backlog = (self.home / "data/backlog.md").read_text()
                    self.write("data/backlog.md", backlog.replace("## Done", "- [ ] unrelated - ordinary work (repo: proj) (kind: scout)\n## Done"))
                    self.write("data/unrelated/brief.md", "Ordinary work\n")
                    self.write("data/unrelated/prep.md", "Prepared ordinary work\n")
                    self.write("data/unrelated/autolaunch-prep", "project=proj\nkind=scout\n")
                    result = self.run_pass(ordinary=True)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(len(self.effects("spawn unrelated ")), 1)
                    self.assertEqual(len(self.effects("spawn ")), 1)
                    self.assertEqual(self.completed("launch-" + role), [])
                    before = self.effects("")
                    self.assertEqual(self.run_pass(ordinary=True).returncode, 0)
                    if lease == "act" and role == "review":
                        self.assertEqual(len(self.completed("launch-review")), 1)
                        self.assertEqual(len(self.effects("spawn builder-review-1-1 ")), 1)
                        self.assertEqual(len(self.effects("spawn ")), 2)
                        before = self.effects("")
                    else:
                        self.assertEqual(self.effects(""), before)
                    self.assertEqual(self.run_pass(ordinary=True).returncode, 0)
                    self.assertEqual(self.effects(""), before)

    def test_ordinary_pass_reconciles_child_launches_once(self):
        for role in ("tester", "review"):
            with self.subTest(role=role):
                self.setUp()
                self.prepare_effect("launch-" + role)
                result = self.run_pass(ordinary=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(self.completed("launch-" + role)), 1)
                self.assertEqual(len(self.effects("spawn ")), 1)
                before = self.effects("")
                self.assertEqual(self.run_pass(ordinary=True).returncode, 0)
                self.assertEqual(self.effects(""), before)

    def test_stale_generation_action_is_refused_before_spawn(self):
        self.prepare_effect("launch-tester")
        self.assertNotEqual(self.run_pass("before:launch-tester").returncode, 0)
        self.seed("generation", "generation:next", generation=2)
        result = subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch.sh"), "--step-dispatch", "special-tester",
                                 "gpt-5.5", "openai", "builder:prep:r1"], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.effects("spawn "), [])

    def test_ordinary_tester_candidates_use_the_shared_model_admission(self):
        for candidates, expected in ((["gpt-5.5"], []), (["default"], []), (["gpt-5.5", "opus"], ["spawn special-tester opus"])):
            with self.subTest(candidates=candidates):
                self.setUp()
                (self.home / "config/autolaunch-steps").unlink()
                self.meta("special-tester", "opus", "old.1")
                (self.home / "state/special-tester.meta").unlink()
                reopened = subprocess.run([str(ROOT / "bin/fm-tasks-axi.sh"), "reopen", "special-tester"], env=self.env,
                                          text=True, capture_output=True)
                self.assertEqual(reopened.returncode, 0, reopened.stderr)
                self.write("data/special-tester/brief.md", "Prepared tester\n")
                self.write("data/special-tester/prep.md", "Prepared tester scope\n")
                self.write("data/special-tester/autolaunch-prep", "project=proj\nkind=scout\n")
                self.write("config/crew-dispatch.json", json.dumps(dict(shared_quota=True, default=[
                    dict(harness="claude" if model == "opus" else "codex", model=model) for model in candidates])))
                result = self.run_pass(ordinary=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.effects("spawn "), expected)
                self.assertEqual(self.run_pass(ordinary=True).returncode, 0)
                self.assertEqual(self.effects("spawn "), expected)

    def test_real_spawn_commit_witness_survives_preserved_term(self):
        script = r'''
FM_TEST_FIXTURE_IMPORT=atomicity
. "$STEP_ROOT/tests/fm-backlog-atomicity.test.sh"
for kind in launch-tester launch-review relaunch-tester recheck-review; do
  for timing in normal before after delivery-failed; do
    role=review
    child=builder-review-1-1
    case "$kind" in *tester) role=tester; child=special-tester ;; esac
    case_dir=$(make_home "step-commit-$kind-$timing" "$child")
    home=$(home_of "$case_dir")
    mkdir -p "$home/data/builder"
    printf 'act builder\n' > "$home/config/autolaunch-steps"
    printf 'REVISION: r1\nCUT: 1\n' > "$home/data/builder/prep.md"
    printf 'kind=ship\nmodel=gpt-5.5\nspawn_gen=builder.1\nmode=direct-PR\nproject=%s/project\n' "$case_dir" > "$home/state/builder.meta"
    cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] builder - slice (repo: project) (kind: ship)
  SLICE: main/demo | visible result | role=owner
  TESTER TASK: special-tester
## Queued
- [ ] $child - child (repo: project) (kind: scout)
  SLICE: main/demo | visible result | role=$role builder=main:builder
## Done
EOF
    python3 - "$home/data/builder/slice-steps.log" "$kind" "$child" <<'PY'
import json, sys
row = dict(at=1, generation=1, owner="builder", step="tests" if sys.argv[2].endswith("tester") else "review",
           trigger="delivery", receipt="pending", effect=dict(kind=sys.argv[2], target=sys.argv[3],
           id="delivery", expected_gen="", note="Current child assignment"))
with open(sys.argv[1], "w") as stream:
    stream.write(json.dumps(row) + "\n")
PY
    case "$timing" in
      before|after) interrupt_spawn_during_start "$case_dir" "$timing" ;;
      delivery-failed) break_launch_delivery "$case_dir" ;;
    esac
    rc=0
    out=$(FM_SPAWN_STEP_ACTION=builder:delivery run_spawn "$case_dir" "$child" "$case_dir/project" --scout --harness claude --model opus) || rc=$?
    if [ "$timing" = delivery-failed ]; then
      [ "$rc" -ne 0 ] || fail 'failed launch was reported as committed'
      assert_absent "$home/state/autolaunch.log" 'failed delivery published no action witness'
      assert_equals queued "$(row_state "$case_dir" "$child")" 'failed delivery leaves the native child queued'
      continue
    fi
    expected=0
    [ "$timing" = normal ] || expected=143
    expect_code "$expected" "$rc" "$kind/$timing: $out"
    assert_equals in_flight "$(row_state "$case_dir" "$child")" 'committed spawn owns an in-flight child'
    printf '#!/usr/bin/env bash\necho dead\n' > "$case_dir/dead-agent"
    printf '#!/usr/bin/env bash\ntouch "%s/unexpected-control"\nexit 3\n' "$case_dir" > "$case_dir/dead-control"
    chmod +x "$case_dir/dead-agent" "$case_dir/dead-control"
    for repeat in 1 2; do
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AUTOLAUNCH_STEPS_AGENT_BIN="$case_dir/dead-agent" \
        FM_AUTOLAUNCH_STEPS_CONTROL_BIN="$case_dir/dead-control" \
        python3 "$ROOT/bin/fm-autolaunch-steps.py" run || fail 'committed child did not reconcile'
    done
    assert_absent "$case_dir/unexpected-control" 'exited committed child was never relaunched'
    python3 - "$home" "$child" <<'PY'
import json, sys
from pathlib import Path
home, child = Path(sys.argv[1]), sys.argv[2]
records = [json.loads(line) for line in (home / "data/builder/slice-steps.log").read_text().splitlines()]
assert len([r for r in records if r["trigger"] == "delivery" and r["receipt"] == "completed"]) == 1
witnesses = [line for line in (home / "state/autolaunch.log").read_text().splitlines()
             if line.endswith("\tlaunched|relaunched " + child + " delivery")]
assert len(witnesses) == 1
PY
  done
done
'''
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True, capture_output=True, timeout=240)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unhandled_deliveries_resume_consumers_that_exit_during_delivery(self):
        for kind in ("note-owner", "relaunch-owner", "cut-delivery", "relaunch-tester",
                     "recheck-review", "route-finding", "launch-tester", "launch-review"):
            for boundary in ("before", "after"):
                with self.subTest(kind=kind, boundary=boundary):
                    self.setUp()
                    target = ("special-tester" if kind in ("launch-tester", "relaunch-tester") else
                              "builder-review-1-1" if kind in ("launch-review", "recheck-review") else
                              "child" if kind == "route-finding" else "builder")
                    self.meta(target, "opus", "original.1")
                    if kind == "route-finding":
                        self.lease_other("child", "act")
                    self.write(f"fake/agent-{target}", "alive")
                    self.seed("build", "delivery", receipt="pending", effect=dict(
                        id="delivery", kind=kind, target=target, expected_gen="original.1",
                        note="Continue this delivery", exclude_model="gpt-5.5"))
                    self.assertNotEqual(self.run_pass(f"{boundary}:{kind}").returncode, 0)
                    self.write(f"fake/agent-{target}", "dead")
                    if kind == "note-owner":
                        guard = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"),
                                                "guard", target, "builder:delivery"], env=self.env)
                        self.assertEqual(guard.returncode, 0)
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.effects("relaunch "), [f"relaunch {target}"])
                    self.assertEqual(len(self.completed(kind)), 1)
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(self.effects("relaunch "), [f"relaunch {target}"])
                    self.assertLessEqual(len(list((self.home / f"state/{target}.inbox").glob("*.msg"))), 1)

    def test_exited_launches_reconcile_before_the_autolaunch_log_append(self):
        for kind in ("launch-tester", "launch-review", "relaunch-owner", "note-owner", "cut-delivery",
                     "relaunch-tester", "recheck-review", "route-finding"):
            with self.subTest(kind=kind):
                self.setUp()
                if kind in ("relaunch-tester", "recheck-review", "route-finding", "note-owner"):
                    target = ("special-tester" if kind == "relaunch-tester" else "builder-review-1-1" if kind == "recheck-review" else
                              "other" if kind == "route-finding" else "builder")
                    self.meta(target, "opus", "original.1")
                    if kind == "route-finding":
                        self.lease_other(target, "act")
                    self.seed("fix", "delivery", receipt="pending", effect=dict(
                        kind=kind, target=target, id="delivery", note="Continue this work", expected_gen="original.1"))
                else:
                    self.prepare_effect(kind)
                    target = "special-tester" if kind == "launch-tester" else "builder-review-1-1" if kind == "launch-review" else "builder"
                self.assertNotEqual(self.run_pass(f"after:{kind}").returncode, 0)
                self.write(f"fake/agent-{target}", "dead")
                self.assertEqual(self.completed(kind), [])
                self.assertEqual((self.home / "state/autolaunch.log").exists(), kind in ("launch-tester", "launch-review"))
                effects = self.effects("")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(self.completed(kind)), 1)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects(""), effects)

    def test_provisional_dead_spawn_metadata_is_not_launch_completion(self):
        for native_state, live in (("queued", False), ("queued", True), ("in_flight", False), ("in_flight", True)):
            with self.subTest(native_state=native_state, live=live):
                self.setUp()
                self.prepare_effect("launch-tester")
                self.assertNotEqual(self.run_pass("before:launch-tester").returncode, 0)
                if native_state == "in_flight":
                    started = subprocess.run([str(ROOT / "bin/fm-tasks-axi.sh"), "start", "special-tester"], env=self.env)
                    self.assertEqual(started.returncode, 0)
                self.meta("special-tester", "opus", "provisional.1")
                self.write("fake/agent-special-tester", "alive" if live else "dead")
                self.tool("control", "exit 3")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.completed("launch-tester"), [])
                self.assertTrue(any(r["receipt"] == "pending" for r in self.rows()))

    def test_later_steps_do_not_reconsume_historical_prep_or_review_triggers(self):
        self.seed("deployed", "deploy:earlier", release="abcdef0", deployed_at=10)
        self.append_status("builder", "working [at=2]: prep ready data/builder/prep.md r1")
        self.append_status("builder", "working [at=3]: pr-ready head=abc checks=started")
        with (self.home / "state/builder.meta").open("a") as f:
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
        self.assertFalse((self.home / "data/builder-tester").exists())
        brief = (self.home / "data/special-tester/brief.md").read_text()
        self.assertIn(str(self.home / "state/special-tester.status"), brief)
        self.assertIn("fm-status-append.sh", brief)
        pairing = [r for r in self.rows() if r["step"] == "tests" and r["receipt"] == "completed"][-1]
        self.assertEqual(pairing["builder_model"], "gpt-5.5")
        self.assertEqual(pairing["tester_model"], "opus")

    def test_tester_family_preference_respects_quota_and_spawn_refusal(self):
        for mode in ("available", "exhausted", "refused", "shared"):
            with self.subTest(mode=mode):
                self.setUp()
                self.meta("builder", "opus", "s1.1.1", harness="claude")
                self.write("config/crew-dispatch.json", json.dumps(dict(
                    shared_quota=mode == "shared", default=[dict(harness="claude", model="sonnet"), dict(harness="codex", model="gpt-5.5")])))
                quota = json.loads((ROOT / "tests/fixtures/quota-axi-healthy.json").read_text())
                if mode == "exhausted":
                    row = next(p for p in quota["providers"] if p["provider"] == "codex")
                    for scope in row["quotaSemantics"]["effectiveAvailability"]:
                        scope["effectivePercentRemaining"] = 0
                        scope["runway"]["status"] = "exhausted_now"
                self.env["FM_QUOTA_SNAPSHOT_FILE"] = str(self.write("fake/quota.json", json.dumps(quota)))
                if mode == "refused":
                    self.write("fake/refuse-gpt-5.5", "yes")
                self.prepare_effect("launch-tester")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                expected = "sonnet" if mode in ("exhausted", "refused") else "gpt-5.5"
                self.assertEqual(self.effects("spawn "), [f"spawn special-tester {expected}"])
                pair = self.completed("launch-tester")[0]
                self.assertEqual(pair["builder_family"], "claude")
                self.assertEqual(pair["tester_family"], "claude" if expected == "sonnet" else "codex")
                if mode == "refused":
                    self.assertEqual((self.home / "fake/attempts").read_text().splitlines(), ["gpt-5.5", "sonnet"])

    def test_fallback_tester_identity_is_persisted_and_branch_scope_is_delivered(self):
        for empty in ("", "  TESTER TASK:\n"):
            with self.subTest(empty=empty):
                self.setUp()
                body = (self.home / "data/backlog.md").read_text().replace("  TESTER TASK: special-tester\n", empty)
                self.write("data/backlog.md", body)
                self.prepare_effect("file-tester")
                self.assertNotEqual(self.run_pass("after:file-tester").returncode, 0)
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("TESTER TASK: main:builder-tester", (self.home / "data/backlog.md").read_text())
                self.assertEqual(self.effects("spawn "), ["spawn builder-tester opus"])
                delivered = (self.home / "data/builder-tester/brief.md").read_text()
                self.assertIn(f"builder's branch fm/builder in {self.home}/projects/proj", delivered)
                self.assertIn("Edit and commit only TESTER PATHS directly", delivered)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(len(self.completed("file-tester")), 1)

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
                self.assertIn("main/demo | visible result | role=tester builder=main:builder", body)

    def test_no_lane_pending_retries_once(self):
        self.prepare_effect("relaunch-owner")
        self.write("fake/free", "0")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertTrue(any(r.get("reason") == "relaunch-due" and r["receipt"] == "pending" for r in self.rows()))
        self.write("fake/free", "1")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.effects("relaunch builder")), 1)

    def test_observed_finding_destination_keeps_its_lifecycle_custody(self):
        for live in (False, True):
            with self.subTest(live=live):
                self.setUp()
                self.meta("other", "opus", "other.1")
                self.lease_other("other", "act")
                self.write("fake/agent-other", "alive" if live else "dead")
                self.seed("fix", "routed-finding", receipt="pending", routed_to="main:other", effect=dict(
                    id="routed-finding", kind="route-finding", target="other", expected_gen="other.1", note="Repair this finding"))
                self.assertNotEqual(self.run_pass("before:route-finding").returncode, 0)
                self.write("config/autolaunch-steps", "act builder\nobserve other\n")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.effects("relaunch "), [])
                self.assertEqual(list((self.home / "state/other.inbox").glob("*.msg")), [])
                guard = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"), "guard", "other", "builder:routed-finding"], env=self.env)
                self.assertEqual(guard.returncode, 3)
                self.assertTrue(any(r.get("reason") == "destination-not-leased" for r in self.rows()))
                self.write("config/autolaunch-steps", "act builder other\n")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(len(self.completed("route-finding")), 1)
                self.assertEqual(self.effects("relaunch other"), [] if live else ["relaunch other"])

    def test_changed_cut_tester_and_result_use_current_resolved_models(self):
        for model in ("opus", "default", ""):
            with self.subTest(model=model):
                self.setUp()
                self.prepare_effect("cut-delivery")
                self.write("state/builder.status", "working [at=4]: cut ready data/builder/prep.md r2 walk_changed=yes risk_changed=no\n")
                self.meta("special-tester", model, "tester.1")
                if model == "opus":
                    self.meta("builder", "opus", "builder.2")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.completed("relaunch-tester"), [])
                self.assertEqual(self.effects("relaunch "), [])
                guard = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"), "guard", "special-tester",
                                        "builder:cut:builder@1:r2:tester"], env=self.env)
                self.assertEqual(guard.returncode, 3)
                self.meta("builder", "gpt-5.5", "builder.3")
                self.meta("special-tester", "opus", "tester.1")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(len(self.completed("relaunch-tester")), 1)
                self.append_status("special-tester", "done [at=5]: tests-ready none revision=r2 walk-list=screen-a,screen-b checks=existing")
                self.meta("builder", "opus", "builder.4")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.completed("cut-delivery"), [])
                self.meta("builder", "gpt-5.5", "builder.5")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(len(self.completed("cut-delivery")), 1)

    def test_tests_ready_literal_forms_advance_once(self):
        for form in ("commit=none", "none", "commit=<sha>"):
            for cut in (False, True):
                with self.subTest(form=form, cut=cut):
                    self.setUp()
                    commit = "none"
                    if form == "commit=<sha>":
                        git = ["git", "-C", str(self.home / "projects/proj")]
                        subprocess.run(git + ["init", "-q", "-b", "fm/builder"], check=True)
                        subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                              "commit", "--allow-empty", "-qm", "existing tests"], check=True)
                        commit = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                    phrase = "tests-ready " + form.replace("<sha>", commit)
                    self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
                    self.meta("special-tester", "opus", "st.1.1")
                    self.write("fake/agent-builder", "alive")
                    if cut:
                        self.seed("tests", "cut:builder@1:r1:tester", revision="r1")
                        self.append_status("builder", "working [at=2]: cut ready data/builder/prep.md r1 walk_changed=yes risk_changed=no")
                    self.append_status("special-tester", f"done [at=3]: {phrase} revision=r1 walk-list=screen-a,screen-b checks=existing")
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    key = "cut:builder@1:r1" if cut else f"tests-ready:{commit}@r1"
                    rows = [r for r in self.rows() if r["trigger"] == key and r["receipt"] == "completed"]
                    self.assertEqual(len(rows), 1, self.rows())
                    self.assertEqual(rows[0]["effect"]["tester_commit"], commit)
                    before = (self.home / "data/builder/slice-steps.log").read_bytes()
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual((self.home / "data/builder/slice-steps.log").read_bytes(), before)
                    self.assertEqual(len(list((self.home / "state/builder.inbox").glob("*.msg"))), 1)

    def test_tests_ready_requires_complete_current_admitted_evidence(self):
        valid = "tests-ready commit=none revision=r1 walk-list=screen-a,screen-b checks=existing"
        invalid = (
            valid.replace("revision=r1", "revision=r0"),
            valid.replace("screen-a,screen-b", "screen-a"),
            valid.replace(" checks=existing", ""),
            valid.replace("commit=none", "commit=none-extra"),
            valid.replace("commit=none", "commit=abcdefg"),
            valid.replace("commit=none", "none-extra"),
            valid.replace("tests-ready", "not-tests-ready"),
            "tests-ready: branch fm/x-j14-save-rerun-tester head 1ff0e3a3ae9d4bfbf6babec63c37f5b683631f9b pushed",
            "tests-ready for cut 1, branch fm/x-j14-alert-handoff-tester head 35c8df424632201e06a2fef67f4a63e35c40e68c pushed",
            "tests-ready: branch fm/x-ai-s13-integrate-tester head 6234cb998a5772feaec505719e40254f505a50a9 pushed",
        )
        for phrase, model in [(p, "opus") for p in invalid] + [(valid, m) for m in ("gpt-5.5", "default", "")]:
            with self.subTest(phrase=phrase, model=model):
                self.setUp()
                self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
                self.meta("special-tester", model, "st.1.1")
                self.write("fake/agent-builder", "alive")
                self.append_status("special-tester", f"done [at=3]: {phrase}")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(self.rows()), 1, self.rows())
                self.assertEqual(list((self.home / "state/builder.inbox").glob("*.msg")), [])

    def test_tester_brief_spells_literal_commit_forms(self):
        self.prepare_effect("file-tester")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        brief = (self.home / "data/special-tester/brief.md").read_text()
        for form in ("commit=<sha>", "commit=none"):
            self.assertIn(f"tests-ready {form} revision=<revision> walk-list=<ids> checks=<names>", brief)

    def test_tester_admission_at_every_continuation_boundary(self):
        for kind in ("launch-tester", "relaunch-tester", "note-owner", "relaunch-owner", "cut-delivery"):
            for model in ("opus", "default", ""):
                with self.subTest(kind=kind, model=model):
                    self.setUp()
                    target = "special-tester" if kind.endswith("tester") else "builder"
                    self.meta("special-tester", "opus", "tester.1")
                    self.meta("builder", model, "builder.1")
                    payload = {} if kind.endswith("tester") else dict(tester_task="special-tester", tester_commit="none")
                    self.seed("tests" if kind.endswith("tester") else "build", "admission", receipt="pending", effect=dict(
                        kind=kind, target=target, expected_gen="tester.1" if kind.endswith("tester") else "builder.1",
                        id="admission", note="Continue admitted tests", **payload))
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.effects(""), [])
                    guard = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"),
                                            "guard", target, "builder:admission"], env=self.env)
                    self.assertEqual(guard.returncode, 3)
                    self.meta("builder", "gpt-5.5", "builder.1")
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(len(self.completed(kind)), 1)
                    before = self.effects("")
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(self.effects(""), before)

    def test_lifecycle_custody_at_every_delivery_boundary(self):
        for kind in ("note-owner", "relaunch-owner", "cut-delivery", "route-finding", "launch-tester",
                     "relaunch-tester", "launch-review", "recheck-review"):
            for live in (False, True):
                with self.subTest(kind=kind, live=live):
                    self.setUp()
                    target = ("special-tester" if kind.endswith("tester") else "builder-review-1-1" if kind.endswith("review") else
                              "other" if kind == "route-finding" else "builder")
                    self.meta(target, "gpt-5.5" if target == "builder" else "opus", "target.1")
                    if target == "other":
                        self.lease_other(target, "observe")
                    else:
                        self.write("config/autolaunch-steps", "observe builder\n")
                    self.write(f"fake/agent-{target}", "alive" if live else "dead")
                    self.seed("fix", "custody", receipt="pending", effect=dict(kind=kind, target=target,
                        expected_gen="target.1", id="custody", note="Continue leased work"))
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.effects(""), [])
                    self.assertEqual(list((self.home / f"state/{target}.inbox").glob("*.msg")), [])
                    guard = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"),
                                            "guard", target, "builder:custody"], env=self.env)
                    self.assertEqual(guard.returncode, 3)
                    self.write("config/autolaunch-steps", "act builder other\n" if target == "other" else "act builder\n")
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(len(self.completed(kind)), 1)
                    before = self.effects("")
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(self.effects(""), before)

    def test_tester_commit_is_on_the_builder_branch_before_any_continuation(self):
        for cut, live, crash in ((False, False, "before"), (False, True, "after"), (True, False, "after"), (True, True, "before"), (False, False, "scope"), (False, False, "rename")):
            with self.subTest(cut=cut, live=live, crash=crash):
                self.setUp()
                project = self.home / "projects/proj"
                git = ["git", "-C", str(project)]
                subprocess.run(git + ["init", "-q", "-b", "fm/builder"], check=True)
                identity = ["-c", "user.name=Tester", "-c", "user.email=test@example.invalid"]
                if crash == "rename":
                    self.write("projects/proj/product.py", "assert 1 == 1\n")
                    subprocess.run(git + ["add", "product.py"], check=True)
                subprocess.run(git + identity + ["commit", "--allow-empty", "-qm", "builder prep"], check=True)
                builder_head = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                tester_copy = self.home / "tester-copy"
                subprocess.run(["git", "clone", "-q", str(project), str(tester_copy)], check=True)
                self.write("tester-copy/tests/risk.py", "assert 1 == 1\n")
                tester_git = ["git", "-C", str(tester_copy)]
                subprocess.run(tester_git + ["add", "tests/risk.py"], check=True)
                if crash == "scope":
                    self.write("tester-copy/product.py", "product = 'unauthorized'\n")
                    subprocess.run(tester_git + ["add", "product.py"], check=True)
                elif crash == "rename":
                    subprocess.run(tester_git + ["rm", "-q", "product.py"], check=True)
                subprocess.run(tester_git + identity + ["commit", "-qm", "tester oracle"], check=True)
                commit = subprocess.check_output(tester_git + ["rev-parse", "HEAD"], text=True).strip()
                self.meta("special-tester", "opus", "tester.1")
                with (self.home / "state/special-tester.meta").open("a") as f:
                    f.write(f"worktree={tester_copy}\n")
                revision = "r2" if cut else "r1"
                if cut:
                    self.prepare_effect("cut-delivery")
                    self.write("state/builder.status", "working [at=4]: cut ready data/builder/prep.md r2 walk_changed=yes risk_changed=no\n")
                    self.assertEqual(self.run_pass().returncode, 0)
                else:
                    self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
                self.append_status("special-tester", f"done [at=5]: tests-ready commit={commit} revision={revision} walk-list=screen-a,screen-b checks=existing")
                self.write("fake/agent-builder", "alive" if live else "dead")
                kind = "cut-delivery" if cut else "note-owner" if live else "relaunch-owner"
                if crash in ("scope", "rename"):
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertTrue(any(r.get("reason") == "tester-scope-violation" for r in self.rows()))
                    self.assertEqual(self.effects("relaunch builder"), [])
                    self.assertEqual(subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip(), builder_head)
                    if crash == "rename":
                        self.assertEqual((project / "product.py").read_text(), "assert 1 == 1\n")
                    continue
                self.assertNotEqual(self.run_pass(f"{crash}:{kind}").returncode, 0)
                if crash == "before":
                    self.assertEqual(subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip(), builder_head)
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                subprocess.run(git + ["merge-base", "--is-ancestor", commit, "refs/heads/fm/builder"], check=True)
                self.assertEqual(subprocess.check_output(git + ["show", "fm/builder:tests/risk.py"], text=True), "assert 1 == 1\n")
                self.assertEqual(subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip(), commit)
                effects = self.effects("")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects(""), effects)
                self.assertEqual(len(self.completed(kind)), 1)

    def test_control_guard_rechecks_models_for_owner_continuations(self):
        self.meta("builder", "opus", "builder.2")
        self.meta("special-tester", "opus", "tester.1")
        self.seed("build", "cut-result", receipt="pending", effect=dict(
            id="cut-result", kind="cut-delivery", target="builder", expected_gen="builder.2", note="Continue",
            tester_task="special-tester", tester_commit="none"))
        result = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"), "guard", "builder", "builder:cut-result"], env=self.env)
        self.assertEqual(result.returncode, 3)

    def walk_only_cut(self, live=False):
        self.prepare_effect("cut-delivery")
        if live:
            self.write("fake/agent-builder", "alive")
        self.meta("special-tester", "opus", "st.1.1")
        self.write("fake/agent-special-tester", "dead")
        self.write("data/builder/prep.md", (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2").replace("screen-a,screen-b", "screen-a,screen-b,screen-c"))
        self.write("state/builder.status", "working [at=4]: cut ready data/builder/prep.md r2 walk_changed=yes risk_changed=no\n")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.effects("relaunch special-tester")), 1)
        self.assertEqual(self.effects("relaunch builder"), [])
        self.append_status("special-tester", "done [at=3]: tests-ready none revision=r1 walk-list=screen-a,screen-b checks=existing")
        self.run_pass()
        self.assertEqual(self.effects("relaunch builder"), [])
        self.append_status("special-tester", "done [at=5]: tests-ready none revision=r2 walk-list=screen-a,screen-b,screen-c checks=existing")
        self.run_pass(); self.run_pass()
        if live:
            self.assertEqual(self.effects("relaunch builder"), [])
            self.assertEqual(len(list((self.home / "state/builder.inbox").glob("*.msg"))), 1)
        else:
            self.assertEqual(len(self.effects("relaunch builder")), 1)
        self.assertEqual(len(self.effects("relaunch special-tester")), 1)

    def test_walk_only_cut_returns_to_same_tester_before_owner(self):
        for live in (False, True):
            for repeat in range(2):
                with self.subTest(live=live, repeat=repeat):
                    self.setUp()
                    self.walk_only_cut(live)

    def test_observe_and_absent_are_noops(self):
        self.prepare_effect("launch-tester")
        for setting in ("observe\n", "observe builder\n", "off\n", None):
            p = self.home / "config/autolaunch-steps"
            if setting is None:
                p.unlink()
            else:
                p.write_text(setting)
            if setting == "observe\n":
                self.write("state/autolaunch-steps.pass", json.dumps(dict(at=2000000000, owners=[])))
            before = sorted(str(p.relative_to(self.home)) for p in self.home.rglob("*"))
            r = self.run_pass()
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertEqual(sorted(str(p.relative_to(self.home)) for p in self.home.rglob("*")), before)
            self.assertEqual(self.rows(), [])
            result = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"), "check"],
                                    env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_no_mistakes_files_no_reviewer(self):
        self.prepare_effect("file-review")
        with (self.home / "state/builder.meta").open("a") as f:
            f.write("mode=no-mistakes\n")
        self.run_pass(); self.run_pass()
        self.assertEqual(self.effects("spawn builder-review"), [])
        self.assertFalse((self.home / "data/builder-review-1-1").exists())

    def test_fix_head_keeps_review_round(self):
        self.prepare_effect("file-review")
        self.run_pass()
        self.append_status("builder", "working [at=7]: pr-ready head=def checks=started")
        self.append_status("builder-review-1-1", "done [at=6]: review-ready reviewed_head=abc finding=bug-1 review=https://github.com/example/proj/pull/1#review-1")
        self.run_pass(); self.run_pass()
        self.assertEqual(len(self.effects("spawn builder-review-1-1")), 1)
        self.assertFalse((self.home / "data/builder-review-1-2").exists())

    def test_repair_progression_survives_walk_bookkeeping(self):
        for site in ("checks", "findings", "recheck", "pipeline"):
            with self.subTest(site=site):
                self.setUp()
                self.prepare_effect("file-review")
                self.assertEqual(self.run_pass().returncode, 0)
                self.seed("merged", "merge:abc", merge="abc")
                self.prepare_effect("walk-request")
                summary = json.loads((self.home / "data/x-board-summary.json").read_text())
                summary["walk_results"] = [dict(walk_owner="main", walk="demo", release="abc", attempt=1,
                    assignment="demo@abc.a1", path="data/walk-result-failed.md", report_sha256="a" * 64,
                    complete=True, steps=[dict(id="screen-a", result="failed", screenshots=["failure.png"]),
                                          dict(id="screen-b", result="green")])]
                self.write("data/x-board-summary.json", json.dumps(summary))
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.rows()[-1]["outcome"], "usable-failed")
                self.write("fake/agent-builder", "dead")
                self.write("fake/agent-builder-review-1-1", "dead")
                self.append_status("builder", f"working [at=8]: pr-ready head=def checks={'red' if site == 'checks' else 'started'}")
                if site == "findings":
                    self.append_status("builder-review-1-1", "done [at=9]: review-ready reviewed_head=def finding=repair-bug review=url")
                elif site == "recheck":
                    self.append_status("builder-review-1-1", "done [at=9]: review-ready reviewed_head=abc finding=none review=url")
                elif site == "pipeline":
                    with (self.home / "state/builder.meta").open("a") as stream:
                        stream.write("mode=no-mistakes\n")
                    self.write("state/builder.step-nm", json.dumps(dict(generation=1, facts=dict(
                        head="def", run_id="run-1", findings=[dict(id="pipeline-bug")]))))
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                expected = {"checks": "checks-red:def", "findings": "review:builder@1:1:repair-bug",
                            "recheck": "recheck:builder@1:1:def", "pipeline": "review:builder@1:1:pipeline-bug"}[site]
                self.assertTrue(any(r["trigger"] == expected and r["receipt"] == "completed" for r in self.rows()))
                effects = self.effects("")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects(""), effects)
                self.assertEqual(len(self.effects("spawn builder-review-1-1")), 1)

    def test_reused_children_dispatch_the_current_saved_context(self):
        for site in ("generation", "cut", "recheck"):
            for state in ("queued", "done", "retired"):
                with self.subTest(site=site, state=state):
                    self.setUp()
                    reviewer = site == "recheck"
                    self.prepare_effect("launch-review" if reviewer else "launch-tester")
                    self.assertEqual(self.run_pass().returncode, 0)
                    target = "builder-review-1-1" if reviewer else "special-tester"
                    (self.home / f"state/{target}.meta").unlink()
                    self.write(f"fake/agent-{target}", "dead")
                    command = "reopen" if state == "queued" else "done"
                    changed = subprocess.run(["bash", str(ROOT / "bin/fm-tasks-axi.sh"), command, target],
                                             env=self.env, text=True, capture_output=True)
                    self.assertEqual(changed.returncode, 0, changed.stderr)
                    if state == "retired":
                        (self.home / f"state/{target}.status").unlink(missing_ok=True)
                    self.write(f"data/{target}/brief.md", "stale generation and builder location\n")
                    self.write(f"data/{target}/prep.md", "REVISION: stale\n")
                    prep = (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2")
                    self.write("data/builder/prep.md", prep)
                    if site == "generation":
                        self.seed("done", "generation-one-finished", spawn_gen="s1.1.1", revision="r1")
                        self.meta("builder", "gpt-5.5", "fresh.2")
                        with (self.home / "state/builder.meta").open("a") as stream:
                            stream.write("branch=fm/builder-g2\n")
                        self.append_status("builder", "working [at=30]: generation ready 2 source=new-ask branch=fm/builder-g2")
                        self.append_status("builder", "working [at=31]: prep ready data/builder/prep.md r2")
                    elif site == "cut":
                        self.append_status("builder", "working [at=30]: cut ready data/builder/prep.md r2 walk_changed=yes risk_changed=no")
                    else:
                        if state != "retired":
                            self.append_status(target, "done [at=30]: review-ready reviewed_head=abc finding=none review=url")
                        self.append_status("builder", "working [at=31]: pr-ready head=def checks=started")
                    self.tool("spawn", (self.home / "fake/spawn").read_text().split("set -eu\n", 1)[1].replace(
                        "id=$1;", 'id=$1; cp "$FM_HOME/data/$id/brief.md" "$FM_HOME/fake/dispatched-brief"; '
                        'cp "$FM_HOME/data/$id/prep.md" "$FM_HOME/fake/dispatched-prep";'))
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(len(self.effects("spawn " + target)), 2)
                    self.assertEqual((self.home / "fake/dispatched-prep").read_text(), prep)
                    brief = (self.home / "fake/dispatched-brief").read_text()
                    self.assertIn("Prep revision: r2", brief)
                    self.assertIn("head=def" if reviewer else ("fm/builder-g2" if site == "generation" else "fm/builder"), brief)
                    before = self.effects("")
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(self.effects(""), before)

    def test_child_binding_is_required_with_and_without_runtime_metadata(self):
        for role in ("tester", "review"):
            for runtime in (False, True):
                with self.subTest(role=role, runtime=runtime):
                    self.setUp()
                    self.prepare_effect("launch-" + role)
                    target = "special-tester" if role == "tester" else "builder-review-1-1"
                    self.meta(target, "opus", "child.1")
                    if not runtime:
                        (self.home / f"state/{target}.meta").unlink()
                    backlog = (self.home / "data/backlog.md").read_text()
                    self.write("data/backlog.md", backlog.replace("builder=main:builder", "builder=main:another-builder"))
                    brief = self.write(f"data/{target}/brief.md", "Other owner's brief\n")
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.effects(""), [])
                    self.assertEqual(brief.read_text(), "Other owner's brief\n")
                    self.assertTrue(any(r.get("reason") == "child-owner-conflict" for r in self.rows()))
                    self.write("data/backlog.md", backlog)
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(len(self.completed("launch-" + role)), 1)

    def test_generated_children_pass_intake_without_owner_custody(self):
        # Oracle: the selected builder= contract must file both child roles in
        # the native backlog, then launch them. Legacy owner= would refuse add.
        for home_id in ("main", "mate"):
            for role in ("tester", "review"):
                with self.subTest(home=home_id, role=role):
                    self.setUp()
                    if home_id != "main":
                        self.write(".fm-secondmate-home", home_id + "\n")
                    self.prepare_effect("file-" + role)
                    target = "special-tester" if role == "tester" else "builder-review-1-1"
                    filed = self.run_pass("after:file-" + role)
                    self.assertNotEqual(filed.returncode, 0, filed.stdout)
                    shown = subprocess.run(["bash", str(ROOT / "bin/fm-tasks-axi.sh"),
                                            "show", target, "--full"], env=self.env,
                                           capture_output=True, text=True)
                    self.assertEqual(shown.returncode, 0, shown.stderr)
                    self.assertIn("  state: queued\n", shown.stdout)
                    emitted = (self.home / f"data/{target}/step-body.md").read_text()
                    self.assertEqual(emitted.splitlines()[0],
                                     f"SLICE: id=demo role={role} builder={home_id}:builder")
                    body_line = next(line for line in shown.stdout.splitlines() if line.startswith("  body: "))
                    self.assertEqual(json.loads(body_line.removeprefix("  body: ")), emitted.strip())
                    resumed = self.run_pass()
                    self.assertEqual(resumed.returncode, 0, resumed.stdout)
                    self.assertEqual(len(self.completed("file-" + role)), 1, self.rows())
                    self.assertEqual(len(self.completed("launch-" + role)), 1, self.rows())

    def test_legacy_child_bindings_remain_readable(self):
        # Persisted owner= bindings predate builder=. Both admission and child
        # reuse must accept them; an unlaunched record is rewritten on reuse.
        for role in ("tester", "review"):
            for runtime in (False, True):
                with self.subTest(role=role, runtime=runtime):
                    self.setUp()
                    self.prepare_effect("launch-" + role)
                    target = "special-tester" if role == "tester" else "builder-review-1-1"
                    self.meta(target, "opus", "child.1")
                    backlog = (self.home / "data/backlog.md").read_text()
                    self.write("data/backlog.md", backlog.replace("builder=main:builder", "owner=main:builder"))
                    if not runtime:
                        (self.home / f"state/{target}.meta").unlink()
                    self.write("config/autolaunch-steps", "off\n")
                    admitted = subprocess.run([sys.executable, str(ROOT / "bin/fm-autolaunch-steps.py"),
                                               "launch-admission", target, "opus", ""],
                                              env=self.env, capture_output=True, text=True)
                    self.assertEqual(admitted.returncode, 0, admitted.stdout + admitted.stderr)
                    self.write("config/autolaunch-steps", "act builder\n")
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(len(self.completed("launch-" + role)), 1, self.rows())

    def test_control_child_continuation_fixture(self):
        script = 'FM_TEST_FIXTURE_IMPORT=control-relaunch; . "$STEP_ROOT/tests/fm-control-relaunch.test.sh"; test_step_action_continuation'
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True, capture_output=True, timeout=240)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_green_review_records_a_wait_without_routing_a_none_finding(self):
        self.prepare_effect("file-review")
        self.assertEqual(self.run_pass().returncode, 0)
        self.append_status("builder-review-1-1", "done [at=7]: review-ready reviewed_head=abc finding=none review=https://github.com/example/proj/pull/1#review-1")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.effects("relaunch builder"), [])
        self.assertTrue(any(r["step"] == "queue" and r["receipt"] == "completed" for r in self.rows()))

    def test_merge_deploy_checkpoint_and_complete_walk(self):
        self.seed("queue", "review:green", reviewed_head="abc")
        self.write("state/builder.pr-poll-merge-notified", "provider=github\nhost=github.com\npath=example/proj\nnumber=1\n")
        with (self.home / "state/builder.meta").open("a") as f:
            f.write("pr=https://github.com/example/proj/pull/1\n")
        subprocess.run(["git", "init", "-q", str(self.home / "projects/proj")], check=True)
        git = ["git", "-C", str(self.home / "projects/proj")]
        subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "base"], check=True)
        sha = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
        self.append_status("builder", "working [at=5]: merged commit=" + sha)
        summary = dict(written_at=2000000000, interval_seconds=600,
                       deploys=[dict(id="d1", release=sha, at=10, live_check="passed")],
                       checkpoints=[dict(id="day1", at=20, kind="daily")])
        self.write("data/x-board-summary.json", json.dumps(summary))
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.effects("walk demo@")), 1)
        self.assertTrue(any(r["step"] == "walk" and r.get("obligation") for r in self.rows()))
        summary["walk_results"] = [dict(walk_owner="main", walk="demo", release=sha, attempt=1, assignment="demo@" + sha + ".a1", path="data/walk-auto-filing/walk-result-demo.md", report_sha256="f" * 64, complete=True, steps=[dict(id="screen-a", result="green"), dict(id="screen-b", result="green")])]
        self.write("data/x-board-summary.json", json.dumps(summary))
        self.run_pass(); self.run_pass()
        self.assertEqual(self.rows()[-1]["step"], "done")
        self.assertEqual(len(self.completed("teardown")), 1)
        self.assertFalse((self.home / "state/builder.meta").exists())
        accepted = next(r for r in self.rows() if r["step"] == "done" and not r.get("effect"))
        self.assertEqual(accepted["last_walk"], "data/walk-auto-filing/walk-result-demo.md")
        self.assertEqual(accepted["release"], sha)

    def test_missed_daily_checkpoint_catches_up(self):
        self.seed("deployed", "deploy:1", release="abc", deployed_at=10)
        self.write("data/x-board-summary.json", json.dumps(dict(written_at=2000000000, interval_seconds=600, daily_due=[dict(date="2033-05-18", at=30)])))
        self.run_pass(); self.run_pass()
        self.assertEqual(len(self.effects("walk demo@abc")), 1)
        self.assertTrue(any(r["trigger"].startswith("checkpoint:catchup:") for r in self.rows()))

    def test_remote_checkpoint_transport_is_distinct_for_each_owner(self):
        parent = self.home / "parent"
        self.write("parent/state/mate-x.meta", f"kind=secondmate\nhome={self.home}\n")
        self.write(".fm-secondmate-home", "mate-x\n")
        self.write(".fm-secondmate-parent", f"schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n")
        self.seed("deployed", "deploy:1", release="abc1234", deployed_at=10)
        self.write("data/x-board-summary.json", json.dumps(dict(written_at=2000000000, interval_seconds=600,
                   checkpoints=[dict(id="daily-1", at=20, kind="daily")])))
        self.meta("other", "opus", "other.1")
        self.write("data/other/prep.md", (self.home / "data/builder/prep.md").read_text().replace("WALK ID: demo", "WALK ID: other"))
        backlog = (self.home / "data/backlog.md").read_text().replace("## Queued", "- [ ] other - slice (repo: proj) (kind: ship)\n  SLICE: main/other | visible result | role=owner\n## Queued")
        self.write("data/backlog.md", backlog)
        self.seed("deployed", "deploy:1", owner="other", release="abc1234", deployed_at=10)
        self.write("config/autolaunch-steps", "act builder other\n")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.run_pass().returncode, 0)
        pending = [r for r in self.rows() if r.get("effect", {}).get("kind") == "walk-request"][-1]
        other = [json.loads(s) for s in (self.home / "data/other/slice-steps.log").read_text().splitlines()][-1]
        self.assertNotEqual(pending["effect"]["corr"], other["effect"]["corr"])
        self.assertEqual(len(list((self.home / "data/walk-briefs").glob("walk-*.md"))), 2)
        lines = (parent / "state/mate-x.status").read_text().splitlines()
        self.assertEqual(len([line for line in lines if "walk-request:" in line]), 2)

    def test_coverage_only_cut_rewalks_the_same_release_before_completion(self):
        for live, coverage_only in ((False, True), (True, True), (False, False)):
            with self.subTest(live=live, coverage_only=coverage_only):
                self.setUp()
                git = ["git", "-C", str(self.home / "projects/proj")]
                subprocess.run(git + ["init", "-q"], check=True)
                subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "base"], check=True)
                release = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                self.seed("merged", "merge:" + release, merge=release)
                self.seed("deployed", "deploy:1", release=release, deployed_at=10)
                summary = dict(written_at=2000000000, interval_seconds=600, checkpoints=[dict(id="day1", at=20, kind="daily")])
                self.write("data/x-board-summary.json", json.dumps(summary))
                self.assertEqual(self.run_pass().returncode, 0)
                prep = (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2").replace("screen-a,screen-b", "screen-a,screen-b,screen-c")
                if coverage_only:
                    prep += "COVERAGE ONLY: yes\n"
                self.write("data/builder/prep.md", prep)
                self.meta("special-tester", "opus", "tester.1")
                self.write("fake/agent-builder", "alive" if live else "dead")
                self.append_status("builder", "working [at=30]: cut ready data/builder/prep.md r2 walk_changed=yes risk_changed=no")
                self.assertEqual(self.run_pass().returncode, 0)
                self.append_status("special-tester", "done [at=31]: tests-ready none revision=r2 walk-list=screen-a,screen-b,screen-c checks=existing")
                summary["walk_results"] = [dict(walk_owner="main", walk="demo", release=release, attempt=1,
                    assignment=f"demo@{release}.a1", path="data/walk-auto-filing/walk-result-old.md", report_sha256="a" * 64,
                    complete=True, steps=[dict(id=s, result="green") for s in ("screen-a", "screen-b")])]
                self.write("data/x-board-summary.json", json.dumps(summary))
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertFalse(any(r["step"] == "done" for r in self.rows()))
                self.assertEqual(self.effects("walk "), [f"walk demo@{release}.a1", f"walk demo@{release}.a2"])
                summary["walk_results"].append(dict(walk_owner="main", walk="demo", release=release, attempt=2,
                    assignment=f"demo@{release}.a2", path="data/walk-auto-filing/walk-result-current.md", report_sha256="b" * 64,
                    complete=True, steps=[dict(id=s, result="green") for s in ("screen-a", "screen-b", "screen-c")]))
                self.write("data/x-board-summary.json", json.dumps(summary))
                self.assertEqual(self.run_pass().returncode, 0)
                if not coverage_only:
                    self.assertFalse(any(r["step"] == "done" for r in self.rows()))
                    subprocess.run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "product cut"], check=True)
                    repaired = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                    self.seed("merged", "merge:" + repaired, merge=repaired)
                    self.seed("deployed", "deploy:2", release=repaired, deployed_at=10)
                    self.assertEqual(self.run_pass().returncode, 0)
                    summary["walk_results"].append(dict(summary["walk_results"][-1], release=repaired, attempt=1,
                                                         assignment=f"demo@{repaired}.a1"))
                    self.write("data/x-board-summary.json", json.dumps(summary))
                    self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(len(self.completed("teardown")), 1)
                self.assertEqual(len([r for r in self.rows() if r["step"] == "merged"]), 1 if coverage_only else 2)
                self.assertEqual(self.effects("relaunch special-tester"), ["relaunch special-tester"])

    def test_walk_findings_use_logical_home_identity_and_retain_the_result_path(self):
        for home_id in ("main", "q-server"):
            with self.subTest(home_id=home_id):
                self.setUp()
                if home_id != "main":
                    self.write(".fm-secondmate-home", home_id)
                self.meta("other", "opus", "other.1")
                self.lease_other("other", "act")
                self.seed("walk", "checkpoint:day1", obligation=True, walk="demo", release="abc", attempt=1,
                          revision="r1", walk_list="screen-a,screen-b")
                result = dict(walk_owner=home_id, walk="demo", release="abc", attempt=1, assignment="demo@abc.a1",
                              path="data/walk-auto-filing/walk-result-failed.md", report_sha256="f" * 64, complete=True,
                              steps=[dict(id="screen-a", result="failed", screenshots=["evidence.png"]), dict(id="screen-b", result="green")],
                              findings=[dict(id="other-screen", routed_to="other")])
                self.write("data/x-board-summary.json", json.dumps(dict(written_at=2000000000, interval_seconds=600, walk_results=[result])))
                run = self.run_pass()
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assertEqual(self.run_pass().returncode, 0)
                routed = {r["routed_to"] for r in self.rows() if r["step"] == "fix"}
                self.assertEqual(routed, {f"{home_id}:builder", f"{home_id}:other"})
                outcome = next(r for r in self.rows() if r.get("outcome") == "usable-failed")
                self.assertEqual(outcome["last_walk"], result["path"])
                self.assertEqual(outcome["release"], "abc")

    def test_green_walk_closes_only_current_coverage_and_repaired_release(self):
        for change in ("revision", "coverage", "walk", "repair-pending", "repair-merged", "saved-outcome", "current"):
            with self.subTest(change=change):
                self.setUp()
                git = ["git", "-C", str(self.home / "projects/proj")]
                subprocess.run(git + ["init", "-q"], check=True)
                commit = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm"]
                subprocess.run(git + commit + ["base"], check=True)
                release = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                self.seed("merged", "merge:" + release, merge=release)
                self.seed("walk", "checkpoint:day1", obligation=True, walk="demo", release=release,
                          attempt=1, revision="r1", walk_list="screen-a,screen-b")
                prep = (self.home / "data/builder/prep.md").read_text()
                if change == "revision":
                    self.write("data/builder/prep.md", prep.replace("REVISION: r1", "REVISION: r2"))
                elif change == "coverage":
                    self.write("data/builder/prep.md", prep.replace("screen-a,screen-b", "screen-a,screen-b,screen-c"))
                elif change == "walk":
                    self.write("data/builder/prep.md", prep.replace("WALK ID: demo", "WALK ID: changed"))
                elif change.startswith("repair-"):
                    self.seed("fix", "walk:demo:failed-step")
                    if change == "repair-merged":
                        subprocess.run(git + commit + ["repair"], check=True)
                        repair = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
                        self.seed("merged", "merge:" + repair, merge=repair)
                elif change == "saved-outcome":
                    self.seed("walk", f"walk-outcome:demo@{release}.a1", outcome="usable-green",
                              revision="r1", walk_list="screen-a", path="data/walk-auto-filing/walk-result-demo.md", report_sha256="f" * 64)
                result = dict(walk_owner="main", walk="demo", release=release, attempt=1,
                              assignment=f"demo@{release}.a1", path="data/walk-auto-filing/walk-result-demo.md", report_sha256="f" * 64, complete=True,
                              steps=[dict(id=s, result="green") for s in ("screen-a", "screen-b")])
                self.write("data/x-board-summary.json", json.dumps(dict(
                    written_at=2000000000, interval_seconds=600, walk_results=[result])))
                run = self.run_pass()
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(any(r["step"] == "done" for r in self.rows()), change == "current")

    def test_mixed_green_and_blocked_reports_retry_then_assign_machinery_failure(self):
        for verdict in ("blocked", "unusable", "unknown"):
            with self.subTest(verdict=verdict):
                self.setUp()
                self.prepare_effect("walk-request")
                self.assertEqual(self.run_pass().returncode, 0)
                summary = dict(written_at=2000000000, interval_seconds=600, walk_results=[])
                for attempt in (1, 2):
                    summary["walk_results"].append(dict(
                        walk_owner="main", walk="demo", release="abc", attempt=attempt,
                        assignment=f"demo@abc.a{attempt}", path="data/walk-auto-filing/walk-result-demo.md", report_sha256=str(attempt) * 64, complete=True,
                        steps=[dict(id="screen-a", result="green"), dict(id="screen-b", result=verdict)]))
                    self.write("data/x-board-summary.json", json.dumps(summary))
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.effects("walk "), ["walk demo@abc.a1", "walk demo@abc.a2"])
                self.assertTrue(any(r.get("failure") == "walk-machinery:demo@abc" for r in self.rows()))
                self.assertFalse(any(r.get("outcome", "").startswith("usable-") or r["step"] == "done" for r in self.rows()))
                self.assertEqual(self.effects("relaunch builder"), [])
                effects = self.effects("")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects(""), effects)

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
        self.assertEqual(self.effects("relaunch builder"), [])

    def test_pending_unsent_walk_recovers_expired_transport_after_restart(self):
        for outcome in ("running", "transport-uncertain", "gap"):
            with self.subTest(outcome=outcome):
                self.setUp()
                self.tool("walk", '''while [ "$#" -gt 0 ]; do
  if [ "$1" = --once-key ]; then echo "attempt $2" >> "$FM_HOME/fake/effects"; fi
  shift
done
''')
                self.prepare_effect("walk-request")
                self.assertNotEqual(self.run_pass("after:walk-request").returncode, 0)
                self.assertEqual(self.completed("walk-request"), [])
                self.write("data/x-board-summary.json", json.dumps(dict(written_at=1, interval_seconds=600)))
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects("attempt "), ["attempt demo@abc.a1"])
                self.assertEqual(len([r for r in self.rows() if r.get("trigger") == "carrier-stale:demo@abc.a1"]), 1)
                summary = dict(written_at=2000000000, interval_seconds=600, walk_attempts=[dict(
                    walk_owner="main", walk="demo", release="abc", attempt=1, outcome="running", claim_expires=2000000100)])
                self.write("data/x-board-summary.json", json.dumps(summary))
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects("attempt "), ["attempt demo@abc.a1"])
                summary["walk_attempts"][0]["claim_expires"] = 1999999999
                self.write("data/x-board-summary.json", json.dumps(summary))
                self.assertNotEqual(self.run_pass("after:walk-request").returncode, 0)
                self.assertEqual(self.effects("attempt "), ["attempt demo@abc.a1", "attempt demo@abc.a2"])
                summary["walk_attempts"].append(dict(walk_owner="main", walk="demo", release="abc", attempt=2,
                                                      outcome=outcome, claim_expires=1999999999))
                self.write("data/x-board-summary.json", json.dumps(summary))
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(len(self.completed("walk-request")), 2)
                self.assertTrue(any(r.get("failure") == "walk-machinery:demo@abc" for r in self.rows()))
                self.assertEqual(self.effects("relaunch "), [])
                self.assertEqual(len(self.effects("attempt ")), 2)

    def test_stale_carrier_leaves_obligation_open_and_reports_once(self):
        self.prepare_effect("walk-request")
        self.run_pass()
        self.write("data/x-board-summary.json", json.dumps(dict(written_at=1, interval_seconds=600)))
        self.run_pass(); self.run_pass()
        self.assertEqual(len([r for r in self.rows() if r.get("reason") == "carrier-stale"]), 1)
        self.assertFalse(any(r["step"] == "done" for r in self.rows()))

    def test_generation_never_revives_previous_runtime(self):
        self.seed("done", "walk-green:demo@abc")
        self.append_status("builder", "working [at=30]: generation ready 2 source=new-ask branch=fm/builder-g2")
        self.run_pass(); self.run_pass()
        self.assertEqual(self.effects("relaunch builder"), [])
        self.assertEqual(len([r for r in self.rows() if r["step"] == "generation" and r["generation"] == 2]), 1)
        self.assertIn("spawn_gen=s1.1.1", (self.home / "state/builder.meta").read_text())

    def test_reopened_generation_enters_prep_after_fresh_admission(self):
        self.seed("done", "walk-green:demo@abc")
        self.append_status("builder", "working [at=30]: generation ready 2 source=new-ask branch=fm/builder-g2")
        self.assertEqual(self.run_pass().returncode, 0)
        self.meta("builder", "gpt-5.5", "fresh.2")
        with (self.home / "state/builder.meta").open("a") as f:
            f.write("branch=fm/builder-g2\n")
        self.append_status("builder", "working [at=31]: prep ready data/builder/prep.md r1")
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.effects("spawn "), [])
        prep = (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2")
        self.write("data/builder/prep.md", prep)
        self.append_status("builder", "working [at=32]: prep ready data/builder/prep.md r2")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.effects("spawn "), ["spawn special-tester opus"])
        self.assertEqual(self.completed("launch-tester")[0]["generation"], 2)

    def test_reopened_generation_accepts_fresh_admission_before_its_first_pass(self):
        self.seed("done", "walk-green:demo@abc", spawn_gen="s1.1.1", revision="r1")
        self.meta("builder", "gpt-5.5", "fresh.2")
        with (self.home / "state/builder.meta").open("a") as f:
            f.write("branch=fm/builder-g2\n")
        self.write("data/builder/prep.md", (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2"))
        self.append_status("builder", "working [at=30]: generation ready 2 source=new-ask branch=fm/builder-g2")
        self.append_status("builder", "working [at=31]: prep ready data/builder/prep.md r2")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.effects("spawn "), ["spawn special-tester opus"])
        self.assertEqual(self.completed("launch-tester")[0]["generation"], 2)

    def test_teardown_crashes_reconcile_and_refusals_keep_the_receipt_pending(self):
        for boundary in ("before", "after", "refused", "ready-before-remove"):
            with self.subTest(boundary=boundary):
                self.setUp()
                self.closure_ready()
                if boundary in ("refused", "ready-before-remove"):
                    marker = "fake/teardown-refuse" if boundary == "refused" else "fake/cleanup-before-remove"
                    self.write(marker, "yes")
                    self.assertEqual(self.run_pass().returncode, 0)
                    self.assertEqual(self.completed("teardown"), [])
                    self.assertFalse(any(r["step"] == "done" for r in self.rows()))
                    self.assertTrue((self.home / "state/builder.meta").exists())
                    self.assertIn("- [ ] builder", (self.home / "data/backlog.md").read_text())
                    (self.home / marker).unlink()
                else:
                    self.assertNotEqual(self.run_pass(f"{boundary}:teardown").returncode, 0)
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(self.completed("teardown")), 1)
                self.assertFalse((self.home / "state/builder.meta").exists())
                effects = self.effects("")
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects(""), effects)
                if boundary not in ("refused", "ready-before-remove"):
                    self.assertEqual(self.effects("teardown "), ["teardown builder"])

    def test_native_acceptance_reconciles_only_after_the_cleanup_receipt(self):
        self.closure_ready()
        self.assertNotEqual(self.run_pass("before:accept-owner").returncode, 0)
        self.assertEqual(len(self.completed("teardown")), 1)
        self.assertIn("- [ ] builder", (self.home / "data/backlog.md").read_text())
        self.assertNotEqual(self.run_pass("after:accept-owner").returncode, 0)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.completed("accept-owner")), 1)
        self.assertEqual(self.effects("teardown "), ["teardown builder"])

    def test_closure_revalidates_proof_before_each_external_effect(self):
        for boundary in ("teardown", "accept-owner"):
            for change in ("revision", "coverage", "repair"):
                with self.subTest(boundary=boundary, change=change):
                    self.setUp()
                    self.closure_ready()
                    self.assertNotEqual(self.run_pass("before:" + boundary).returncode, 0)
                    if change == "repair":
                        self.seed("fix", "new-repair")
                    else:
                        prep = (self.home / "data/builder/prep.md").read_text()
                        prep = prep.replace("REVISION: r1", "REVISION: r2") if change == "revision" else prep.replace(
                            "screen-a,screen-b", "screen-a,screen-b,screen-c")
                        self.write("data/builder/prep.md", prep)
                    result = self.run_pass()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertFalse(any(r["step"] == "done" for r in self.rows()))
                    self.assertIn("- [ ] builder", (self.home / "data/backlog.md").read_text())
                    self.assertTrue(any(r.get("superseded_by") == "proof-changed" for r in self.rows()))
                    if boundary == "teardown" and change == "revision":
                        self.append_status("builder", "working [at=31]: cut ready data/builder/prep.md r2 walk_changed=no risk_changed=no")
                        self.assertEqual(self.run_pass().returncode, 0)
                        self.assertEqual(len(self.completed("cut-delivery")), 1)

    def test_guarded_runtime_cleanup_precedes_native_closure(self):
        script = r'''
FM_TEST_FIXTURE_IMPORT=teardown
. "$STEP_ROOT/tests/fm-teardown.test.sh"
unset FM_AUTOLAUNCH_STEPS_TEARDOWN_BIN
for scenario in unique open merged; do
  case_dir=$(prepare_recorded_github_pr "step-cleanup-$scenario" local-only)
  fm_test_tasks_toml "$case_dir/.tasks.toml"
  mkdir -p "$case_dir/data/task-x1"
  printf 'act task-x1\n' > "$case_dir/config/autolaunch-steps"
  printf 'REVISION: r1\nWALK ID: demo\nWALK LIST: screen-a,screen-b\n' > "$case_dir/data/task-x1/prep.md"
  install_github_pr_class "$case_dir" merged
  if [ "$scenario" = unique ]; then
    wt_commit_file "$case_dir" extra.txt unique 'unmerged repair'
  elif [ "$scenario" = open ]; then
    install_github_pr_class "$case_dir" open
  fi
  python3 - "$case_dir/data/task-x1/slice-steps.log" "$case_dir" <<'PY'
import json, sys, subprocess
from pathlib import Path
meta = dict(line.split("=", 1) for line in Path(sys.argv[2], "state/task-x1.meta").read_text().splitlines() if "=" in line)
release = subprocess.check_output(["git", "-C", meta["project"], "rev-parse", "HEAD"], text=True).strip()
merge = dict(at=1, generation=1, owner="task-x1", step="merged", trigger="merge:"+release, receipt="completed", merge=release)
row = dict(at=1, generation=1, owner="task-x1", step="walk", closure_ready=True, trigger="walk-green:proof",
           receipt="completed", last_walk="data/walk-result-proof.md", revision="r1",
           spawn_gen="teardown-test-task-x1", release=release, project=meta["project"], walk="demo", walk_list="screen-a,screen-b")
with open(sys.argv[1], "w") as stream:
    stream.write(json.dumps(merge) + "\n" + json.dumps(row) + "\n")
PY
  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" run > "$case_dir/step.log" 2>&1 \
    || fail "step cleanup command failed: $(cat "$case_dir/step.log")"
  if [ "$scenario" = merged ]; then
    assert_absent "$case_dir/state/task-x1.meta" 'guarded cleanup removes only the completed runtime'
    assert_equals done "$(backlog_row_state "$case_dir")" 'native acceptance follows successful runtime cleanup'
    python3 - "$case_dir/data/task-x1/slice-steps.log" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
cleanup = next(i for i, r in enumerate(rows) if r.get("effect", {}).get("kind") == "teardown" and r["receipt"] == "completed")
acceptance = next(i for i, r in enumerate(rows) if r.get("effect", {}).get("kind") == "accept-owner")
done = next(i for i, r in enumerate(rows) if r["step"] == "done")
assert cleanup < acceptance < done
PY
  else
    assert_present "$case_dir/state/task-x1.meta" 'unsafe cleanup preserves the runtime record'
    assert_equals in_flight "$(backlog_row_state "$case_dir")" 'unsafe cleanup never closes the native task'
    python3 - "$case_dir/data/task-x1/slice-steps.log" <<'PY_CHECK'
import json, sys
assert not any(json.loads(line)["step"] == "done" for line in open(sys.argv[1]))
PY_CHECK
    if [ "$scenario" = unique ]; then
      assert_equals unique "$(cat "$case_dir/wt/extra.txt")" 'unmerged bytes survive the refusal'
    fi
  fi
done
'''
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_teardown_reconciles_after_done_history_is_pruned(self):
        self.closure_ready()
        self.assertNotEqual(self.run_pass("after:teardown").returncode, 0)
        self.write("data/backlog.md", "## In flight\n## Queued\n## Done\n")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(self.completed("teardown")), 1)
        self.assertEqual(self.effects("teardown "), ["teardown builder"])

    def test_reopening_supersedes_pending_teardown_before_touching_the_runtime(self):
        for fresh in (False, True):
            with self.subTest(fresh=fresh):
                self.setUp()
                self.closure_ready()
                self.assertNotEqual(self.run_pass("before:teardown").returncode, 0)
                self.append_status("builder", "working [at=30]: generation ready 2 source=new-ask branch=fm/builder-g2")
                if fresh:
                    self.meta("builder", "gpt-5.5", "fresh.2")
                    with (self.home / "state/builder.meta").open("a") as f:
                        f.write("branch=fm/builder-g2\n")
                    self.write("data/builder/prep.md", (self.home / "data/builder/prep.md").read_text().replace("REVISION: r1", "REVISION: r2"))
                    self.append_status("builder", "working [at=31]: prep ready data/builder/prep.md r2")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertEqual(self.effects("teardown "), [])
                self.assertTrue((self.home / "state/builder.meta").exists())
                self.assertEqual(self.completed("teardown")[0]["superseded_by"], "new-ask")
                self.assertTrue(any(r["step"] == "generation" and r["generation"] == 2 for r in self.rows()))
                self.assertEqual(len(self.completed("launch-tester")), int(fresh))

    def test_walk_retry_uses_its_saved_brief_after_prep_changes(self):
        self.prepare_effect("walk-request")
        self.assertEqual(self.run_pass().returncode, 0)
        (self.home / "data/walk-briefs/demo.md").unlink()
        self.write("data/builder/prep.md", "REVISION: r2\nWALK ID: invalid/id\n")
        self.write("data/x-board-summary.json", json.dumps(dict(written_at=2000000000, interval_seconds=600,
                   walk_attempts=[dict(walk_owner="main", walk="demo", release="abc", attempt=1, outcome="gap")])))
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.effects("walk "), ["walk demo@abc.a1", "walk demo@abc.a2"])
        retry = next(r for r in self.rows() if r.get("retry_of") and r["receipt"] == "completed")
        self.assertEqual(retry["revision"], "r1")
        self.assertEqual(retry["walk_list"], "screen-a,screen-b")

    def test_long_pr_read_requests_full_value(self):
        self.seed("build", "tests-ready:none@r1", revision="r1")
        with (self.home / "state/builder.meta").open("a") as f:
            f.write("pr=https://github.com/example/proj/pull/1\npr_head=old\n")
        value = dict(headRefOid="abc", isDraft=False, state="OPEN", mergeCommit=None,
                     commits=dict(nodes=[dict(commit=dict(statusCheckRollup=dict(contexts=dict(nodes=[
                         dict(__typename="CheckRun", isRequired=True, status="COMPLETED", conclusion="SUCCESS")
                         for _ in range(34)
                     ]))))]))
        encoded = base64.b64encode(json.dumps(value).encode()).decode()
        self.assertGreater(len(encoded), 4000)
        self.write("fake/pr.json", encoded)
        self.write("fake/pr-truncated", encoded[:4000] + "... (truncated)")
        self.tool("pr", '''for arg in "$@"; do
  if [ "$arg" = --full ]; then cat "$FM_HOME/fake/pr.json"; exit 0; fi
done
cat "$FM_HOME/fake/pr-truncated"
''')
        self.env["FM_AUTOLAUNCH_STEPS_PR_BIN"] = str(self.home / "fake/pr")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        cached = json.loads((self.home / "state/builder.step-pr").read_text())
        self.assertEqual(cached["facts"]["head"], "abc")
        self.assertEqual(len(self.effects("spawn builder-review-1-1")), 1)

    def test_unreadable_pr_result_does_not_abort_step_pass(self):
        for output in ("A" * 4000 + "... (truncated)",
                       base64.b64encode(b"not JSON").decode(),
                       base64.b64encode(b"\xff").decode(), "non-ASCII: \u00e9"):
            with self.subTest(output=output[-30:]):
                self.setUp()
                self.prepare_effect("walk-request")
                with (self.home / "state/builder.meta").open("a") as f:
                    f.write("pr=https://github.com/example/proj/pull/1\n")
                self.tool("pr", 'cat "$FM_HOME/fake/pr.json"\n')
                self.write("fake/pr.json", output)
                self.env["FM_AUTOLAUNCH_STEPS_PR_BIN"] = str(self.home / "fake/pr")
                result = self.run_pass()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.home / "state/builder.step-pr").exists())
                self.assertTrue((self.home / "state/autolaunch-steps.pass").exists())
                self.assertEqual(self.effects("walk "), ["walk demo@abc.a1"])

    def test_recorded_pr_uses_required_checks_and_merge_facts_without_status_phrase(self):
        for required, conclusion in ((True, "FAILURE"), (False, "FAILURE"), (True, "SUCCESS")):
            with self.subTest(required=required, conclusion=conclusion):
                self.setUp()
                self.seed("build", "tests-ready:none@r1", revision="r1")
                with (self.home / "state/builder.meta").open("a") as f:
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
                self.assertEqual(len(self.effects("relaunch builder")), int(required and conclusion == "FAILURE"))
                self.assertEqual(len(self.effects("spawn builder-review-1-1")), 1)
                self.write("state/builder.pr-poll-merge-notified", "provider=github\nhost=github.com\npath=example/proj\nnumber=1\n")
                value["state"] = "MERGED"
                value["mergeCommit"] = dict(oid="b" * 40)
                self.write("fake/pr.json", base64.b64encode(json.dumps(value).encode()).decode())
                self.assertEqual(self.run_pass().returncode, 0)
                self.assertTrue(any(row["trigger"] == "merge:" + "b" * 40 for row in self.rows()))

    def test_pipeline_review_gate_is_the_round_and_never_files_a_reviewer(self):
        self.seed("build", "tests-ready:none@r1", revision="r1")
        with (self.home / "state/builder.meta").open("a") as f:
            f.write("mode=no-mistakes\n")
        self.write("fake/agent-builder", "alive")
        self.tool("nm", 'cat "$FM_HOME/fake/nm.toon"\n')
        self.write("fake/nm.toon", "run:\n  id: RUN1\n  head: abc\nsteps[1]{name,status}:\n  review,awaiting_review\ngate:\n  step: review\nfindings[1]{id,severity,file,line,description,authority}:\n  BUG1,fix,app.py,1,Handle missing value,automatic\n")
        self.env["FM_AUTOLAUNCH_STEPS_NM_BIN"] = str(self.home / "fake/nm")
        result = self.run_pass()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(r.get("pipeline_run") == "RUN1" and r["step"] == "review" for r in self.rows()))
        self.assertEqual(len(list((self.home / "state/builder.inbox").glob("*.msg"))), 1)
        self.assertFalse((self.home / "data/builder-review-1-1").exists())
        self.assertEqual(self.run_pass().returncode, 0)
        self.assertEqual(len(list((self.home / "state/builder.inbox").glob("*.msg"))), 1)

    def test_c2_does_not_alarm_for_a_trigger_newer_than_last_completed_pass(self):
        self.seed("tests", "prep:r1", tester="special-tester", revision="r1")
        self.meta("special-tester", "opus", "st.1.1")
        self.write("state/autolaunch-steps.pass", json.dumps(dict(at=100, owners=["builder"])))
        self.append_status("special-tester", "done [at=101]: tests-ready none revision=r1 walk-list=screen-a,screen-b checks=existing")
        def check():
            return subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch-check.sh")], env=self.env,
                                  text=True, capture_output=True, timeout=20).stdout
        self.assertEqual(check(), "")
        self.write("state/autolaunch-steps.pass", json.dumps(dict(at=102, owners=["builder"])))
        self.assertIn("trigger without receipt", check())

    def test_handled_inbox_receipt_still_deduplicates(self):
        self.prepare_effect("note-owner")
        self.assertNotEqual(self.run_pass("after:note-owner").returncode, 0)
        inbox = self.home / "state/builder.inbox"
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
        self.write("state/autolaunch-steps.pass", json.dumps(dict(at=2000000000, owners=["builder"])))
        env = dict(self.env, FM_AUTOLAUNCH_CHECK_NOW="2000000001")
        def check():
            return subprocess.run(["bash", str(ROOT / "bin/fm-autolaunch-check.sh")], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20).stdout
        self.assertIn("RED", check())
        self.assertEqual(check(), "")
        self.run_pass()
        self.assertEqual(check(), "")
        self.assertFalse((self.home / "state/.autolaunch-check.red").exists())


class Timer(unittest.TestCase):
    """Oracle: the printed recipe can read a leased owner with no login shell.

    This replays the emitted Environment/ExecStart contract, not a live timer.
    The held owner exercises real tasks-axi but cannot launch or contact a forge.
    """
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="fm-timer-")
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / 'home'
        for part in ('config', 'data', 'state'):
            (self.home / part).mkdir(parents=True, exist_ok=True)
        (self.home / '.tasks.toml').write_text('[tasks]\nadapter = "markdown"\nfile = "data/backlog.md"\n')
        (self.home / 'data/backlog.md').write_text(
            '## In flight\n- [ ] timer-owner - leased fixture (kind: ship) '
            '(hold: parked: fixture) (hold-kind: external) (hold-until: 2099-01-01)\n'
            '## Queued\n## Done\n')
        (self.home / 'config/autolaunch-steps').write_text('act timer-owner\n')
        self.tools = Path(tmp.name) / 'tool space%z'
        self.tools.mkdir()
        self.commands = {name: shutil.which(name) for name in
                         ('bash', 'sh', 'printenv', 'python3', 'tasks-axi', 'node')}
        for name, executable in self.commands.items():
            if executable:
                (self.tools / name).symlink_to(executable)
            elif name != 'node':
                self.fail(f'{name} is required for the Timer fixtures')
        self.path = str(self.tools) + os.pathsep + '/usr/bin:/bin'
        self.al = str(ROOT / 'bin/fm-autolaunch.sh')
        # No host home, account, backend, quota, task or override environment.
        self.env = dict(HOME=str(self.home), FM_HOME=str(self.home), PATH=self.path)

    def render(self, *flags):
        result = subprocess.run([self.commands['bash'], self.al, '--print-timer', *flags],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in (self.home / 'state').iterdir()), [])
        return result.stdout

    def service(self, recipe):
        # Only the generator's quoted assignments and literal argv are replayed;
        # actual manager activation remains the installer's proof obligation.
        env = dict(HOME=str(self.home), PATH='/usr/bin:/bin')
        command = None
        for line in recipe.splitlines():
            if line.startswith('Environment='):
                for assignment in shlex.split(line.partition('=')[2]):
                    key, value = assignment.split('=', 1)
                    env[key] = value.replace('%%', '%')
            if line.startswith('ExecStart='):
                command = shlex.split(line.partition('=')[2].replace('%%', '%'))
        self.assertIsNotNone(command)
        self.assertEqual(env.get('FM_HOME'), str(self.home))
        return env, command

    def test_timer_rejects_unrelated_or_extra_flags(self):
        for flags in (('--dry-run',), ('--steps-only', '--dry-run')):
            with self.subTest(flags=flags):
                result = subprocess.run([self.commands['bash'], self.al, '--print-timer', *flags],
                                        env=self.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')

    def test_plain_timer_carries_path(self):
        recipe = self.render()
        env, command = self.service(recipe)
        self.assertEqual(command, [self.al])
        result = subprocess.run([self.commands['bash'], str(ROOT / 'bin/fm-tasks-axi.sh'),
                                 'show', 'timer-owner', '--full'],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('timer-owner', result.stdout)
        self.assertEqual(env['PATH'], self.path)

    def test_steps_timer_runs_from_emitted_environment(self):
        recipe = self.render('--steps-only')
        env, command = self.service(recipe)
        self.assertEqual(env['PATH'], self.path)
        self.assertEqual(command, [self.al, '--steps-only'])
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        stamp = json.loads((self.home / 'state/autolaunch-steps.pass').read_text())
        self.assertEqual(stamp['owners'], ['timer-owner'])
        self.assertFalse((self.home / 'data/timer-owner/slice-steps.log').exists())

    def test_missing_tool_is_one_owned_failure(self):
        env, command = self.service(self.render('--steps-only'))
        (self.tools / 'tasks-axi').unlink()
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.count('owner task unreadable: timer-owner'), 1)
        self.assertFalse((self.home / 'state/autolaunch-steps.pass').exists())

    def test_cron_alternative_carries_path_and_step_scope(self):
        for flags in ((), ('--steps-only',)):
            with self.subTest(flags=flags):
                recipe = self.render(*flags)
                line, = [line for line in recipe.splitlines() if line.startswith('*/5 ')]
                command = line.split(' ', 5)[5].removesuffix(' >/dev/null 2>&1')
                # cron consumes backslash-percent before passing text to /bin/sh.
                self.assertNotRegex(command, r'(?<!\\)%')
                command = command.replace(r'\%', '%')
                # Inspect argv/environment at the shell boundary without launching
                # the ordinary ready queue. The step path is executed above.
                words = shlex.split(command)
                self.assertEqual(words[2:], [self.al, *flags])
                assignments = command.rsplit(shlex.quote(self.al), 1)[0]
                result = subprocess.run([self.commands['sh'], '-c', assignments +
                    ' ' + shlex.quote(self.commands['printenv']) + ' PATH FM_HOME'],
                    env=dict(PATH='/usr/bin:/bin'), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [self.path, str(self.home)])


if __name__ == "__main__":
    unittest.main()
