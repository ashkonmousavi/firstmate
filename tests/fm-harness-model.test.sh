#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-model)
FM_QUOTA_MODEL_CATALOG_FILE='' python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
vendor = scratch / "vendor"
vendor.write_text('''#!/usr/bin/env python3
import json
import os
import sys
h = os.environ["CATALOG_ADAPTER"]
wanted = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else ""
if wanted == "absent":
    sys.exit(1)
if h == "opencode":
    print(json.dumps({"model":"account/model-v1"}) if "debug" in sys.argv else "account/model-v1")
    sys.exit()
if h == "polytoken":
    assert sys.argv[1:] == ["models", "--format", "json"]
    print(json.dumps({"models":[{"id":"model-v1", "aliases":["alias"], "provider":"account", "isDefault":True}]}))
    sys.exit()
if h in ("cursor", "agy"):
    print("model-v1\\tModel V1" if h == "agy" else "model-v1 - Model V1 (default)")
    sys.exit()
if h == "kimi" and sys.argv[1:4] == ["provider", "list", "--json"]:
    print(json.dumps({"models":{"kimi-alias":{"model":"model-v1", "provider":"account"}}}))
    sys.exit()
if h in ("pi", "pi-signed", "omp"):
    if os.environ.get("EXPECT_CONTEXT"):
        assert sys.argv[sys.argv.index("--provider") + 1] == "account"
        assert sys.argv[sys.argv.index("--session") + 1] == os.environ["EXPECT_SESSION"]
        assert "--no-session" not in sys.argv
    else:
        assert "--no-session" in sys.argv
    if h == "omp":
        assert sys.argv[sys.argv.index("--config") + 1] == os.environ["EXPECT_OVERLAY"]
for line in sys.stdin:
    req = json.loads(line)
    if "request_id" in req:
        assert h == "claude"
        kind = req["request"]["subtype"]
        assert kind in ("initialize", "get_settings")
        result = {} if kind == "initialize" else {"applied":{"model":"model-v1", "provider":"account"}}
        print(json.dumps({"type":"control_response", "response":{"request_id":req["request_id"],"subtype":"success","response":result}}), flush=True)
        continue
    if "id" not in req:
        continue
    method = req.get("method", req.get("type"))
    if method == "initialize":
        result = {}
    elif method == "get_state":
        result = {"model":{"provider":"account", "id":"model-v1"}}
    elif method == "config/read":
        assert req["params"]["cwd"] == os.getcwd()
        result = {"config":{"model":"model-v1", "model_provider":"account"}}
    elif method == "model/list":
        if h == "codex":
            result = {"data":[{"id":"alias", "model":"model-v1", "isDefault":True}]}
        else:
            result = {"models":[{"modelId":"model-v1", "aliases":["alias"], "providerId":"account", "isDefault":True}]}
    elif method in ("session/new", "_x.ai/models/list"):
        if method == "session/new":
            assert req["params"]["cwd"] == os.getcwd()
            assert req["params"]["mcpServers"] == []
        mid = "kimi-alias" if h == "kimi" else "model-v1"
        state = {"currentModelId":mid, "availableModels":[{"modelId":mid, "providerId":"account", "provider":"account", "aliases":["alias"]}]}
        result = {"models":state} if method == "session/new" else {"modelState":state}
    else:
        raise AssertionError("catalog probe sent a generating or unsupported operation: " + str(req))
    if "type" in req:
        response = {"id":req["id"], "success":True, "data":result}
    else:
        response = {"id":req["id"], "result":result}
    print(json.dumps(response), flush=True)
''')
vendor.chmod(0o755)
context = {"overlay": str(scratch / "worker.yml")}
settings = scratch / "home/.gemini/antigravity-cli/settings.json"
settings.parent.mkdir(parents=True)
settings.write_text(json.dumps({"model":"Model V1"}))
adapters = "claude codex opencode pi pi-signed grok kimi cursor omp agy gemini muse rovo devin commandcode polytoken".split()
for harness in adapters:
    env = dict(os.environ, HOME=str(scratch / "home"), CATALOG_ADAPTER=harness, EXPECT_OVERLAY=context["overlay"])
    canonical = "account/model-v1" if harness in ("pi", "pi-signed", "omp", "opencode") else "model-v1"
    selections = ["", canonical]
    if harness not in ("cursor", "agy", "opencode"):
        selections += ["alias"]
    for selection in selections:
        run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                              str(vendor), selection, str(scratch), json.dumps(context)],
                             env=env, capture_output=True, text=True)
        assert run.returncode == 0, (harness, selection, run.stdout, run.stderr)
        actual = json.loads(run.stdout)
        assert actual["model"] == canonical, (harness, selection, actual)
        if harness not in ("cursor", "agy"):
            assert actual["provider"] == "account", (harness, actual)
    run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                          str(vendor), "absent", str(scratch), json.dumps(context)],
                         env=env, capture_output=True, text=True)
    assert run.returncode != 0, (harness, "accepted an unresolved model")
for harness in ("pi", "pi-signed"):
    resume = {"provider":"account", "session": str(scratch / "saved.jsonl")}
    env = dict(os.environ, CATALOG_ADAPTER=harness, EXPECT_CONTEXT="1", EXPECT_SESSION=resume["session"])
    run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                          str(vendor), "account/model-v1", str(scratch), json.dumps(resume)],
                         env=env, capture_output=True, text=True)
    assert run.returncode == 0, (harness, run.stdout, run.stderr)
print("ok - all 16 adapters resolve native defaults and explicit models without generating; catalog aliases, Codex cwd and Pi provider/session arguments follow vendor contracts")
PY
