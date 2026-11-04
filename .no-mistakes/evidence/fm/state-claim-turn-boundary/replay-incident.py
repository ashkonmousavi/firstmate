"""Replay every capacity Stop rejection in a real Claude transcript through two guard builds.
For each 'Stop hook feedback ... (capacity)' row, the transcript as it stood at that Stop
(rows before the feedback row) is written to a scratch file and a Stop payload with the
rejected assistant text is fed to each guard. Also reports whether that turn really ran
activity.sh successfully and whether any tool_result row carried text blocks."""
import json, subprocess, sys, os, tempfile
src, base, branch, scratch = sys.argv[1:5]
rows = [json.loads(l) for l in open(src, encoding="utf-8")]
def is_feedback(r):
    c = r.get("message", {}).get("content")
    return r.get("type") == "user" and isinstance(c, str) and c.startswith("Stop hook feedback:") and "(capacity)" in c
hits = [i for i, r in enumerate(rows) if is_feedback(r)]
print(f"transcript rows={len(rows)} capacity-rejections={len(hits)}")
summary = {"base_block": 0, "branch_block": 0}
for i in hits:
    prefix = rows[:i]
    # rejected assistant text = last assistant text blocks before the feedback row
    text = None; cwd = None
    for r in reversed(prefix):
        cwd = cwd or r.get("cwd")
        if r.get("type") == "assistant":
            c = r.get("message", {}).get("content", [])
            t = [b.get("text") for b in c if isinstance(b, dict) and b.get("type") == "text"]
            if t: text = "".join(t); break
    # turn analysis: since last human (string, non-feedback) row
    start = max(j for j, r in enumerate(prefix) if r.get("type") == "user" and (
        isinstance(r.get("message", {}).get("content"), str) and not r["message"]["content"].startswith("Stop hook feedback")))
    calls = {}; ok_reads = 0; mixed = 0
    for r in prefix[start:]:
        c = r.get("message", {}).get("content")
        if not isinstance(c, list): continue
        for b in c:
            if not isinstance(b, dict): continue
            if r.get("type") == "assistant" and b.get("type") == "tool_use" and b.get("name") == "Bash":
                calls[b.get("id")] = b.get("input", {}).get("command", "")
            if r.get("type") == "user" and b.get("type") == "tool_result" and not b.get("is_error") and "activity.sh" in calls.get(b.get("tool_use_id"), ""):
                ok_reads += 1
                if any(isinstance(x, dict) and x.get("type") == "text" for x in c): mixed += 1
    fd, path = tempfile.mkstemp(dir=scratch, suffix=".jsonl"); os.close(fd)
    with open(path, "w") as f:
        for r in prefix: f.write(json.dumps(r) + "\n")
    payload = json.dumps({"hook_event_name": "Stop", "session_id": "replay-%d" % i, "stop_hook_active": False,
                          "transcript_path": path, "cwd": cwd, "last_assistant_message": text or ""})
    out = {}
    for name, guard in (("base", base), ("branch", branch)):
        env = dict(os.environ, FM_STATE_OVERRIDE=scratch)
        p = subprocess.run([sys.executable, guard], input=payload, text=True, capture_output=True, env=env)
        out[name] = (p.returncode, p.stderr.strip().splitlines()[0][:90] if p.stderr.strip() else "")
        if p.returncode == 2: summary[name + "_block"] += 1
    os.unlink(path)
    print(f"row {i}: turn activity.sh ok-results={ok_reads} (of which on a tool_result+text row={mixed}) | "
          f"base rc={out['base'][0]} {out['base'][1]!r} | branch rc={out['branch'][0]} {out['branch'][1]!r}")
print("summary:", summary)
