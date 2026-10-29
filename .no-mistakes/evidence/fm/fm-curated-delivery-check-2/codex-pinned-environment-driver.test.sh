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
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex)
      printf '%s -c %q -c %q -c %q -c %q' 'codex -c check_for_update_on_startup=false --dangerously-bypass-approvals-and-sandbox --disable hooks' \
        'shell_environment_policy.inherit="all"' \
        'shell_environment_policy.include_only=[]' \
        'shell_environment_policy.ignore_default_excludes=true' \
        "shell_environment_policy.set={FM_HOME=\"$home\",FM_TASK_INBOX=\"$home/state/live-codex.inbox\"}"
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
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
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
    pass "$name ($version): $mode doorbell reached a real worker, which acted and acked with the mv"
    if [ "$mode" = fresh ]; then
      case "$name" in
        claude|opencode) check_busy_doorbell "$win" "$home" "$task" "$version" "$name" || FAILED=1 ;;
      esac
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

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'cursor claude codex opencode pi pi-signed grok kimi muse omp gemini rovo agy devin commandcode polytoken'}
for h in $HARNESSES; do
  case "$h" in
    cursor) binary=$(fm_cursor_resolve_binary 2>/dev/null) || binary= ;;
    *) binary=$(command -v "$h" 2>/dev/null) || binary= ;;
  esac
  if [ -n "$binary" ]; then
    if [ "${FM_SEND_INBOX_LIVE_PENDING_ONLY:-0}" != 1 ]; then
      check_harness_doorbell "$h" fresh "$binary"
    fi
    check_harness_doorbell "$h" pending "$binary"
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
