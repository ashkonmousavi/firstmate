#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# exercised through REAL fm-send for a fresh record and through
# fm_task_inbox_ring for a seeded, unsubmitted own-doorbell draft. Each case
# must both ACT on the instruction (create a named file) and ACKNOWLEDGE it
# (the mv into handled/), failing loudly with the harness name and version.
# The pending case requires no action or acknowledgement before the ring and
# has no later fresh-send retry that could mask a failed recovery.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Set FM_SEND_INBOX_LIVE_PENDING_ONLY=1 to run only pending-draft recovery.
# FM_SEND_INBOX_LIVE_CLAUDE_MODES selects individual Claude cases; optional
# FM_SEND_INBOX_LIVE_EVIDENCE_DIR retains CLI output and terminal captures.
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux jq

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_SEND_INBOX_LIVE_FAULT_DIR:-}" ]; then
  fault=\$FM_SEND_INBOX_LIVE_FAULT_DIR
  case "\${1:-}" in
    send-keys)
      if [ "\${!#}" = Enter ]; then
        n=0
        [ ! -f "\$fault/enters" ] || read -r n < "\$fault/enters"
        n=\$((n + 1))
        printf '%s\\n' "\$n" > "\$fault/enters"
        python3 -c 'import time; print(time.monotonic())' >> "\$fault/enter-times"
        if [ "\$n" = 1 ] && [ -f "\$fault/unrelated-window" ]; then
          "$REAL_TMUX" -L "$SOCKET" send-keys -t "\$(cat "\$fault/unrelated-window")" Enter || exit 1
        fi
        [ "\$n" -gt "\$(cat "\$fault/swallow")" ] || exit 0
      else
        printf 'typed\\n' >> "\$fault/types"
        printf '%s' "\${!#}" > "\$fault/payload"
      fi
      ;;
    capture-pane)
      [ ! -e "\$fault/accepted" ] || [ -e "\$fault/unrelated-window" ] || exit 1
      if [ -e "\$fault/fail-capture" ] && [ -e "\$fault/types" ]; then exit 1; fi
      ;;
  esac
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
. "$ROOT/bin/fm-cursor-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name> <home> <binary>
  local home=${2:-} binary=${3:-} config
  case "$1" in
    codex)
      printf 'codex -c check_for_update_on_startup=false --dangerously-bypass-approvals-and-sandbox --disable hooks -c %q -c %q' \
        "shell_environment_policy.set.FM_HOME=\"$home\"" \
        "shell_environment_policy.set.FM_TASK_INBOX=\"$home/state/live-codex.inbox\""
      ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    cursor) printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_INVOKED_AS %q --trust --yolo' "$binary" ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    omp)
      printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 omp --config %q --auto-approve --cwd %q' \
        "$ROOT/.omp/fm-worker-overlay.yml" "$ROOT"
      ;;
    gemini) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS GEMINI_CLI_TRUST_WORKSPACE=true gemini -y' ;;
    rovo)
      config=$(jq -cn --arg lab "${home%/*}" '{toolPermissions:{allowedExternalPaths:[$lab]}}') || return 1
      printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS rovo run --yolo --config-override %q' "$config"
      ;;
    agy) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS agy --dangerously-skip-permissions' ;;
    devin)
      bash "$ROOT/bin/fm-devin-config.sh" "$home/state" live-devin 0 || return 1
      printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u NO_COLOR devin --permission-mode dangerous --respect-workspace-trust false --config %q' \
        "$home/state/live-devin.devin-config.json"
      ;;
    commandcode) printf '%s' 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u NO_COLOR COLORTERM=truecolor commandcode --yolo --trust --skip-onboarding --no-auto-update' ;;
    polytoken)
      . "$ROOT/bin/fm-polytoken-lib.sh"
      fm_polytoken_write_config "$home/polytoken-config" || return 1
      fm_polytoken_write_facet "$home" "$home/state/live-polytoken.inbox" || return 1
      # Expand the environment variables in the launched shell.
      # shellcheck disable=SC2016
      printf '%s' 'for _fmv in $(env | cut -d= -f1 | grep -E '\''^(ORCA_|FM_)'\''); do case $_fmv in FM_TASK_ID|FM_TASK_INBOX|FM_ZELLIJ_SESSION) ;; *) unset $_fmv ;; esac; done; '
      printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u AGENT polytoken --config-dir %q new --sessions-dir %q --facet firstmate-worker --facets-dir %q' \
        "$home/polytoken-config" "$home/polytoken-sessions" "$home/.polytoken/facets"
      ;;
    *) return 1 ;;
  esac
}

