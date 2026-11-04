"""Round 3: for each cited-window capacity rejection (22:10-22:20Z) and the later still-blocked rows,
list every successful activity.sh Bash command in the turn with a shape label, so a reviewer can see
whether the remaining blocks are piped/chained executions or not reads at all."""
import json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
def content(r):
    m = r.get("message"); return m.get("content") if isinstance(m, dict) else None
def feedback(r):
    c = content(r); return r.get("type") == "user" and isinstance(c, str) and c.startswith("Stop hook feedback:")
for i in map(int, sys.argv[2:]):
    start = max(j for j in range(i) if rows[j].get("type") == "user" and isinstance(content(rows[j]), str)
                and not feedback(rows[j]) and not rows[j].get("isMeta"))
    calls = {}; out = []
    for r in rows[start:i]:
        c = content(r)
        if not isinstance(c, list): continue
        for b in c:
            if not isinstance(b, dict): continue
            if r.get("type") == "assistant" and b.get("type") == "tool_use" and b.get("name") == "Bash":
                calls[b.get("id")] = b.get("input", {}).get("command", "")
            if r.get("type") == "user" and b.get("type") == "tool_result" and not b.get("is_error"):
                cmd = calls.get(b.get("tool_use_id"), "")
                if "activity.sh" in cmd:
                    first = cmd.split()[0] if cmd.split() else ""
                    shape = ("prints-source" if re.match(r"\s*(cat|head|tail|sed|grep|less|wc)\b", cmd) else
                             "piped/chained-exec" if re.search(r"\||;|&&|\(|\n", cmd) else "standalone-exec")
                    out.append(shape)
                    print(f"row {i} [{rows[i].get('timestamp')}] {shape}: {cmd[:140]!r}")
    print(f"row {i}: shapes={sorted(set(out))}")
