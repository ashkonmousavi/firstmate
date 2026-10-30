#!/usr/bin/env python3
"""Send one pane.scroll request to a Herdr control socket.

The herdr CLI has no scroll subcommand, so Firstmate's composer reads use this
helper to put a pane's viewport back at the bottom (offset 0) before trusting a
visible capture. It sends only the ``pane.scroll`` method for an exact pane id
and a non-negative offset; it never types into the pane.

Schema verified against Herdr 0.9.5 (``herdr api schema --json``,
PaneScrollParams: required pane_id and offset_from_bottom, a uint64):

  request:  {"id":"fm-pane-scroll","method":"pane.scroll",
             "params":{"pane_id":P,"offset_from_bottom":N}}\n
  response: {"id":"fm-pane-scroll","result":{...}}\n

Usage: herdr-pane-scroll.py <socket_path> <pane_id> <offset_from_bottom>

Exit status:
  0  the server answered the matching request without an error;
  2  arguments or socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
REQUEST_ID = "fm-pane-scroll"


def _read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv):
    if len(argv) != 4:
        return 2
    socket_path, pane_id, raw_offset = argv[1:]
    if not socket_path.startswith("/") or not pane_id:
        return 2
    if any(char in pane_id for char in "\t\r\n"):
        return 2
    try:
        offset = int(raw_offset)
    except ValueError:
        return 2
    if offset < 0 or str(offset) != raw_offset:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "pane.scroll",
        "params": {"pane_id": pane_id, "offset_from_bottom": offset},
    }
    try:
        sock.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
    except OSError:
        return 3

    line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    if (
        not isinstance(response, dict)
        or response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or not isinstance(response.get("result"), dict)
    ):
        return 4
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
