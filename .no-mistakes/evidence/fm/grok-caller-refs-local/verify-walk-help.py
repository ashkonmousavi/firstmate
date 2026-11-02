import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path.cwd()
evidence = Path(__file__).parent
# Oracle: the author's required public help wording and its placement before Usage.
pointer = "For this fleet, load grok-bots before writing or forwarding a walker brief; the selected private dispatcher validates the citation in the transmitted task text."
results = []
with tempfile.TemporaryDirectory(prefix=".walk-help-live-", dir=root) as fixture:
    lab = Path(fixture)
    home = lab / "absent-home"
    env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
    env.update(FM_HOME=str(home))
    cases = [
        ("request-help", "fm-walk-request.sh", ["--help"], 0, False),
        ("request-short-help", "fm-walk-request.sh", ["-h"], 0, False),
        ("check-help", "fm-walk-request-check.sh", ["--help"], 0, False),
        ("check-short-help", "fm-walk-request-check.sh", ["-h"], 0, False),
        ("request-help-invalid-fields", "fm-walk-request.sh", ["--brief", str(home / "missing.md"), "--release", "invalid", "--walks", "../invalid", "--help"], 0, False),
        ("check-help-invalid-routing", "fm-walk-request-check.sh", ["--help"], 0, True),
        ("request-unknown-option", "fm-walk-request.sh", ["--unknown-option"], 2, False),
        ("check-unknown-action", "fm-walk-request-check.sh", ["unknown-action"], 2, False),
    ]
    for name, script, args, expected_rc, invalid_routing in cases:
        case_env = env.copy()
        if invalid_routing:
            case_env.update(FM_WALK_REQUEST_PROJECT="../invalid", FM_WALK_REQUEST_TARGET="")
        command = ["bash", str(root / "bin" / script), *args]
        completed = subprocess.run(command, env=case_env, cwd=root, capture_output=True, text=True, timeout=15)
        output = completed.stdout if expected_rc == 0 else completed.stderr
        failures = []
        if completed.returncode != expected_rc:
            failures.append(f"expected exit {expected_rc}, got {completed.returncode}")
        lines = output.splitlines()
        if lines.count(pointer) != 1 or "Usage:" not in lines or lines.index(pointer) >= lines.index("Usage:"):
            failures.append("expected exact pointer once before Usage")
        if expected_rc == 0 and (not output.startswith(pointer + "\n\nUsage:\n") or completed.stderr):
            failures.append("help must start with pointer then Usage and have empty stderr")
        if expected_rc != 0 and completed.stdout:
            failures.append("usage error must not write stdout")
        if list(lab.iterdir()):
            failures.append("help or usage handling created disposable home/state")
        transcript = evidence / (name + ".txt")
        transcript.write_text(
            "Command: " + shlex.join(command) + "\n"
            + "FM_HOME: " + str(home) + " (absent disposable home)\n"
            + ("FM_WALK_REQUEST_PROJECT=../invalid; FM_WALK_REQUEST_TARGET=empty\n" if invalid_routing else "")
            + f"Exit: {completed.returncode}\n--- stdout ---\n" + completed.stdout
            + "--- stderr ---\n" + completed.stderr
            + "--- observations ---\nNo fixture entries: " + str(not list(lab.iterdir())) + "\n"
            + "Result: " + ("FAIL " + "; ".join(failures) if failures else "PASS") + "\n"
        )
        results.append(dict(name=name, result="fail" if failures else "pass", exit=completed.returncode, failures=failures, transcript=str(transcript)))
(evidence / "walk-help-results.json").write_text(json.dumps(results, indent=2) + "\n")
for result in results:
    print(result["name"] + ": " + result["result"] + "; exit=" + str(result["exit"]))
raise SystemExit(1 if any(r["failures"] for r in results) else 0)