# codex's crewmate launch in bin/fm-spawn.sh carries --disable hooks because the
# hook-trust modal ("N hooks are new or changed") opens on "Review hooks" and
# firstmate's key plane has no arrow navigation to move off it. Without the flag
# this guard parks on that dialog for the whole timeout and reports the doorbell
# unhonored, which is a dialog verdict rather than a doorbell one, so pin the
# switch here instead of letting the codex check go quietly unprovable again.
case "$(launch_cmd codex)" in
  *'--disable hooks'*) ;;
  *) fail 'codex launch recipe lost --disable hooks; the check would park on the hook-trust modal instead of judging the doorbell' ;;
esac

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen trusted=0
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
    if [ "$trusted" = 0 ] && [[ "$screen" == *'Yes, I trust this folder'* ]]; then
      tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Down Enter || return 1
      trusted=1
    fi
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_busy_doorbell() {
  local win=$1 home=$2 task=$3 version=$4 name=$5 started release finished acted handled i command
  started="$LAB/$name-tool-started"
  release="$LAB/$name-tool-release"
  finished="$LAB/$name-tool-finished"
  acted="$LAB/acted-busy-$name"
  handled="$home/state/$task.inbox/handled/003.msg"
  command="touch $(printf '%q' "$started"); while [ ! -e $(printf '%q' "$release") ] && [ \"\$SECONDS\" -lt $TIMEOUT ]; do sleep 1; done; test -e $(printf '%q' "$release") && touch $(printf '%q' "$finished")"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" --one-way \
    "First move this record into handled/. Then run the following exact shell command in a foreground shell tool call with a timeout of at least $TIMEOUT seconds, without backgrounding it, and wait for it to return before finishing your response:
$command" \
    > "$LAB/$name-busy-start.log" 2>&1; then
    printf 'not ok - %s (%s): could not send the blocking-tool instruction\n' "$name" "$version" >&2
    return 1
  fi
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    if [ -e "$started" ] && [ ! -e "$finished" ] && fm_pane_is_busy "$SESSION:$win" "$name"; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$i" -eq "$TIMEOUT" ]; then
    printf 'not ok - %s (%s): never observed the real foreground tool running beside a busy pane\n' "$name" "$version" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" --one-way \
    "After running the following exact shell command, move this record into handled/:
touch $(printf '%q' "$acted")" \
    > "$LAB/$name-busy-send.log" 2>&1; then
    printf 'not ok - %s (%s): fm-send refused the busy steer\n' "$name" "$version" >&2
    return 1
  fi
  if [ -e "$finished" ]; then
    printf 'not ok - %s (%s): the blocking tool finished before the busy steer was submitted\n' "$name" "$version" >&2
    return 1
  fi
  : > "$release"
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -e "$finished" ] && [ -e "$acted" ] && [ -f "$handled" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ ! -e "$finished" ] || [ ! -e "$acted" ] || [ ! -f "$handled" ]; then
    printf 'not ok - %s (%s): busy doorbell not acted on and acknowledged without an idle re-ring\n' "$name" "$version" >&2
    return 1
  fi
  pass "$name ($version): a doorbell submitted during a real foreground tool was acted on and acked without an idle re-ring"
}

