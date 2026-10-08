import json, os, pathlib, shutil, subprocess, tempfile
ROOT = pathlib.Path("/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4E7BAHBXQ3NWFFXVXNYRF29")
EVIDENCE = pathlib.Path("/home/tegris/.no-mistakes/evidence/01M4E7BAHBXQ3NWFFXVXNYRF29")
lab = pathlib.Path(tempfile.mkdtemp(prefix=".test2-local-seams-", dir=ROOT))
records = []
try:
    home = lab / "home"
    home.mkdir()
    fakebin = lab / "fakebin"
    fakebin.mkdir()
    spy = fakebin / "codex"
    spy.write_text("#!/usr/bin/env python3\nimport json, os, sys\nprint(json.dumps({\"argv\":sys.argv[1:],\"inherited_thread\":os.environ.get(\"CODEX_THREAD_ID\"),\"inherited_session\":os.environ.get(\"CODEX_SESSION_ID\")}))\n")
    spy.chmod(0o700)
    env = os.environ.copy()
    for key in ("HERDR_ENV", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "HERDR_SESSION", "FM_SUPERVISION_ACTOR", "FM_SUPERVISION_PRIMARY_HARNESS"):
        env.pop(key, None)
    env.update(FM_HOME=str(home), PATH=str(fakebin)+os.pathsep+env["PATH"], CODEX_THREAD_ID="fixture-parent-thread", CODEX_SESSION_ID="fixture-parent-session")
    def run(name, args, changes=None):
        current=env.copy()
        current.update(changes or {})
        result=subprocess.run(args, cwd=ROOT, env=current, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        record=dict(name=name, command=args, environment_overrides=changes or {}, exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr, evidence_class="public-command fixture; no model session")
        records.append(record)
        return result
    result=run("valid launcher identity reaches recording executable without interactive input", ["bash", "bin/fm-codex-primary.sh", "--fixture-development"])
    assert result.returncode == 0, result.stderr
    payload=json.loads(result.stdout)
    assert payload["argv"][-1] == "--fixture-development"
    assert payload["inherited_thread"] is None and payload["inherited_session"] is None
    settings={}
    args=payload["argv"][:-1]
    assert len(args)%2 == 0
    for i in range(0,len(args),2):
        assert args[i] == "-c"
        key,value=args[i+1].split("=",1)
        settings[key]=json.loads(value)
    assert settings["shell_environment_policy.set.FM_CODEX_CLIENT_HOME"] == str(home)
    assert settings["shell_environment_policy.set.FM_CODEX_CLIENT_PID"].isdigit()
    assert settings["shell_environment_policy.set.FM_CODEX_CLIENT_BIRTH"].startswith("proc:")
    records[-1]["result"]="pass"
    result=run("incomplete Herdr identity refuses before executable launch", ["bash", "bin/fm-codex-primary.sh", "--fixture-development"], {"HERDR_ENV":"1"})
    assert result.returncode == 1 and result.stdout == ""
    assert "error: incomplete Herdr pane identity at Codex launch" in result.stderr
    records[-1]["result"]="pass"
    result=run("configured supervision identity permits known harness", ["bash", "bin/fm-harness.sh"], {"FM_SUPERVISION_ACTOR":"branch", "FM_SUPERVISION_PRIMARY_HARNESS":"codex"})
    assert result.returncode == 0 and result.stdout.strip() == "codex"
    records[-1]["result"]="pass"
    result=run("unknown supervision identity returns named refusal without interactive input", ["bash", "bin/fm-harness.sh"], {"FM_SUPERVISION_ACTOR":"branch", "FM_SUPERVISION_PRIMARY_HARNESS":"fixture-unknown"})
    assert result.returncode == 2 and result.stdout == ""
    assert "names no known harness; refusing to resolve" in result.stderr
    records[-1]["result"]="pass"
finally:
    shutil.rmtree(lab)
    (EVIDENCE / "test2-local-seams-results.json").write_text(json.dumps({"tested_head_sha":"4c86c7fe04da4d08560bdb3d1ec9971584588fb0", "records":records,"lab_removed":not lab.exists()},indent=2)+"\n")
print(json.dumps({"focused_cases":len(records),"passed":sum(r.get("result")=="pass" for r in records),"lab_removed":not lab.exists()}))
