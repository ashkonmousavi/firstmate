#!/usr/bin/env bash
# End-to-end driver: a primary home and a secondmate home, each with a
# crew-dispatch.json holding a Grok Bot rule, driven through the real
# fm-dispatch-select.sh and fm-grok-bot-dispatch.sh CLIs. The primary's bridge
# at $FM_HOME/data/grok-bot-bridge/grokbot.mjs is a local stand-in for the
# home-private credentialed bridge (no network, no xAI account touched).
set -u
REPO=$1
LAB=$(mktemp -d)
trap 'rm -rf "$LAB"' EXIT
SEL="$REPO/bin/fm-dispatch-select.sh"
BOT="$REPO/bin/fm-grok-bot-dispatch.sh"
step() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

PRIMARY="$LAB/primary"; SECOND="$LAB/secondmate"
mkdir -p "$PRIMARY/config" "$PRIMARY/data/grok-bot-bridge" "$SECOND/config"
cat > "$PRIMARY/config/crew-dispatch.json" <<'JSON'
{"rules":[
  {"when":"web research","use":[{"grok_bot":"fm-researcher"},{"harness":"claude","model":"sonnet"}]},
  {"when":"public repo reading","use":{"grok_bot":"fm-repo-scout"}}
],"default":{"harness":"codex"}}
JSON
cp "$PRIMARY/config/crew-dispatch.json" "$SECOND/config/crew-dispatch.json"
export STUB_LOG="$LAB/bridge-calls.jsonl"
cat > "$PRIMARY/data/grok-bot-bridge/grokbot.mjs" <<'JS'
import { appendFileSync } from "node:fs";
const [cmd, ...a] = process.argv.slice(2);
appendFileSync(process.env.STUB_LOG, JSON.stringify([cmd, ...a]) + "\n");
const out = (o) => console.log(JSON.stringify(o, null, 2));
if (cmd === "list") out([{ id: "bot-7", name: "fm-researcher" }, { id: "bot-9", name: "fm-repo-scout" }]);
else if (cmd === "chat") {
  out({ sent: { ok: true } });
  out({ stillRunning: process.env.STUB_RUNNING === "1",
        newEntries: [{ id: 1, text: a[1] }, { id: 2, text: "Repo A uses SQLite; repo B uses Postgres. Sources: https://example.com/a" }] });
} else process.exit(1);
JS
cat > "$LAB/brief.md" <<'MD'
# Task
## Captain's intent
"compare the three public trading-journal repos"

## Firstmate spec
- Read each public repository and report storage differences.

## Setup
PRIVATE-LOCAL-PATH /home/operator/secret-notes must not leave this machine.
MD

echo '=== S1: primary intake selects the Grok Bot target from the router ==='
step "$SEL" "$PRIMARY/config/crew-dispatch.json" 0

echo; echo '=== S2: selected Bot target dispatched through the router tool (primary home, default bridge path) ==='
cd "$LAB"
env -u FM_GROKBOT_BRIDGE FM_HOME="$PRIMARY" "$BOT" "$LAB/brief.md" --bot fm-researcher --timeout 45
printf '[exit %s]\n' "$?"
echo '--- what the bridge received (chat call) ---'
grep '^\["chat"' "$STUB_LOG"
if grep -q PRIVATE-LOCAL-PATH "$STUB_LOG"; then echo 'LEAK: setup section was sent'; else echo 'OK: setup section stayed local'; fi

echo; echo '=== S3: Bot still working at the timeout ==='
STUB_RUNNING=1 env -u FM_GROKBOT_BRIDGE FM_HOME="$PRIMARY" "$BOT" "$LAB/brief.md" --bot fm-repo-scout --timeout 5
printf '[exit %s]\n' "$?"

echo; echo '=== S4: usage spent -> blocked fact -> router falls to next candidate ==='
echo '[{"candidate":0,"kind":"blocked","detail":"Grok Bot weekly usage spent"}]' > "$LAB/blocked.json"
step "$SEL" "$PRIMARY/config/crew-dispatch.json" 0 --facts "$LAB/blocked.json"

echo; echo '=== S5: secondmate home (rules inherited, no bridge) ==='
env -u FM_GROKBOT_BRIDGE FM_HOME="$SECOND" "$BOT" "$LAB/brief.md" --bot fm-researcher
printf '[exit %s]\n' "$?"
echo '[{"candidate":0,"kind":"launch_failed","detail":"Grok Bot bridge not found in this home"}]' > "$LAB/nobridge.json"
step "$SEL" "$SECOND/config/crew-dispatch.json" 0 --facts "$LAB/nobridge.json"
echo '--- Bot-only rule in the secondmate ---'
step "$SEL" "$SECOND/config/crew-dispatch.json" 1 --facts "$LAB/nobridge.json"

echo; echo '=== S6: removed --out option is refused ==='
env -u FM_GROKBOT_BRIDGE FM_HOME="$PRIMARY" "$BOT" "$LAB/brief.md" --bot fm-researcher --out "$LAB/reply.txt"
printf '[exit %s]\n' "$?"
[ -e "$LAB/reply.txt" ] && echo 'reply file was written' || echo 'no reply file written'

echo; echo '=== S7: grok_bot inside a quota-balanced rule is rejected by the router ==='
echo '{"rules":[{"when":"web research","select":"quota-balanced","use":[{"grok_bot":"fm-researcher"},{"harness":"claude"}]}]}' > "$LAB/qb.json"
step "$SEL" "$LAB/qb.json" 0

echo; echo '=== S8: malformed Bot profiles are rejected ==='
echo '{"rules":[{"when":"x","use":{"grok_bot":"fm-researcher","harness":"grok"}}]}' > "$LAB/mixed.json"
step "$SEL" "$LAB/mixed.json" 0
echo '{"rules":[{"when":"x","use":{"grok_bot":"   "}}]}' > "$LAB/blank.json"
step "$SEL" "$LAB/blank.json" 0
echo '--- off Bot is skipped in order ---'
echo '{"rules":[{"when":"x","use":[{"grok_bot":"fm-researcher","off":true},{"harness":"claude"}]}]}' > "$LAB/off.json"
step "$SEL" "$LAB/off.json" 0
