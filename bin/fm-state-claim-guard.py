#!/usr/bin/env python3
"""Claude Stop state-claim check; stdin is the original Stop JSON payload.

Called by fm-turnend-guard.sh --claude --state-claims after primary scoping.
Exit 2 names unsupported claims on stderr; all other paths allow silently.
No network, subprocess, model, or durable marker is used. stop_hook_active
bounds this check to one block. Unreadable, malformed, oversized or incomplete
transcripts fail open. Only the last 2 MiB are read, and a real user message
must establish the current turn inside that window (tool results do not).
The Stop payload owns final text because transcript writes may lag Stop.

POLICY is the single claim-to-read table. This is a lexical reminder, not a
proof of the remote state: it requires a completed matching tool command,
not that the command output supports the prose. 'last read at' exempts only
its sentence. Shell commands are tokenized, never executed.
"""

import json
import os
import re
import shlex
import stat
import sys
import time


def rx(pattern):
    return re.compile(pattern, re.I)


POLICY = (
    ("PR", rx(r"\b(?:in (?:the )?(?:merge )?queue|queued|merged)\b"), None,
     rx(r"^(?:gh|gh-axi)\s+(?:pr\s+(?:view|checks)\b|api\s+.*\S*/pulls(?:/|\b))")),
    ("deploy", rx(r"\b(?:deployed|live)\b"), None,
     rx(r"^curl\s+.*https?://")),
    ("lane", rx(r"\brunning\b"),
     rx(r"\b(?:lane|worker|crew|scout|mate|task|supervisor|watcher|agent)\b"),
     rx(r"^(?:fm-crew-state\.sh|fm-crew-state)(?:\s|$)")),
)
MAX_BYTES = 2 * 1024 * 1024
PR_ID = rx(r"(?:\bpr\s*#?\s*|/pull/)(\d+)\b")


def claims(text):
    text = re.sub(r"```.*?(?:```|$)", "", text, flags=re.S)
    text = text.replace("`", "")
    for sentence in re.split(r"[\n]|(?<=[.!?])\s+", text):
        if rx(r"^\s*example\s*:").search(sentence):
            continue
        if rx(r"\blast read at\b").search(sentence):
            continue
        for family, words, context, _ in POLICY:
            if context and not context.search(sentence):
                continue
            for match in words.finditer(sentence):
                before = sentence[max(0, match.start() - 60):match.start()]
                after = sentence[match.end():match.end() + 25]
                # Descriptions, conditions, questions and explicit negation do
                # not assert a current state. Keep these exceptions local.
                if rx(r"\b(?:not|never|isn't|aren't|wasn't|isn’t|aren’t|wasn’t|will|would|should|could|if|whether)\b").search(before):
                    continue
                if sentence.rstrip().endswith("?"):
                    continue
                if family == "deploy" and match.group().lower() == "live" and rx(
                    r"^[- ](?:check|read|proof|test|guard|state|evidence|URL|before)\b"
                ).search(after):
                    continue
                yield family, sentence.strip(), set(PR_ID.findall(sentence))
                break


def read_commands(command, deadline):
    """Recognize executable reads, not quoted examples or write subcommands."""
    if len(command) > 16384 or "<<" in command:
        return
    tokens = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    tokens.whitespace = " \t\r"
    tokens.whitespace_split = True
    segment = []
    for token in [*tokens, ";"]:
        if time.monotonic() > deadline:
            return
        if token and all(c in ";&|()\n" for c in token):
            if segment:
                while segment and (re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", segment[0]) or segment[0] == "env"):
                    segment.pop(0)
                if segment and os.path.basename(segment[0]) in ("bash", "sh"):
                    segment.pop(0)
                if segment:
                    segment[0] = os.path.basename(segment[0])
                    # gh's global repository/host flags can precede 'pr'.
                    if segment[0] in ("gh", "gh-axi"):
                        while len(segment) > 2 and segment[1] in ("-R", "--repo", "--hostname"):
                            del segment[1:3]
                    normalized = " ".join(segment)
                    for family, _, _, reads in POLICY:
                        if reads.search(normalized):
                            # Requests with a write verb or body are not reads.
                            if any(t in ("--data", "--form", "--field", "--raw-field", "--input", "--upload-file")
                                   or t.startswith(("-d", "-F", "-T", "--data=", "--data-", "--form=", "--field=", "--raw-field=", "--input=", "--upload-file="))
                                   or (family == "PR" and t.startswith("-f")) for t in segment):
                                continue
                            if any(t in ("-X", "--method", "--request") and segment[i + 1:i + 2] not in (["GET"], ["HEAD"])
                                   for i, t in enumerate(segment)):
                                continue
                            if any((t.startswith("-X") and len(t) > 2 and t[2:] not in ("GET", "HEAD"))
                                   or (t.startswith(("--method=", "--request=")) and t.split("=", 1)[1] not in ("GET", "HEAD"))
                                   for t in segment):
                                continue
                            yield family, normalized
            segment = []
        else:
            segment.append(token)


def current_reads(path, deadline):
    # O_NONBLOCK prevents a malicious/accidental FIFO transcript from hanging
    # the Stop hook. The fstat also rejects directories and device streams.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            return None
        offset = max(0, info.st_size - MAX_BYTES)
        stream.seek(offset)
        data = stream.read(MAX_BYTES)
    if offset:
        data = data.partition(b"\n")[2]
    pending, completed, boundary = {}, [], False
    for line in data.splitlines():
        if time.monotonic() > deadline:
            return None
        row = json.loads(line)
        if not isinstance(row, dict):
            return None
        message = row.get("message", {})
        if not isinstance(message, dict):
            continue
        content = message.get("content", [])
        if row.get("type") == "user":
            if isinstance(content, str) or (isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "text" for b in content
            )):
                pending, completed, boundary = {}, [], True
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if row.get("type") == "assistant" and block.get("type") == "tool_use" and block.get("name") == "Bash":
                command = block.get("input", {}).get("command")
                if isinstance(command, str):
                    pending[block.get("id")] = command
            elif row.get("type") == "user" and block.get("type") == "tool_result":
                command = pending.pop(block.get("tool_use_id"), None)
                # A pending `gh pr checks` exits nonzero but still reads the
                # forge. This guard checks read presence, not output truth.
                if command:
                    completed.extend(read_commands(command, deadline))
    return completed if boundary else None


def main():
    deadline = time.monotonic() + 0.12
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        return 0
    payload = json.loads(raw)
    if not isinstance(payload, dict) or payload.get("stop_hook_active") is not False:
        return 0
    text = payload.get("last_assistant_message")
    if not isinstance(text, str) or len(text) > 65536:
        return 0
    if payload.get("hook_event_name") != "Stop" or "/.pi/" in payload.get("transcript_path", ""):
        return 0
    unsupported = list(claims(text))
    if not unsupported:
        return 0
    reads = current_reads(payload["transcript_path"], deadline)
    if reads is None or time.monotonic() > deadline:
        return 0
    for family, sentence, pr_ids in unsupported:
        matching = [command for kind, command in reads if kind == family]
        if pr_ids:
            if not all(any(re.search(
                r"(?:^|\s)#?" + ident + r"(?=\s|$)|/pulls?/" + ident + r"(?=[/?#\s]|$)", command
            ) for command in matching) for ident in pr_ids):
                matching = []
        if not matching:
            print(f"State claim needs a same-turn read ({family}): {sentence[:300]}\n"
                  "Read that state now, correct the claim, or qualify it with 'last read at'. "
                  "This claim check blocks only once.", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        # Transcript/input uncertainty must never hold a supervisor's turn.
        sys.exit(0)
