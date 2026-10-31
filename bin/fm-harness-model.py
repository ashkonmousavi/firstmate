#!/usr/bin/env python3
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time


def rpc(argv, requests):
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 15
    results = []
    pending = b""
    try:
        for request in requests:
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            if "id" not in request:
                continue
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError("catalog query timed out")
                while b"\n" not in pending:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        raise TimeoutError("catalog query timed out")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise ValueError("catalog query ended without a response")
                    pending += chunk
                line, pending = pending.split(b"\n", 1)
                try:
                    response = json.loads(line)
                except ValueError:
                    continue
                if response.get("id") == request["id"]:
                    if response.get("error") or response.get("success") is False:
                        raise ValueError("catalog query failed")
                    results.append(response.get("result", response.get("data")))
                    break
        return results
    finally:
        selector.close()
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def command(argv):
    return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, timeout=15, check=True).stdout


def select_model(models, wanted, default=None):
    wanted = wanted or default
    matches = [m for m in models if wanted and wanted in
               [m.get("id"), m.get("model"), m.get("selector"), *m.get("aliases", [])]]
    if len(matches) != 1:
        raise ValueError("model is not uniquely resolved by the catalog")
    return matches[0]


def resolve(harness, executable, wanted):
    if harness in ("pi", "pi-signed"):
        argv = [executable, "--mode", "rpc", "--no-session", "--offline",
                "--no-skills", "--no-prompt-templates", "--no-themes"]
        if wanted:
            argv += ["--model", wanted]
        state, = rpc(argv, [{"id": "quota-model", "type": "get_state"}])
        model = state["model"]
        return {"model": model["provider"] + "/" + model["id"], "provider": model["provider"]}
    if harness == "codex":
        _, config, catalog = rpc([executable, "app-server"], [
            {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "firstmate-quota", "version": "1"}}},
            {"method": "initialized"},
            {"id": 2, "method": "config/read", "params": {"includeLayers": False}},
            {"id": 3, "method": "model/list", "params": {"limit": 1000}},
        ])
        config = config["config"]
        models = catalog["data"]
        default = config.get("model") or next((m.get("model") for m in models if m.get("isDefault")), None)
        model = select_model(models, wanted, default)
        return {"model": model["model"], "provider": config.get("model_provider") or "openai"}
    if harness == "grok":
        _, catalog = rpc([executable, "agent", "stdio"], [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1, "clientCapabilities": {}}},
            {"jsonrpc": "2.0", "id": 2, "method": "_x.ai/models/list", "params": {}},
        ])
        catalog = catalog.get("result", catalog)
        state = catalog.get("modelState", catalog)
        models = [{**m, "id": m["modelId"]} for m in state["availableModels"]]
        model = select_model(models, wanted, state.get("currentModelId"))
        return {"model": model["id"], "provider": model.get("provider", "")}
    if harness == "omp":
        catalog = json.loads(command([executable, "models", "--json"]))
        model = select_model(catalog["models"], wanted, catalog.get("defaultModel"))
        return {"model": model["selector"], "provider": model["provider"]}
    if harness == "opencode":
        config = json.loads(command([executable, "debug", "config"]))
        models = []
        for line in command([executable, "models"]).splitlines():
            if "/" in line and len(line.split()) == 1:
                provider, model = line.split("/", 1)
                models.append({"id": model, "selector": line, "provider": provider})
        model = select_model(models, wanted, config.get("model"))
        return {"model": model["selector"], "provider": model["provider"]}
    if harness in ("cursor", "agy"):
        listing = command([executable, "--list-models"] if harness == "cursor" else [executable, "models"])
        listing = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", listing)
        models = []
        default = None
        for line in listing.splitlines():
            if " - " in line or "\t" in line:
                model = line.split()[0]
                models.append({"id": model})
                if "(default)" in line:
                    default = model
        model = select_model(models, wanted, default)
        return {"model": model["id"], "provider": ""}
    raise ValueError("no non-generating catalog resolver for this adapter")


def main():
    harness, executable, wanted, cwd = sys.argv[1:]
    os.chdir(cwd)
    wanted = "" if wanted == "default" else wanted
    fixture = os.environ.get("FM_QUOTA_MODEL_CATALOG_FILE") if os.environ.get("FM_TEST_SEAM") == "1" else None
    if fixture:
        with open(fixture, encoding="utf-8") as handle:
            entries = json.load(handle).get(harness, [])
        result = select_model(entries, wanted, next((m["id"] for m in entries if m.get("default")), None))
        result = {"model": result.get("model", result["id"]), "provider": result.get("provider", "")}
    else:
        result = resolve(harness, executable, wanted)
    if not result["model"]:
        raise ValueError("catalog returned no effective model")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
