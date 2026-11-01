#!/usr/bin/env python3
import json
import os
import re
import selectors
import shlex
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
            request_id = request.get("id", request.get("request_id"))
            if request_id is None:
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
                if response.get("type") == "control_response":
                    response = response["response"]
                if response.get("id", response.get("request_id")) == request_id:
                    if response.get("error") or response.get("success") is False:
                        raise ValueError("catalog query failed")
                    results.append(response.get("result", response.get("data", response.get("response"))))
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
               [m.get("id"), m.get("model"), m.get("selector"), *(m.get("aliases") or [])]]
    if len(matches) != 1:
        raise ValueError("model is not uniquely resolved by the catalog")
    return matches[0]


def resolve(harness, executable, wanted, context):
    if harness == "claude":
        argv = [executable, "--print", "--input-format", "stream-json", "--output-format",
                "stream-json", "--verbose", "--no-session-persistence"]
        if wanted:
            argv += ["--model", wanted]
        _, settings = rpc(argv, [
            {"type": "control_request", "request_id": "quota-init", "request": {"subtype": "initialize"}},
            {"type": "control_request", "request_id": "quota-settings", "request": {"subtype": "get_settings"}},
        ])
        return {"model": settings["applied"]["model"], "provider": settings["applied"].get("provider", "")}
    if harness in ("pi", "pi-signed", "omp"):
        argv = [executable, "--mode", "rpc", "--no-skills"]
        if harness != "omp":
            argv += ["--offline", "--no-prompt-templates", "--no-themes"]
        elif context.get("overlay"):
            argv += ["--config", context["overlay"]]
        if context.get("session"):
            argv += ["--session", context["session"]]
        else:
            argv += ["--no-session"]
        if context.get("provider"):
            argv += ["--provider", context["provider"]]
        if wanted:
            argv += ["--model", wanted]
        state, = rpc(argv, [{"id": "quota-model", "type": "get_state"}])
        model = state["model"]
        return {"model": model["provider"] + "/" + model["id"], "provider": model["provider"]}
    if harness == "codex":
        _, config, catalog = rpc([executable, "app-server"], [
            {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "firstmate-quota", "version": "1"}}},
            {"method": "initialized"},
            {"id": 2, "method": "config/read", "params": {"includeLayers": False, "cwd": os.getcwd()}},
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
    if harness in ("gemini", "rovo", "devin", "commandcode", "kimi"):
        argv = [executable, "--experimental-acp"] if harness == "gemini" else [executable, "acp"]
        if wanted:
            argv += ["--model", wanted]
        _, session = rpc(argv, [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1, "clientCapabilities": {}}},
            {"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": os.getcwd(), "mcpServers": []}},
        ])
        state = session["models"]
        models = [{**m, "id": m["modelId"]} for m in state["availableModels"]]
        model = select_model(models, state["currentModelId"])
        if harness == "kimi":
            catalog = json.loads(command([executable, "provider", "list", "--json"]))
            configured = catalog["models"][model["id"]]
            return {"model": configured["model"], "provider": configured["provider"], "selector":model["id"]}
        return {"model": model["id"], "provider": model.get("providerId", model.get("provider", ""))}
    if harness == "muse":
        _, catalog = rpc([executable, "serve"], [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "firstmate-quota", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "initialized", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "model/list", "params": {}},
        ])
        if catalog.get("source") == "unresolvedCatalog":
            raise ValueError("Muse catalog is unresolved")
        models = [{**m, "id": m["modelId"]} for m in catalog["models"]]
        default = next((m["id"] for m in models if m.get("isDefault")), None)
        model = select_model(models, wanted, default)
        return {"model": model["id"], "provider": model["providerId"]}
    if harness == "polytoken":
        catalog = json.loads(command([executable, "models", "--format", "json"]))
        models = catalog if isinstance(catalog, list) else catalog["models"]
        default = next((m["id"] for m in models if m.get("isDefault") or m.get("default")), None)
        model = select_model(models, wanted, default)
        return {"model": model.get("model", model["id"]), "provider": model.get("provider", ""), "selector":model["id"]}
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
                label = line.split("\t", 1)[1].strip() if "\t" in line else line.split(" - ", 1)[1].strip()
                models.append({"id": model, "aliases": [label]})
                if harness == "cursor" and "(default)" in line:
                    default = model
        if harness == "agy" and not wanted:
            path = os.path.expanduser("~/.gemini/antigravity-cli/settings.json")
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as handle:
                    default = json.load(handle).get("model")
            if not default:
                startup = command([executable, "--print", "--input-format", "stream-json", "--output-format", "stream-json"])
                for line in startup.splitlines():
                    event = json.loads(line)
                    if event.get("type") == "system" and event.get("subtype") == "init":
                        default = event.get("model")
        model = select_model(models, wanted, default)
        return {"model": model["id"], "provider": ""}
    raise ValueError("no non-generating catalog resolver for this adapter")