check_nonqueue_live() {
 local win=$1 home=$2 task=$3 started="$LAB/nonqueue-started" release="$LAB/nonqueue-release" finished="$LAB/nonqueue-finished" acted="$LAB/nonqueue-acted" rec watcher i=0 wrc
 FM_HOME="$home" "$ROOT/bin/fm-send.sh" "$task" --one-way "First move this message into handled/. Then run exactly this foreground shell command without backgrounding it, with a timeout of 150 seconds: touch '$started'; while [ ! -e '$release' ]; do sleep 1; done; touch '$finished'" > "$LAB/nonqueue-start.log" 2>&1 || return 1
 while [ "$i" -lt 100 ] && [ ! -e "$started" ]; do sleep 1; i=$((i+1)); done
 [ -e "$started" ] && [ ! -e "$finished" ] || return 1
 rec=$(fm_task_inbox_write "$home/state" "$task" "Run touch '$acted', then move this message into handled/.") || return 1
 touch -d '2 hours ago' "$rec"
 FM_HOME="$home" FM_POLL=1 FM_TASK_INBOX_GRACE_SECS=3600 FM_TASK_INBOX_BUSY_MAX=100 FM_SIGNAL_GRACE=0 bash "$ROOT/bin/fm-watch.sh" > "$LAB/nonqueue-watch.log" 2>&1 &
 watcher=$!
 i=0
 while [ "$i" -lt 40 ] && [ ! -s "$home/state/$task.inbox/.busy-state" ]; do
   kill -0 "$watcher" 2>/dev/null || break
   sleep 1; i=$((i+1))
 done
 if [ ! -s "$home/state/$task.inbox/.busy-state" ]; then
   cat "$LAB/nonqueue-watch.log" >&2
   touch "$release"
   kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
   return 1
 fi
 [ ! -e "$acted" ] && [ ! -e "$finished" ] || { kill "$watcher"; wait "$watcher"; return 1; }
 printf 'Real Grok foreground tool still running; watcher busy deferral:\n' > "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR/nonqueue-watch.txt"
 cat "$home/state/$task.inbox/.busy-state" >> "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR/nonqueue-watch.txt"
 touch "$rec"
 touch "$release"
 i=0
 while [ "$i" -lt 100 ]; do
   [ ! -e "$acted" ] || [ ! -e "$home/state/$task.inbox/handled/003.msg" ] || break
   sleep 1; i=$((i+1))
 done
 kill "$watcher" 2>/dev/null
 wait "$watcher"; wrc=$?
 {
   printf 'Owned watcher stop exit=%s; no instruction handled until release.\n' "$wrc"
   cat "$LAB/nonqueue-watch.log"
   printf 'Handled followup:\n'
   cat "$home/state/$task.inbox/handled/003.msg"
   tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" -S -50
 } >> "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR/nonqueue-watch.txt"
 [ -e "$finished" ] && [ -e "$acted" ] && [ -f "$home/state/$task.inbox/handled/003.msg" ] || return 1
 [ ! -e "$home/state/$task.inbox/.busy-state" ] || return 1
 pass 'Real Grok watcher deferred during foreground work, then delivered exactly the owed followup inside grace on idle'
}

check_harness_doorbell() {  # <name> <mode> <binary>
  local name=$1 mode=$2 binary=$3 version cmd win="hx-$1-$2" home task acted rec handled i ready_rc line seeded=0
  version=$(harness_version "$binary")
  home="$LAB/$name-$mode-home"
  mkdir -p "$home/state"
  cmd=$(launch_cmd "$name" "$home" "$binary") || { FAILED=1; printf 'not ok - %s (%s): launch recipe preparation failed\n' "$name" "$version" >&2; return 0; }
  task="live-$name"
  acted="$LAB/acted-$name-$mode"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "export FM_HOME=$(printf '%q' "$home") FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if [ "$mode" = pending ]; then
    rec=$(fm_task_inbox_write "$home/state" "$task" \
      "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line.") || {
      FAILED=1
      printf 'not ok - %s (%s): could not write the draft recovery record\n' "$name" "$version" >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    }
  elif ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  if [ "$mode" = pending ]; then
    line=$(fm_task_inbox_doorbell_line "$rec") || {
      FAILED=1
      printf 'not ok - %s (%s): could not construct the doorbell\n' "$name" "$version" >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    }
    tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l -- "$line" || {
      FAILED=1
      printf 'not ok - %s (%s): could not seed the draft\n' "$name" "$version" >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    }
    for i in 1 2 3 4 5; do
      sleep 1
      if [ "$(fm_tmux_composer_state "$SESSION:$win")" = pending ] \
        && fm_task_inbox_composer_holds tmux "$SESSION:$win" "$line"; then
        seeded=1
        break
      fi
    done
    if [ "$seeded" -ne 1 ] || [ -f "$handled" ] || [ -e "$acted" ]; then
      FAILED=1
      printf 'not ok - %s (%s): could not prove an unsubmitted own-doorbell draft\n' "$name" "$version" >&2
      tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    fi
    if ! fm_task_inbox_ring tmux "$SESSION:$win" "$rec"; then
      FAILED=1
      printf 'not ok - %s (%s): production ring refused the pending own doorbell\n' "$name" "$version" >&2
      tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
      return 0
    fi
  fi
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$mode" = fresh ] && [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    if [ "$mode" = fresh ]; then check_nonqueue_live "$win" "$home" "$task" || fail "nonqueue live watcher failed"; fi
    pass "$name ($version): $mode doorbell reached a real worker, which acted and acked with the mv"
    if [ "$mode" = fresh ]; then
      case "$name" in
        claude|opencode) check_busy_doorbell "$win" "$home" "$task" "$version" "$name" || FAILED=1 ;;
      esac
    fi
    if [ -n "${FM_SEND_INBOX_LIVE_EVIDENCE_DIR:-}" ]; then
      mkdir -p "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR" || fail 'could not create live evidence directory'
      {
        printf 'harness=%s\nmode=%s\nacted=yes\nacknowledged=yes\ninbox record:\n' "$version" "$mode"
        cat "$handled"
        printf '\nterminal:\n'
        tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" -S -50
      } > "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR/$name-$mode.txt" || fail 'could not retain live evidence'
    fi
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

