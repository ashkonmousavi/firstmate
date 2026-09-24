#!/usr/bin/env bash
# Drives bin/fm-bearings-board.sh build repeatedly against the REAL lavish-axi
# (isolated state dir + port), counting browser-tab launches via the preload.
# usage: drive-live.sh <board-script> <label> <repo-root>
set -u
umask 077
BOARD=$1 LABEL=$2 ROOT=$3
H=$(cd "$(dirname "$0")" && pwd)
home=$(mktemp -d "${TMPDIR:-/tmp}/fmbb-live-$LABEL.XXXXXX"); home=$(cd -P "$home" && pwd -P)
mkdir -p "$home/state" "$home/data" "$home/procevent-claims"; mkdir -m 700 "$home/lavish-axi-state"
port=$(( 45000 + RANDOM % 10000 ))
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_PORT=$port \
  LAVISH_AXI_STATE_DIR="$home/lavish-axi-state" LAVISH_AXI_TELEMETRY=0 \
  NODE_OPTIONS="--require $H/browser-intercept.cjs" BROWSER_OPEN_LOG="$home/browser-opens.log"
unset LAVISH_AXI_NO_OPEN
: > "$BROWSER_OPEN_LOG"
cleanup() {
  "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  lavish-axi stop >/dev/null 2>&1 || true
  rm -rf "$home"
}
trap cleanup EXIT
tabs() { wc -l < "$BROWSER_OPEN_LOG" | tr -d ' '; }
build() {  # <step-name>
  local before after out rc
  before=$(tabs)
  out=$("$BOARD" build "$H/payload.json" 2>&1); rc=$?
  after=$(tabs)
  printf '\n### %s  (exit %s)\n' "$1" "$rc"
  printf '%s\n' "$out" | grep -vE "^(  (file|url):|session:$|next_step:)" | sed "s#$home#<home>#g"
  printf 'browser tabs opened by this build: %s   (total so far: %s)\n' $((after - before)) "$after"
}
echo "== $LABEL: $(basename "$BOARD") against real lavish-axi $(lavish-axi --version) on isolated port $port"
build "build 1 - first build, no session yet"
build "build 2 - rebuild while board session is open"
build "build 3 - rebuild again while board session is open"
board=$("$BOARD" path)
printf '\n### server listing after build 3\n'; lavish-axi 2>&1 | grep -F "$(basename "$board")" | sed "s#$home#<home>#g"
printf '\n### agent ends the session: lavish-axi end <board>\n'; lavish-axi end "$board" 2>&1 | grep -E 'status' | sed "s#$home#<home>#g"
build "build 4 - rebuild after the session was ended (not listed open)"
build "build 5 - rebuild while the re-established session is open"
url=$(lavish-axi 2>&1 | grep -F "$board," | sed -n 's/.*"\(http[^"]*\)".*/\1/p' | head -1); key=${url##*/}
printf '\n### captain ends the session from the browser (the page End button: POST /api/<key>/end)\n'
curl -s -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$LAVISH_AXI_PORT/api/$key/end"; echo
printf '### a plain lavish-axi open of the captain-ended board now reports:\n'; LAVISH_AXI_NO_OPEN=1 lavish-axi "$board" 2>&1 | grep -E '^  status' 
build "build 6 - rebuild after the captain ended the session from the browser"
build "build 7 - rebuild while the reopened session is open"
printf '\n== %s TOTAL browser tabs across 7 builds: %s\n' "$LABEL" "$(tabs)"
sed "s#$home#<home>#g" "$BROWSER_OPEN_LOG" | sed 's/^/   tab-launch: /'
