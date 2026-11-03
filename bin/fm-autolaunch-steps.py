#!/usr/bin/env python3
"""Durable slice transitions for fm-autolaunch.sh (the shell owns the pass lock).

Usage: fm-autolaunch-steps.py run|dry|check|wait <owner>|guard <task> <action>

Record owner: data/<owner>/slice-steps.log, append-only JSONL. Every record has
at, owner, generation, step, trigger and receipt (pending/completed). An effect
has its immutable payload, target, expected spawn_gen and id in the pending
record; completion preserves that payload. The latest record for an id wins.
Facts have no effect and are written completed in one append. fsync precedes
every external call. A damaged log fails closed, including a partial tail.

Config: absent/off disables; each line is `act <owner> ...` or
`observe <owner> ...`; bare observe observes all recorded owners. Duplicate or
invalid owners refuse the entire config. Only act grants a transition lease.
Observation and dry mode write nothing. A pass reconciles pending effects
before discovering new triggers, then publishes state/autolaunch-steps.pass
atomically. C2 only judges evidence older than this completed-pass record.

Input status phrases: prep ready <data-path> <revision>; cut ready <data-path>
<revision> walk_changed=yes|no risk_changed=yes|no; done: tests-ready
commit=<sha>|none revision=<revision> walk-list=<ids> checks=<names>;
pr-ready head=<sha> checks=started|red; review-ready reviewed_head=<sha>
finding=<id> review=<url>; merged commit=<sha>; generation ready <n>
source=<receipt> branch=<fresh-branch>. Cut/prep revisions must match the
committed prep's REVISION. Tests-ready must name the accepted walk list.
Prep fields: REVISION, CUT, WALK ID, WALK LIST, WALK BRIEF, WALK BOT,
WALK PROJECT, WALK TARGET (explicit MAIN dispatcher routing), TESTER PATHS,
TESTER RULE, RISKS, COVERAGE ONLY (yes only for a list-only cut with no product
work). TESTER TASK comes from the owner task, else <owner>-tester.
No-mistakes review evidence uses `pipeline-review round=<round> head=<sha>`
and optional finding=<id>; it never creates a second review task.

Carrier contract (P2 producer): data/[from-main/]x-board-summary.json has
written_at, interval_seconds, deploys[{id,at,release,merge,live_check}],
checkpoints[{id,at,kind,journey}], daily_due[{date,at}],
walk_attempts[{walk,release,attempt,outcome,claim_expires,reason}], and
walk_results[{walk,release,attempt,assignment,path,report_sha256,complete,steps,
findings}]. Steps have id,result,screenshots; unrelated findings require
routed_to=<task> or stay owned by intake. Times are epoch or ISO UTC.
Only a COMPLETE result matching the walk/release and covering the accepted
list closes a slice. Machinery failures never go to its product builder.

Test seams require FM_TEST_SEAM=1: FM_AUTOLAUNCH_STEPS_{AGENT,CONTROL,SEND,WALK,TEARDOWN}_BIN,
FM_AUTOLAUNCH_STEPS_NOW, FM_AUTOLAUNCH_STEPS_STOP=before|after:<effect-kind>.
The stop seam sends SIGKILL to this engine, leaving the durable receipt.
"""

import datetime as dt
import base64
import csv
from fnmatch import fnmatchcase
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shlex
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
HOME = Path(os.environ.get("FM_HOME", BIN.parent))
DATA = Path(os.environ.get("FM_DATA_OVERRIDE", HOME / "data"))
STATE = Path(os.environ.get("FM_STATE_OVERRIDE", HOME / "state"))
CONFIG = Path(os.environ.get("FM_CONFIG_OVERRIDE", HOME / "config"))
TEST = os.environ.get("FM_TEST_SEAM") == "1"
NOW = int(os.environ.get("FM_AUTOLAUNCH_STEPS_NOW", time.time())) if TEST else int(time.time())
SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")


def read(path):
    try:
        if path.is_symlink():
            raise ValueError(f"symlink refused: {path}")
        return path.read_text()
    except FileNotFoundError:
        return ""


def kv(path):
    return dict(line.split("=", 1) for line in read(path).splitlines() if "=" in line)


