#!/usr/bin/env bash
# fm-heal.sh - guarded mechanical operations for the private /heal ledger.
#
# Usage:
#   fm-heal.sh owner-status
#   fm-heal.sh init
#   fm-heal.sh new --id ID --fingerprint KEY --component TEXT --title TEXT
#     --classification KIND --severity LEVEL --observed-at TIME --event-key KEY
#     --notifications N --evidence REF --owner REF
#   fm-heal.sh observe --id ID --event-key KEY --observed-at TIME
#     --notifications N --evidence REF
#   fm-heal.sh verify ID --verified-at TIME --evidence REF
#   fm-heal.sh transition ID STATE --reason TEXT [state conditions]
#   fm-heal.sh publish ID --candidate PATH
#   fm-heal.sh archive ID [--month YYYY-MM]
#   fm-heal.sh rebuild-index [--limit N]
#   fm-heal.sh checkpoint-begin --scan-id ID --window TEXT --started-at TIME
#   fm-heal.sh checkpoint-source --scan-id ID --source-id ID --identity TEXT
#     --cursor TEXT --read-at TIME
#   fm-heal.sh checkpoint-complete --scan-id ID --completed-at TIME
#     --expect SOURCE=IDENTITY [--expect SOURCE=IDENTITY ...]
#   fm-heal.sh checkpoint-status
#   fm-heal.sh lookup QUERY
#
# The Markdown finding format is fm-heal-finding.v1: a JSON object between the
# first two `---` lines followed by human-maintained Markdown sections.
# checkpoint.json is fm-heal-checkpoint.v1 and is incomplete until one exact
# scan id is completed against the identities of every expected source.
# INDEX.md and data/heal/indexes/ are rebuildable views; finding files are the
# authority. Every mutation first proves that this process descends from the
# verified harness that owns FM_HOME/state/.lock. This command never acquires,
# recovers, or replaces that lock and never touches supervisor queue cursors.
# Whole-file writes use a mode-0600 temporary file in the destination directory,
# fsync, and atomic replacement. Archive moves use same-filesystem replacement.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HEAL_ROOT="$FM_HOME/data/heal"

# shellcheck source=bin/fm-session-lock-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  sed -n '2,29{s/^# \{0,1\}//;p;}' "$0"
}

owner_status() {
  if fm_session_lock_owned_by_self "$STATE"; then
    printf '%s\n' owner
  else
    printf '%s\n' advisor
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  owner-status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    owner_status
    exit 0
    ;;
  checkpoint-status|lookup)
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    if ! fm_session_lock_owned_by_self "$STATE"; then
      printf '%s\n' 'heal: verified session lock ownership required; use read-only advisor behavior' >&2
      exit 4
    fi
    ;;
esac

COMMAND=$1
shift
exec python3 - "$HEAL_ROOT" "$SCRIPT_DIR" "$STATE" "$SCRIPT_DIR/fm-session-lock-lib.sh" "$COMMAND" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


FORMAT = "fm-heal-finding.v1"
CHECKPOINT_FORMAT = "fm-heal-checkpoint.v1"
STATES = ("Open", "Active", "Blocked", "Unverified", "Closed")
TRANSITIONS = {
    "Open": {"Active", "Blocked", "Closed"},
    "Active": {"Open", "Blocked", "Unverified", "Closed"},
    "Blocked": {"Open", "Active", "Unverified", "Closed"},
    "Unverified": {"Active", "Blocked", "Closed"},
    "Closed": {"Open"},
}
SEVERITIES = ("critical", "high", "medium", "low")
CLASSIFICATIONS = (
    "recurring-failure",
    "neglected-obligation",
    "delivery-friction",
    "legitimate-hold",
    "ownerless-obligation",
    "historical-report",
    "other",
)
DISPOSITIONS = ("Fixed", "Disproved", "Duplicate", "Superseded", "Captain-authorized-scope")
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
ISO_TIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
STATE_DIR = Path(sys.argv[3])
LOCK_LIB = Path(sys.argv[4])


