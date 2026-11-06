"""Token-free installed-Codex MCP startup proof using captured spawn arguments."""
import json
import os
from pathlib import Path
import queue
import shlex
import signal
import subprocess
import sys
import threading
import time


def mcp_fixture():
    name, marker = sys.argv[2:4]
    with open(marker, "a") as receipt:
        receipt.write(str(os.getpid()) + "\n")
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        if method == "initialize":
            result = {
                "protocolVersion": request["params"]["protocolVersion"],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": name, "version": "1.0"},
            }
        elif method == "tools/list":
            result = {"tools": [{"name": "identity", "inputSchema": {"type": "object"}}]}
        elif method == "ping":
            result = {}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {
                "code": -32601, "message": "Unsupported fixture method"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def check_startup(binary, profile, case, launch_file):
    case = Path(case)
    case.mkdir(parents=True, exist_ok=True)
    config_home = case / "codex-home"
    config_home.mkdir()
    # Only static argv from the emitted launch is read; no brief is evaluated.
    raw = Path(launch_file).read_text().split("codex ", 1)[1].split('"$(', 1)[0]
    args = shlex.split(raw)
    overrides = []
    for i, arg in enumerate(args[:-1]):
        if arg in ("-c", "--config") and args[i + 1].startswith("mcp_servers."):
            overrides.extend([arg, args[i + 1]])
    names = {"gitnexus", "claude-context", "retained"}
    config = ['check_for_update_on_startup = false', 'approval_policy = "never"']
    for name in sorted(names):
        config.extend([
            f'[mcp_servers."{name}"]',
            f'command = {json.dumps(sys.executable)}',
            f'args = {json.dumps([str(Path(__file__).resolve()), "mcp", name, str(case / (name + ".pid"))])}',
        ])
    (config_home / "config.toml").write_text("\n".join(config) + "\n")
    expected = names if profile == "product-code" else {"retained"}
    messages = queue.Queue()
    version = subprocess.check_output([binary, "--version"], text=True).strip()
    stderr = open(case / "stderr.log", "w")
    process = subprocess.Popen(
        [binary, *overrides, "app-server", "--stdio"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
        text=True, cwd=case,
        env={**os.environ, "CODEX_HOME": str(config_home), "HOME": str(case)},
        start_new_session=True,
    )
    known_pids = set()

    def reader():
        for line in process.stdout:
            messages.put(json.loads(line))
        messages.put(None)

    threading.Thread(target=reader, daemon=True).start()
    sequence = 0

    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def rpc(method, params):
        nonlocal sequence
        sequence += 1
        target = sequence
        send({"id": target, "method": method, "params": params})
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
            assert message is not None, "app-server exited before response"
            if message.get("id") == target:
                assert "error" not in message, message
                return message["result"]
        raise AssertionError(f"timeout waiting for {method}")

    try:
        rpc("initialize", {"clientInfo": {"name": "firstmate_lane_profile_guard", "version": "1.0"}})
        send({"method": "initialized", "params": {}})
        thread = rpc("thread/start", {"cwd": str(case), "ephemeral": True})["thread"]["id"]
        deadline = time.monotonic() + 45
        states = {}
        while time.monotonic() < deadline:
            status = rpc("mcpServerStatus/list", {"threadId": thread, "limit": 100})
            assert not status.get("nextCursor"), "fixture inventory unexpectedly paginated"
            states = {row["name"]: row for row in status["data"]}
            connected = {name for name, row in states.items() if row.get("tools")}
            if expected <= connected:
                # The native inventory is a startup barrier when runtime status
                # is available; otherwise require every configured enabled peer
                # to have completed the tool handshake before reading processes.
                pending = [row for row in states.values() if row.get("runtimeStatus") in ("starting", "notStarted")]
                if not pending:
                    break
            time.sleep(0.05)
        else:
            raise AssertionError(f"MCP startup did not complete: {states}")
        observed = set()
        for name in sorted(names):
            marker = case / (name + ".pid")
            if not marker.exists():
                continue
            for receipt in marker.read_text().splitlines():
                pid = int(receipt)
                known_pids.add(pid)
                readback = subprocess.run(["ps", "-p", str(pid), "-o", "pid=,ppid=,comm="], text=True, capture_output=True)
                if readback.returncode:
                    continue
                assert readback.stdout.split()[0] == str(pid), readback.stdout
                observed.add(name)
                print(f"process-readback {profile} {name}: {readback.stdout.strip()}", flush=True)
        print("native-runtime " + json.dumps({k: v.get("runtimeStatus") for k, v in states.items()}), flush=True)
        assert observed == expected, f"{version} {profile}: processes {observed}, expected {expected}"
        assert connected == expected, f"{version} {profile}: initialized servers {connected}, expected {expected}"
        print(f"ok - {version} {profile}: {','.join(sorted(observed))}; no model turn submitted", flush=True)
    finally:
        # These are this guard's exact process IDs, never a shared daemon or
        # another session's namespace. The app-server owns its MCP children.
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for name in names:
            marker = case / (name + ".pid")
            if marker.exists():
                known_pids.update(int(value) for value in marker.read_text().splitlines())
        for pid in known_pids:
            identity = subprocess.run(["ps", "-p", str(pid), "-o", "args="], text=True, capture_output=True)
            if str(Path(__file__).resolve()) not in identity.stdout or str(case) not in identity.stdout:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        stderr.close()


if __name__ == "__main__":
    if sys.argv[1] == "mcp":
        mcp_fixture()
    else:
        check_startup(*sys.argv[1:])
