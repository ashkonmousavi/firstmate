#!/usr/bin/env python3
"""Staged candidate snapshot join, without ranking, claims or actor execution.

Public entry: fm-autolaunch.sh --join | --publish-candidates.
Internal argv: fm-next-in-line.py join | publish-candidates.

The publication is <physical home>/state/autolaunch-steps.candidates, JSON
fm-seat-candidates/v1. Required sources are tasks, prep, slice and catalogue.
Each names status (ok/not_applicable for a completed read), opaque revision and
sha256:<hex> evidence_digest; not_applicable instead supplies its authoritative
reason. Every source consumed by an entry reference or fact must satisfy the
same evidence rule and have an explicit nonempty matching revision/reference.
Required-source evidence failures make the publication unavailable; within an
otherwise complete publication, invalid consumed evidence leaves the entry
UNKNOWN. Unused optional sources do not affect publication completeness.
The envelope names machine, home, publication_id, integer completed_at and
valid_until, boolean complete and entries. Complete-empty requires successful
coverage of every required source. Expiry never proves a writer/claim absent.

An entry names owner{home,task}, slice_id, actor{home,task,kind}, phase, cut,
owner_generation, prep{revision,digest,brief_digest}, source_refs and facts.
A fact has verdict allow/deny/unknown, authority, source_ref and a reason.
Task/dependency facts come from tasks, prep from prep, phase from slice,
placement from catalogue and claim from claims. Other facts retain their named
authority. Source refs must agree with the publication's revisions. Prep and
brief digests are sha256:<hex> of data/<task>/{prep,brief}.md. Opaque source
digests do not establish current external truth; machine identity and live
phase/generation revalidation await their owning contracts.

join/v1 reports COMPLETE (exit 0) or NO_PICK (exit 75), typed machine reasons,
every available/unavailable home, and ELIGIBLE/INELIGIBLE/UNKNOWN entries.
Bounded entry evidence failures retain UNKNOWN; incomplete home membership or
publication coverage and conflicting ownership produce NO_PICK. Unknown takes
precedence over deny. COMPLETE is eligibility information, never admission.
Home discovery follows local parent records and readable child registries;
missing state or an unavailable ancestor does not erase known membership.
Each unavailable home retains its identity in homes and a home-unavailable
machine reason naming home, owner and retry disposition in reasons.
No kick is written or interpreted as evidence of missing claims/writers.

Producer read seam: the existing registered-home/parent parsers and tasks-axi
ready/show preparation predicates, behind fm-autolaunch.sh --candidate-prep.
Ready grammar/count must be complete; identified refused entries are retained.
No catalogue adapter or accepted task/phase/claim mappings are supplied yet:
those sources remain missing, so production completeness is OPEN. Publications
are explicitly incomplete and valid only at completed_at until the producer
freshness contract lands. Publication identity is independent of evidence
hashes, accepted prep revisions and future actor/claim generations.

Reads of commands use the existing preparation reader's 15-second bound; the
producer owners must supply the final budgets. Nonregular publications are
rejected before reading; the parser accepts at most 16 MiB per publication.
Only publication replaces a file, using a same-directory fsynced atomic write.
No existing run path calls this seam automatically. The existing test-only
FM_TEST_SEAM=1 / FM_AUTOLAUNCH_NOW_FILE clock also applies here.
"""

import csv
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

BIN = Path(__file__).resolve().parent
REQUIRED = ("tasks", "prep", "slice", "catalogue")
COMPLETE_READ = ("ok", "not_applicable")
AUTHORITIES = {"task": "tasks", "dependencies": "tasks", "prep": "prep",
               "phase": "slice", "placement": "catalogue", "claim": "claims"}
TASK = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
READ_TIMEOUT = 15
MAX_PUBLICATION = 16 * 1024 * 1024


def now():
    if os.environ.get("FM_TEST_SEAM") == "1" and os.environ.get("FM_AUTOLAUNCH_NOW_FILE"):
        return int(Path(os.environ["FM_AUTOLAUNCH_NOW_FILE"]).read_text().strip())
    return int(time.time())


