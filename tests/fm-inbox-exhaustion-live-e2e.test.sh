#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_INBOX_EXHAUSTION_LIVE tmux jq
. "$ROOT/bin/fm-task-inbox-lib.sh"

lab=$(mktemp -d "$ROOT/.inbox-exhaustion-live.XXXXXX") || exit 1
evidence=${FM_INBOX_EXHAUSTION_EVIDENCE:-$ROOT/data/review-evidence/inbox-exhaustion}
mkdir -p "$evidence" "$lab/bin"
real_tmux=$(command -v tmux)
socket="fm-inbox-exhaustion-$$"
session=exhaustion
cleanup() {
  "$real_tmux" -L "$socket" kill-server 2>/dev/null || true
  rm -rf "$lab"
}
trap cleanup EXIT
cat > "$lab/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -L "$socket" "\$@"
SH
chmod +x "$lab/bin/tmux"
PATH="$lab/bin:$PATH"
tmux new-session -d -s "$session" -x 160 -y 50 -c "$lab"
checked=0
failed=0

check_harness() {
  local harness=$1 binary=$2 version home work rec status=0 i cap gen="live-$1-$$" auth
  home="$lab/$harness/home"
  work="$lab/$harness/work"
  mkdir -p "$home/state" "$home/config" "$home/data" "$work" "$home/.cursor" "$home/.grok"
  chmod 700 "$home" "$home/.cursor" "$home/.grok"
  git -C "$work" init -q
  case "$harness" in
    grok)
      auth=${FM_GROK_AUTH_FILE:-$HOME/.grok/auth.json}
      [ ! -f "$auth" ] || { cp "$auth" "$home/.grok/auth.json" && chmod 600 "$home/.grok/auth.json"; } || return 1
      ;;
  esac
  version=$(HOME="$home" GROK_HOME="$home/.grok" CURSOR_CONFIG_DIR="$home/.cursor" "$binary" --version 2>&1 | head -1)
  printf '%s\n' "$version" > "$evidence/$harness.version"
  if [ "$harness" = cursor ] && [ -z "${CURSOR_API_KEY:-}" ]; then
    printf 'not ok - %s (%s): isolated live authentication requires CURSOR_API_KEY; no login or credential creation is performed\n' "$harness" "$version" >&2
    return 1
  fi
  printf '# %s (%s): requesting one reply; this guard requires an already-exhausted account/model\n' "$harness" "$version"
  local -a args=()
  case "$harness" in
    cursor)
      args=(--trust --yolo)
      [ -z "${FM_INBOX_EXHAUSTION_CURSOR_MODEL:-}" ] || args+=(--model "$FM_INBOX_EXHAUSTION_CURSOR_MODEL")
      ;;
    grok) args=(--always-approve) ;;
  esac
  tmux new-window -d -t "$session:" -n "fm-$harness" -c "$work" \
    env HOME="$home" GROK_HOME="$home/.grok" CURSOR_CONFIG_DIR="$home/.cursor" \
    XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" \
    GROK_DISABLE_AUTOUPDATER=1 GROK_AUTO_UPDATE=0 \
    bash -c '"$@"; exec bash --noprofile --norc' _ \
    "$binary" "${args[@]}" 'Reply with exactly OK. Do not use tools.' || return 1
  printf 'window=%s:fm-%s\nendpoint_task_id=%s\nharness=%s\nkind=ship\nworktree=%s\nspawn_gen=%s\n' \
    "$session" "$harness" "$harness" "$harness" "$work" "$gen" > "$home/state/$harness.meta"
  for ((i=0; i<${FM_INBOX_EXHAUSTION_TIMEOUT:-60}; i++)); do
    if fm_task_inbox_usage_exhausted tmux "$session:fm-$harness" "$harness" "fm-$harness"; then break; fi
    cap=$(tmux capture-pane -p -t "$session:fm-$harness")
    case "$cap" in
      *'Do you trust the contents of this directory?'*) tmux send-keys -t "$session:fm-$harness" Enter ;;
    esac
    sleep 1
  done
  tmux capture-pane -p -t "$session:fm-$harness" > "$evidence/$harness.before.txt"
  if ! fm_task_inbox_usage_exhausted tmux "$session:fm-$harness" "$harness" "fm-$harness"; then
    printf 'not ok - %s (%s): no real exhaustion banner; detection/release remains unverified\n' "$harness" "$version" >&2
    return 1
  fi
  rec=$(fm_task_inbox_write "$home/state" "$harness" 'Retain this instruction for recovery.') || return 1
  fm_task_inbox_ring tmux "$session:fm-$harness" "$rec" "fm-$harness" "$harness" || status=$?
  [ "$status" = 4 ] || { printf 'not ok - %s (%s): exhausted ring returned %s\n' "$harness" "$version" "$status" >&2; return 1; }
  FM_HOME="$home" FM_CONTROL_EXIT_WAIT=10 fm_task_inbox_release_exhausted "$harness" \
    > "$evidence/$harness.release.txt" 2>&1 || {
      printf 'not ok - %s (%s): production exhausted-seat release failed\n' "$harness" "$version" >&2
      return 1
    }
  [ "$(fm_backend_agent_state tmux "$session:fm-$harness")" = dead ] && [ -f "$rec" ] \
    || { printf 'not ok - %s (%s): release did not stop the agent and preserve the inbox\n' "$harness" "$version" >&2; return 1; }
  tmux capture-pane -p -t "$session:fm-$harness" > "$evidence/$harness.after.txt"
  checked=$((checked + 1))
  pass "$harness ($version): real exhaustion blocked ringing; production control stopped the agent and retained its inbox"
}

for harness in grok cursor; do
  case "$harness" in grok) binary=$(command -v grok || true) ;; cursor) binary=$(command -v cursor-agent || true) ;; esac
  if [ -z "$binary" ]; then
    printf '# harness absent, not verified here: %s\n' "$harness"
    printf 'absent\n' > "$evidence/$harness.result"
    continue
  fi
  if check_harness "$harness" "$binary"; then
    printf 'passed\n' > "$evidence/$harness.result"
  else
    printf 'failed\n' > "$evidence/$harness.result"
    failed=1
  fi
done
[ "$failed" = 0 ] && [ "$checked" -gt 0 ] || fail 'live exhaustion guard did not prove every installed exhaustion-capable harness'
