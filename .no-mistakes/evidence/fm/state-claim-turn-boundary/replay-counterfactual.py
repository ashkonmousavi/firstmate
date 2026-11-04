"""Counterfactual on the real 22:15:16Z capacity rejection (row 7434 of MAIN session 593af4e3).
Keep every real transcript row, but strip the pipeline tail from the real activity read at
row 7420 so it is the bare read. If base also passes, the real on-disk row shape never needed
this branch's fix; the pipe was what blocked the read."""
import json, os, subprocess, sys, tempfile

src, base, branch, scratch = sys.argv[1:5]
rows = [json.loads(line) for line in open(src, encoding="utf-8")]


def run(prefix, label):
    text = ""
    for r in reversed(prefix):
        if r.get("type") == "assistant":
            t = [b["text"] for b in r["message"]["content"] if isinstance(b, dict) and b.get("type") == "text"]
            if t:
                text = "".join(t)
                break
    fd, path = tempfile.mkstemp(dir=scratch, suffix=".jsonl")
    os.close(fd)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in prefix))
    payload = json.dumps({"hook_event_name": "Stop", "session_id": "cf", "stop_hook_active": False,
                          "transcript_path": path, "cwd": "~/Firstmate/firstmate",
                          "last_assistant_message": text})
    for name, guard in (("base", base), ("branch", branch)):
        q = subprocess.run([sys.executable, guard], input=payload, text=True, capture_output=True,
                           env=dict(os.environ, FM_STATE_OVERRIDE=scratch))
        print(f"{label}: {name} rc={q.returncode} {q.stderr.strip()[:80]!r}")
    os.unlink(path)


prefix = rows[:7434]
use = [b for b in prefix[7420]["message"]["content"] if b.get("type") == "tool_use"][0]
cmd = use["input"]["command"]
print("real command at row 7420:", cmd)
run(prefix, "real rows, real piped command")
prefix = json.loads(json.dumps(prefix))
for b in prefix[7420]["message"]["content"]:
    if b.get("type") == "tool_use":
        b["input"]["command"] = cmd.split(" | ")[0]
        print("counterfactual command:", b["input"]["command"])
run(prefix, "real rows, bare read (pipe removed)")
