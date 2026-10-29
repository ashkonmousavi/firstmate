import json
import os
import signal
import subprocess
import sys
import time


def processes():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,stat=,lstart="],
        check=True, capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"},
    )
    return {
        int(pid): (int(parent), state, started)
        for line in result.stdout.splitlines()
        for pid, parent, state, started in [line.split(None, 3)]
    }


def live(snapshot, owned):
    return [
        pid for pid, started in owned.items()
        if pid in snapshot and snapshot[pid][2] == started
        and not snapshot[pid][1].startswith("Z")
    ]


def stop():
    session_id, timeout = sys.argv[1:]
    session = next(row for row in json.load(sys.stdin) if row.get("id") == session_id)
    root = session.get("pid")
    if type(root) is not int or root <= 1:
        raise RuntimeError(f"session {session_id} has no live process identity")
    snapshot = processes()
    if root not in snapshot:
        raise RuntimeError(f"session {session_id} process {root} disappeared before ownership capture")
    owned = {root: snapshot[root][2]}
    while True:
        children = {
            pid: started for pid, (parent, state, started) in snapshot.items()
            if parent in owned and pid not in owned
        }
        if not children:
            break
        owned.update(children)
    if os.getpid() in owned or os.getppid() in owned:
        raise RuntimeError(f"session {session_id} contains the cleanup process")
    for pid in live(processes(), owned):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    subprocess.run(
        ["claude", "stop", session_id], timeout=float(timeout), check=False,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for sig in (None, signal.SIGKILL):
        remaining = live(processes(), owned)
        if sig:
            for pid in remaining:
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 1
        while remaining and time.monotonic() < deadline:
            time.sleep(0.05)
            remaining = live(processes(), owned)
        if not remaining:
            return
    raise RuntimeError(f"session {session_id} left processes running: {remaining}")


if __name__ == "__main__":
    try:
        stop()
    except (OSError, ValueError, RuntimeError, StopIteration, subprocess.SubprocessError) as error:
        sys.exit(f"Claude background cleanup failed: {error}")
