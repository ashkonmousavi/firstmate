#!/usr/bin/env python3
"""fm-walk-marker.py - claim or release one walk in the shared walk marker.

Usage (run on the host and account that own the marker, usually piped through a
transport as `python3 - <args>`; see bin/fm-grok-bot-dispatch.sh --walk):
  fm-walk-marker.py claim <walk> <owner> <seconds>
  fm-walk-marker.py release <walk> <owner>

The marker is $XDG_STATE_HOME/q-walk/in-progress.json (default
~/.local/state/q-walk/in-progress.json), the file every restart path on that
host reads before stopping a service:
  {"walks": ["<walk id>", ...], "started": "<UTC>", "expires_at": "<UTC>", "owner": "<id>"}
Times are %Y-%m-%dT%H:%M:%SZ. The claim holds restarts while now < expires_at.

claim: an absent or expired marker is replaced by this walk, started now and
  expiring <seconds> later. An active marker of the same owner gains the walk
  and keeps the earlier start and the later expiry. An already active walk,
  another owner's active marker, or a malformed or non-regular marker is refused.
release: removes only this walk from a marker of this owner, deleting the file
  when no walk remains; the remaining claim keeps its expiry. An absent marker
  or one no longer listing the walk is already released. Another owner's or a
  malformed marker is left untouched and refused.

Times come from this host's clock (FM_WALK_MARKER_NOW overrides it for tests),
so the start never lies ahead of the readers' clock.
Output: one JSON line. Exit 0 done, 1 refused (marker left as found), 2 usage.
Standard library only.
"""

import datetime as dt
import fcntl
import json
import os
import re
import sys
from pathlib import Path

FORMAT = "%Y-%m-%dT%H:%M:%SZ"
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")


class Refused(Exception):
    pass


def parse(text):
    return dt.datetime.strptime(text, FORMAT).replace(tzinfo=dt.timezone.utc)


def stamp(moment):
    return moment.strftime(FORMAT)


def now():
    fixed = os.environ.get("FM_WALK_MARKER_NOW")
    return parse(fixed) if fixed else dt.datetime.now(dt.timezone.utc)


def marker_path():
    home = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    if not os.path.isabs(home):
        raise Refused("XDG_STATE_HOME must be absolute")
    return Path(home) / "q-walk" / "in-progress.json"


def read(path):
    """The valid marker, None when absent; Refused when it cannot be trusted."""
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise Refused(f"{path} is not a regular file; its owner must check it")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise Refused(f"{path} is unreadable or malformed; its owner must check it ({exc})") from None
    try:
        walks, owner = data["walks"], data["owner"]
        if (not isinstance(walks, list) or not walks or not all(isinstance(w, str) and w.strip() for w in walks)
                or not isinstance(owner, str) or not owner.strip()):
            raise ValueError("walks or owner")
        if parse(data["expires_at"]) <= parse(data["started"]):
            raise ValueError("interval")
    except (KeyError, TypeError, ValueError) as exc:
        raise Refused(f"{path} is malformed; its owner must check it ({exc})") from None
    return data


def write(path, data):
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(json.dumps(data) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def claim(path, walk, owner, seconds):
    at = now()
    current = read(path)
    expires = (at + dt.timedelta(seconds=seconds)).replace(microsecond=0)
    if at.microsecond:
        expires += dt.timedelta(seconds=1)
    if current and at < parse(current["expires_at"]):
        if current["owner"] != owner:
            raise Refused(f"walk marker held by {current['owner']} for {', '.join(current['walks'])} "
                          f"until {current['expires_at']}")
        if walk in current["walks"]:
            raise Refused(f"walk {walk} is already active until {current['expires_at']}")
        expires = max(parse(current["expires_at"]), expires)
        walks = current["walks"] + [walk]
        data = {**current, "walks": walks, "expires_at": stamp(expires)}
    else:
        data = {"walks": [walk], "started": stamp(at), "expires_at": stamp(expires),
                "owner": owner}
    write(path, data)
    return {"result": "claimed", **data}


def release(path, walk, owner):
    current = read(path)
    if current is None:
        return {"result": "absent"}
    if current["owner"] != owner:
        raise Refused(f"walk marker now held by {current['owner']}; {walk} is not released by {owner}")
    if walk not in current["walks"]:
        return {"result": "not-listed", **current}
    walks = [w for w in current["walks"] if w != walk]
    if not walks:
        path.unlink()
        return {"result": "cleared"}
    data = {**current, "walks": walks}
    write(path, data)
    return {"result": "released", **data}


def main(argv):
    op = argv[0] if argv else ""
    if not ((op == "claim" and len(argv) == 4 and argv[3].isdigit() and int(argv[3]) > 0)
            or (op == "release" and len(argv) == 3)) or not all(ID.fullmatch(x) for x in argv[1:3]):
        print(json.dumps({"error": "usage: claim <walk> <owner> <seconds> | release <walk> <owner>"}))
        return 2
    try:
        path = marker_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path.parent / ".in-progress.lock", "a", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = claim(path, argv[1], argv[2], int(argv[3])) if op == "claim" else release(path, argv[1], argv[2])
    except (Refused, OSError) as exc:
        print(json.dumps({"result": "refused", "reason": str(exc)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