check_claude_submit() {
  local mode=$1 binary=$2 version home task=live-claude win="claude-$1" gen prefix receipt
  local acted rec handled baseline line output expected b_gen b_seq hash rc=0 i=0 fault types=1 actual_types=0 min_enters=3 enters donor
  version=$(harness_version "$binary")
  home="$LAB/claude-$mode-home"
  fault="$home/fault"
  acted="$home/acted"
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  mkdir -p "$home/state" "$home/config" "$home/data" "$fault"
  gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$task" --state idle --source fm-recovery --event ready) \
    || fail "claude ($version): could not arm the live submit record"
  printf -v prefix '%q apply %q %q' "$ROOT/bin/fm-busy-event.sh" "$home/state" "$task"
  printf -v receipt '%q' "$fault/accepted"
  jq -n --arg prefix "$prefix" --arg gen "$gen" --arg receipt "$receipt" '
    def hook($state; $event): [{hooks:[{type:"command",command:
      ($prefix + " " + $state + " --gen " + $gen + " --source claude-hook --event " + $event
        + (if $event == "user-prompt-submit" then " --prompt-stdin" else "" end) + " 2>/dev/null"
        + (if $event == "user-prompt-submit" then " && touch " + $receipt else "" end) + " || true")}]}];
    {feedbackDrafts:"off",hooks:{UserPromptSubmit:hook("busy";"user-prompt-submit"),
      Stop:hook("idle";"stop"),StopFailure:hook("idle";"stop-failure"),SessionEnd:hook("idle";"session-end")}}
  ' > "$home/settings.json" || fail "claude ($version): could not prepare lifecycle settings"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- env -u CLAUDECODE -u GROK_AGENT -u GROK_HOOK_EVENT FM_HOME="$home" FM_TASK_INBOX="$home/state/$task.inbox" \
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    "$binary" --dangerously-skip-permissions --setting-sources user --settings "$home/settings.json" \
    || fail "claude ($version): could not launch the submit guard"
  wait_ready "$win" || fail "claude ($version): submit guard never reached an empty composer"
  printf 'window=%s:%s\nkind=%s\nharness=claude\n' "$SESSION" "$win" \
    "$([ "$mode" = typed ] && printf secondmate || printf ship)" > "$home/state/$task.meta"
  printf -v line "Run exactly this shell command now: \`touch %s\`. Then follow the mv instruction if you were given one. Reply with one short line." "$acted"
  expected=$line
  [ "$mode" = typed ] || expected=$(fm_task_inbox_doorbell_line "$rec")
  baseline=$(fm_busy_submit_baseline "$home/state" "$task" claude "$expected") \
    || fail "claude ($version): live submit baseline unavailable"
  printf '2\n' > "$fault/swallow"
  if [ "$mode" = unrelated ]; then
    donor="$win-donor"
    tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$donor" -c "$ROOT" \
      -- env -u CLAUDECODE FM_HOME="$home" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
      "$binary" --dangerously-skip-permissions --setting-sources user --settings "$home/settings.json" \
      || fail 'could not launch the unrelated-submit source'
    wait_ready "$donor" || fail 'unrelated-submit source never reached a composer'
    tmux -L "$SOCKET" send-keys -t "$SESSION:$donor" -l -- 'Reply with exactly UNRELATED_SUBMIT and do not use tools.' \
      || fail 'could not prepare the unrelated prompt'
    sleep 1
    printf '%s\n' "$SESSION:$donor" > "$fault/unrelated-window"
  fi
  if [ "$mode" = pending ]; then
    types=0
    fm_task_inbox_write "$home/state" "$task" "$line" >/dev/null \
      || fail "claude ($version): could not prepare pending record"
    line=$(fm_task_inbox_doorbell_line "$rec") || fail "claude ($version): could not prepare pending doorbell"
    tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l -- "$line" \
      || fail "claude ($version): could not type the pending doorbell"
    sleep 1
    if ! { [ "$(fm_tmux_composer_state "$SESSION:$win")" = pending ] \
      && fm_task_inbox_composer_holds tmux "$SESSION:$win" "$line"; }; then
      fail "claude ($version): pending doorbell was not proven in the composer"
    fi
    [ ! -e "$acted" ] && [ ! -e "$handled" ] \
      || fail "claude ($version): pending doorbell acted before submission"
    fm_busy_submit_confirmed "$home/state" "$task" claude "$baseline" \
      && fail "claude ($version): unsubmitted draft advanced the hook signal"
    FM_SEND_INBOX_LIVE_FAULT_DIR="$fault" fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || rc=$?
  else
    if [ "$mode" = blocked ] || [ "$mode" = unrelated ] || [ "$mode" = capture-failed ]; then
      printf '99\n' > "$fault/swallow"
      min_enters=5
    fi
    if [ "$mode" = capture-failed ]; then
      touch "$fault/fail-capture"
      min_enters=1
    fi
    [ "$mode" != typed ] || line="/$line"
    output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_INBOX_LIVE_FAULT_DIR="$fault" \
      bash "$ROOT/bin/fm-send.sh" "$task" "$line" 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    cat "$home/state/$task.busy-state" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" -S -30 >&2
    fail "claude ($version): $mode submit refused (exit $rc): ${output:-}"
  fi
  enters=$(cat "$fault/enters" 2>/dev/null)
  case "$enters" in ''|*[!0-9]*) fail "claude ($version): $mode submit left no Enter count" ;; esac
  [ "$enters" -ge "$min_enters" ] && [ "$enters" -le 5 ] \
    || fail "claude ($version): $mode submit used $enters Enter presses, expected $min_enters to 5"
  python3 - "$fault/enter-times" <<'PY' || fail 'Enter retries were closer than the required two seconds'
