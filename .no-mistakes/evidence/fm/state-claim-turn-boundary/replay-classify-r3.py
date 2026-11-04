"""Round 3: replay every capacity Stop rejection in real MAIN session 593af4e3 through the base
guard (411ed483) and the HEAD guard, and classify each turn that HEAD still blocks:
  no-ok-read      no successful Bash tool_result whose command mentions activity.sh in the turn
  only-unsafe     every successful activity.sh command in the turn is piped/chained (HEAD's read_commands yields no capacity read)
  reset-by-other  a standalone successful read exists, but a later Stop-feedback row from another hook (not this guard) follows it
  other           anything else (would indicate a defect in the HEAD fix)
Turn = rows after the last human row (string content, not isMeta, not Stop feedback)."""
import json, os, subprocess, sys, tempfile, time, importlib.util
src, base, head, scratch = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("g", head); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
rows = [json.loads(l) for l in open(src, encoding="utf-8")]
def content(r):
    m = r.get("message"); return m.get("content") if isinstance(m, dict) else None
def feedback(r):
    c = content(r); return r.get("type") == "user" and isinstance(c, str) and c.startswith("Stop hook feedback:")
def own_feedback(c):
    import re
    entries = re.split(r"\n(?=\[)", c.strip())[1:]
    return bool(entries) and all(re.match(r"\[.*?\]: (?:State claim needs a same-turn |Reply shape: )", e) for e in entries)
hits = [i for i, r in enumerate(rows) if feedback(r) and "(capacity)" in content(r)]
print(f"transcript rows={len(rows)} capacity-rejections={len(hits)}")
tally = {}; changed = 0
for i in hits:
    prefix = rows[:i]
    text = cwd = None
    for r in reversed(prefix):
        cwd = cwd or r.get("cwd")
        if r.get("type") == "assistant":
            t = [b.get("text") for b in (content(r) or []) if isinstance(b, dict) and b.get("type") == "text"]
            if t: text = "".join(t); break
    start = max(j for j, r in enumerate(prefix) if r.get("type") == "user" and isinstance(content(r), str)
                and not feedback(r) and not r.get("isMeta"))
    calls = {}; ok = []; other_fb_after_safe = False; safe_seen = False
    for j in range(start, i):
        r = prefix[j]; c = content(r)
        if feedback(r) and not own_feedback(c) and safe_seen: other_fb_after_safe = True
        if not isinstance(c, list): continue
        for b in c:
            if not isinstance(b, dict): continue
            if r.get("type") == "assistant" and b.get("type") == "tool_use" and b.get("name") == "Bash":
                calls[b.get("id")] = b.get("input", {}).get("command", "")
            if r.get("type") == "user" and b.get("type") == "tool_result" and not b.get("is_error"):
                cmd = calls.get(b.get("tool_use_id"), "")
                if "activity.sh" in cmd:
                    safe = any(f == "capacity" for f, *_ in g.read_commands(cmd, time.monotonic() + 5, r.get("cwd") or cwd))
                    ok.append(safe); safe_seen = safe_seen or safe
    fd, path = tempfile.mkstemp(dir=scratch, suffix=".jsonl"); os.close(fd)
    with open(path, "w") as f:
        for r in prefix: f.write(json.dumps(r) + "\n")
    payload = json.dumps({"hook_event_name": "Stop", "session_id": "replay-%d" % i, "stop_hook_active": False,
                          "transcript_path": path, "cwd": cwd, "last_assistant_message": text or ""})
    rc = {}
    for name, guard in (("base", base), ("head", head)):
        p = subprocess.run([sys.executable, guard], input=payload, text=True, capture_output=True, env=dict(os.environ, FM_STATE_OVERRIDE=scratch))
        rc[name] = p.returncode
    os.unlink(path)
    if rc["head"] == 0: cls = "unblocked-on-head"
    elif not ok: cls = "no-ok-read"
    elif not any(ok): cls = "only-unsafe"
    elif other_fb_after_safe: cls = "reset-by-other"
    else: cls = "other"
    tally[cls] = tally.get(cls, 0) + 1
    print(f"row {i}: base rc={rc['base']} head rc={rc['head']} ok-activity-results={len(ok)} standalone={sum(ok)} class={cls}")
print("tally:", tally)
