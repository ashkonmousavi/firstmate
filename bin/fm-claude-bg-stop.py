"""Remove one Claude session and verify its session-owned processes stop.

Usage: python3 fm-claude-bg-stop.py <short-id> <timeout> <session-json>.
Capture ownership before rm deletes the session: inherited session UUIDs survive
respawn and reparenting; transcript continued-in records connect handoff forks.
Never infer ownership from a process name, cwd, or shared supervisor alone.
"""

import ctypes
import errno
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def processes():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,stat=,lstart="], check=True,
        capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"},
    )
    return {
        int(pid): (int(parent), state, started)
        for line in result.stdout.splitlines()
        for pid, parent, state, started in [line.split(None, 3)]
    }


def process_env(pid):
    try:
        if sys.platform == "linux":
            raw = Path(f"/proc/{pid}/environ").read_bytes()
        elif sys.platform == "darwin":
            # KERN_PROCARGS2 supplies NUL-separated argv and environment,
            # preserving account paths containing spaces (ps -E does not).
            libc = ctypes.CDLL(None, use_errno=True)
            mib = (ctypes.c_int * 3)(1, 49, pid)
            size = ctypes.c_size_t()
            if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0):
                raise OSError(ctypes.get_errno(), "sysctl KERN_PROCARGS2")
            buf = ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0):
                raise OSError(ctypes.get_errno(), "sysctl KERN_PROCARGS2")
            raw = buf.raw[:size.value]
            argc = int.from_bytes(raw[:4], sys.byteorder)
            pos = raw.index(b"\0", 4) + 1  # executable path and padding
            while pos < len(raw) and raw[pos] == 0:
                pos += 1
            for _ in range(argc):
                pos = raw.index(b"\0", pos) + 1
            raw = raw[pos:]
        else:
            raise RuntimeError("session process ownership requires Linux or macOS")
        return dict(
            entry.decode(errors="surrogateescape").split("=", 1)
            for entry in raw.split(b"\0") if b"=" in entry
        )
    except OSError as error:
        # Other users' protected processes and processes that exited mid-read
        # cannot supply this account's inherited session identity.
        if error.errno in (errno.ENOENT, errno.ESRCH, errno.EACCES, errno.EPERM):
            return {}
        raise


def account_root(env):
    return Path(env.get("CLAUDE_CONFIG_DIR") or Path(env.get("HOME", str(Path.home()))) / ".claude").resolve()


def session_family(session, account):
    if not isinstance(session.get("sessionId"), str) or not re.fullmatch(r"[A-Za-z0-9_-]+", session["sessionId"]):
        raise RuntimeError("session has no valid full session identity")
    family = {session["sessionId"]}
    cwd = Path(session["cwd"])
    edges = []
    for directory in {str(cwd), str(cwd.resolve())}:
        project = account / "projects" / re.sub(r"[^a-zA-Z0-9]", "-", directory)
        for transcript in project.glob("*.jsonl"):
            with transcript.open() as source:
                for line in source:
                    if '"continued-in"' not in line:
                        continue
                    row = json.loads(line)
                    if row.get("type") == "continued-in":
                        edges.append((row.get("sessionId"), row.get("continuedInSessionId")))
    while True:
        parents = {parent for parent, child in edges if child in family and isinstance(parent, str)}
        if parents <= family:
            return family
        family.update(parents)


def live(snapshot, owned):
    return [pid for pid, started in owned.items()
            if pid in snapshot and snapshot[pid][2] == started
            and not snapshot[pid][1].startswith("Z")]


def refresh(owned, family, account):
    snapshot = processes()
    for pid, (_, state, started) in snapshot.items():
        if state.startswith("Z"):
            continue
        env = process_env(pid)
        if env.get("CLAUDE_CODE_SESSION_ID") in family and account_root(env) == account:
            owned[pid] = started
    # Descendants can clear their environment or create new process groups.
    # Only still-matching parent identities may establish new ownership.
    roots = set(live(snapshot, owned))
    while True:
        children = {pid: started for pid, (parent, state, started) in snapshot.items()
                    if parent in roots and pid not in roots and not state.startswith("Z")}
        if not children:
            break
        owned.update(children)
        roots.update(children)
    if os.getpid() in roots or os.getppid() in roots:
        raise RuntimeError("session contains the cleanup process")
    return live(snapshot, owned)


def stop():
    session_id, timeout, serialized = sys.argv[1:]
    session = json.loads(serialized)
    account = account_root(os.environ)
    family = session_family(session, account)
    owned = {}
    refresh(owned, family, account)
    subprocess.run(
        ["claude", "rm", session_id], timeout=float(timeout), check=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for sig in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            remaining = refresh(owned, family, account)
            if not remaining:
                return
            for pid in remaining:
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
            time.sleep(0.05)
    remaining = refresh(owned, family, account)
    if remaining:
        raise RuntimeError(f"session {session_id} left carried processes running: {remaining}")


if __name__ == "__main__":
    try:
        stop()
    except (OSError, ValueError, KeyError, RuntimeError, StopIteration, subprocess.SubprocessError) as error:
        sys.exit(f"Claude background cleanup failed: {error}")
