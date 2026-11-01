#!/usr/bin/env python3
"""Opt-in Codex folders: selection, quota, duplicate guard and watcher checks.

Usage: fm-codex-accounts.py {select,quota,guard,check,maintain,prepare,register,preflight} --help
The config is one literal absolute folder per line, no comments or empty lines.
Absent config opts out; a present invalid/empty list fails closed. Folder aliases
and auth symlinks/hardlinks refuse. The guard compares file metadata and the
runner's reported account identity, never reading credential contents itself.
Missing auth is allowed in the list but cannot win. The runner's local status
is not a network validation.

quota-axi >=0.1.66 --profile-only supplies one redacted reading per folder without
refresh, cache or fallback. Applicable exhausted quota excludes a folder before
fresh main weekly ranking; unknown ranks below measured, with lexical folder
order breaking ties. All vendor output is
captured; only allowlisted quota fields escape this process.

check is silent when healthy; stale file age (six days) is a maintenance warning,
not an expiry timestamp. Revocation cannot be predicted. maintain explicitly runs
the official weekly normal-exec pattern; it never runs login/logout or a refresh
endpoint. register creates per-folder checks using fm-check-register.sh, never a
timer. prepare links only named non-auth configuration into an existing folder;
it refuses conflicting destinations and never overwrites them.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time


SCRIPT = Path(__file__).resolve()
SHARED = ("config.toml", "AGENTS.md", "rules", "skills", "AGENTS.override.md")
REQUIRED = SHARED[:3]


def folders(config):
    if not Path(config).is_file():
        raise ValueError(f"codex-accounts must be a readable regular file: {config}")
    try:
        body = Path(config).read_bytes().decode("utf-8")
    except OSError:
        raise ValueError(f"cannot read codex-accounts: {config}") from None
    roots = body.removesuffix("\n").split("\n")
    if not roots or any(not r.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in r)
                        for r in roots):
        raise ValueError(f"codex-accounts needs literal absolute folders, one per line: {config}")
    resolved = []
    for root in roots:
        p = Path(root)
        if not p.is_dir() or not os.access(p, os.R_OK | os.X_OK):
            raise ValueError(f"codex-accounts folder is unavailable: {root}")
        resolved.append(str(p.resolve()))
    if len(set(resolved)) != len(roots):
        raise ValueError("codex-accounts contains duplicate folders or aliases")
    return sorted(resolved)


def guard(roots, codex):
    seen = {}
    accounts = {}
    for root in roots:
        p = Path(root) / "auth.json"
        try:
            info = p.stat(follow_symlinks=False)
        except FileNotFoundError:
            continue
        except OSError:
            raise ValueError(f"cannot inspect independent sign-in in folder: {root}") from None
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError(f"sign-in must be an independent regular file: {root}")
        for identity in (("inode", info.st_dev, info.st_ino), ("stamp", info.st_size, info.st_mtime_ns)):
            if identity in seen:
                raise ValueError(f"duplicate sign-in files in folders: {seen[identity]} and {root}")
            seen[identity] = root
        account = account_identity(root, codex)
        if account is not None:
            if account in accounts:
                raise ValueError(f"duplicate Codex account in folders: {accounts[account]} and {root}")
            accounts[account] = root


def clean_env(root):
    env = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME") if k in os.environ}
    env["CODEX_HOME"] = root
    return env


def stop_vendor(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


@contextmanager
def vendor_process(args, root, **options):
    process = None
    interrupted = None

    def cancel(signum, frame):
        nonlocal interrupted
        interrupted = signum
        if process is not None:
            stop_vendor(process)

    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in handlers:
            signal.signal(sig, cancel)
        with subprocess.Popen(args, env=clean_env(root), start_new_session=True, **options) as process:
            try:
                if interrupted is not None:
                    raise SystemExit(128 + interrupted)
                yield process
            finally:
                stop_vendor(process)
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        if interrupted is not None:
            raise SystemExit(128 + interrupted)


def run_vendor(args, root, seconds=10, cwd=None):
    try:
        with vendor_process(args, root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=cwd) as process:
            stdout, stderr = process.communicate(timeout=seconds)
            return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    except (OSError, subprocess.TimeoutExpired):
        return None


def signed_in(root, codex):
    result = run_vendor([codex, "-c", 'cli_auth_credentials_store="file"', "login", "status"], root)
    return result is not None and result.returncode == 0


def app_server_read(root, codex, method, params):
    try:
        with vendor_process([codex, "-c", 'cli_auth_credentials_store="file"', "app-server"], root,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
            deadline = time.monotonic() + 10
            process.stdin.write(json.dumps({"id": 0, "method": "initialize", "params": {
                "clientInfo": {"name": "firstmate_account_guard", "version": "1"}}}).encode() + b"\n")
            process.stdin.flush()
            pending = b""
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while time.monotonic() < deadline:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        return None
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        return None
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        message = json.loads(line)
                        if message.get("id") == 0:
                            if "error" in message:
                                return None
                            process.stdin.write(json.dumps({"method": "initialized", "params": {}}).encode() + b"\n")
                            process.stdin.write(json.dumps({"id": 1, "method": method,
                                                            "params": params}).encode() + b"\n")
                            process.stdin.flush()
                        elif message.get("id") == 1:
                            result = message.get("result")
                            return result if isinstance(result, dict) else None
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return None


def account_identity(root, codex):
    result = app_server_read(root, codex, "account/read", {"refreshToken": False})
    account = (result or {}).get("account") or {}
    email = account.get("email")
    if account.get("type") == "chatgpt" and isinstance(email, str) and email.strip():
        return email.strip().casefold()
    return None


def effective_model(root, codex, model, cwd):
    if model and model != "default":
        return model
    result = app_server_read(root, codex, "config/read", {"includeLayers": False, "cwd": cwd})
    if result is None:
        raise ValueError(f"cannot resolve Codex launch model for folder: {root}")
    model = result.get("config", {}).get("model")
    if model is None:
        catalog = app_server_read(root, codex, "model/list", {"includeHidden": True})
        defaults = [m.get("model") for m in (catalog or {}).get("data", []) if m.get("isDefault") is True]
        model = defaults[0] if len(defaults) == 1 else None
    if not isinstance(model, str) or not model or model == "default" or any(ord(c) < 32 or ord(c) == 127 for c in model):
        raise ValueError(f"cannot resolve Codex launch model for folder: {root}")
    return model


def shared_ready(root):
    p = Path(root)
    if not ((p / "config.toml").is_file() and (p / "AGENTS.md").is_file() and (p / "rules").is_dir()):
        return False
    # Codex follows a linked rules directory but ignores linked .rules files.
    rules = list((p / "rules").glob("*.rules"))
    return bool(rules) and all(r.is_file() and not r.is_symlink() for r in rules)


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 100


def reading(root):
    result = run_vendor(["quota-axi", "--provider", "codex", "--profile-only",
                         "--no-credential-refresh", "--full", "--json"], root)
    try:
        data = json.loads(result.stdout) if result is not None and result.returncode == 0 else {}
        row, = [r for r in data.get("providers", []) if r.get("provider") == "codex"]
        # Never expose vendor diagnostics, account identity, sources or raw payload.
        fresh = row.get("state", {}).get("status") == "fresh"
        windows = [{"id": w["id"], "kind": "weekly", "percentRemaining": w["percentRemaining"]}
                   for w in row.get("windows", []) if w.get("id") == "weekly" and
                   w.get("kind") == "weekly" and number(w.get("percentRemaining"))] if fresh else []
        semantic = row.get("quotaSemantics", {})
        bounds = []
        for b in semantic.get("effectiveAvailability", []) if fresh else []:
            if not isinstance(b.get("scope"), str):
                continue
            item = {"scope": b["scope"], "status": "unknown"}
            if b.get("runway", {}).get("status") == "exhausted_now":
                item["runway"] = {"status": "exhausted_now"}
            if b.get("status") == "known" and number(b.get("effectivePercentRemaining")):
                item.update(status="known", effectivePercentRemaining=b["effectivePercentRemaining"])
                item["runway"] = {k: v for k, v in b.get("runway", {}).items() if k in (
                    "status", "projectionConfidence", "usableRunwaySeconds", "projectedExhaustedAt")}
                item["selection"] = {k: v for k, v in b.get("selection", {}).items()
                                     if k in ("status", "spendPriority")}
            bounds.append(item)
        status = semantic.get("status") if fresh else "unknown"
        if status not in ("known", "partial", "unknown"):
            status = "unknown"
        return {"generatedAt": data.get("generatedAt"),
                "state": {"status": "fresh" if fresh else "unavailable"}, "windows": windows,
                "quotaSemantics": {"status": status, "effectiveAvailability": bounds}}
    except (ValueError, TypeError, KeyError, AttributeError):
        return {"state": {"status": "unavailable"}, "windows": [],
                "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}}


def quota_usable(row, model):
    bare = model.rsplit("/", 1)[-1]
    scopes = {"all_models", "all_products"}
    if bare:
        scopes.update(("model:" + bare, "product:" + bare))
    return not any(b["scope"] in scopes and (
        b.get("runway", {}).get("status") == "exhausted_now" or
        (b.get("status") == "known" and b.get("effectivePercentRemaining") == 0))
        for b in row["quotaSemantics"]["effectiveAvailability"])


def preflight(roots, codex):
    guard(roots, codex)
    if not any(signed_in(root, codex) and shared_ready(root) and quota_usable(reading(root), "")
               for root in roots):
        raise ValueError("codex-accounts has no usable signed-in folder with shared configuration")


def snapshot(roots, codex, model, cwd):
    guard(roots, codex)
    rows = []
    for root in roots:
        ready = signed_in(root, codex)
        configured = ready and shared_ready(root)
        launch_model = effective_model(root, codex, model, cwd) if configured else ""
        row = reading(root) if ready else {"state": {"status": "unavailable"}, "windows": [],
                                           "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}}
        row.update(provider="codex", accountKey="codex-folder:" + hashlib.sha256(root.encode()).hexdigest()[:16],
                   accountLocator={"kind": "codex-home", "path": root}, signedIn=ready,
                   model=launch_model, launchReady=configured and quota_usable(row, launch_model))
        rows.append(row)
    usable = [r for r in rows if r["launchReady"]]
    def rank(row):
        weekly = row["windows"]
        return weekly[0]["percentRemaining"] if len(weekly) == 1 else -1
    # rows already have deterministic lexical order, including for equal room.
    winner = max(usable, key=rank) if usable else None
    return {"schemaVersion": 6, "providers": rows,
            "selectedRoot": winner["accountLocator"]["path"] if winner else None}


def require_winner(data):
    if not data["selectedRoot"]:
        raise ValueError("codex-accounts has no usable signed-in folder with config.toml, AGENTS.md and rules; no default fallback")
    return data["selectedRoot"]


def check(root, roots, codex):
    guard(roots, codex)
    if not signed_in(root, codex):
        raise ValueError(f"Codex folder is not locally signed in: {root}")
    if not shared_ready(root):
        raise ValueError(f"Codex folder is missing shared configuration: {root}")
    try:
        age = time.time() - (Path(root) / "auth.json").stat().st_mtime
    except OSError:
        raise ValueError(f"Codex file-backed sign-in is missing: {root}") from None
    if age < 0 or age >= 6 * 86400:
        raise ValueError(f"Codex folder needs maintenance (file age is not token expiry): {root}")


def prepare(root, shared):
    root, shared = Path(root).resolve(), Path(shared).resolve()
    if not root.is_dir() or not shared.is_dir() or root == shared:
        raise ValueError("prepare needs distinct existing account and shared configuration folders")
    links = [(root / name, shared / name) for name in SHARED if (shared / name).exists()]
    if not shared_ready(shared):
        raise ValueError("shared configuration needs config.toml, AGENTS.md and real .rules files in rules/")
    for dest, src in links:
        if os.path.lexists(dest) and not (dest.is_symlink() and dest.resolve() == src.resolve()):
            raise ValueError(f"prepare refuses existing configuration: {dest}")
    for dest, src in links:
        if not os.path.lexists(dest):
            dest.symlink_to(src, target_is_directory=src.is_dir())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("select", "quota", "guard", "check", "maintain", "prepare", "register", "preflight"))
    parser.add_argument("--config", help="absolute codex-accounts list")
    parser.add_argument("--folder", help="one configured folder (or prepare destination)")
    parser.add_argument("--shared", help="prepare: shared non-auth configuration folder")
    parser.add_argument("--state", help="register: existing Firstmate state directory")
    parser.add_argument("--codex", default="codex", help="Codex executable")
    parser.add_argument("--model", default="", help="literal launch model for applicable quota scopes")
    parser.add_argument("--cwd", default=os.getcwd(), help="launch directory for effective project configuration")
    parser.add_argument("--gate", action="store_true", help="quota: return selected row as codex-home for the launch quota gate")
    args = parser.parse_args()
    if args.command == "prepare":
        if not args.folder or not args.shared:
            parser.error("prepare requires --folder and --shared")
        prepare(args.folder, args.shared)
        return
    if not args.config or not Path(args.config).is_absolute():
        parser.error("an absolute --config is required")
    roots = folders(args.config)
    if args.command == "guard":
        guard(roots, args.codex)
    elif args.command == "preflight":
        preflight(roots, args.codex)
    elif args.command in ("select", "quota"):
        cwd = str(Path(args.cwd).resolve())
        if not Path(cwd).is_dir():
            raise ValueError(f"Codex launch directory is unavailable: {cwd}")
        data = snapshot(roots, args.codex, args.model, cwd)
        if args.folder:
            root = str(Path(args.folder).resolve())
            if not any(r["launchReady"] and r["accountLocator"]["path"] == root for r in data["providers"]):
                raise ValueError("codex-accounts preselected folder is no longer usable; no fallback")
            data["selectedRoot"] = root
        if args.command == "select":
            root = require_winner(data)
            selected = next(r for r in data["providers"] if r["accountLocator"]["path"] == root)
            print(f"{root}\t{root}\t{selected['model']}")
        else:
            if args.gate:
                root = require_winner(data)
                data["providers"] = [r for r in data["providers"] if r["accountLocator"]["path"] == root]
                data["providers"][0]["accountKey"] = "codex-home"
                data["generatedAt"] = data["providers"][0].get("generatedAt")
                data["selectedModel"] = data["providers"][0]["model"]
            print(json.dumps(data, allow_nan=False))
    elif args.command == "register":
        state_dir = Path(args.state or "")
        if not args.state or not state_dir.is_dir() or state_dir.is_symlink():
            parser.error("register requires an existing --state directory")
        for root in roots:
            ident = "codex-account-" + hashlib.sha256(root.encode()).hexdigest()[:16]
            dest = state_dir / f"{ident}.check.sh"
            command = shlex.join(["python3", str(SCRIPT), "check", "--config", str(Path(args.config).resolve()),
                                  "--folder", root, "--codex", args.codex])
            # Re-registration is explicit and refuses a different existing check.
            body = f"#!/usr/bin/env bash\n{command}\n"
            if os.path.lexists(dest) and (dest.is_symlink() or dest.read_text() != body):
                raise ValueError(f"register refuses an existing different check: {dest}")
            if not dest.exists():
                with dest.open("x") as stream:
                    stream.write(body)
                dest.chmod(0o700)
            env = dict(os.environ, FM_STATE_OVERRIDE=str(state_dir))
            subprocess.run(["bash", str(SCRIPT.with_name("fm-check-register.sh")), ident], env=env, check=True)
    else:
        root = str(Path(args.folder or "").resolve())
        if not args.folder or root not in roots:
            parser.error("--folder must name a configured account folder")
        if args.command == "check":
            check(root, roots, args.codex)
        else:
            guard(roots, args.codex)
            if not signed_in(root, args.codex) or not shared_ready(root):
                raise ValueError(f"maintenance needs a configured signed-in folder: {root}")
            with tempfile.TemporaryDirectory(prefix="fm-codex-maintenance-") as scratch:
                result = run_vendor([args.codex, "exec", "--skip-git-repo-check", "--json",
                                     "--sandbox", "read-only", "-c", 'approval_policy="never"',
                                     "-c", 'cli_auth_credentials_store="file"',
                                     "Reply with the single word OK. Do not use tools."], root, 120, scratch)
            if result is None or result.returncode != 0:
                raise ValueError(f"Codex maintenance failed; request/refresh needs attention: {root}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