def epoch(value):
    if isinstance(value, (float, int)) or str(value).isdigit():
        return int(value)
    try:
        return int(dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def effect_is_note(row, handled=False):
    effect = row["effect"]
    request = hashlib.sha256(effect["id"].encode()).hexdigest()[:32]
    inbox = STATE / f"{effect['target']}.inbox"
    patterns = ("handled/*.msg",) if handled else ("*.msg", "handled/*.msg")
    return any(f"request-id={request}\n" in read(p) for pattern in patterns for p in inbox.glob(pattern))


def leases():
    text = read(CONFIG / "autolaunch-steps").strip()
    if text in ("", "off"):
        return {}
    result = {}
    for line in text.splitlines():
        words = line.split()
        if not words or words[0].startswith("#"):
            continue
        if words == ["observe"]:
            words += [p.parent.name for p in DATA.glob("*/slice-steps.log")]
        if words[0] not in ("act", "observe") or len(words) < 2:
            raise ValueError("invalid autolaunch-steps lease")
        for owner in words[1:]:
            if not SLUG.fullmatch(owner) or owner in (".", "..") or owner in result:
                raise ValueError("invalid or duplicate autolaunch-steps owner")
            result[owner] = words[0]
    return result


def rows(owner):
    text = read(DATA / owner / "slice-steps.log")
    if text and not text.endswith("\n"):
        raise ValueError(f"partial slice step log: {owner}")
    result = [json.loads(line) for line in text.splitlines()]
    for row in result:
        if row.get("owner") != owner or row.get("receipt") not in ("pending", "completed"):
            raise ValueError(f"invalid slice step log: {owner}")
    return result


def append(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f"symlink refused: {path}")
    with path.open("a") as f:
        f.write(text + "\n")
        f.flush()
        os.fsync(f.fileno())


def atomic(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        tmp = Path(f.name)
        json.dump(value, f, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def invoke(args, **kwargs):
    return subprocess.run([str(a) for a in args], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=120, **kwargs)


def tool(name, default):
    return os.environ.get("FM_AUTOLAUNCH_STEPS_" + name + "_BIN", str(default)) if TEST else str(default)


def agent(task):
    seam = tool("AGENT", "")
    args = [seam, task] if seam else [BIN / "fm-autolaunch.sh", "--step-agent", task]
    r = invoke(args)
    answer = r.stdout.strip()
    return answer if r.returncode == 0 and answer in ("alive", "dead", "missing") else "unknown"


def statuses(task, only=None):
    result = []
    for line in read(STATE / f"{task}.status").splitlines():
        if only and not re.match(only + r"(?:\s|:)", line):
            continue
        match = re.search(r"(?:^|\s)(?:working|done|paused|blocked|note)(?:\s+\[[^\]]*\])*:\s*(.*)", line)
        if match:
            stamp = re.search(r"\[at=(\d+)\]", line)
            result.append((int(stamp[1]) if stamp else 0, match[1]))
    return result


def tokens(text):
    return dict(re.findall(r"([\w-]+)=([^\s]+)", text))


def fields(text):
    return dict(re.findall(r"^([A-Z][A-Z ]*):[ \t]*(.*)$", text, re.M))


def latest(records):
    return {r["trigger"]: r for r in records}


def task_body(shown):
    match = re.search(r"^  body: (.*)$", shown, re.M)
    value = match[1] if match else ""
    return json.loads(value) if value.startswith('"') else value


def task_missing(result):
    return result.returncode != 0 and bool(re.search(r"^code: NOT_FOUND$", result.stdout, re.M))


def model_family(meta):
    if meta.get("model_family"):
        return meta["model_family"]
    result = invoke([BIN / "fm-autolaunch.sh", "--step-family", meta.get("harness", ""), meta.get("model", "")])
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else "unknown"


def tester_admitted(owner, tester):
    builder_model = kv(STATE / f"{owner}.meta").get("model", "")
    tester_model = kv(STATE / f"{tester}.meta").get("model", "")
    return bool(builder_model and builder_model != "default" and tester_model and
                tester_model != "default" and tester_model != builder_model)


def destination_leased(effect):
    return effect["kind"] != "route-finding" or leases().get(effect["target"]) == "act"


def effect_tester(effect):
    return effect["target"] if effect["kind"] in ("launch-tester", "relaunch-tester") else effect.get("tester_task")


def tester_scope(worktree, branch):
    if not worktree or not branch:
        raise ValueError("owner branch location is missing")
    return (f"Edit and commit only TESTER PATHS directly on the builder's branch {branch} in {worktree}. "
            f"Before editing, run `git -C {shlex.quote(worktree)} branch --show-current` and require {shlex.quote(branch)}; refuse a different branch. "
            "The builder owns every other path. Read the prep without reading builder code or its diff; never open a PR.")


class Slice:
    def __init__(self, owner, refresh=False, persist=False):
        self.owner = owner
        self.path = DATA / owner / "slice-steps.log"
        self.records = rows(owner)
        self.generation = max([r.get("generation", 1) for r in self.records] or [1])
        self.meta = kv(STATE / f"{owner}.meta")
        self.status = statuses(owner)
        self.prep_path = DATA / owner / "prep.md"
        self.prep = fields(read(self.prep_path))
        self.revision = self.prep.get("REVISION", "")
        self.cut = self.prep.get("CUT", "1")
        shown = invoke([BIN / "fm-tasks-axi.sh", "show", owner, "--full"])
        if shown.returncode and not (task_missing(shown) and any(
                r["step"] == "done" and r.get("generation", 1) == self.generation and not r.get("effect") for r in self.records)):
            raise ValueError(f"owner task unreadable: {owner}")
        self.body = task_body(shown.stdout)
        self.held = bool(re.search(r"^  held: yes$", shown.stdout, re.M))
        self.home_id = read(HOME / ".fm-secondmate-home").strip() or "main"
        self.tester = self.body_field("TESTER TASK") or f"{owner}-tester"
        if ":" in self.tester:
            tester_home, self.tester = self.tester.split(":", 1)
            if tester_home != self.home_id:
                raise ValueError("TESTER TASK belongs to another home; no local fallback permitted")
        if not SLUG.fullmatch(self.tester):
            raise ValueError("invalid TESTER TASK")
        self.project = self.meta.get("project", "")
        self.repo = Path(self.project).name if self.project else ""
        for key, value in re.findall(r"^  (repo|kind): (.+)$", shown.stdout, re.M):
            if key == "repo" and not self.repo:
                self.repo = value.strip('"')
        self.project = self.project or str(HOME / "projects" / self.repo)
        self.mode = self.meta.get("mode") or kv(DATA / owner / "autolaunch-prep").get("mode")
        self.pr = {}
        self.pipeline = {}
        if self.mode == "no-mistakes":
            cache = STATE / f"{owner}.step-nm"
            saved = json.loads(read(cache) or "{}")
            if saved.get("generation") == self.generation:
                self.pipeline = saved.get("facts", {})
            if refresh and (not TEST or os.environ.get("FM_AUTOLAUNCH_STEPS_NM_BIN")):
                result = invoke([tool("NM", BIN / "fm-autolaunch.sh"), "--step-nm", owner])
                self.pipeline = self.pipeline_facts(result.stdout) if result.returncode == 0 else {}
                if self.pipeline and persist:
                    atomic(cache, dict(generation=self.generation, facts=self.pipeline))
        if self.meta.get("pr"):
            cache = STATE / f"{owner}.step-pr"
            saved = json.loads(read(cache) or "{}")
            if saved.get("url") == self.meta["pr"] and saved.get("generation") == self.generation:
                self.pr = saved.get("facts", {})
            if refresh and (not TEST or os.environ.get("FM_AUTOLAUNCH_STEPS_PR_BIN")):
                facts = self.read_pr()
                if facts:
                    self.pr = facts
                    # A dry pass may read facts but never writes its cache.
                    if persist:
                        atomic(cache, dict(url=self.meta["pr"], generation=self.generation, facts=facts))
        self.walk = self.prep.get("WALK ID", "")
        self.walk_list = self.prep.get("WALK LIST", "")
        self.summary = {}
        for path in (DATA / "from-main/x-board-summary.json", DATA / "x-board-summary.json"):
            if path.exists():
                self.summary = json.loads(read(path))
                break

    def read_pr(self):
        """Read exact head/check/merge facts through the installed forge tool.

        The check alarm consumes only this pass's cached result, never network.
        Unsupported forges retain explicit status evidence and mate custody.
        """
        match = re.fullmatch(r"https://github.com/([\w.-]+)/([\w.-]+)/pull/(\d+)", self.meta["pr"])
        if not match:
            return {}
        owner, repo, number = match.groups()
        query = '''query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid isDraft state mergeCommit{oid} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{isRequired(pullRequestNumber:$number) status conclusion} ... on StatusContext{isRequired(pullRequestNumber:$number) state}}}}}}}}}}'''
        # --input preserves typed GraphQL variables. Base64 preserves the JSON
        # value across gh-axi's normal TOON presentation of object results.
        payload = json.dumps(dict(query=query, variables=dict(owner=owner, repo=repo, number=int(number))))
        result = invoke([tool("PR", "gh-axi"), "api", "POST", "/graphql", "--input", "-",
                         "--jq", ".data.repository.pullRequest | @base64"], input=payload)
        if result.returncode:
            return {}
        value = json.loads(base64.b64decode(result.stdout.strip().strip('"'), validate=True))
        if not isinstance(value, dict):
            return {}
        checks = []
        for node in value.get("commits", {}).get("nodes", []):
            checks += (node["commit"].get("statusCheckRollup") or {}).get("contexts", {}).get("nodes", [])
        red = any(check.get("isRequired") is True and (
            check.get("state") in ("FAILURE", "ERROR") or
            check.get("conclusion") in ("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE")
        ) for check in checks)
        return dict(head=value.get("headRefOid"), draft=value.get("isDraft"), started=bool(checks),
                    checks="red" if red else "started", state=value.get("state"),
                    merge=(value.get("mergeCommit") or {}).get("oid"))

    def body_field(self, key):
        match = re.search(r"(?:^|\n)[ \t]*" + re.escape(key) + r":[ \t]*([^\n]*)", self.body)
        return match[1].strip() if match else ""

    @staticmethod
    def pipeline_facts(text):
        def scalar(name):
            match = re.search(r"^\s*" + name + r":\s*(.+)$", text, re.M)
            return match[1].strip('"') if match else ""
        def table(name):
            match = re.search(r"^(\s*)" + name + r"\[\d+\]\{([^}]+)\}:\n((?:[ \t]+[^\n]+\n?)*)", text, re.M)
            if not match:
                return []
            keys = match[2].split(",")
            records = []
            for line in match[3].splitlines():
                if len(line) - len(line.lstrip()) <= len(match[1]):
                    break
                records.append(dict(zip(keys, next(csv.reader([line.strip()])))))
            return records
        review = [row for row in table("steps") if row.get("name", row.get("step")) == "review"]
        if not review:
            return {}
        review_gate = bool(re.search(r"gate:\s*review\b|gate:\n[ \t]+step:\s*review\b", text))
        return dict(run_id=scalar("id"), head=scalar("head"), review=review[-1], findings=table("findings") if review_gate else [])

    def log(self, row):
        record = dict(row, at=NOW, owner=self.owner, generation=self.generation)
        append(self.path, json.dumps(record, sort_keys=True))
        self.records.append(record)
        return record

    def have(self, key):
        return key in latest(self.records)

    def fact(self, step, key, **values):
        return dict(step=step, trigger=key, receipt="completed", **values)

    def action(self, step, key, kind, task=None, note="", **values):
        target = task or self.owner
        meta = kv(STATE / f"{target}.meta")
        effect = dict(kind=kind, target=target, expected_gen=meta.get("spawn_gen", ""),
                      note=note, id=key, **values.pop("payload", {}))
        return dict(step=step, trigger=key, receipt="pending", effect=effect, **values)

    def deliver(self, step, key, note, **values):
        kind = "note-owner" if agent(self.owner) == "alive" else "relaunch-owner"
        return self.action(step, key, kind, note=note, **values)

    def current(self):
        return [r for r in self.records if r.get("generation", 1) == self.generation]

    def done(self, key):
        return latest(self.records).get(key, {}).get("receipt") == "completed"

    def reopening(self, generation):
        for _, text in self.status:
            match = re.search(r"generation ready (\d+) source=(\S+) branch=(\S+)", text)
            if match and int(match[1]) == generation + 1:
                return match
        return None

    def tester_ready(self, revision):
        if not tester_admitted(self.owner, self.tester):
            return ""
        for _, text in reversed(statuses(self.tester, "done")):
            data = tokens(text)
            if "tests-ready " not in text or data.get("revision") != revision:
                continue
            if data.get("walk-list") != self.walk_list or not data.get("checks"):
                continue
            match = re.search(r"tests-ready (?:commit=([0-9a-f]+)|(none))\b", text)
            if match:
                return match[1] or "none"
        return ""

    def tester_delivery(self, commit):
        tester = kv(STATE / f"{self.tester}.meta")
        return dict(tester_task=self.tester, tester_commit=commit,
                    owner_worktree=self.meta.get("worktree", ""), owner_branch=self.meta.get("branch", ""),
                    tester_worktree=tester.get("worktree", ""),
                    tester_paths=self.body_field("TESTER PATHS") or self.prep.get("TESTER PATHS", ""))

    def task_action(self, role, target, key, step, **values):
        file_key = key + ":file"
        if not self.done(file_key):
            return self.action("prep" if role == "tester" else "build", file_key, "file-" + role, target, payload={
                "role": role, "repo": self.repo, "revision": self.revision,
                "prep": read(self.prep_path), "body": self.body,
                "project": self.project, "owner_branch": self.meta.get("branch", ""),
                "owner_worktree": self.meta.get("worktree", ""),
                "tester_rule": self.body_field("TESTER RULE") or self.prep.get("TESTER RULE", ""),
                "tester_paths": self.body_field("TESTER PATHS") or self.prep.get("TESTER PATHS", ""),
                "pr": self.meta.get("pr", ""), **values}, **values)
        if not self.done(key):
            return self.action(step, key, "launch-" + role, target,
                               note=f"Continue as {role} for {self.home_id}:{self.owner}, prep revision {self.revision}.\n{read(self.prep_path)}\n" +
                               (tester_scope(self.meta.get("worktree"), self.meta.get("branch")) if role == "tester" else ""),
                               waiting=True, **values)
        return None

    def next(self):
        if self.held:
            return None
        current = self.current()
        phase = current[-1]["step"] if current else "prep"
        # A completed generation cannot consume the previous runtime's events.
        if current and current[-1]["step"] == "done":
            proof = next(r for r in reversed(current) if r["step"] == "done" and not r.get("effect"))
            m = self.reopening(self.generation)
            if m:
                return self.fact("generation", "generation:" + m[2], next_generation=int(m[1]),
                                 source=m[2], branch=m[3], previous_gen=proof.get("spawn_gen", self.meta.get("spawn_gen", "")),
                                 previous_revision=proof.get("revision", self.revision))
            key = f"teardown:{self.owner}@{self.generation}"
            if not self.done(key):
                return self.action("done", key, "teardown", note=json.dumps(proof, sort_keys=True))
            accepted = f"accept:{self.owner}@{self.generation}"
            if not self.done(accepted):
                return self.action("done", accepted, "accept-owner", note=json.dumps(proof, sort_keys=True),
                                   payload={"teardown_key": key})
            return None
        generation = next((r for r in reversed(current) if r["step"] == "generation"), None)
        if generation and (self.meta.get("branch") != generation["branch"] or
                           not self.meta.get("spawn_gen") or self.meta.get("spawn_gen") == generation["previous_gen"] or
                           not self.revision or self.revision == generation.get("previous_revision")):
            return None
        # Cuts take precedence over stale tests/PR events. A changed list always
        # returns to the named tester and waits for a revision-bound receipt.
        for _, text in reversed(self.status):
            m = re.search(r"cut ready (\S+) (\S+)", text)
            if not m or m[2] != self.revision or (HOME / m[1]).resolve() != self.prep_path.resolve():
                continue
            key = f"cut:{self.owner}@{self.generation}:{m[2]}"
            if self.done(key):
                break
            changes = tokens(text)
            if changes.get("walk_changed") == "yes" or changes.get("risk_changed") == "yes":
                tester_key = key + ":tester"
                if not self.done(tester_key):
                    return self.action("tests", tester_key, "relaunch-tester", self.tester,
                                       note=f"Revise walk list for cut {m[2]}; add assertions only for uncovered risks.\n{read(self.prep_path)}\n" +
                                       tester_scope(self.meta.get("worktree"), self.meta.get("branch")),
                                       revision=m[2], waiting=True)
                commit = self.tester_ready(m[2])
                if not commit:
                    return None
            return self.action("build", key, "cut-delivery", note=f"Continue committed cut {m[2]}.\n{read(self.prep_path)}",
                               payload=self.tester_delivery(commit) if changes.get("walk_changed") == "yes" or changes.get("risk_changed") == "yes" else {},
                               revision=m[2], coverage_only=self.prep.get("COVERAGE ONLY") == "yes" and
                               changes.get("walk_changed") == "yes" and changes.get("risk_changed") == "no")
        for _, text in reversed(self.status) if phase in ("prep", "generation") else []:
            m = re.search(r"prep ready (\S+) (\S+)", text)
            if m and m[2] == self.revision and (HOME / m[1]).resolve() == self.prep_path.resolve():
                key = f"prep:{self.generation}:{m[2]}"
                # The initial generation retains the plan's short prep key.
                if self.generation == 1:
                    key = "prep:" + m[2]
                if not self.meta.get("model") or self.meta["model"] == "default":
                    return None
                action = self.task_action("tester", self.tester, key, "tests", tester=self.tester, revision=m[2])
                if action:
                    return action
                break
        tests = next((r for r in reversed(current) if r["step"] == "tests" and r["receipt"] == "completed"), None)
        if tests and phase == "tests":
            revision = tests.get("revision", self.revision)
            # A cut's tester receipt feeds its cut-delivery action. It must
            # not also create a second ordinary tests-ready continuation.
            cut_key = f"cut:{self.owner}@{self.generation}:{revision}"
            commit = "" if self.done(cut_key) else self.tester_ready(revision)
            key = f"tests-ready:{commit}@{revision}"
            if self.generation > 1:
                key += f":g{self.generation}"
            if commit and not self.have(key):
                return self.deliver("build", key, f"Continue slice with tests-ready {commit}; revision={revision} walk-list={self.walk_list}.",
                                    payload=self.tester_delivery(commit), revision=revision)
        # Review/check findings are keyed to their round, not the successive heads.
        round_id = f"{self.owner}@{self.generation}:{self.cut}"
        reviewer = f"{self.owner}-review-{self.generation}-{self.cut}"
        review_active = phase in ("build", "review", "queue", "fix")
        if self.mode == "no-mistakes" and self.pipeline and review_active:
            key = "round:" + round_id
            if not self.have(key):
                return self.fact("review", key, round=round_id, reviewed_head=self.pipeline["head"],
                                 pipeline_run=self.pipeline["run_id"], waiting=True)
            for finding in self.pipeline.get("findings", []):
                finding_key = f"review:{round_id}:{finding['id']}"
                if not self.have(finding_key):
                    return self.deliver("fix", finding_key,
                                        "Continue the no-mistakes gate; the pipeline owns every fix.\n" + json.dumps(finding, sort_keys=True),
                                        round=round_id, pipeline_run=self.pipeline["run_id"])
        pr_events = [(at, text, tokens(text)) for at, text in self.status if "pr-ready " in text]
        head = pr_events[-1][2].get("head", "") if pr_events else self.meta.get("pr_head", "")
        if self.pr.get("head"):
            head = self.pr["head"]
        if self.pr.get("started") and self.pr.get("draft") is False:
            pr_events.append((NOW, "", dict(head=head, checks=self.pr["checks"])))
        if self.meta.get("pr") and pr_events and review_active and self.pr.get("state") not in ("MERGED", "CLOSED"):
            check = pr_events[-1][2].get("checks")
            if check == "red":
                key = "checks-red:" + head
                if not self.have(key):
                    return self.deliver("fix", key, f"Repair failing required checks on {self.meta['pr']} head={head}.")
            if check in ("started", "green", "red"):
                key = "round:" + round_id
                if self.mode == "direct-PR":
                    action = self.task_action("review", reviewer, key, "review", round=round_id, reviewed_head=head)
                    if action:
                        return action
                elif self.mode == "no-mistakes":
                    evidence = [text for _, text in self.status if "pipeline-review " in text and tokens(text).get("round") == round_id]
                    if evidence and not self.have(key):
                        return self.fact("review", key, round=round_id, reviewed_head=tokens(evidence[-1]).get("head"), waiting=True)
        reviews = (statuses(reviewer, "done") if self.mode == "direct-PR" else self.status) if review_active else []
        for _, text in reviews:
            data = tokens(text)
            if not data.get("reviewed_head", data.get("head")) or data.get("finding", "none") in ("none", "-", "[]"):
                continue
            key = f"review:{round_id}:{data['finding']}"
            if not self.have(key):
                return self.deliver("fix", key, f"Review finding in round {round_id}: {text}", round=round_id)
        # A recheck of a fix is the same review task, in the same round.
        prior_review = [tokens(text) for _, text in reviews if "review-ready " in text]
        if self.mode == "direct-PR" and prior_review and prior_review[-1].get("reviewed_head") == head and prior_review[-1].get("review") and prior_review[-1].get("finding", "none") in ("none", "-", "[]"):
            key = f"review-green:{round_id}:{head}"
            if not self.have(key):
                return self.fact("queue", key, round=round_id, reviewed_head=head, waiting=True)
        if self.mode == "direct-PR" and prior_review and head and head != prior_review[-1].get("reviewed_head"):
            key = f"recheck:{round_id}:{head}"
            if not self.have(key):
                return self.action("review", key, "recheck-review", reviewer,
                                   note=f"Recheck fix head={head} on {self.meta.get('pr')} inside round {round_id}; no new round.",
                                   round=round_id, reviewed_head=head, waiting=True)
        merge_marker = STATE / f"{self.owner}.pr-poll-merge-notified"
        if merge_marker.exists() and self.pr.get("state") == "MERGED" and self.pr.get("merge"):
            key = "merge:" + self.pr["merge"]
            if not self.have(key):
                return self.fact("merged", key, merge=self.pr["merge"], waiting=True)
        if merge_marker.exists():
            for _, text in reversed(self.status):
                m = re.search(r"merged commit=([0-9a-f]+)", text)
                if m:
                    if not self.have("merge:" + m[1]):
                        return self.fact("merged", "merge:" + m[1], merge=m[1], waiting=True)
                    break
        merged = next((r for r in reversed(current) if r["step"] == "merged"), None)
        if merged:
            for event in self.summary.get("deploys", []):
                key = "deploy:" + str(event["id"])
                if self.have(key) or event.get("live_check") != "passed":
                    continue
                if self.contains(event.get("release", ""), merged["merge"]):
                    return self.fact("deployed", key, release=event["release"], deployed_at=epoch(event["at"]), waiting=True)
        deployed = next((r for r in reversed(current) if r["step"] == "deployed"), None)
        obligations = [r for r in current if r.get("obligation") and r["receipt"] == "completed"]
        for obligation in obligations:
            action = self.walk_outcome(obligation)
            if action:
                return action
        if deployed and self.walk:
            walked = [r for r in obligations if r["release"] == deployed["release"] and self.walk_matches(r)]
            if walked:
                return None
            checkpoints = list(self.summary.get("checkpoints", []))
            # P2 derives daily_due from the workflow cron, rather than this
            # consumer hard-coding a schedule in a second location.
            checkpoints += [dict(id="catchup:" + e["date"], at=e["at"], kind="catchup") for e in self.summary.get("daily_due", []) if epoch(e["at"]) <= NOW]
            failures = [r for r in current if r["step"] == "fix" and r["trigger"].startswith("walk:")]
            if failures:
                checkpoints.append(dict(id="fix:" + failures[-1]["trigger"], at=deployed["deployed_at"], kind="fix"))
            for event in checkpoints:
                if epoch(event["at"]) < deployed["deployed_at"] or epoch(event["at"]) > NOW:
                    continue
                if event.get("journey") and event["journey"] != self.prep.get("JOURNEY"):
                    continue
                key = f"checkpoint:{event['id']}:g{self.generation}:{self.revision}:{deployed['release']}"
                if not self.have(key):
                    return self.walk_action(key, deployed["release"], self.next_attempt(self.walk, deployed["release"]))
        return None

    def contains(self, release, commit):
        return bool(re.fullmatch(r"[0-9a-f]{7,64}", release) and re.fullmatch(r"[0-9a-f]{7,64}", commit) and
                    invoke(["git", "-C", self.project, "merge-base", "--is-ancestor", commit, release]).returncode == 0)

    def next_attempt(self, walk, release):
        return 1 + max([r.get("attempt", 0) for r in self.records if r.get("obligation") and
                        r.get("walk") == walk and r.get("release") == release] or [0])

    def walk_matches(self, obligation):
        return (obligation.get("generation") == self.generation and obligation.get("revision") == self.revision and
                obligation.get("walk") == self.walk and
                set(filter(None, obligation.get("walk_list", "").split(","))) == set(filter(None, self.walk_list.split(","))))

    def walk_action(self, key, release, attempt, previous=None):
        if previous:
            payload = {k: v for k, v in previous["effect"].items() if k not in ("id", "kind", "target", "expected_gen", "note", "corr")}
            payload["attempt"] = attempt
        else:
            if not SLUG.fullmatch(self.walk):
                raise ValueError("invalid WALK ID")
            brief = self.prep.get("WALK BRIEF", "")
            path = HOME / brief
            if not brief or not path.is_file() or not path.resolve().is_relative_to(DATA.resolve()):
                raise ValueError("missing or unconfined WALK BRIEF")
            payload = {
                "walk": self.walk, "release": release, "attempt": attempt,
                "bot": self.prep.get("WALK BOT", os.environ.get("FM_WALK_REQUEST_BOT", "")),
                "walk_project": self.prep.get("WALK PROJECT", os.environ.get("FM_WALK_REQUEST_PROJECT", "")),
                "walk_target": self.prep.get("WALK TARGET", os.environ.get("FM_WALK_REQUEST_TARGET", "")),
                "brief": str(path), "brief_text": read(path)}
        revision = previous.get("revision", "") if previous else self.revision
        walk_list = previous.get("walk_list", "") if previous else self.walk_list
        identity = [self.home_id, self.owner, self.generation, key, payload["walk"], release, attempt, revision, walk_list]
        payload["corr"] = hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:16]
        return self.action("walk", key, "walk-request", payload=payload,
                           release=release, walk=payload["walk"], attempt=attempt, obligation=True, waiting=True,
                           revision=revision, walk_list=walk_list, retry_of=previous["trigger"] if previous else "")

    def walk_can_close(self, obligation, outcome):
        current = self.current()
        merge = next((r for r in reversed(current) if r["step"] == "merged"), None)
        work = [r for r in current if r["step"] in ("build", "fix", "tests") and
                r.get("effect", {}).get("target", self.owner) == self.owner and not r.get("coverage_only")]
        return bool(self.walk_matches(obligation) and outcome.get("generation") == self.generation and outcome.get("last_walk") and
                    outcome.get("revision") == obligation.get("revision") and
                    outcome.get("walk_list") == obligation.get("walk_list") and
                    self.walk_list and merge and
                    (not work or current.index(work[-1]) < current.index(merge)) and
                    self.contains(obligation["release"], merge["merge"]))

    def walk_outcome(self, obligation):
        walk, release, attempt = obligation["walk"], obligation["release"], obligation["attempt"]
        logical = f"{walk}@{release}"
        key = f"walk-outcome:{logical}.a{attempt}"
        done_key = f"walk-green:{logical}:g{self.generation}:{self.revision}"
        if self.have(key):
            outcome = latest(self.records)[key]
            if outcome.get("outcome") == "usable-green" and not self.have(done_key) and self.walk_can_close(obligation, outcome):
                return self.fact("done", done_key, release=release,
                                 report_sha256=outcome["report_sha256"], last_walk=outcome["last_walk"],
                                 revision=self.revision, spawn_gen=self.meta.get("spawn_gen", ""))
            return None
        if NOW - epoch(self.summary.get("written_at", 0)) > int(self.summary.get("interval_seconds", 600)):
            stale = f"carrier-stale:{logical}.a{attempt}"
            if not self.have(stale):
                return self.fact("walk", stale, reason="carrier-stale", waiting=True)
            return None
        for result in self.summary.get("walk_results", []):
            if not self.belongs(result):
                continue
            if result.get("walk") != walk or result.get("release") != release or result.get("attempt", 1) != attempt:
                continue
            steps = result.get("steps", [])
            expected = set(filter(None, obligation.get("walk_list", self.walk_list).split(",")))
            usable = result.get("complete") is True and result.get("report_sha256") and isinstance(result.get("path"), str) and result["path"].strip() and result.get("assignment") in (logical, f"{logical}.a{attempt}") and expected <= {s["id"] for s in steps}
            failed = [s for s in steps if s.get("result") in ("failed", "not-built", "red")]
            usable = usable and all(s.get("screenshots") for s in failed) and all(
                s.get("result") in ("green", "failed", "not-built", "red") for s in steps)
            if not usable:
                return self.retry_walk(key, logical, release, "unusable", obligation)
            for step in failed:
                finding = f"walk:{logical}:{step['id']}"
                if not self.have(finding):
                    return self.deliver("fix", finding, f"Walk failed on release {release}: {json.dumps(step, sort_keys=True)}",
                                        routed_to=f"{self.home_id}:{self.owner}", report_sha256=result["report_sha256"])
            for finding in result.get("findings", []):
                target = finding.get("routed_to")
                fkey = f"walk:{logical}:other:{finding['id']}"
                if not self.have(fkey):
                    if not target or not SLUG.fullmatch(target):
                        return self.fact("walk", fkey, intake="unmatched", finding=finding, waiting=True)
                    return self.action("fix", fkey, "route-finding", target, note=json.dumps(finding, sort_keys=True), routed_to=f"{self.home_id}:{target}")
            if not failed and expected and all(s.get("result") == "green" for s in steps if s["id"] in expected):
                return self.fact("walk", key, outcome="usable-green", proof=done_key,
                                 revision=obligation.get("revision"), walk_list=obligation.get("walk_list"),
                                 report_sha256=result["report_sha256"], last_walk=result["path"], release=release)
            return self.fact("walk", key, outcome="usable-failed", waiting=True,
                             report_sha256=result["report_sha256"], last_walk=result["path"], release=release)
        for event in self.summary.get("walk_attempts", []):
            if not self.belongs(event):
                continue
            if event.get("walk") != walk or event.get("release") != release or event.get("attempt", 1) != attempt:
                continue
            outcome = event.get("outcome")
            if outcome in ("gap", "unusable") or (outcome in ("running", "transport-uncertain") and epoch(event.get("claim_expires", NOW + 1)) < NOW):
                return self.retry_walk(key, logical, release, outcome, obligation)
            if outcome == "refused":
                refusal = f"refused:{logical}.a{attempt}"
                if not self.have(refusal):
                    return self.fact("walk", refusal, outcome=outcome, reason=event.get("reason"), waiting=True)
        return None

    def belongs(self, event):
        return event.get("walk_owner") == self.home_id

    def retry_walk(self, key, logical, release, outcome, obligation):
        if not obligation.get("retry_of"):
            retry = key + ":retry"
            if not self.have(retry):
                return self.walk_action(retry, release, self.next_attempt(obligation["walk"], release), obligation)
        return self.fact("walk", key, outcome=outcome, failure="walk-machinery:" + logical if obligation.get("retry_of") else "",
                         routed_to="fleet-ops:main-walk-auto-filing", waiting=True)

    def pending_walk_outcome(self, row):
        if NOW - epoch(self.summary.get("written_at", 0)) > int(self.summary.get("interval_seconds", 600)):
            return "carrier-stale"
        def matches(event):
            return (self.belongs(event) and event.get("walk") == row["walk"] and
                    event.get("release") == row["release"] and event.get("attempt", 1) == row["attempt"])
        logical = f"{row['walk']}@{row['release']}"
        if any(matches(result) and result.get("assignment") in (logical, f"{logical}.a{row['attempt']}")
               for result in self.summary.get("walk_results", [])):
            return "filed"
        for event in self.summary.get("walk_attempts", []):
            if not matches(event):
                continue
            outcome = event.get("outcome")
            if outcome in ("gap", "unusable"):
                return outcome
            if outcome in ("running", "transport-uncertain"):
                return "expired" if epoch(event.get("claim_expires", NOW + 1)) < NOW else "running"
        return ""

    @staticmethod
    def tests_on_branch(effect):
        commit = effect.get("tester_commit", "none")
        if commit == "none":
            return True
        worktree, branch = effect.get("owner_worktree", ""), effect.get("owner_branch", "")
        if not worktree or not branch or not re.fullmatch(r"[0-9a-f]{7,64}", commit):
            return False
        current = invoke(["git", "-C", worktree, "branch", "--show-current"])
        return (current.returncode == 0 and current.stdout.strip() == branch and
                invoke(["git", "-C", worktree, "merge-base", "--is-ancestor", commit, "HEAD"]).returncode == 0)

    def integrate_tests(self, effect):
        if self.tests_on_branch(effect):
            return True, ""
        worktree, branch, commit = effect.get("owner_worktree", ""), effect.get("owner_branch", ""), effect.get("tester_commit", "")
        if not worktree or not branch or not re.fullmatch(r"[0-9a-f]{7,64}", commit):
            return False, "tester-commit-location-missing"
        current = invoke(["git", "-C", worktree, "branch", "--show-current"])
        clean = invoke(["git", "-C", worktree, "status", "--porcelain"])
        if current.returncode or current.stdout.strip() != branch or clean.returncode or clean.stdout:
            return False, "tester-integration-branch-not-ready"
        available = invoke(["git", "-C", worktree, "cat-file", "-e", commit + "^{commit}"])
        if available.returncode:
            tester_worktree = effect.get("tester_worktree", "")
            if not tester_worktree:
                return False, "tester-commit-unavailable"
            fetched = invoke(["git", "-C", worktree, "fetch", "--no-tags", tester_worktree, commit])
            if fetched.returncode:
                return False, "tester-commit-unavailable"
        paths = shlex.split(effect.get("tester_paths", "").replace(",", " "))
        changed = invoke(["git", "-C", worktree, "diff", "--no-renames", "--name-only", "-z", "HEAD", commit])
        if changed.returncode or not paths or any(p.startswith("/") or ".." in Path(p).parts for p in paths):
            return False, "tester-paths-unavailable"
        if any(not any(fnmatchcase(path, scope) or scope.endswith("/") and path.startswith(scope) for scope in paths)
               for path in changed.stdout.split("\0") if path):
            return False, "tester-scope-violation"
        merged = invoke(["git", "-C", worktree, "merge", "--ff-only", commit])
        return merged.returncode == 0 and self.tests_on_branch(effect), merged.stderr.strip() or "tester-integration-refused"

    def effect_present(self, row):
        effect = row["effect"]
        kind, target = effect["kind"], effect["target"]
        if effect.get("tester_commit") and not self.tests_on_branch(effect):
            return False
        if kind.startswith("file-"):
            shown = invoke([BIN / "fm-tasks-axi.sh", "show", target, "--full"])
            if shown.returncode:
                return False
            if kind == "file-tester":
                owner = invoke([BIN / "fm-tasks-axi.sh", "show", self.owner, "--full"])
                match = re.search(r"^[ \t]*TESTER TASK:[ \t]*([^\n]+)", task_body(owner.stdout), re.M)
                return bool(owner.returncode == 0 and match and match[1].strip() in (target, f"{self.home_id}:{target}"))
            return True
        if kind == "teardown":
            return teardown_recorded(target, effect["id"]) and not (STATE / f"{target}.meta").exists()
        if kind == "accept-owner":
            shown = invoke([BIN / "fm-tasks-axi.sh", "show", target, "--full"])
            return bool((shown.returncode == 0 and re.search(r"^  state: done$", shown.stdout, re.M) or task_missing(shown)) and
                        self.done(effect["teardown_key"]) and not (STATE / f"{target}.meta").exists())
        if kind == "walk-request":
            once = f"{effect['walk']}@{effect['release']}.a{effect['attempt']}"
            return any((base / once / "sent").exists() for base in (STATE / "grok-bot-once", DATA / "grok-dispatch/once")) or any(
                e.get("walk") == effect["walk"] and e.get("release") == effect["release"] and
                e.get("attempt") == effect["attempt"] and e.get("outcome") == "sent"
                for e in self.summary.get("walk_attempts", []) if self.belongs(e))
        if effect_is_note(row, handled=True):
            return True
        meta = kv(STATE / f"{target}.meta")
        launched = f"launched|relaunched {target} {effect['id']}"
        if any(line.endswith("\t" + launched) for line in read(STATE / "autolaunch.log").splitlines()):
            return True
        changed = bool(meta.get("spawn_gen") and meta["spawn_gen"] != effect.get("expected_gen"))
        if changed:
            journal = kv(STATE / f"{target}.control-relaunch")
            prior = kv(STATE / f"{target}.control-relaunch.meta-prior")
            if journal.get("task") == target and journal.get("phase") == "complete" and prior.get("spawn_gen") == effect.get("expected_gen"):
                return True
            if kind.startswith("launch-") and not effect.get("expected_gen"):
                shown = invoke([BIN / "fm-tasks-axi.sh", "show", target, "--full"])
                if shown.returncode == 0 and re.search(r"^  state: in_flight$", shown.stdout, re.M):
                    return True
        return agent(target) == "alive" and (changed or effect_is_note(row))

    def apply(self, row):
        effect = row["effect"]
        kind, target = effect["kind"], effect["target"]
        if kind == "accept-owner":
            accepted = invoke([BIN / "fm-autolaunch.sh", "--step-accept", target, f"{self.owner}:{effect['id']}"])
            return accepted.returncode == 0, accepted.stderr.strip() or "acceptance-refused"
        if kind == "teardown":
            meta = kv(STATE / f"{target}.meta")
            if meta and meta.get("spawn_gen") != effect["expected_gen"]:
                return False, "teardown-incarnation-changed"
            shown = invoke([BIN / "fm-tasks-axi.sh", "show", target, "--full"])
            if shown.returncode and not task_missing(shown):
                return False, "teardown-task-unreadable"
            if re.search(r"^  state: queued$", shown.stdout, re.M):
                return False, "teardown-task-reopened"
            if re.search(r"^  held: yes$", shown.stdout, re.M):
                return False, "teardown-task-held"
            if not meta:
                return False, "cleanup-record-missing"
            result = invoke([tool("TEARDOWN", BIN / "fm-teardown.sh"), target, "--step-action", f"{self.owner}:{effect['id']}"])
            return result.returncode == 0, result.stderr.strip() or "teardown-refused"
        if kind.startswith("file-"):
            task_dir = DATA / target
            task_dir.mkdir(parents=True, exist_ok=True)
            # A child always reads the durable prep. The tester receives no
            # builder diff; its own test paths are the only writing scope.
            role = effect["role"]
            brief = (f"# Task\n{role.title()} for owner {self.owner}.\n"
                     f"Prep revision: {effect['revision']}\n{effect['prep']}\n"
                     f"Owner branch: {effect['owner_branch']}\nTESTER TASK: {self.tester}\n"
                     f"TESTER RULE: {effect['tester_rule']}\nTESTER PATHS: {effect['tester_paths']}\n")
            if role == "tester":
                if not effect.get("owner_worktree") or not effect["owner_branch"]:
                    return False, "owner-branch-location-missing"
                brief += (tester_scope(effect["owner_worktree"], effect["owner_branch"]) +
                          " Reuse existing checks; add red cases only for uncovered risks. Write the walk list there. "
                          "Report tests-ready commit=<sha>|none revision=<revision> walk-list=<ids> checks=<names>.\n")
            else:
                brief += f"Review {effect['pr']} head={effect.get('reviewed_head')} round={effect.get('round')}. Check TESTER PATHS against TESTER RULE. Post findings to the PR and report review-ready reviewed_head=<sha> finding=<id> review=<url>. Recheck fix heads inside this round; never create another round.\n"
            brief += ("\nReport completion to the task status record with the command below, replacing the payload with the result phrase above.\n"
                      f"FM_HOME={shlex.quote(str(HOME))} FM_CONFIG_OVERRIDE={shlex.quote(str(CONFIG))} "
                      f"bash {shlex.join([str(BIN / 'fm-status-append.sh'), str(STATE / (target + '.status')), 'done'])} <<'EOF'\n"
                      "<result phrase>\nEOF\n")
            for name, content in (("brief.md", brief), ("prep.md", effect["prep"]),
                                  ("autolaunch-prep", f"project={effect['repo']}\nkind=scout\n")):
                path = task_dir / name
                if not path.exists():
                    path.write_text(content)
            body = task_dir / "step-body.md"
            slice_line = self.body_field("SLICE")
            if "role=owner" not in slice_line:
                return False, "owner SLICE role is missing"
            child_slice = slice_line.replace("role=owner", f"role={role} owner={self.home_id}:{self.owner}")
            body.write_text(f"SLICE: {child_slice}\nPrep: data/{target}/prep.md\nStep action: {effect['id']}\n")
            r = invoke([BIN / "fm-tasks-axi.sh", "show", target, "--full"])
            if r.returncode:
                r = invoke([BIN / "fm-tasks-axi.sh", "add", target, f"{role} for {self.owner}",
                            "--kind", "scout", "--repo", effect["repo"], "--body-file", body])
            if r.returncode or role != "tester":
                return r.returncode == 0, r.stderr.strip()
            owner = invoke([BIN / "fm-tasks-axi.sh", "show", self.owner, "--full"])
            if owner.returncode:
                return False, "owner-body-unreadable"
            owner_body = task_body(owner.stdout)
            match = re.search(r"^[ \t]*TESTER TASK:[ \t]*([^\n]*)", owner_body, re.M)
            if match and match[1].strip():
                return match[1].strip() in (target, f"{self.home_id}:{target}"), "tester-reference-conflict"
            updated = f"TESTER TASK: {self.home_id}:{target}"
            owner_body = owner_body[:match.start()] + updated + owner_body[match.end():] if match else owner_body.rstrip() + "\n" + updated + "\n"
            owner_file = DATA / self.owner / "step-owner-body.md"
            owner_file.write_text(owner_body)
            r = invoke([BIN / "fm-tasks-axi.sh", "update", self.owner, "--body-file", owner_file, "--archive-body"])
            return r.returncode == 0, r.stderr.strip()
        if kind.startswith("launch-") or kind == "relaunch-tester":
            existing = kv(STATE / f"{target}.meta")
            if not existing and kind.startswith("launch-"):
                builder = kv(STATE / f"{self.owner}.meta")
                exclude = builder.get("model", "") if kind == "launch-tester" else ""
                if kind == "launch-tester" and exclude in ("", "default"):
                    return False, "builder-model-unknown"
                r = invoke([BIN / "fm-autolaunch.sh", "--step-dispatch", target,
                            exclude, model_family(builder) if kind == "launch-tester" else ""])
                return r.returncode == 0, "relaunch-due" if r.returncode == 75 else r.stderr.strip()
            if kind in ("launch-tester", "relaunch-tester") and not tester_admitted(self.owner, target):
                return False, "same-or-unknown-tester-model"
            # The named child already has an incarnation. Continue that task
            # through control/inbox below rather than allocating a fresh copy.
        if kind == "walk-request":
            brief = DATA / self.owner / ("walk-" + effect["corr"] + ".md")
            brief.write_text(effect["brief_text"])
            if (HOME / ".fm-secondmate-home").exists():
                # The approved carrier confines briefs under data/walk-briefs.
                brief = DATA / "walk-briefs" / brief.name
                brief.parent.mkdir(parents=True, exist_ok=True)
                brief.write_text(effect["brief_text"])
                command = [BIN / "fm-walk-request.sh", "--brief", brief, "--walks", effect["walk"],
                           "--release", effect["release"], "--attempt", effect["attempt"]]
                if effect["bot"]:
                    command += ["--bot", effect["bot"]]
                r = invoke(command,
                           env=dict(os.environ, FM_WALK_REQUEST_CORR=effect["corr"]))
                # Request accepted is not sent. The obligation is completed
                # only from the copied once-key outcome, on a later pass.
                return False, "walk-expect" if r.returncode == 0 else r.stderr.strip()
            if not all(effect.get(name) for name in ("bot", "walk_project", "walk_target")):
                return False, "walk-routing-missing"
            command = [tool("WALK", DATA / "bin/fm-grok-bot-dispatch.sh"), brief,
                        "--bot", effect["bot"], "--project", effect["walk_project"], "--target", effect["walk_target"],
                        "--walk", effect["walk"], "--walk-owner", "main", "--once-key",
                        f"{effect['walk']}@{effect['release']}.a{effect['attempt']}"]
            if TEST and os.environ.get("FM_AUTOLAUNCH_STEPS_WALK_BIN"):
                r = invoke(command)
                return r.returncode in (0, 3), r.stderr.strip()
            # Walks outlive the small timer pass. The dispatcher owns the once
            # key, so a restart before its sent record can repeat this safely.
            with (DATA / self.owner / f"walk-{effect['corr']}.log").open("a") as output:
                subprocess.Popen([str(a) for a in command], stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=output, start_new_session=True)
            return False, "walk-expect"
        if effect.get("tester_commit"):
            integrated, reason = self.integrate_tests(effect)
            if not integrated:
                return False, reason
        if not destination_leased(effect):
            return False, "destination-not-leased"
        state = agent(target)
        if state == "unknown":
            return False, "agent-state-unknown"
        if state == "alive":
            env = dict(os.environ, FM_SEND_REQUEST_ID=hashlib.sha256(effect["id"].encode()).hexdigest()[:32])
            r = invoke([tool("SEND", BIN / "fm-send.sh"), target, "--one-way", effect["note"]], env=env)
            return r.returncode == 0, r.stderr.strip()
        capacity = os.environ.get("FM_AUTOLAUNCH_CAPACITY_BIN") if TEST else None
        r = invoke([capacity or BIN / "fm-capacity.sh", "--admit"])
        m = re.search(r"free_lanes=(\d+)", r.stdout)
        if r.returncode or not m or int(m[1]) == 0:
            return False, "relaunch-due"
        note = DATA / self.owner / ("note-" + hashlib.sha256(effect["id"].encode()).hexdigest()[:16] + ".md")
        note.write_text(effect["note"])
        r = invoke([tool("CONTROL", BIN / "fm-control.sh"), target, "relaunch", "--if-recoverable",
                    "--step-action", f"{self.owner}:{effect['id']}", "--note-file", note])
        return r.returncode == 0, "relaunch-due" if r.returncode == 75 else r.stderr.strip() or "relaunch-refused"

    def perform(self, row):
        if leases().get(self.owner) != "act":
            return False
        effect = row["effect"]
        kind = effect["kind"]
        tester = effect_tester(effect)
        if tester:
            fresh = kind == "launch-tester" and not kv(STATE / f"{tester}.meta")
            builder = kv(STATE / f"{self.owner}.meta").get("model", "")
            if not builder or builder == "default" or not (fresh or tester_admitted(self.owner, tester)):
                if row.get("reason") != "same-or-unknown-tester-model":
                    self.log(dict(row, receipt="pending", reason="same-or-unknown-tester-model"))
                return False
        if kind in ("teardown", "accept-owner"):
            reopened = self.reopening(row.get("generation", self.generation))
            if reopened:
                self.log(dict(row, receipt="completed", reason="", superseded_by=reopened[2]))
                return True
        present = self.effect_present(row)
        if kind == "walk-request" and not present:
            transport = self.pending_walk_outcome(row)
            if transport in ("gap", "unusable", "expired", "filed"):
                self.log(dict(row, receipt="completed", reason="", transport_outcome=transport))
                return True
            if transport in ("carrier-stale", "running"):
                reason = "carrier-stale" if transport == "carrier-stale" else "walk-expect"
                stale = f"carrier-stale:{row['walk']}@{row['release']}.a{row['attempt']}"
                if transport == "carrier-stale" and not self.have(stale):
                    self.log(self.fact("walk", stale, reason=reason, waiting=True))
                if row.get("reason") != reason:
                    self.log(dict(row, receipt="pending", reason=reason))
                return False
        if present:
            # Validate tester metadata even when an interrupted launch already
            # produced a real agent; a same-model run never advances to build.
            success, reason = True, ""
        else:
            if not destination_leased(effect):
                if row.get("reason") != "destination-not-leased":
                    self.log(dict(row, receipt="pending", reason="destination-not-leased"))
                return False
            self.stop("before", row)
            success, reason = self.apply(row)
            self.stop("after", row)
            if success and not effect_is_note(row) and row["effect"]["kind"] not in ("walk-request", "teardown", "accept-owner") and not row["effect"]["kind"].startswith("file-"):
                effect = row["effect"]
                append(STATE / "autolaunch.log", f"{NOW}\t-\t{effect['target']}\t-\tlaunched|relaunched {effect['target']} {effect['id']}")
            success = success and self.effect_present(row)
        effect = row["effect"]
        extra = {}
        if success and tester:
            tester_task = effect_tester(effect)
            tester = kv(STATE / f"{tester_task}.meta")
            builder = kv(STATE / f"{self.owner}.meta")
            if not tester_admitted(self.owner, tester_task):
                success, reason = False, "same-or-unknown-tester-model"
            else:
                extra = dict(builder_model=builder.get("model"), tester_model=tester.get("model"),
                             builder_family=model_family(builder), tester_family=model_family(tester))
        if success:
            self.log(dict(row, receipt="completed", reason="", **extra))
        elif reason != row.get("reason"):
            self.log(dict(row, receipt="pending", reason=reason))
        return success

    @staticmethod
    def stop(boundary, row):
        if TEST and os.environ.get("FM_AUTOLAUNCH_STEPS_STOP") == f"{boundary}:{row['effect']['kind']}":
            os.kill(os.getpid(), signal.SIGKILL)

    def run(self, dry=False):
        if self.held:
            return
        pending = [r for r in latest(self.records).values() if r["receipt"] == "pending"]
        for row in pending:
            if dry:
                print(f"would-step: {self.owner} reconcile {row['trigger']}")
            elif not self.perform(row):
                return
        for _ in range(40):
            row = self.next()
            if not row:
                return
            if dry:
                print(f"would-step: {self.owner} {row['trigger']}")
                return
            if row.get("next_generation"):
                self.generation = row.pop("next_generation")
            self.log(row)
            if row["receipt"] == "pending" and not self.perform(row):
                return
        raise ValueError(f"too many transitions for {self.owner}")


def guard(task, action):
    owner, sep, key = action.partition(":")
    if not sep or leases().get(owner) != "act":
        return False
    records = rows(owner)
    row = latest(records).get(key, {})
    effect = row.get("effect", {})
    if effect.get("kind") == "route-finding" and not destination_leased(effect):
        return False
    tester = effect_tester(effect) if effect else None
    if tester and not tester_admitted(owner, tester):
        return False
    if effect.get("tester_commit") and not Slice.tests_on_branch(effect):
        return False
    meta = kv(STATE / f"{task}.meta")
    marker = kv(STATE / f"{task}.released")
    if marker and (marker.get("spawn_gen") != effect.get("expected_gen") or
                   marker.get("result") != "released" or
                   marker.get("class") not in (("owner-waiting",) if task == owner else ("owner-waiting", "scout"))):
        return False
    return bool(row.get("receipt") == "pending" and effect.get("target") == task and
                effect.get("id") == key and effect.get("kind") in (
                    "note-owner", "relaunch-owner", "cut-delivery", "relaunch-tester", "recheck-review", "route-finding", "launch-tester", "launch-review") and
                meta.get("spawn_gen") and meta["spawn_gen"] == effect.get("expected_gen") and
                meta.get("kind") in ("ship", "scout") and meta.get("endpoint_task_id", task) == task)


def teardown_recorded(task, key):
    return any(line.endswith(f"\tcleanup-ready {task} {key}") for line in read(STATE / "autolaunch.log").splitlines())


def teardown_receipt(task, action):
    owner, sep, key = action.partition(":")
    if not sep or owner != task or leases().get(owner) != "act":
        return None
    records = rows(owner)
    row = latest(records).get(key, {})
    effect = row.get("effect", {})
    generation = max([r.get("generation", 1) for r in records] or [1])
    if (row.get("receipt") != "pending" or effect.get("kind") != "teardown" or effect.get("id") != key or
            effect.get("target") != task or row.get("generation", 1) != generation):
        return None
    if not any(r["step"] == "done" and r["receipt"] == "completed" and not r.get("effect") and
               r.get("generation", 1) == generation for r in records):
        return None
    if any(re.search(rf"generation ready {generation + 1} source=\S+ branch=\S+", text) for _, text in statuses(task)):
        return None
    return row


def teardown_guard(task, action):
    row = teardown_receipt(task, action)
    if not row:
        return False
    meta = kv(STATE / f"{task}.meta")
    shown = invoke([BIN / "fm-tasks-axi.sh", "show", task, "--full"])
    return bool(meta.get("spawn_gen") and meta["spawn_gen"] == row["effect"].get("expected_gen") and
                meta.get("kind") == "ship" and shown.returncode == 0 and
                not re.search(r"^  (held: yes|state: queued)$", shown.stdout, re.M))


def record_teardown(task, action):
    row = teardown_receipt(task, action)
    if not row or not teardown_guard(task, action):
        return False
    key = row["effect"]["id"]
    if not teardown_recorded(task, key):
        append(STATE / "autolaunch.log", f"{NOW}\t-\t{task}\t-\tcleanup-ready {task} {key}")
    return True


def accept_owner(task, action):
    owner, sep, key = action.partition(":")
    if not sep or task != owner or leases().get(owner) != "act":
        return False
    slice_ = Slice(owner)
    row = latest(slice_.records).get(key, {})
    effect = row.get("effect", {})
    if (row.get("receipt") != "pending" or effect.get("kind") != "accept-owner" or
            effect.get("target") != task or row.get("generation", 1) != slice_.generation or
            effect.get("id") != key or (STATE / f"{task}.meta").exists() or slice_.held or
            slice_.reopening(slice_.generation)):
        return False
    cleanup = latest(slice_.records).get(effect.get("teardown_key"), {})
    if cleanup.get("receipt") != "completed" or cleanup.get("superseded_by") or not slice_.effect_present(cleanup):
        return False
    shown = invoke([BIN / "fm-tasks-axi.sh", "show", task, "--full"])
    if shown.returncode or re.search(r"^  (held: yes|state: queued)$", shown.stdout, re.M):
        return False
    return invoke([BIN / "fm-tasks-axi.sh", "done", task, "--note", effect["note"]]).returncode == 0


def waiting(owner):
    records = rows(owner)
    row = records[-1] if records else {}
    return bool(row.get("receipt") == "completed" and row.get("waiting") and row.get("step") != "done")


def check():
    stamp = json.loads(read(STATE / "autolaunch-steps.pass") or "{}")
    if not stamp:
        return
    for owner, mode in leases().items():
        if mode != "act" or owner not in stamp.get("owners", []):
            continue
        slice_ = Slice(owner)
        for row in latest(slice_.records).values():
            if row["receipt"] == "pending" and row.get("at", 0) <= stamp["at"]:
                if row.get("reason") != "relaunch-due" and not (row.get("obligation") and row.get("reason") in ("carrier-stale", "walk-expect")):
                    print(f"{owner} pending {row['trigger']}")
                    return
        candidate = slice_.next()
        if candidate and not slice_.have(candidate["trigger"]):
            # A newly fired status event after the last pass is not a stall.
            reviewer = f"{owner}-review-{slice_.generation}-{slice_.cut}"
            evidence = slice_.status + statuses(slice_.tester) + statuses(reviewer)
            if all(at <= stamp["at"] for at, _ in evidence) and epoch(slice_.summary.get("written_at", 0)) <= stamp["at"]:
                print(f"{owner} trigger without receipt {candidate['trigger']}")
                return


def main():
    if len(sys.argv) == 1 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    command = sys.argv[1]
    arities = {"run": 2, "dry": 2, "check": 2, "guard": 4, "teardown-guard": 4, "record-teardown": 4, "accept-owner": 4, "wait": 3}
    if command not in arities or len(sys.argv) != arities[command]:
        raise ValueError("usage: run|dry|check|wait <owner>|guard <task> <action>")
    if command == "guard":
        return 0 if guard(*sys.argv[2:]) else 3
    if command == "teardown-guard":
        return 0 if teardown_guard(*sys.argv[2:]) else 3
    if command == "record-teardown":
        return 0 if record_teardown(*sys.argv[2:]) else 3
    if command == "accept-owner":
        return 0 if accept_owner(*sys.argv[2:]) else 3
    if command == "wait":
        return 0 if waiting(sys.argv[2]) else 3
    if command == "check":
        check()
        return 0
    modes = leases()
    for owner, mode in modes.items():
        Slice(owner, refresh=command in ("run", "dry"), persist=mode == "act" and command == "run").run(command == "dry" or mode == "observe")
    active = [owner for owner, mode in modes.items() if mode == "act"]
    if command == "run" and active:
        atomic(STATE / "autolaunch-steps.pass", dict(at=NOW, owners=active))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"fm-autolaunch-steps: {error}", file=sys.stderr)
        sys.exit(1)