def sha(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate JSON member: {key}")
            result[key] = value
        return result

    def constant(value):
        raise ValueError(f"nonfinite JSON value: {value}")

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


def regular_bytes(path):
    # O_NONBLOCK also closes the lstat/open race with a substituted FIFO.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError(f"not a regular file: {path}")
        raw = source.read(MAX_PUBLICATION + 1)
    if len(raw) > MAX_PUBLICATION:
        raise ValueError(f"publication/evidence exceeds {MAX_PUBLICATION} bytes")
    return raw


def command(argv, home):
    env = dict(os.environ, FM_HOME=str(home))
    # Publications are qualified by their physical home; inherited overrides
    # from a different calling home cannot redirect an authority read or mkdir.
    for name in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
        env.pop(name, None)
    return subprocess.run([str(a) for a in argv], env=env, capture_output=True,
                          text=True, timeout=READ_TIMEOUT, check=False)


def homes(home):
    script = '''. "$1/fm-secondmate-parent-lib.sh"
. "$1/fm-secondmate-registry-lib.sh"
homes=("$2")
ancestor=$2
depth=0
while [ -e "$ancestor/.fm-secondmate-parent" ] || [ -L "$ancestor/.fm-secondmate-parent" ]; do
  if ! fm_secondmate_parent_record_parse "$ancestor/.fm-secondmate-parent"; then
    printf '%s\\0%s\\0' "$ancestor" 'cannot resolve the root Firstmate home: invalid parent record'
    break
  fi
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || break
  parent=$FM_SECONDMATE_PARENT_HOME
  physical=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || {
    homes+=("$parent")
    break
  }
  known=0
  for existing in "${homes[@]}"; do
    [ "$existing" != "$physical" ] || known=1
  done
  homes+=("$physical")
  depth=$((depth + 1))
  if [ "$known" = 1 ] || [ "$depth" -gt 64 ]; then
    printf '%s\\0%s\\0' "$ancestor" 'cannot resolve the root Firstmate home: parent cycle or depth exceeded'
    break
  fi
  ancestor=$physical
done
seen=()
i=0
while [ "$i" -lt "${#homes[@]}" ]; do
  member=${homes[$i]}
  i=$((i + 1))
  physical=$(CDPATH='' cd -- "$member" 2>/dev/null && pwd -P) || {
    printf '%s\\0%s\\0' "$member" "registered local Firstmate home is unavailable: $member"
    continue
  }
  known=0
  for existing in "${seen[@]}"; do
    [ "$existing" != "$physical" ] || known=1
  done
  [ "$known" = 0 ] || continue
  seen+=("$physical")
  member=$physical
  reason=
  reg="$member/data/secondmates.md"
  if [ ! -r "$member" ] || [ ! -x "$member" ]; then
    reason="local Firstmate registry parent is unreadable at $member"
  elif { [ -e "$member/data" ] || [ -L "$member/data" ]; } &&
       { [ ! -d "$member/data" ] || [ ! -r "$member/data" ] || [ ! -x "$member/data" ]; }; then
    reason="local Firstmate registry parent is unreadable at $member/data"
  elif [ -e "$reg" ] || [ -L "$reg" ]; then
    if [ ! -f "$reg" ] || [ -L "$reg" ] || [ ! -r "$reg" ]; then
      reason="local Firstmate registry is unsafe at $reg"
    else
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "- "*)
            if ! secondmate_registry_parse_line "$line"; then
              reason="malformed local Firstmate registry entry in $reg"
              continue
            fi
            [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
            homes+=("$SECONDMATE_REGISTRY_HOME")
            ;;
        esac
      done < "$reg" || reason="cannot read local Firstmate registry at $reg"
    fi
  fi
  printf '%s\\0%s\\0' "$member" "$reason"
done'''
    result = command(["bash", "-c", script, "_", BIN, home], home)
    fields = result.stdout.split("\0")
    registered = {home: ""}
    if len(fields) < 3 or fields[-1] or len(fields) % 2 != 1:
        registered[home] = "registered home enumeration returned malformed records"
    else:
        for member, reason in zip(fields[:-1:2], fields[1:-1:2]):
            if not member:
                registered[home] = "registered home enumeration returned an empty home"
                continue
            try:
                member = Path(member).resolve(strict=True)
            except (OSError, RuntimeError) as error:
                member = Path(member).absolute()
                reason = reason or str(error)
            registered[member] = registered.get(member) or reason
    if result.returncode:
        registered[home] = registered[home] or result.stderr.strip() or "registered home enumeration failed"
    return dict(sorted(registered.items(), key=lambda item: str(item[0])))


def source_error(source):
    if not isinstance(source, dict) or source.get("status") not in COMPLETE_READ:
        return "is unavailable or incomplete"
    if not isinstance(source.get("revision"), str) or not source["revision"]:
        return "lacks revision"
    if source["status"] == "ok":
        if not isinstance(source.get("evidence_digest"), str) or not DIGEST.fullmatch(source["evidence_digest"]):
            return "lacks evidence digest"
    elif not isinstance(source.get("reason"), str) or not source["reason"]:
        return "lacks not_applicable evidence"
    return None


def publication(home, clock):
    doc = strict_json(regular_bytes(home / "state/autolaunch-steps.candidates"))
    if not isinstance(doc, dict) or doc.get("schema") != "fm-seat-candidates/v1":
        raise ValueError("unsupported or malformed candidate publication")
    if doc.get("home") != str(home):
        raise ValueError("candidate publication names another home")
    if not isinstance(doc.get("machine"), str) or not doc["machine"]:
        raise ValueError("candidate publication lacks machine identity")
    if not isinstance(doc.get("publication_id"), str) or not doc["publication_id"]:
        raise ValueError("candidate publication lacks publication_id")
    if doc.get("complete") is not True:
        raise ValueError("candidate publication is incomplete")
    for field in ("completed_at", "valid_until"):
        if type(doc.get(field)) is not int:
            raise ValueError(f"candidate publication lacks integer {field}")
    if not 0 <= doc["completed_at"] <= clock <= doc["valid_until"]:
        raise ValueError("candidate publication is expired or has invalid times")
    sources = doc.get("sources")
    if not isinstance(sources, dict):
        raise ValueError("candidate publication lacks sources")
    for name in REQUIRED:
        error = source_error(sources.get(name))
        if error:
            raise ValueError(f"required source {name} {error}")
    if not isinstance(doc.get("entries"), list):
        raise ValueError("candidate publication lacks entries")
    for entry in doc["entries"]:
        owner = entry.get("owner") if isinstance(entry, dict) else None
        if (not isinstance(owner, dict) or not isinstance(owner.get("home"), str)
                or not Path(owner["home"]).is_absolute() or not isinstance(owner.get("task"), str)
                or not TASK.fullmatch(owner["task"])):
            raise ValueError("candidate publication contains unidentified entry")
    return doc


def entry_result(home, doc, entry):
    reasons = []
    if entry["owner"]["home"] != str(home):
        reasons.append("publication does not own this entry")
    actor = entry.get("actor")
    if (not isinstance(actor, dict) or actor.get("home") != str(home)
            or not isinstance(actor.get("task"), str) or not TASK.fullmatch(actor["task"])
            or not isinstance(actor.get("kind"), str) or not actor["kind"]):
        reasons.append("actor identity missing or conflicting")
    for field in ("slice_id", "phase", "cut"):
        if not isinstance(entry.get(field), str) or not entry[field]:
            reasons.append(f"{field} evidence missing")
    if type(entry.get("owner_generation")) is not int or entry["owner_generation"] < 1:
        reasons.append("owner generation evidence missing")
    refs = entry.get("source_refs")
    sources = doc["sources"]
    if not isinstance(refs, dict):
        reasons.append("source references missing")
        refs = {}
    for name in REQUIRED:
        if refs.get(name) != sources[name]["revision"]:
            reasons.append(f"stale {name} source revision")
    for name, revision in refs.items():
        source = sources.get(name)
        error = source_error(source)
        if error:
            reasons.append(f"source {name} {error}")
        elif source["revision"] != revision:
            reasons.append(f"conflicting {name} source revision")
    prep = entry.get("prep")
    if not isinstance(prep, dict) or not isinstance(prep.get("revision"), str) or not prep["revision"]:
        reasons.append("accepted prep revision missing")
        prep = {}
    for name, file in (("digest", "prep.md"), ("brief_digest", "brief.md")):
        try:
            actual = sha(regular_bytes(home / "data" / entry["owner"]["task"] / file))
            if prep.get(name) != actual:
                reasons.append(f"{file} changed since publication")
        except (OSError, ValueError):
            reasons.append(f"{file} evidence unavailable")
    facts = entry.get("facts")
    if not isinstance(facts, dict) or any(name not in facts for name in AUTHORITIES):
        reasons.append("required eligibility facts missing")
        facts = facts if isinstance(facts, dict) else {}
    denied = []
    for name, fact in sorted(facts.items()):
        if not isinstance(fact, dict):
            reasons.append(f"{name} fact malformed")
            continue
        authority = fact.get("authority")
        source = sources.get(authority) if isinstance(authority, str) else None
        if (source_error(source)
                or "source_ref" not in fact or authority not in refs
                or fact.get("source_ref") != source.get("revision")
                or refs.get(authority) != source.get("revision")
                or (name in AUTHORITIES and authority != AUTHORITIES[name])):
            reasons.append(f"{name} fact authority/revision conflict")
        if fact.get("verdict") == "deny":
            denied.append(f"{name}: {fact.get('reason') or 'authoritative denial'}")
        elif fact.get("verdict") != "allow":
            reasons.append(f"{name}: {fact.get('reason') or 'unknown evidence'}")
    if reasons:
        return "UNKNOWN", sorted(set(reasons))
    return ("INELIGIBLE", denied) if denied else ("ELIGIBLE", [])


def join(home):
    out = dict(schema="join/v1", status="COMPLETE", reasons=[], homes=[], entries=[])
    clock = now()
    try:
        registered = homes(home)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        out.update(status="NO_PICK")
        out["reasons"].append(dict(scope="machine", code="enumeration", reason=str(error)))
        registered = {home: str(error)}
    seen = {}
    for member, error in registered.items():
        try:
            if error:
                raise ValueError(error)
            state = member / "state"
            if not state.is_dir() or state.is_symlink():
                raise ValueError(f"registered home state unavailable: {state}")
            doc = publication(member, clock)
        except (OSError, ValueError, UnicodeError) as error:
            out["status"] = "NO_PICK"
            reason = str(error)
            out["homes"].append(dict(home=str(member), status="unavailable", reason=reason))
            out["reasons"].append(dict(scope="machine", code="home-unavailable", home=str(member),
                                       owner=str(member), retry="fresh complete publication", reason=reason))
            continue
        out["homes"].append(dict(home=str(member), status="available", reason="complete publication",
                                 publication_id=doc["publication_id"]))
        for entry in doc["entries"]:
            identity = (entry["owner"]["home"], entry["owner"]["task"])
            result, reasons = entry_result(member, doc, entry)
            if identity in seen or identity[0] != str(member):
                out["status"] = "NO_PICK"
                reasons.append("ownership conflict")
                result = "UNKNOWN"
                out["reasons"].append(dict(scope="machine", code="ownership-conflict", owner=entry["owner"],
                                           reason="owner identity published more than once or by another home"))
                for previous in out["entries"]:
                    if previous["owner"] == entry["owner"]:
                        previous.update(result="UNKNOWN", reasons=["ownership conflict"])
            seen[identity] = member
            out["entries"].append(dict(owner=entry["owner"], result=result, reasons=reasons))
    return out


def ready(stdout):
    lines = stdout.splitlines()
    counts = [int(m[1]) for line in lines if (m := re.fullmatch(r"count: (\d+)", line))]
    if len(counts) != 1:
        raise ValueError("ready response lacks one declared count")
    count = counts[0]
    if count == 0:
        if (sum(bool(re.fullmatch(r"ready: 0(?: .*)?", line)) for line in lines) != 1
                or any(line.startswith("ready[") for line in lines)):
            raise ValueError("ready response lacks complete-empty evidence")
        start = next(i for i, line in enumerate(lines) if re.fullmatch(r"ready: 0(?: .*)?", line)) + 1
        for line in lines[start:]:
            if line and not line[0].isspace():
                break
            if line.strip():
                raise ValueError("ready empty response contains task rows")
        return []
    headers = [(i, m) for i, line in enumerate(lines)
               if (m := re.fullmatch(r"ready\[(\d+)\]\{(id,[^}]+)\}:.*", line))]
    if len(headers) != 1 or int(headers[0][1][1]) != count:
        raise ValueError("ready table/count disagreement")
    start = headers[0][0] + 1
    rows = lines[start:start + count]
    if len(rows) != count or any(not line.startswith("  ") or line.startswith("   ") for line in rows):
        raise ValueError("ready table is truncated")
    if len(lines) > start + count and lines[start + count].startswith("  "):
        raise ValueError("ready table has more rows than its declared count")
    columns = headers[0][1][2].split(",")
    if len(set(columns)) != len(columns):
        raise ValueError("ready table contains duplicate columns")
    try:
        parsed = list(csv.reader([line[2:] for line in rows], strict=True, escapechar="\\"))
    except csv.Error as error:
        raise ValueError(f"malformed ready row: {error}") from error
    if any(len(row) != len(columns) for row in parsed):
        raise ValueError("ready row width does not match its header")
    ids = [row[0] for row in parsed]
    if any(not TASK.fullmatch(task) for task in ids) or len(set(ids)) != count:
        raise ValueError("ready task identity invalid or duplicated")
    return ids


def publish(home):
    clock = now()
    state = home / "state"
    if not state.is_dir() or state.is_symlink():
        raise ValueError("publication state directory unavailable")
    entries, evidence = [], []
    task_raw = b""
    task_status, task_reason = "ok", "ready membership read completely"
    try:
        result = command(["bash", BIN / "fm-tasks-axi.sh", "ready"], home)
        task_raw = result.stdout.encode()
        if result.returncode:
            raise ValueError(result.stderr.strip() or "ready reader failed")
        tasks = ready(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        tasks = []
        task_status, task_reason = "unknown", str(error)
    for task in tasks:
        details = dict(prep=dict(verdict="unknown", reason="preparation reader unavailable"), held="unknown")
        try:
            result = command(["bash", BIN / "fm-autolaunch.sh", "--candidate-prep", task], home)
            if result.returncode:
                raise ValueError("preparation reader failed")
            got = strict_json(result.stdout)
            if not isinstance(got, dict) or not isinstance(got.get("prep"), dict):
                raise ValueError("preparation reader malformed")
            details = got
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            details["prep"]["reason"] = str(error)
        prep = dict(revision=None, digest=None, brief_digest=None)
        for field, file in (("digest", "prep.md"), ("brief_digest", "brief.md")):
            try:
                raw = regular_bytes(home / "data" / task / file)
                prep[field] = sha(raw)
                evidence.append((task, file, prep[field]))
            except (OSError, ValueError):
                evidence.append((task, file, None))
        entries.append(dict(owner=dict(home=str(home), task=task), slice_id=None,
                            actor=dict(home=str(home), task=task, kind="unknown"),
                            phase="unknown", cut=None, owner_generation=None,
                            prep=prep, facts={}, source_refs={}, _details=details))
    def source(status, revision, digest, reason):
        return dict(status=status, revision=revision, evidence_digest=digest, reason=reason)
    prep_digest = sha(json.dumps(evidence, sort_keys=True).encode())
    sources = dict(tasks=source(task_status, sha(task_raw), sha(task_raw), task_reason),
                   prep=source("ok", prep_digest, prep_digest, "preparation evidence attempts retained"))
    for name in ("slice", "catalogue", "claims"):
        sources[name] = source("missing", None, None, f"{name} producer contract not supplied")
    for entry in entries:
        details = entry.pop("_details")
        for name, authority in AUTHORITIES.items():
            verdict, reason = "unknown", f"{name} producer evidence not supplied"
            if name == "prep":
                verdict, reason = details["prep"].get("verdict", "unknown"), details["prep"].get("reason", "")
            elif name == "task" and details.get("held") in ("yes", "no"):
                verdict, reason = ("deny", "task held") if details["held"] == "yes" else ("allow", "task detail read")
            entry["facts"][name] = dict(verdict=verdict, authority=authority,
                                        source_ref=sources[authority]["revision"], reason=reason)
        entry["source_refs"] = {name: value["revision"] for name, value in sources.items()}
    doc = dict(schema="fm-seat-candidates/v1", machine=os.uname().nodename, home=str(home),
               publication_id=str(uuid.uuid4()), completed_at=clock, valid_until=clock,
               complete=False, sources=sources, entries=entries)
    fd, temporary = tempfile.mkstemp(prefix=".autolaunch-candidates-", dir=state)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(doc, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, state / "autolaunch-steps.candidates")
        directory = os.open(state, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return doc


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("join", "publish-candidates"):
        print("usage: fm-next-in-line.py join|publish-candidates", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    try:
        home = Path(os.environ.get("FM_HOME", BIN.parent)).absolute()
        try:
            home = home.resolve(strict=True)
        except (OSError, RuntimeError):
            if mode != "join":
                raise
        result = join(home) if mode == "join" else publish(home)
    except (OSError, RuntimeError, ValueError, UnicodeError, subprocess.TimeoutExpired) as error:
        if mode != "join":
            print(f"fm-next-in-line: {error}", file=sys.stderr)
            return 75
        result = dict(schema="join/v1", status="NO_PICK", homes=[], entries=[],
                      reasons=[dict(scope="machine", code="reader-unavailable", reason=str(error))])
    print(json.dumps(result, sort_keys=True))
    return 75 if mode == "join" and result["status"] == "NO_PICK" else 0


if __name__ == "__main__":
    sys.exit(main())
