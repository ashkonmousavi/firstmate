#!/usr/bin/env python3
"""Pure structural custody and merge for explicitly bound native owner requests.

Owner-request packet authoring contract for fm-tasks-axi.sh --owner-request-file:
For each owner-origin request that creates or updates a native task, including
an explanation-only request or later correction, MAIN or the receiving
secondmate reads this contract and authors the packet before that call.
A mid-task addition or change is bound first, before the brief's Captain's
intent is updated: append its source-linked requirement or correction to the
same bound task, or create a separate bound item when the existing task is a
legacy unbound row.
Non-owner tasks and historical unbound rows keep their existing task path.
Write one private UTF-8 JSON file with the required PACKET keys below;
proof_updates is the only optional top-level key.
For add, expected_body_sha256 is null; for update it is SHA256 of the exact
previous native body. origin_home and origin_task_id identify the original
home/task, while the wrapper addresses the current owning home and task ID.
Set interpretation_complete=true only after conversational intake has identified
every action and explanation part, including later corrections. This assertion
belongs to that interpreter: this helper cannot detect omitted intent.

Each SOURCE row keeps the source session_id, message_uuid and file_ref.
For nonsecret source_custody=complete, retain full_text and its exact UTF-8
full_text_sha256 in the native body. If a source contains credentials, mark it
restricted with both fields null; never copy or hash a secret span into the
packet. Preserve its original only in the existing protected source.
For each independently verified safe part of a restricted source, use a
verified_safe requirement with complete nonsecret safe_text. Keep inseparable
or secret-dependent parts restricted with text_ref/safe_text null and pending
or held disposition. For a complete source, verified_complete text_ref must
resolve inside its retained full_text. Unknown source completeness cannot
silently make an omitted requirement accepted.

Each REQ row has a stable id, source_message_uuid, action|explanation kind,
binding, disposition, proof_refs and superseded_by. Record every action part;
an explanation-only request still has one explanation requirement with
proof_kind=reply, not an empty requirement list. Action proof_kind is one of
product_live, installed_generation, observed_consumer or artifact_delivery.
acceptance_level=source|installed|observed records the promised evidence level,
not a verdict. Required kind-specific fields are checked in validate() below.
proof_refs identify existing receipts by source_owner, receipt_id and exact
content_sha256; do not invent a receipt or infer one from a filename.
For an existing requirement, an update packet may include optional
proof_updates[{id,proof_refs,disposition}] with the complete current proof
reference list and proof_owed|accepted disposition.
Proof-only updates may leave sources and requirements empty.
Each updated ID must exist before this packet, appear once in proof_updates,
and be neither held nor superseded nor involved in this packet's corrections
as an original or replacement ID.
Each proof list must have unique (source_owner, receipt_id) identities.
The native archived body retains the prior list, including a receipt refreshed
at the same path.
Product proof updates may also supply fix_commit and deployed_receipt_ref;
omitted release fields retain their current values.
Only product_live requirements allow these release fields; accepted products
require both to be nonnull, while proof_owed permits null to invalidate one.
All other requirement fields remain immutable under an existing ID.
These fields are structural custody only: B6's proof observer still decides
whether the referenced content qualifies on the current release.

On correction, append the new source UUID and replacement requirement ID in
the same task. Use corrections[{id,superseded_by:[replacement_id]}] only for
the specifically superseded prior IDs; preserve unrelated sources and parts.
Replacement IDs must exist and the combined replacement graph must be acyclic.
The wrapper merges under the existing task lock and verifies show --full;
an unconfirmed write or stale body preimage is a refusal, not an automatic retry.
Transfer, archive and relaunch retain the section rather than reinterpret it.
The helper validates structure and retained source custody only. A task Done,
an acknowledgement, or a syntactically accepted disposition never establishes
the qualified owner receipt and current proof required by B6.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

START = "```Owner request acceptance v1\n"
END = "\n```"
FIELDS = {"version", "origin_home", "origin_task_id", "sources", "requirements"}
SOURCE = {"session_id", "message_uuid", "file_ref", "source_custody", "full_text", "full_text_sha256"}
REQ = {"id", "kind", "source_message_uuid", "text_ref", "safe_text", "source_binding", "disposition", "proof_refs", "superseded_by", "proof_kind", "acceptance_level"}
PROOF_KINDS = {"product_live", "installed_generation", "observed_consumer", "artifact_delivery", "reply"}
LEVELS = {"source", "installed", "observed"}
PACKET = {"version", "origin_home", "origin_task_id", "expected_body_sha256", "interpretation_owner", "interpretation_complete", "sources", "requirements", "corrections"}
PROOF_UPDATE = {"id", "proof_refs", "disposition"}
PRODUCT_PROOF_UPDATE = {"fix_commit", "deployed_receipt_ref"}
REF = {"source_owner", "receipt_id", "content_sha256"}
HEX = re.compile(r"^[0-9a-f]{64}$")


class Invalid(ValueError):
    pass


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise Invalid("duplicate JSON field")
        result[key] = value
    return result


def read_json(raw):
    try:
        return json.loads(raw, object_pairs_hook=pairs)
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise Invalid("invalid JSON") from exc


def fields(value, required, label):
    if not isinstance(value, dict) or set(value) != required:
        raise Invalid(f"{label} has missing or unknown fields")


def slug(value, label):
    if not isinstance(value, str) or not value or any(c in value for c in "\r\n\0"):
        raise Invalid(f"{label} must be nonempty one-line text")


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def validate(metadata, task_id, home):
    fields(metadata, FIELDS, "acceptance")
    if type(metadata["version"]) is not int or metadata["version"] != 1 or metadata["origin_task_id"] != task_id:
        raise Invalid("acceptance identity mismatch")
    slug(metadata["origin_home"], "origin home")
    if not isinstance(metadata["sources"], list) or not isinstance(metadata["requirements"], list):
        raise Invalid("acceptance lists are malformed")
    if not metadata["sources"] or not metadata["requirements"]:
        raise Invalid("acceptance is empty")
    sources = {}
    for source in metadata["sources"]:
        fields(source, SOURCE, "source")
        for key in ("session_id", "message_uuid", "file_ref"):
            slug(source[key], key)
        uid = source["message_uuid"]
        if uid in sources:
            raise Invalid("duplicate source UUID")
        if source["source_custody"] == "complete":
            text = source["full_text"]
            if not isinstance(text, str) or not text or not isinstance(source["full_text_sha256"], str) or not HEX.fullmatch(source["full_text_sha256"]) or digest(text) != source["full_text_sha256"]:
                raise Invalid("complete source text or digest is invalid")
        elif source["source_custody"] == "restricted":
            if source["full_text"] is not None or source["full_text_sha256"] is not None:
                raise Invalid("restricted source carries copied text or hash")
        else:
            raise Invalid("source custody is unknown")
        sources[uid] = source
    ids = set()
    for req in metadata["requirements"]:
        if not isinstance(req, dict) or req.get("kind") not in ("action", "explanation"):
            raise Invalid("requirement kind is invalid")
        proof_kind = req.get("proof_kind")
        if not isinstance(proof_kind, str) or proof_kind not in PROOF_KINDS:
            raise Invalid("proof kind is unknown")
        expected_fields = set(REQ)
        if isinstance(req, dict) and req.get("kind") == "action":
            expected_fields.add("target_refs")
            expected_fields.update({
                "product_live": {"project", "outcome_ids", "fix_commit", "deployed_receipt_ref"},
                "installed_generation": {"expected_hosts"},
                "observed_consumer": {"consumer_targets"},
                "artifact_delivery": {"delivered_path"},
            }.get(proof_kind, set()))
        fields(req, expected_fields, "requirement")
        if not isinstance(req["acceptance_level"], str) or req["acceptance_level"] not in LEVELS:
            raise Invalid("proof kind or acceptance level is unknown")
        if req["kind"] == "explanation":
            if req["proof_kind"] != "reply":
                raise Invalid("explanation requires reply proof")
        else:
            if req["proof_kind"] == "reply" or not isinstance(req["target_refs"], list) or not req["target_refs"]:
                raise Invalid("action requires target references and action proof")
            for target in req["target_refs"]:
                slug(target, "target reference")
            if req["proof_kind"] == "product_live":
                slug(req["project"], "project")
                if not isinstance(req["outcome_ids"], list) or not req["outcome_ids"]:
                    raise Invalid("product outcomes are missing")
                for outcome in req["outcome_ids"]:
                    slug(outcome, "outcome ID")
                for key in ("fix_commit", "deployed_receipt_ref"):
                    if req[key] is not None:
                        slug(req[key], key)
            elif req["proof_kind"] in ("installed_generation", "observed_consumer"):
                key = "expected_hosts" if req["proof_kind"] == "installed_generation" else "consumer_targets"
                if not isinstance(req[key], list) or not req[key]:
                    raise Invalid("required host or consumer target is missing")
                for value in req[key]:
                    slug(value, key)
            elif req["proof_kind"] == "artifact_delivery":
                slug(req["delivered_path"], "delivered path")
        slug(req["id"], "requirement id")
        if req["id"] in ids:
            raise Invalid("duplicate requirement ID")
        ids.add(req["id"])
        slug(req["source_message_uuid"], "source message UUID")
        if req["source_message_uuid"] not in sources:
            raise Invalid("requirement source is invalid")
        if req["disposition"] not in ("pending", "proof_owed", "accepted", "superseded", "held"):
            raise Invalid("disposition is invalid")
        if req["source_binding"] == "verified_complete":
            source = sources[req["source_message_uuid"]]
            if source["source_custody"] != "complete" or not isinstance(req["text_ref"], str) or not req["text_ref"] or req["text_ref"] not in source["full_text"]:
                raise Invalid("complete binding cannot resolve archived text")
            if req["safe_text"] is not None:
                raise Invalid("complete binding has redundant safe text")
        elif req["source_binding"] == "verified_safe":
            if not isinstance(req["safe_text"], str) or not req["safe_text"]:
                raise Invalid("safe binding has no verified safe text")
            if req["text_ref"] is not None:
                raise Invalid("safe binding has unexpected text reference")
        elif req["source_binding"] == "restricted":
            if req["safe_text"] is not None or req["text_ref"] is not None or req["disposition"] not in ("pending", "held", "superseded"):
                raise Invalid("restricted binding cannot close")
        else:
            raise Invalid("binding is unknown")
        if not isinstance(req["proof_refs"], list) or not isinstance(req["superseded_by"], list):
            raise Invalid("requirement reference lists are malformed")
        for ref in req["proof_refs"]:
            fields(ref, REF, "proof reference")
            for key in ("source_owner", "receipt_id"):
                slug(ref[key], key)
            if not isinstance(ref["content_sha256"], str) or not HEX.fullmatch(ref["content_sha256"]):
                raise Invalid("proof digest is invalid")
        if req["disposition"] == "accepted":
            if not req["proof_refs"]:
                raise Invalid("accepted requirement lacks proof reference")
            if req["kind"] == "explanation" and not any(ref["source_owner"] == "reply" for ref in req["proof_refs"]):
                raise Invalid("accepted explanation lacks delivered reply reference")
            if req["proof_kind"] == "product_live" and (req["fix_commit"] is None or req["deployed_receipt_ref"] is None):
                raise Invalid("accepted product action lacks release references")
        if req["disposition"] == "superseded" and not req["superseded_by"]:
            raise Invalid("superseded requirement lacks replacement")
    for req in metadata["requirements"]:
        for replacement in req["superseded_by"]:
            slug(replacement, "superseding requirement")
            if replacement not in ids:
                raise Invalid("invalid superseding requirement")
    graph = {req["id"]: req["superseded_by"] for req in metadata["requirements"]}
    incoming = dict.fromkeys(graph, 0)
    for replacements in graph.values():
        for replacement in replacements:
            incoming[replacement] += 1
    ready = [key for key, count in incoming.items() if count == 0]
    visited = 0
    while ready:
        key = ready.pop()
        visited += 1
        for replacement in graph[key]:
            incoming[replacement] -= 1
            if incoming[replacement] == 0:
                ready.append(replacement)
    if visited != len(graph):
        raise Invalid("cyclic superseding requirements")


def section(body):
    if body.count(START) != 1:
        raise Invalid("acceptance section count is not one")
    first = body.index(START)
    end = body.find(END, first + len(START))
    if end < 0:
        raise Invalid("acceptance section is truncated")
    raw = body[first + len(START):end]
    if START in body[end + len(END):]:
        raise Invalid("duplicate acceptance section")
    return first, end + len(END), read_json(raw)


def encoded(metadata):
    return START + json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + END


def merge(body, packet, task_id, home, operation):
    if not isinstance(packet, dict) or not PACKET <= set(packet) or set(packet) - PACKET - {"proof_updates"}:
        raise Invalid("packet has missing or unknown fields")
    if type(packet["version"]) is not int or packet["version"] != 1 or packet["interpretation_complete"] is not True:
        raise Invalid("packet version or interpretation assertion is invalid")
    slug(packet["interpretation_owner"], "interpretation owner")
    if packet["origin_task_id"] != task_id:
        raise Invalid("packet task identity mismatch")
    proof_updates = packet.get("proof_updates", [])
    if (not isinstance(packet["sources"], list) or not isinstance(packet["requirements"], list)
            or not isinstance(packet["corrections"], list) or not isinstance(proof_updates, list)):
        raise Invalid("packet lists are malformed")
    if operation == "add" and proof_updates:
        raise Invalid("new task cannot update prior proof")
    if not packet["requirements"] and not proof_updates:
        raise Invalid("empty owner request packet")
    if operation == "add":
        if packet["expected_body_sha256"] is not None or START in body:
            raise Invalid("new task has stale or duplicate acceptance")
        current = {"version": 1, "origin_home": home, "origin_task_id": task_id, "sources": [], "requirements": []}
    else:
        expected = packet["expected_body_sha256"]
        if not isinstance(expected, str) or not HEX.fullmatch(expected):
            raise Invalid("expected body digest is malformed")
        stale = expected != digest(body)
        _, _, current = section(body)
        validate(current, task_id, home)
        if packet["origin_home"] != current["origin_home"] or packet["origin_task_id"] != current["origin_task_id"]:
            raise Invalid("packet changes immutable origin")
    if operation == "add" and packet["origin_home"] != home:
        raise Invalid("new task origin home mismatch")
    prior_sources = {item["message_uuid"]: item for item in current["sources"]}
    prior_requirements = {item["id"]: item for item in current["requirements"]}
    existing_requirement_ids = set(prior_requirements)
    for source in packet["sources"]:
        if not isinstance(source, dict) or "message_uuid" not in source:
            raise Invalid("malformed source")
        slug(source["message_uuid"], "source UUID")
        old = prior_sources.get(source["message_uuid"])
        if old is not None and old != source:
            raise Invalid("conflicting source UUID")
        if old is None:
            current["sources"].append(source)
            prior_sources[source["message_uuid"]] = source
    for req in packet["requirements"]:
        if not isinstance(req, dict) or "id" not in req:
            raise Invalid("malformed requirement")
        slug(req["id"], "requirement ID")
        old = prior_requirements.get(req["id"])
        if old is not None and old != req:
            raise Invalid("conflicting requirement ID")
        if old is None:
            current["requirements"].append(req)
            prior_requirements[req["id"]] = req
    for correction in packet["corrections"]:
        fields(correction, {"id", "superseded_by"}, "correction")
        slug(correction["id"], "corrected requirement")
        original = prior_requirements.get(correction["id"])
        replacements = correction["superseded_by"]
        if not isinstance(replacements, list) or not replacements:
            raise Invalid("ambiguous correction")
        for replacement in replacements:
            slug(replacement, "replacement requirement")
        if original is None or any(rep not in prior_requirements or rep == correction["id"] for rep in replacements):
            raise Invalid("ambiguous correction")
        if original["disposition"] == "superseded" and original["superseded_by"] == replacements:
            continue
        if original["disposition"] not in ("pending", "proof_owed", "held", "accepted") or original["superseded_by"]:
            raise Invalid("conflicting correction")
        original["disposition"] = "superseded"
        original["superseded_by"] = replacements
    corrected_ids = {item["id"] for item in packet["corrections"]}
    corrected_ids.update(replacement for item in packet["corrections"]
                         for replacement in item["superseded_by"])
    updated_ids = set()
    for update in proof_updates:
        if (not isinstance(update, dict) or not PROOF_UPDATE <= set(update)
                or set(update) - PROOF_UPDATE - PRODUCT_PROOF_UPDATE):
            raise Invalid("proof update has missing or unknown fields")
        slug(update["id"], "proof requirement ID")
        rid = update["id"]
        if rid in updated_ids or rid not in existing_requirement_ids or rid in corrected_ids:
            raise Invalid("proof update identity is ambiguous")
        updated_ids.add(rid)
        original = prior_requirements[rid]
        if original["proof_kind"] != "product_live" and set(update) & PRODUCT_PROOF_UPDATE:
            raise Invalid("release references require product proof")
        if original["disposition"] in ("held", "superseded") or original["superseded_by"]:
            raise Invalid("proof update cannot change held or superseded requirement")
        if update["disposition"] not in ("proof_owed", "accepted"):
            raise Invalid("proof update disposition is invalid")
        refs = update["proof_refs"]
        if not isinstance(refs, list):
            raise Invalid("proof update references are malformed")
        seen_refs = set()
        for ref in refs:
            fields(ref, REF, "proof reference")
            for key in ("source_owner", "receipt_id"):
                slug(ref[key], key)
            if not isinstance(ref["content_sha256"], str) or not HEX.fullmatch(ref["content_sha256"]):
                raise Invalid("proof digest is invalid")
            identity = (ref["source_owner"], ref["receipt_id"])
            if identity in seen_refs:
                raise Invalid("duplicate proof reference identity")
            seen_refs.add(identity)
        original["proof_refs"] = refs
        original["disposition"] = update["disposition"]
        for key in PRODUCT_PROOF_UPDATE:
            if key in update:
                original[key] = update[key]
    validate(current, task_id, home)
    if operation == "add":
        return body.rstrip("\n") + ("\n\n" if body.strip() else "") + encoded(current) + "\n"
    first, last, _ = section(body)
    candidate = body[:first] + encoded(current) + body[last:]
    if stale and candidate != body:
        raise Invalid("stale body preimage")
    return candidate


def shown_body(show, task_id):
    lines = show.splitlines()
    ids = [line[6:] for line in lines if line.startswith("  id: ")]
    values = [line[8:] for line in lines if line.startswith("  body: ")]
    if len(ids) != 1 or ids[0].strip('"') != task_id or len(values) != 1:
        raise Invalid("native show identity or body is missing")
    value = values[0]
    if value == "-":
        return ""
    decoded = read_json(value) if value.startswith('"') else value
    if not isinstance(decoded, str):
        raise Invalid("native body is malformed")
    return decoded


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("merge", "validate", "show-body", "compare-show", "validate-show", "compare-section"))
    parser.add_argument("--body-file")
    parser.add_argument("--packet-file")
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--home")
    parser.add_argument("--operation", choices=("add", "update"))
    args = parser.parse_args()
    try:
        if args.command in ("show-body", "compare-show", "validate-show"):
            body = shown_body(sys.stdin.read(), args.task_id)
            if args.command == "show-body":
                sys.stdout.write(body)
            elif args.command == "validate-show":
                validate(section(body)[2], args.task_id, args.home)
            else:
                expected = Path(args.body_file).read_text(encoding="utf-8")
                if body != expected.rstrip("\n"):
                    raise Invalid("native readback body mismatch")
                validate(section(body)[2], args.task_id, args.home)
        elif args.command == "compare-section":
            prior = Path(args.body_file).read_text(encoding="utf-8")
            candidate = Path(args.packet_file).read_text(encoding="utf-8")
            if START not in prior and START in candidate:
                raise Invalid("ordinary body edit cannot create bound acceptance")
            if START in prior:
                first, last, old = section(prior)
                validate(old, args.task_id, args.home)
                next_first, next_last, next_metadata = section(candidate)
                if candidate[next_first:next_last] != prior[first:last]:
                    raise Invalid("ordinary body edit changed protected acceptance")
                validate(next_metadata, args.task_id, args.home)
        elif args.command == "validate":
            body = Path(args.body_file).read_text(encoding="utf-8")
            validate(section(body)[2], args.task_id, args.home)
        else:
            body = Path(args.body_file).read_text(encoding="utf-8")
            packet = read_json(Path(args.packet_file).read_text(encoding="utf-8"))
            sys.stdout.write(merge(body, packet, args.task_id, args.home, args.operation))
    except (Invalid, OSError, UnicodeError) as exc:
        print(f"fm-request-acceptance: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