import pathlib, sys
times = [float(t) for t in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert all(b - a >= 2 for a, b in zip(times, times[1:]))
PY
  [ ! -e "$fault/types" ] || actual_types=$(wc -l < "$fault/types")
  [ "$actual_types" -eq "$types" ] \
    || fail "claude ($version): $mode submit retyped text"
  if [ "$mode" = typed ]; then
    read -r b_gen b_seq _ <<< "$baseline"
    hash=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read().replace(chr(0x2063).encode("utf-8"), b"")).hexdigest())' < "$fault/payload")
    baseline="$b_gen $b_seq $hash"
  fi
  if [ "$mode" = blocked ] || [ "$mode" = unrelated ] || [ "$mode" = capture-failed ]; then
    case "$output" in *'doorbell NOT delivered:'*) ;; *) fail "claude ($version): exhausted confirmation was not reported" ;; esac
    [ -f "$rec" ] && [ ! -e "$handled" ] && [ ! -e "$acted" ] \
      || fail "claude ($version): exhausted confirmation lost or acted on its durable record"
    if [ "$mode" = unrelated ]; then
      [ -e "$fault/accepted" ] || fail 'the unrelated real prompt did not emit a hook receipt'
      [ "$(fm_busy_current_gen "$home/state" "$task")" = "$gen" ] || fail 'unrelated submit changed the incarnation'
    else
      [ ! -e "$fault/accepted" ] || fail "claude ($version): swallowed Enters emitted a submit receipt"
    fi
    fm_busy_submit_confirmed "$home/state" "$task" claude "$baseline" \
      && fail "claude ($version): swallowed Enters advanced the hook signal"
  else
    fm_busy_submit_confirmed "$home/state" "$task" claude "$baseline" \
      || fail "claude ($version): $mode submit had no real harness confirmation"
    while [ "$i" -lt "$TIMEOUT" ]; do
      if [ -e "$acted" ] && { [ "$mode" = typed ] || [ -e "$handled" ]; }; then break; fi
      sleep 1
      i=$((i + 1))
    done
    if ! { [ -e "$acted" ] && { [ "$mode" = typed ] || [ -e "$handled" ]; }; }; then
      fail "claude ($version): $mode submit was not acted on and acknowledged within ${TIMEOUT}s"
    fi
    [ -e "$fault/accepted" ] || fail "claude ($version): $mode submit left no real hook receipt"
  fi
  CHECKED=$((CHECKED + 1))
  if [ -n "${FM_SEND_INBOX_LIVE_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR" || fail 'could not create live evidence directory'
    {
      printf 'harness=%s\nmode=%s\nEnter presses=%s\nliteral text writes=%s\n' "$version" "$mode" "$enters" "$actual_types"
      printf 'fm-send output:\n%s\n' "${output:-<direct inbox ring>}"
      printf 'acted=%s\nacknowledged=%s\n' "$([ -e "$acted" ] && echo yes || echo no)" "$([ -e "$handled" ] && echo yes || echo no)"
      printf 'harness state:\n'
      cat "$home/state/$task.busy-state"
      printf '\nsubmit receipts:\n'
      for hash in "$home/state/$task.submit-state/"*; do
        [ ! -f "$hash" ] || { printf '%s: ' "${hash##*/}"; cat "$hash"; }
      done
      printf '\nEnter timestamps:\n'
      cat "$fault/enter-times"
      printf '\nterminal:\n'
      tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" -S -50
      if [ -n "${donor:-}" ]; then
        printf '\nunrelated source terminal:\n'
        tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$donor" -S -50
      fi
    } > "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR/claude-$mode.txt" || fail 'could not retain live evidence'
  fi
  pass "claude ($version): $mode submit checked real lifecycle hooks with $enters Enter presses"
  [ -z "${donor:-}" ] || tmux -L "$SOCKET" kill-window -t "$SESSION:$donor" 2>/dev/null || true
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'cursor claude codex opencode pi pi-signed grok kimi muse omp gemini rovo agy devin commandcode polytoken'}
for h in $HARNESSES; do
  case "$h" in
    cursor) binary=$(fm_cursor_resolve_binary 2>/dev/null) || binary= ;;
    *) binary=$(command -v "$h" 2>/dev/null) || binary= ;;
  esac
  if [ -n "$binary" ]; then
    if [ "$h" = claude ]; then
      if [ -n "${FM_SEND_INBOX_LIVE_CLAUDE_MODES:-}" ]; then
        for mode in $FM_SEND_INBOX_LIVE_CLAUDE_MODES; do check_claude_submit "$mode" "$binary"; done
        continue
      fi
      if [ "${FM_SEND_INBOX_LIVE_PENDING_ONLY:-0}" != 1 ]; then
        check_claude_submit typed "$binary"
        check_claude_submit fresh "$binary"
        check_claude_submit blocked "$binary"
        check_claude_submit capture-failed "$binary"
        check_claude_submit unrelated "$binary"
      fi
      check_claude_submit pending "$binary"
      continue
    fi
    if [ "${FM_SEND_INBOX_LIVE_PENDING_ONLY:-0}" != 1 ]; then
      check_harness_doorbell "$h" fresh "$binary"
    fi
    # Pending already proven by original live run.
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED cases honored the doorbell contract"
