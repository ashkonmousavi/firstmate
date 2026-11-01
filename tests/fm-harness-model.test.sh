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
import shlex
import sys

root, scratch = map(Path, sys.argv[1:])
vendor = scratch / "vendor"
vendor.write_text('''#!/usr/bin/env python3
import json
import os
import sys
h = os.environ["CATALOG_ADAPTER"]
keys = json.loads(os.environ.get("ENV_CAPTURE_KEYS", "[]"))
actual_env = {key:os.environ.get(key) for key in keys}
if "--launch-check" in sys.argv:
    selector = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else ""
    if h == "kimi":
        assert selector == "kimi-code/k3", "Kimi requires its configured alias"
    print(json.dumps({"env":actual_env,"selector":selector}))
    sys.exit()
if os.environ.get("ENV_CAPTURE_FILE"):
    with open(os.environ["ENV_CAPTURE_FILE"], "w") as handle:
        json.dump(actual_env, handle)
wanted = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else ""
if wanted == "absent":
    sys.exit(1)
if h == "opencode":
    print(json.dumps({"model":"account/model-v1"}) if "debug" in sys.argv else "account/model-v1")
    sys.exit()
if h == "polytoken":
    assert sys.argv[1:] == ["models", "--format", "json"]
    print(json.dumps({"models":[{"id":"model-v1", "model":"upstream-v1", "aliases":["alias"], "provider":"account", "isDefault":True}]}))
    sys.exit()
if h in ("cursor", "agy"):
    print("model-v1\\tModel V1" if h == "agy" else "model-v1 - Model V1 (default)")
    sys.exit()
if h == "kimi" and sys.argv[1:4] == ["provider", "list", "--json"]:
    print(json.dumps({"models":{"kimi-code/k3":{"model":"k3", "provider":"account"}}}))
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
        mid = "kimi-code/k3" if h == "kimi" else "model-v1"
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
context = {"overlay":str(scratch / "worker.yml"), "state":str(scratch / "state"), "id":"task",
           "effort":"high", "muse_config":str(scratch / "muse-config"), "muse_data":str(scratch / "muse-data")}
keys = "CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS FM_OMP_HARNESS GEMINI_CLI CURSOR_AGENT CURSOR_INVOKED_AS ATLASSIAN_AGENT_TYPE ROVODEV_CLI AGENT NO_COLOR COLORTERM OMP_SKIP_SETUP GEMINI_CLI_TRUST_WORKSPACE GEMINI_CLI_SYSTEM_SETTINGS_PATH XDG_CONFIG_HOME XDG_DATA_HOME MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL OPENCODE_CONFIG_CONTENT COMPACT_ADVISER_DISABLE CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF CLAUDE_CODE_DISABLE_AGENT_VIEW CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CODE_SEND_FEEDBACK ORCA_NATIVE_TEST FM_NATIVE_TEST FM_TASK_ID".split()
settings = scratch / "home/.gemini/antigravity-cli/settings.json"
settings.parent.mkdir(parents=True)
settings.write_text(json.dumps({"model":"Model V1"}))
adapters = "claude codex opencode pi pi-signed grok kimi cursor omp agy gemini muse rovo devin commandcode polytoken".split()
for harness in adapters:
    env = dict(os.environ, **{key:"inherited-sentinel" for key in keys})
    env.update(HOME=str(scratch / "home"), CATALOG_ADAPTER=harness, EXPECT_OVERLAY=context["overlay"],
               ENV_CAPTURE_KEYS=json.dumps(keys), ENV_CAPTURE_FILE=str(scratch / "probe-env.json"))
    canonical = "account/model-v1" if harness in ("pi", "pi-signed", "omp", "opencode") else "model-v1"
    if harness == "kimi":
        canonical = "k3"
    if harness == "polytoken":
        canonical = "upstream-v1"
    selector = "kimi-code/k3" if harness == "kimi" else "model-v1" if harness == "polytoken" else canonical
    selections = ["", selector]
    if harness not in ("cursor", "agy", "opencode"):
        selections += ["alias"]
    for selection in selections:
        run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                              str(vendor), selection, str(scratch), json.dumps(context)],
                             env=env, capture_output=True, text=True)
        assert run.returncode == 0, (harness, selection, run.stdout, run.stderr)
        record = json.loads(run.stdout)
        actual = record["quota_identity"]
        assert actual["model"] == canonical, (harness, selection, actual)
        assert record["launch_selector"] == selector, (harness, record)
        if harness not in ("cursor", "agy"):
            assert actual["provider"] == "account", (harness, actual)
        prefix = subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"), "--environment", json.dumps(record)], text=True)
        flags = subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"), "--model-flag", json.dumps(record)], text=True)
        assert shlex.split(flags) == ["--model", selector], (harness, flags)
        launch = subprocess.run(["bash", "-c", prefix + " " + shlex.quote(str(vendor)) + " --launch-check " + flags],
                                env=env, capture_output=True, text=True, check=True)
        launched = json.loads(launch.stdout)
        assert launched["env"] == json.loads((scratch / "probe-env.json").read_text()), (harness, launched)
        assert launched["selector"] == selector, (harness, launched)
        for key in ("COMPACT_ADVISER_DISABLE", "CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF", "CLAUDE_CODE_DISABLE_AGENT_VIEW"):
            assert launched["env"][key] == "1", (harness, key)
        if harness == "gemini":
            assert launched["env"]["GEMINI_CLI_TRUST_WORKSPACE"] == "true"
            assert launched["env"]["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] == str(scratch / "state/task.gemini-settings.json")
        if harness in ("pi", "pi-signed"):
            assert launched["env"]["FM_PI_HARNESS"] == harness
        if harness == "omp":
            assert launched["env"]["OMP_SKIP_SETUP"] == "1" and launched["env"]["FM_OMP_HARNESS"] == "omp"
        if harness == "muse":
            assert launched["env"]["XDG_CONFIG_HOME"] == context["muse_config"]
            assert launched["env"]["MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL"] == "on"
        if harness == "polytoken":
            assert launched["env"]["ORCA_NATIVE_TEST"] is None and launched["env"]["FM_NATIVE_TEST"] is None
            assert launched["env"]["FM_TASK_ID"] == "inherited-sentinel"
    print("ok - " + harness + ": probe environment equals launch environment and printed model equals its catalog selector")
    run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                          str(vendor), "absent", str(scratch), json.dumps(context)],
                         env=env, capture_output=True, text=True)
    assert run.returncode != 0, (harness, "accepted an unresolved model")

for harness in adapters:
    raw_context = {**context, "raw":1}
    record = json.loads(subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"),
                        "--describe", harness, "", json.dumps(raw_context)], text=True))
    prefix = subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"), "--environment", json.dumps(record)], text=True)
    env = dict(os.environ, **{key:"inherited-sentinel" for key in keys}, CATALOG_ADAPTER=harness, ENV_CAPTURE_KEYS=json.dumps(keys))
    launch = subprocess.check_output(["bash", "-c", prefix + " " + shlex.quote(str(vendor)) + " --launch-check --model kimi-code/k3"], env=env, text=True)
    actual = json.loads(launch)["env"]
    assert actual["COMPACT_ADVISER_DISABLE"] == "1", (harness, actual)
    if harness in ("pi", "pi-signed"):
        assert actual["FM_PI_HARNESS"] == harness, actual
    if harness in ("claude", "codex", "opencode", "pi", "pi-signed", "grok", "kimi", "gemini", "muse", "rovo", "agy", "devin", "commandcode"):
        assert actual["CURSOR_AGENT"] is None and actual["GEMINI_CLI"] is None, (harness, actual)
    assert actual["GEMINI_CLI_TRUST_WORKSPACE"] == "inherited-sentinel", (harness, actual)
    assert actual["OPENCODE_CONFIG_CONTENT"] == "inherited-sentinel", (harness, actual)
    assert actual["ORCA_NATIVE_TEST"] == "inherited-sentinel", (harness, actual)
poly_context = {**context, "model_ref":"model-v1(high)"}
record = json.loads(subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"),
                    "--describe", "polytoken", "model-v1", json.dumps(poly_context)], text=True))
flags = subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"), "--model-flag", json.dumps(record)], text=True)
assert record["launch_selector"] == "model-v1" and shlex.split(flags) == ["--model", "model-v1(high)"], record
fixture = scratch / "kimi-catalog.json"
fixture.write_text(json.dumps({"kimi":[{"id":"kimi-code/k3","model":"k3","provider":"account","default":True}]}))
run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), "kimi", str(vendor), "", str(scratch), json.dumps(context)],
                     env=dict(os.environ, FM_TEST_SEAM="1", FM_QUOTA_MODEL_CATALOG_FILE=str(fixture)), capture_output=True, text=True, check=True)
record = json.loads(run.stdout)
assert record["launch_selector"] == "kimi-code/k3" and record["quota_identity"]["model"] == "k3", record
variant = subprocess.check_output([sys.executable, str(root / "bin/fm-harness-model.py"), "--describe", "opencode", "anthropic/opus", json.dumps(context)], text=True)
assert json.loads(json.loads(variant)["launch_env"]["set"]["OPENCODE_CONFIG_CONTENT"]) == {
    "permission":{"*":"allow"}, "agent":{"build":{"model":"anthropic/opus", "variant":"high"}}}
for harness in ("pi", "pi-signed"):
    resume = {"provider":"account", "session": str(scratch / "saved.jsonl")}
    env = dict(os.environ, CATALOG_ADAPTER=harness, EXPECT_CONTEXT="1", EXPECT_SESSION=resume["session"])
    run = subprocess.run([sys.executable, str(root / "bin/fm-harness-model.py"), harness,
                          str(vendor), "account/model-v1", str(scratch), json.dumps(resume)],
                         env=env, capture_output=True, text=True)
    assert run.returncode == 0, (harness, run.stdout, run.stderr)
print("ok - all 16 adapters resolve native defaults and explicit models without generating; catalog aliases, Codex cwd and Pi provider/session arguments follow vendor contracts")
PY