class HealError(Exception):
    def __init__(self, message: str, code: int = 2):
        super().__init__(message)
        self.code = code


def fail(message: str, code: int = 2) -> None:
    raise HealError(message, code)


def clean_text(value: str, label: str, *, allow_empty: bool = False) -> str:
    if "\n" in value or "\r" in value or "\x00" in value:
        fail(f"{label} must be one line")
    value = value.strip()
    if not value and not allow_empty:
        fail(f"{label} must not be empty")
    return value


def safe_id(value: str, label: str = "id") -> str:
    value = clean_text(value, label)
    if not SAFE_ID.fullmatch(value):
        fail(f"{label} must match {SAFE_ID.pattern}")
    return value


def iso_time(value: str, label: str) -> str:
    value = clean_text(value, label)
    if not ISO_TIME.fullmatch(value):
        fail(f"{label} must be an ISO-8601 UTC timestamp ending in Z")
    return value


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def require_owner() -> None:
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            '. "$1"; fm_session_lock_owned_by_self "$2"',
            "_",
            str(LOCK_LIB),
            str(STATE_DIR),
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        fail("verified session lock ownership required; ownership changed before ledger mutation", 4)


def require_safe_dir(path: Path, *, create: bool = False, mode: int = 0o700) -> None:
    if path.is_symlink():
        fail(f"unsafe symlinked directory: {path}")
    if not path.exists():
        if not create:
            fail(f"directory is missing: {path}")
        require_owner()
        path.mkdir(mode=mode, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        fail(f"not an ordinary directory: {path}")


def validate_destination(path: Path) -> None:
    require_safe_dir(path.parent)
    if path.is_symlink():
        fail(f"unsafe symlinked file: {path}")
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode):
            fail(f"not an ordinary file: {path}")
        if info.st_nlink != 1:
            fail(f"hardlinked file refused: {path}")


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    validate_destination(path)
    require_owner()
    fd, staged = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    staged_path = Path(staged)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(staged_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        staged_path.unlink(missing_ok=True)
        raise


def render_record(meta: dict, body: str) -> str:
    return "---\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n---\n" + body.lstrip("\n")


def parse_record(path: Path) -> tuple[dict, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read finding {path}: {exc}")
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n") != "---":
        fail(f"finding has no JSON frontmatter: {path}")
    end = next((index for index, line in enumerate(lines[1:], start=1) if line.rstrip("\r\n") == "---"), None)
    if end is None:
        fail(f"finding frontmatter is incomplete: {path}")
    try:
        meta = json.loads("".join(lines[1:end]))
    except json.JSONDecodeError as exc:
        fail(f"finding frontmatter is invalid JSON in {path}: {exc}")
    if not isinstance(meta, dict):
        fail(f"finding frontmatter must be an object: {path}")
    validate_meta(meta, path)
    return meta, "".join(lines[end + 1 :])


def validate_meta(meta: dict, path: Path | None = None) -> None:
    label = str(path) if path else "finding"
    required = {
        "format",
        "id",
        "fingerprint",
        "state",
        "severity",
        "classification",
        "component",
        "title",
        "first_observed",
        "latest_occurrence",
        "last_verification",
        "occurrence_count",
        "notification_count",
        "occurrence_keys",
        "owner",
        "blocking_reason",
        "release_trigger",
        "next_action",
        "proof_required",
        "consumer_proof",
        "disposition",
        "closure_evidence",
        "scope_authority",
        "surviving_finding",
    }
    missing = sorted(required - set(meta))
    if missing:
        fail(f"{label} is missing metadata: {', '.join(missing)}")
    if meta["format"] != FORMAT:
        fail(f"{label} has unsupported format")
    safe_id(str(meta["id"]))
    safe_id(str(meta["fingerprint"]), "fingerprint")
    if meta["state"] not in STATES:
        fail(f"{label} has invalid state")
    if meta["severity"] not in SEVERITIES:
        fail(f"{label} has invalid severity")
    if meta["classification"] not in CLASSIFICATIONS:
        fail(f"{label} has invalid classification")
    for field in ("first_observed", "latest_occurrence"):
        iso_time(str(meta[field]), field)
    if meta["last_verification"]:
        iso_time(str(meta["last_verification"]), "last_verification")
    if not isinstance(meta["occurrence_count"], int) or meta["occurrence_count"] < 1:
        fail(f"{label} has invalid occurrence_count")
    if not isinstance(meta["notification_count"], int) or meta["notification_count"] < meta["occurrence_count"]:
        fail(f"{label} has invalid notification_count")
    if not isinstance(meta["occurrence_keys"], list) or len(meta["occurrence_keys"]) != meta["occurrence_count"]:
        fail(f"{label} has occurrence key/count mismatch")
    if len(set(meta["occurrence_keys"])) != len(meta["occurrence_keys"]):
        fail(f"{label} has duplicate occurrence keys")
    for field in required - {"occurrence_count", "notification_count", "occurrence_keys"}:
        if field in {"format", "state", "severity", "classification"}:
            continue
        if not isinstance(meta[field], str):
            fail(f"{label} field {field} must be text")


def append_history(body: str, when: str, message: str) -> str:
    line = f"- {when} | {message}\n"
    marker = "## Material history\n"
    if marker not in body:
        return body.rstrip() + "\n\n" + marker + "\n" + line
    return body.rstrip() + "\n" + line


def all_finding_paths(root: Path) -> list[Path]:
    paths: list[Path] = []
    current = root / "findings"
    if current.is_dir() and not current.is_symlink():
        paths.extend(sorted(current.glob("*.md")))
    archive = root / "archive"
    if archive.is_dir() and not archive.is_symlink():
        paths.extend(sorted(archive.glob("*/*.md")))
    return paths


def locate(root: Path, finding_id: str) -> tuple[Path, bool]:
    finding_id = safe_id(finding_id)
    current = root / "findings" / f"{finding_id}.md"
    if current.exists() or current.is_symlink():
        return current, False
    archive = root / "archive"
    matches = sorted(archive.glob(f"*/{finding_id}.md")) if archive.is_dir() and not archive.is_symlink() else []
    if len(matches) > 1:
        fail(f"finding id has multiple archived records: {finding_id}")
    if matches:
        return matches[0], True
    fail(f"finding not found: {finding_id}")


def navigation_readme(script_dir: Path) -> str:
    workflow = script_dir.parent / ".agents" / "skills" / "heal" / "workflow.md"
    return (
        "# Heal ledger\n\n"
        "This private ledger is maintained by the manually invoked `/heal` workflow.\n"
        f"Tracked workflow instructions: `{workflow}`.\n"
        "Current navigation view: [INDEX.md](INDEX.md).\n"
    )


def initial_checkpoint() -> dict:
    return {
        "format": CHECKPOINT_FORMAT,
        "scan_id": None,
        "window": None,
        "started_at": None,
        "completed_at": None,
        "complete": False,
        "sources": {},
    }


def checkpoint_text(value: dict) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def ensure_ledger(root: Path, script_dir: Path) -> None:
    require_safe_dir(root.parent, create=True)
    require_safe_dir(root, create=True)
    for directory in (root / "findings", root / "archive"):
        require_safe_dir(directory, create=True)
    readme = root / "README.md"
    if not readme.exists():
        atomic_write(readme, navigation_readme(script_dir))
    checkpoint = root / "checkpoint.json"
    if not checkpoint.exists():
        atomic_write(checkpoint, checkpoint_text(initial_checkpoint()))
    index = root / "INDEX.md"
    if not index.exists():
        rebuild_index(root, 20)


def finding_link(path: Path, meta: dict, prefix: str = "") -> str:
    return f"- [{meta['id']}]({prefix}findings/{meta['id']}.md) | {meta['severity']} | {meta['state']} | {meta['title']}\n"


def load_current(root: Path) -> tuple[list[tuple[Path, dict]], list[tuple[Path, str]]]:
    records: list[tuple[Path, dict]] = []
    damaged: list[tuple[Path, str]] = []
    directory = root / "findings"
    if not directory.exists():
        return records, damaged
    require_safe_dir(directory)
    for path in sorted(directory.glob("*.md")):
        try:
            meta, _ = parse_record(path)
            records.append((path, meta))
        except HealError as exc:
            damaged.append((path, str(exc)))
    return records, damaged


def rebuild_index(root: Path, limit: int) -> None:
    if limit < 1 or limit > 100:
        fail("index limit must be between 1 and 100")
    require_safe_dir(root, create=True)
    require_safe_dir(root / "findings", create=True)
    records, damaged = load_current(root)
    severity_rank = {name: index for index, name in enumerate(SEVERITIES)}
    state_rank = {"Active": 0, "Blocked": 1, "Unverified": 2, "Open": 3, "Closed": 4}
    records.sort(key=lambda item: (severity_rank[item[1]["severity"]], state_rank[item[1]["state"]], item[1]["id"]))
    unresolved = [(path, meta) for path, meta in records if meta["state"] != "Closed"]
    closed = [(path, meta) for path, meta in records if meta["state"] == "Closed"]
    lines = [
        "# Heal index\n\n",
        "This file is a rebuildable navigation view; finding records are authoritative.\n\n",
        f"- Unresolved: {len(unresolved)}\n",
        f"- Current closed awaiting archival: {len(closed)}\n",
        f"- Damaged records requiring recovery: {len(damaged)}\n\n",
        "## Priority view\n\n",
    ]
    if not unresolved:
        lines.append("No actionable findings.\n")
    else:
        shown = unresolved[:limit]
        if len(unresolved) > limit:
            lines.append(f"Showing highest-priority {len(shown)} of {len(unresolved)} unresolved findings.\n\n")
        lines.extend(finding_link(path, meta) for path, meta in shown)
    indexes = root / "indexes"
    if len(unresolved) > limit:
        require_safe_dir(indexes, create=True)
        page_paths: list[Path] = []
        for page_number, offset in enumerate(range(0, len(unresolved), 50), start=1):
            page = indexes / f"unresolved-{page_number:03d}.md"
            page_paths.append(page)
            page_lines = [
                f"# Complete unresolved heal index {page_number}\n\n",
                f"Total unresolved across all pages: {len(unresolved)}.\n\n",
            ]
            for _, meta in unresolved[offset : offset + 50]:
                page_lines.append(finding_link(root / "findings" / f"{meta['id']}.md", meta, "../"))
            atomic_write(page, "".join(page_lines))
        lines.append("\n## Complete unresolved indexes\n\n")
        for page in page_paths:
            lines.append(f"- [{page.name}](indexes/{page.name})\n")
    if closed:
        lines.append("\n## Recent closed awaiting archival\n\n")
        lines.extend(finding_link(path, meta) for path, meta in closed[:3])
    if damaged:
        lines.append("\n## Damaged records\n\n")
        for path, reason in damaged:
            lines.append(f"- [findings/{path.name}](findings/{path.name}) | {reason}\n")
    atomic_write(root / "INDEX.md", "".join(lines))


def load_checkpoint(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"corrupt checkpoint: {exc}")
    if not isinstance(value, dict) or value.get("format") != CHECKPOINT_FORMAT:
        fail("corrupt checkpoint: unsupported format")
    if not isinstance(value.get("complete"), bool) or not isinstance(value.get("sources"), dict):
        fail("corrupt checkpoint: invalid fields")
    return value


def preserve_checkpoint(path: Path, reason: str) -> Path:
    if reason not in {"corrupt", "incomplete"}:
        fail(f"unsupported checkpoint preservation reason: {reason}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = path.with_name(f"checkpoint.{reason}.{stamp}.json")
    serial = 1
    while destination.exists() or destination.is_symlink():
        destination = path.with_name(f"checkpoint.{reason}.{stamp}.{serial}.json")
        serial += 1
    validate_destination(destination)
    require_owner()
    os.replace(path, destination)
    return destination


def record_template(script_dir: Path, meta: dict, evidence: str, observed_at: str) -> str:
    template = script_dir.parent / ".agents" / "skills" / "heal" / "templates" / "finding.md"
    try:
        body = template.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read finding template: {exc}")
    if body.startswith("---"):
        fail("finding template must contain body content only")
    replacements = {
        "{{TITLE}}": meta["title"],
        "{{COMPONENT}}": meta["component"],
        "{{EVIDENCE}}": evidence,
        "{{OBSERVED_AT}}": observed_at,
        "{{OWNER}}": meta["owner"],
    }
    for key, value in replacements.items():
        body = body.replace(key, value)
    if "{{" in body or "}}" in body:
        fail("finding template has unresolved placeholders")
    return body


def parser() -> argparse.ArgumentParser:
    command = sys.argv[5]
    result = argparse.ArgumentParser(prog=f"fm-heal.sh {command}")
    if command == "init":
        return result
    if command == "new":
        result.add_argument("--id", required=True)
        result.add_argument("--fingerprint", required=True)
        result.add_argument("--component", required=True)
        result.add_argument("--title", required=True)
        result.add_argument("--classification", choices=CLASSIFICATIONS, required=True)
        result.add_argument("--severity", choices=SEVERITIES, required=True)
        result.add_argument("--observed-at", required=True)
        result.add_argument("--event-key", required=True)
        result.add_argument("--notifications", type=int, required=True)
        result.add_argument("--evidence", required=True)
        result.add_argument("--owner", required=True)
        return result
    if command == "observe":
        result.add_argument("--id", required=True)
        result.add_argument("--event-key", required=True)
        result.add_argument("--observed-at", required=True)
        result.add_argument("--notifications", type=int, required=True)
        result.add_argument("--evidence", required=True)
        return result
    if command == "verify":
        result.add_argument("id")
        result.add_argument("--verified-at", required=True)
        result.add_argument("--evidence", required=True)
        return result
    if command == "transition":
        result.add_argument("id")
        result.add_argument("state", choices=STATES)
        result.add_argument("--reason", required=True)
        result.add_argument("--evidence", default="")
        result.add_argument("--owner", default="")
        result.add_argument("--trigger", default="")
        result.add_argument("--next-action", default="")
        result.add_argument("--proof-required", default="")
        result.add_argument("--consumer-proof", default="")
        result.add_argument("--disposition", choices=DISPOSITIONS)
        result.add_argument("--survivor", default="")
        result.add_argument("--authority", default="")
        result.add_argument("--new-evidence", default="")
        return result
    if command == "publish":
        result.add_argument("id")
        result.add_argument("--candidate", required=True)
        return result
    if command == "archive":
        result.add_argument("id")
        result.add_argument("--month")
        return result
    if command == "rebuild-index":
        result.add_argument("--limit", type=int, default=20)
        return result
    if command == "checkpoint-begin":
        result.add_argument("--scan-id", required=True)
        result.add_argument("--window", required=True)
        result.add_argument("--started-at", required=True)
        return result
    if command == "checkpoint-source":
        result.add_argument("--scan-id", required=True)
        result.add_argument("--source-id", required=True)
        result.add_argument("--identity", required=True)
        result.add_argument("--cursor", required=True)
        result.add_argument("--read-at", required=True)
        return result
    if command == "checkpoint-complete":
        result.add_argument("--scan-id", required=True)
        result.add_argument("--completed-at", required=True)
        result.add_argument("--expect", action="append", required=True)
        return result
    if command == "checkpoint-status":
        return result
    if command == "lookup":
        result.add_argument("query")
        return result
    fail(f"unknown command: {command}")


def main() -> int:
    root = Path(sys.argv[1])
    script_dir = Path(sys.argv[2])
    command = sys.argv[5]
    args = parser().parse_args(sys.argv[6:])

    if command == "checkpoint-status":
        checkpoint = root / "checkpoint.json"
        if not checkpoint.exists():
            print("missing")
            return 1
        try:
            value = load_checkpoint(checkpoint)
        except HealError as exc:
            print(str(exc))
            return 1
        print("complete" if value["complete"] else "incomplete")
        return 0

    if command == "lookup":
        query = clean_text(args.query, "query").casefold()
        if not root.exists():
            print("no matching findings")
            return 1
        matches = []
        for path in all_finding_paths(root):
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                continue
            if query in path.name.casefold() or query in text.casefold():
                matches.append(path.relative_to(root).as_posix())
        if not matches:
            print("no matching findings")
            return 1
        print("\n".join(matches))
        return 0

    ensure_ledger(root, script_dir)
    if command == "init":
        print(root)
        return 0

    if command == "new":
        finding_id = safe_id(args.id)
        fingerprint = safe_id(args.fingerprint, "fingerprint")
        observed = iso_time(args.observed_at, "observed_at")
        event_key = clean_text(args.event_key, "event_key")
        evidence = clean_text(args.evidence, "evidence")
        owner = clean_text(args.owner, "owner")
        if args.notifications < 1:
            fail("notifications must be a positive integer")
        for path in all_finding_paths(root):
            meta, _ = parse_record(path)
            if meta["id"] == finding_id or meta["fingerprint"] == fingerprint:
                print(f"existing={meta['id']} owner={meta['owner']} path={path.relative_to(root).as_posix()}")
                return 3
        meta = {
            "format": FORMAT,
            "id": finding_id,
            "fingerprint": fingerprint,
            "state": "Open",
            "severity": args.severity,
            "classification": args.classification,
            "component": clean_text(args.component, "component"),
            "title": clean_text(args.title, "title"),
            "first_observed": observed,
            "latest_occurrence": observed,
            "last_verification": "",
            "occurrence_count": 1,
            "notification_count": args.notifications,
            "occurrence_keys": [event_key],
            "owner": owner,
            "blocking_reason": "",
            "release_trigger": "",
            "next_action": "triage against current authoritative state",
            "proof_required": "",
            "consumer_proof": "",
            "disposition": "",
            "closure_evidence": "",
            "scope_authority": "",
            "surviving_finding": "",
        }
        body = record_template(script_dir, meta, evidence, observed)
        atomic_write(root / "findings" / f"{finding_id}.md", render_record(meta, body))
        rebuild_index(root, 20)
        print(f"created={finding_id}")
        return 0

    if command == "observe":
        path, archived = locate(root, args.id)
        meta, body = parse_record(path)
        observed = iso_time(args.observed_at, "observed_at")
        event_key = clean_text(args.event_key, "event_key")
        evidence = clean_text(args.evidence, "evidence")
        if args.notifications < 1:
            fail("notifications must be a positive integer")
        meta["notification_count"] += args.notifications
        new_occurrence = event_key not in meta["occurrence_keys"]
        if new_occurrence:
            meta["occurrence_keys"].append(event_key)
            meta["occurrence_count"] += 1
            meta["latest_occurrence"] = observed
            body = append_history(body, observed, f"Independent occurrence recorded from `{evidence}`.")
            if meta["state"] == "Closed":
                meta["state"] = "Open"
                meta["disposition"] = ""
                meta["closure_evidence"] = ""
                meta["scope_authority"] = ""
                meta["surviving_finding"] = ""
                meta["next_action"] = "triage recurrence against current authoritative state"
                body = append_history(body, observed, f"Reopened on new recurrence evidence `{evidence}`.")
        destination = root / "findings" / f"{meta['id']}.md" if archived and new_occurrence else path
        if archived and new_occurrence:
            validate_destination(destination)
            require_owner()
            os.replace(path, destination)
        atomic_write(destination, render_record(meta, body))
        rebuild_index(root, 20)
        print(f"finding={meta['id']} new_occurrence={'yes' if new_occurrence else 'no'}")
        return 0

    if command == "verify":
        path, _ = locate(root, args.id)
        meta, body = parse_record(path)
        verified = iso_time(args.verified_at, "verified_at")
        evidence = clean_text(args.evidence, "evidence")
        meta["last_verification"] = verified
        body = append_history(body, verified, f"Current state verified from `{evidence}` without recording a recurrence.")
        atomic_write(path, render_record(meta, body))
        rebuild_index(root, 20)
        print(f"verified={meta['id']}")
        return 0

    if command == "transition":
        path, archived = locate(root, args.id)
        meta, body = parse_record(path)
        source = meta["state"]
        destination = args.state
        if destination not in TRANSITIONS[source]:
            fail(f"transition not permitted: {source} -> {destination}")
        reason = clean_text(args.reason, "reason")
        evidence = clean_text(args.evidence, "evidence", allow_empty=True)
        owner = clean_text(args.owner, "owner", allow_empty=True) or meta["owner"]
        trigger = clean_text(args.trigger, "trigger", allow_empty=True)
        next_action = clean_text(args.next_action, "next_action", allow_empty=True)
        proof_required = clean_text(args.proof_required, "proof_required", allow_empty=True)
        consumer_proof = clean_text(args.consumer_proof, "consumer_proof", allow_empty=True)
        if destination == "Active" and (not owner or owner == "none"):
            fail("Active requires an existing owner")
        if destination == "Blocked" and (not owner or owner == "none" or not trigger):
            fail("Blocked requires a reason, owner, and release trigger")
        if destination == "Unverified" and (not evidence or not proof_required):
            fail("Unverified requires correction evidence and the remaining proof")
        if destination == "Open" and not (next_action or trigger):
            fail("reprioritizing to Open requires a next action or trigger")
        if source == "Closed" and destination == "Open" and not clean_text(args.new_evidence, "new_evidence", allow_empty=True):
            fail("Closed to Open requires new evidence")
        if source == "Closed" and destination == "Open" and not evidence:
            evidence = clean_text(args.new_evidence, "new_evidence")
        if destination == "Closed":
            if not args.disposition or not evidence:
                fail("Closed requires a disposition and closure evidence")
            if args.disposition == "Fixed" and not consumer_proof:
                fail("Fixed closure requires consuming-workflow proof")
            if args.disposition in {"Duplicate", "Superseded"} and not args.survivor:
                fail(f"{args.disposition} closure requires a surviving finding or owner")
            if args.disposition == "Captain-authorized-scope" and not args.authority:
                fail("Captain-authorized-scope closure requires the authority reference")
        meta["state"] = destination
        meta["owner"] = owner
        meta["blocking_reason"] = reason if destination == "Blocked" else ""
        meta["release_trigger"] = trigger
        meta["next_action"] = next_action
        meta["proof_required"] = proof_required
        meta["consumer_proof"] = consumer_proof
        if destination == "Closed":
            meta["disposition"] = args.disposition
            meta["closure_evidence"] = evidence
            meta["scope_authority"] = clean_text(args.authority, "authority", allow_empty=True)
            meta["surviving_finding"] = clean_text(args.survivor, "survivor", allow_empty=True)
        elif source == "Closed":
            meta["disposition"] = ""
            meta["closure_evidence"] = ""
            meta["scope_authority"] = ""
            meta["surviving_finding"] = ""
        stamp = utc_now()
        detail = f"State changed {source} -> {destination}: {reason}"
        if evidence:
            detail += f" Evidence: `{evidence}`."
        body = append_history(body, stamp, detail)
        destination_path = root / "findings" / f"{meta['id']}.md"
        if archived:
            validate_destination(destination_path)
            require_owner()
            os.replace(path, destination_path)
        atomic_write(destination_path, render_record(meta, body))
        rebuild_index(root, 20)
        print(f"transition={source}->{destination}")
        return 0

    if command == "publish":
        path, archived = locate(root, args.id)
        if archived:
            fail("publish cannot move an archived record; use observe or an allowed transition")
        current_meta, _ = parse_record(path)
        candidate = Path(args.candidate)
        candidate_meta, candidate_body = parse_record(candidate)
        if candidate_meta != current_meta:
            fail("publish candidate changed protected metadata; use the owning subcommand")
        atomic_write(path, render_record(candidate_meta, candidate_body))
        print(f"published={current_meta['id']}")
        return 0

    if command == "archive":
        path, archived = locate(root, args.id)
        if archived:
            print(f"already-archived={args.id}")
            return 0
        meta, _ = parse_record(path)
        if meta["state"] != "Closed":
            fail("only a Closed finding may be archived")
        month = args.month or utc_now()[:7]
        if not re.fullmatch(r"\d{4}-(?:0[1-9]|1[0-2])", month):
            fail("archive month must be YYYY-MM")
        directory = root / "archive" / month
        require_safe_dir(directory, create=True)
        destination = directory / path.name
        if destination.exists() or destination.is_symlink():
            fail(f"archive destination already exists: {destination}")
        require_owner()
        os.replace(path, destination)
        rebuild_index(root, 20)
        print(f"archived={destination.relative_to(root).as_posix()}")
        return 0

    if command == "rebuild-index":
        rebuild_index(root, args.limit)
        print(f"rebuilt={root / 'INDEX.md'}")
        return 0

    checkpoint_path = root / "checkpoint.json"
    if command == "checkpoint-begin":
        scan_id = safe_id(args.scan_id, "scan_id")
        started = iso_time(args.started_at, "started_at")
        window = clean_text(args.window, "window")
        try:
            value = load_checkpoint(checkpoint_path)
        except HealError:
            preserve_checkpoint(checkpoint_path, "corrupt")
            value = initial_checkpoint()
        if value.get("scan_id") == scan_id and not value.get("complete"):
            if value.get("window") != window or value.get("started_at") != started:
                fail("repeated scan id changed its window or start identity")
        else:
            if value.get("scan_id") and not value.get("complete"):
                preserve_checkpoint(checkpoint_path, "incomplete")
            value = {
                "format": CHECKPOINT_FORMAT,
                "scan_id": scan_id,
                "window": window,
                "started_at": started,
                "completed_at": None,
                "complete": False,
                "sources": {},
            }
        atomic_write(checkpoint_path, checkpoint_text(value))
        print(f"scan={scan_id} complete=false")
        return 0

    if command == "checkpoint-source":
        value = load_checkpoint(checkpoint_path)
        scan_id = safe_id(args.scan_id, "scan_id")
        source_id = safe_id(args.source_id, "source_id")
        if value.get("scan_id") != scan_id or value.get("complete"):
            fail("checkpoint source does not belong to the active incomplete scan")
        identity = clean_text(args.identity, "identity")
        existing_source = value["sources"].get(source_id)
        if existing_source and existing_source.get("identity") != identity:
            fail("source identity changed during the scan; preserve the incomplete checkpoint and start a refreshed scan")
        value["sources"][source_id] = {
            "identity": identity,
            "cursor": clean_text(args.cursor, "cursor"),
            "read_at": iso_time(args.read_at, "read_at"),
        }
        atomic_write(checkpoint_path, checkpoint_text(value))
        print(f"source={source_id}")
        return 0

    if command == "checkpoint-complete":
        value = load_checkpoint(checkpoint_path)
        scan_id = safe_id(args.scan_id, "scan_id")
        if value.get("scan_id") != scan_id or value.get("complete"):
            fail("checkpoint completion does not belong to the active incomplete scan")
        expected: dict[str, str] = {}
        for item in args.expect:
            if "=" not in item:
                fail("expected source binding must be SOURCE=IDENTITY")
            source_id, identity = item.split("=", 1)
            source_id = safe_id(source_id, "expected source_id")
            identity = clean_text(identity, "expected identity")
            if source_id in expected:
                fail(f"duplicate expected source: {source_id}")
            expected[source_id] = identity
        actual = {key: source.get("identity") for key, source in value["sources"].items()}
        if actual != expected:
            fail("checkpoint sources do not exactly match the identities actually expected")
        value["complete"] = True
        value["completed_at"] = iso_time(args.completed_at, "completed_at")
        atomic_write(checkpoint_path, checkpoint_text(value))
        print(f"scan={scan_id} complete=true")
        return 0

    fail(f"unknown command: {command}")


try:
    raise SystemExit(main())
except HealError as exc:
    print(f"heal: {exc}", file=sys.stderr)
    raise SystemExit(exc.code)
PY