def launch_environment(harness, context):
    values = {"COMPACT_ADVISER_DISABLE":"1", "CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF":"1", "CLAUDE_CODE_DISABLE_AGENT_VIEW":"1"}
    unset = []
    raw = context.get("raw", False)
    if harness in ("claude", "codex", "opencode", "pi", "pi-signed", "grok", "kimi", "gemini", "muse", "rovo", "agy", "devin", "commandcode"):
        unset += ["CURSOR_AGENT", "CURSOR_INVOKED_AS", "GEMINI_CLI"]
    if not raw and harness in ("cursor", "omp", "agy", "gemini", "devin", "polytoken", "commandcode", "muse", "rovo"):
        unset += ["CLAUDECODE", "PI_CODING_AGENT", "GROK_AGENT", "FM_PI_HARNESS"]
    if not raw and harness in ("devin", "polytoken", "commandcode"):
        unset += ["FM_OMP_HARNESS", "ATLASSIAN_AGENT_TYPE", "ROVODEV_CLI"]
    if not raw and harness in ("omp", "polytoken"):
        unset += ["GEMINI_CLI", "CURSOR_AGENT", "CURSOR_INVOKED_AS"]
    if not raw and harness == "cursor":
        unset += ["GEMINI_CLI", "CURSOR_INVOKED_AS"]
    if not raw and harness in ("devin", "commandcode"):
        unset += ["NO_COLOR"]
    if not raw and harness == "claude":
        values.update(CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false", CLAUDE_CODE_SEND_FEEDBACK="0")
    if not raw and harness == "commandcode":
        values["COLORTERM"] = "truecolor"
    if not raw and harness == "polytoken":
        unset += ["AGENT"]
    if harness in ("pi", "pi-signed"):
        values["FM_PI_HARNESS"] = harness
    if not raw and harness == "omp":
        values.update(FM_OMP_HARNESS="omp", OMP_SKIP_SETUP="1")
    if not raw and harness == "gemini":
        values["GEMINI_CLI_TRUST_WORKSPACE"] = "true"
        if context.get("state") and context.get("id"):
            values["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = os.path.join(os.path.realpath(context["state"]), context["id"] + ".gemini-settings.json")
    if not raw and harness == "muse":
        values.update(XDG_CONFIG_HOME=os.path.abspath(context.get("muse_config") or os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")),
                      XDG_DATA_HOME=os.path.abspath(context.get("muse_data") or os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")),
                      MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL="on")
    if not raw and harness == "opencode":
        config = {"permission":{"*":"allow"}}
        model, effort = context.get("model", ""), context.get("effort", "")
        provider = model.split("/", 1)[0]
        if ((provider == "anthropic" and effort in ("high", "max")) or
                (provider == "openai" and effort in ("low", "medium", "high", "xhigh"))):
            config["agent"] = {"build":{"model":model, "variant":effort}}
        values["OPENCODE_CONFIG_CONTENT"] = json.dumps(config, separators=(",", ":"))
    pin = context.get("pin", "")
    if pin:
        _, root, _ = pin.split("\t")
        if harness == "claude":
            unset += context.get("claude_shed", "").split()
            if root:
                values["CLAUDE_CONFIG_DIR"] = root
            else:
                unset += ["CLAUDE_CONFIG_DIR"]
        elif harness in ("pi", "pi-signed"):
            values["PI_CODING_AGENT_DIR"] = root
    elif harness == "claude" or raw:
        if os.environ.get("CLAUDE_CONFIG_DIR"):
            values["CLAUDE_CONFIG_DIR"] = os.environ["CLAUDE_CONFIG_DIR"]
        else:
            unset += ["CLAUDE_CONFIG_DIR"]
    if os.environ.get("DISABLE_AUTOUPDATER"):
        values["DISABLE_AUTOUPDATER"] = os.environ["DISABLE_AUTOUPDATER"]
    return {"set":values, "unset":sorted(set(unset) - values.keys()),
            "clear_prefixes":["ORCA_", "FM_"] if harness == "polytoken" and not raw else [],
            "keep":["FM_TASK_ID", "FM_TASK_INBOX", "FM_ZELLIJ_SESSION"] if harness == "polytoken" else []}


def apply_environment(environment):
    for key in list(os.environ):
        if key in environment["unset"] or (key not in environment["keep"] and
                any(key.startswith(prefix) for prefix in environment["clear_prefixes"])):
            os.environ.pop(key, None)
    os.environ.update(environment["set"])


def environment_prefix(environment):
    parts = []
    if environment["clear_prefixes"]:
        patterns = "|".join(prefix + "*" for prefix in environment["clear_prefixes"])
        keep = "|".join(environment["keep"])
        parts.append("for _fmv in $(env | cut -d= -f1); do case $_fmv in " + patterns +
                     ") case $_fmv in " + keep + ") ;; *) unset \"$_fmv\" ;; esac ;; esac; done;")
    if environment["unset"]:
        parts.append("unset " + " ".join(environment["unset"]) + ";")
    if environment["set"]:
        parts.append("export " + " ".join(key + "=" + shlex.quote(value) for key, value in environment["set"].items()) + ";")
    return " ".join(parts)


def describe(harness, wanted, context):
    context = {**context, "model":wanted}
    if context.get("pin"):
        context["provider"] = context["pin"].split("\t")[2]
    if harness == "omp" and not context.get("overlay"):
        context["overlay"] = os.path.join(context.get("root") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".omp/fm-worker-overlay.yml")
    return {"launch_env":launch_environment(harness, {**context, "model":wanted}),
            "launch_selector":wanted, "quota_identity":None,
            "native_model_ref":context.get("model_ref") if harness == "polytoken" else None,
            "launch_context":context}


def main():
    if sys.argv[1] == "--environment":
        print(environment_prefix(json.loads(sys.argv[2])["launch_env"]))
        return 0
    if sys.argv[1] == "--model-flag":
        record = json.loads(sys.argv[2])
        selector = record.get("native_model_ref") or record["launch_selector"]
        print("--model '" + selector.replace("'", "'\\''") + "' " if selector else "", end="")
        return 0
    if sys.argv[1] == "--describe":
        harness, wanted, context = sys.argv[2:]
        print(json.dumps(describe(harness, "" if wanted == "default" else wanted, json.loads(context))))
        return 0
    harness, executable, wanted, cwd = sys.argv[1:5]
    context = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
    wanted = "" if wanted == "default" else wanted
    fixture = os.environ.get("FM_QUOTA_MODEL_CATALOG_FILE") if os.environ.get("FM_TEST_SEAM") == "1" else None
    record = describe(harness, wanted, context)
    context = record["launch_context"]
    os.chdir(cwd)
    apply_environment(record["launch_env"])
    try:
        if fixture:
            with open(fixture, encoding="utf-8") as handle:
                entries = json.load(handle).get(harness, [])
            result = select_model(entries, wanted, next((m["id"] for m in entries if m.get("default")), None))
            result = {"model":result.get("model", result["id"]), "provider":result.get("provider", ""),
                      "selector":result.get("selector", result["id"])}
        else:
            result = resolve(harness, executable, wanted, context)
        if not result["model"]:
            raise ValueError("catalog returned no effective model")
        record.update(launch_selector=result.get("selector", result["model"]), quota_identity={"model":result["model"], "provider":result["provider"]})
        print(json.dumps(record))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({**record, "error":str(error)}))
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({"error":str(error)}))
        sys.exit(1)
