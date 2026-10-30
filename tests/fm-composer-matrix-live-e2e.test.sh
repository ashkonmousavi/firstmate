#!/usr/bin/env bash
# tests/fm-composer-matrix-live-e2e.test.sh - the live composer-matrix guard
# (live-harness-optin family; task fm-composer-thin-adapter-refactor-r1).
#
# The shared composer classifier's shape catalogue (bin/fm-composer-lib.sh) is
# built entirely from vendor-rendered signals, so per
# .agents/skills/firstmate-coding-guidelines it must be proven against the
# REAL harnesses: a stub can only confirm the assumption already written into
# the stub. This guard launches every INSTALLED verified harness idle in an
# isolated tmux server and requires the real fm_tmux_composer_state to reach
# `empty`, failing loudly with the harness name and version. It also proves:
#   - the strict blank-row posture live: a plain shell pane with a blank
#     cursor row must classify unknown and defer injection;
#   - the zellij false-positive regression live (when zellij is installed): a
#     pane whose content changes for reasons unrelated to submission must NOT
#     report a delivered send, and a real claude-in-zellij `dump-screen
#     --ansi` capture must classify empty through the zellij thin adapter;
#   - the CURSORLESS read of the same real idle pane, which is the read every
#     non-tmux backend performs and the one a vendor's own footer rows can
#     break: a harness that renders a statusLine or mode hint below its
#     composer must never make an idle composer read `pending`, because that
#     verdict is what skips a steer's doorbell fleet-wide.
#
# Run explicitly with FM_COMPOSER_MATRIX_LIVE=1. The Claude wrapped-composer
# check submits a prompt and spends model tokens. An absent harness is reported
# explicitly and skipped; a run that verified nothing fails rather than
# passing vacuously. Refresh docs/verification/runtime-backends.md ("Composer
# classification matrix") from this guard's output after any harness upgrade.
#
# Folder trust: harnesses are launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_COMPOSER_MATRIX_LIVE tmux python3

SOCKET="fm-cmx-live-$$"
SESSION="cmxlive"
ZELLIJ_SESSION="fm-cmx-live-zj-$$"
CHECKED=0
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${ZJ_BG:-}" ] || kill "$ZJ_BG" 2>/dev/null || true
  if command -v zellij >/dev/null 2>&1; then
    zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmx-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

check_harness_idle_empty() {  # <name> <launch-cmd...>
  local name=$1 win="hx-$1" verdict='' i=0 budget=${FM_COMPOSER_MATRIX_LIVE_POLLS:-45} version dismissed=0 startup_screen
  shift
  version=$(harness_version "$1")
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- "$@" \
    || fail "$name ($version): could not launch in the isolated tmux server"
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && break
    i=$((i + 1))
    # A fresh harness may park on a vendor update-available modal (observed
    # live: codex 0.146.0 and opencode 1.14.46), which the strict classifier
    # correctly refuses to call a composer. Dismiss it once, mid-budget, with
    # a single Escape - the one key that submits nothing anywhere and is how
    # the audit declined the same prompts. Never Enter: on codex's dialog
    # Enter would RUN the upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      # Trust prompts also accept Escape, but there it exits the harness and
      # erases the actionable failure surface. Preserve those prompts; only
      # dismiss a non-trust startup modal.
      startup_screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$startup_screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  if [ "$verdict" != empty ]; then
    printf '# %s pane tail at failure:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): idle composer never classified empty (last verdict: %s)\n' \
      "$name" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): real idle composer classifies empty"
    check_harness_idle_cursorless "$name" "$version" "$SESSION:$win"
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# The same proven-idle pane read the way every cursorless backend reads it
# (herdr, zellij, cmux, orca): no #{cursor_y} to anchor the shape, so the
# bottom-most shape on the screen wins. A vendor footer drawn BELOW the
# composer - a statusLine, a permission-mode hint - lives exactly where that
# rule looks, and a footer row opening with an agent prompt glyph used to be
# selected as a composer holding typed text, skipping every doorbell to that
# worker (live regression, claude 2.x on herdr 0.8.0, 2026-09-20).
# `pending` is the one verdict that blocks a steer, so that is what this
# refuses; `unknown` stays legitimate for a shape only identity can prove.
check_harness_idle_cursorless() {  # <name> <version> <target>
  local name=$1 version=$2 target=$3 pane caps verdict identity
  pane=$(fm_tmux_composer_capture "$target") || {
    FAILED=1
    printf 'not ok - %s (%s): cursorless re-read could not capture the proven-idle pane\n' \
      "$name" "$version" >&2
    return 0
  }
  caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')
  verdict=$(fm_composer_classify_screen "$caps" "$pane")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$pane" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  if [ "$verdict" = pending ]; then
    printf '# %s cursorless pane tail:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): a proven-idle composer read cursorless as pending; every steer to this harness would skip its doorbell\n' \
      "$name" "$version" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the same idle pane read cursorless is not pending (verdict: $verdict)"
  fi
}

claude_wrapped_surface() {
  python3 -c '
import re
import sys

mode, expected = sys.argv[1:]
rows = [[]]
dim = False
for token in re.finditer(r"\x1b\[([0-9;]*)m|([^\x1b])", sys.stdin.read()):
    if token[1] is not None:
        codes = [int(code or 0) for code in token[1].split(";")]
        i = 0
        while i < len(codes):
            code = codes[i]
            if code == 0 or code == 22:
                dim = False
            elif code == 2:
                dim = True
            elif code in (38, 48, 58) and i + 1 < len(codes):
                i += 4 if codes[i + 1] == 2 else 2
            i += 1
    elif token[2] == "\n":
        rows.append([])
    else:
        rows[-1].append((token[2], dim))
plain = ["".join(c for c, _ in row).strip() for row in rows]
tops = [i for i, row in enumerate(plain) if row.startswith("─") and "fm-wrap-live" in row]
if not tops:
    sys.exit(1)
top = tops[-1]
bottom = next((i for i in range(top + 1, len(rows)) if re.fullmatch(r"─+", plain[i])), None)
if bottom is None or bottom - top < 3 or not plain[top + 1].startswith("❯"):
    sys.exit(1)
body = rows[top + 1:bottom]
prompt = next(i for i, (c, _) in enumerate(body[0]) if c == "❯")
body[0] = body[0][prompt + 1:]
text = ["".join(c for c, _ in row).strip() for row in body]
if mode == "ghost":
    visible = [(c, faint) for row in body for c, faint in row if not c.isspace()]
    valid = sum(bool(line) for line in text) >= 2 and visible and all(faint for _, faint in visible)
else:
    valid = "".join("".join(text).split()) == "".join(expected.split())
    if mode == "newline":
        valid = valid and not text[0] and any(text[1:])
    else:
        valid = valid and sum(bool(line) for line in text) >= 2
sys.exit(0 if valid else 1)
' "$1" "${2:-}"
}

check_claude_wrapped() {
  local target="$SESSION:claude-wrap" version pane='' plain cy caps actual mode draft i
  version=$(harness_version claude)
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n claude-wrap -c "$ROOT" \
    env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 \
    claude --name fm-wrap-live --setting-sources '' \
    --settings '{"disableAllHooks":true,"promptSuggestionEnabled":true}' \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools '' \
    --system-prompt 'Answer briefly in plain text. Do not use tools or change files.' \
    || fail "claude ($version): could not launch the wrapped-composer probe"
  tmux -L "$SOCKET" resize-window -t "$target" -x 40 -y 40 \
    || fail "claude ($version): could not narrow the wrapped-composer pane"
  for ((i=0; i<45; i++)); do
    [ "$(fm_tmux_composer_state "$target")" = empty ] && break
    sleep 1
  done
  [ "$i" -lt 45 ] || fail "claude ($version): wrapped-composer probe never became ready"
  tmux -L "$SOCKET" send-keys -t "$target" -l \
    'I want to add a narrow-terminal regression check for wrapped prompt suggestions and multiline drafts. First, explain in one sentence why terminal width matters. I will ask you to outline the regression cases next.' \
    || fail "claude ($version): could not type the probe prompt"
  tmux -L "$SOCKET" send-keys -t "$target" Enter \
    || fail "claude ($version): could not submit the probe prompt"
  draft='Unsent draft spanning several terminal rows to prove real input remains pending in a narrow composer'
  for mode in ghost wrapped newline; do
    case "$mode" in
      wrapped)
        tmux -L "$SOCKET" send-keys -t "$target" -l "$draft" \
          || fail "claude ($version): could not type the wrapped draft"
        ;;
      newline)
        tmux -L "$SOCKET" send-keys -t "$target" C-u \
          || fail "claude ($version): could not clear the wrapped draft"
        printf '\n%s' "$draft" | tmux -L "$SOCKET" load-buffer -b wrapped-draft - \
          || fail "claude ($version): could not buffer the newline draft"
        tmux -L "$SOCKET" paste-buffer -p -d -b wrapped-draft -t "$target" \
          || fail "claude ($version): could not type the newline draft"
        ;;
    esac
    for ((i=0; i<90; i++)); do
      pane=$(fm_tmux_composer_capture "$target")
      printf '%s\n' "$pane" | claude_wrapped_surface "$mode" "$draft" && break
      sleep 1
    done
    if [ "$i" -eq 90 ]; then
      tmux -L "$SOCKET" capture-pane -p -t "$target" >&2
      fail "claude ($version): required titled $mode surface not rendered; live coverage unavailable"
    fi
    cy=$(fm_tmux_composer_cursor_row "$target")
    for caps in "$(fm_tmux_composer_caps)" \
      $'styled=1\ncursor=0\nidentity=0\nrows=0' $'styled=1\ncursor=0\nidentity=1\nrows=0'; do
      actual=$(fm_composer_classify_screen "$caps" "$pane" "$cy" $'claude\tidle')
      case "$mode:$actual" in
        ghost:empty|wrapped:pending|newline:pending) ;;
        *) fail "claude ($version): $mode composer classified $actual with $caps" ;;
      esac
    done
    if [ "$mode" = ghost ]; then
      plain=$(tmux -L "$SOCKET" capture-pane -p -t "$target" -S 0 -E -)
      for caps in $'styled=0\ncursor=0\nidentity=1\nrows=0' $'styled=0\ncursor=1\nidentity=1\nrows=0'; do
        actual=$(fm_composer_classify_screen "$caps" "$plain" "$cy" $'claude\tidle')
        [ "$actual" = unknown ] \
          || fail "claude ($version): unstyled wrapped suggestion classified $actual, expected unknown"
      done
    fi
    CHECKED=$((CHECKED + 1))
    pass "claude ($version): real titled $mode composer verified through cursor and cursorless reads"
  done
  tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
}

# --- 1. Every installed verified harness must reach a proven-empty composer --
for h in claude codex opencode pi grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_idle_empty "$h" "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if command -v claude >/dev/null 2>&1; then
  check_claude_wrapped
fi

# --- 2. The strict blank-row posture, live ----------------------------------
# A plain shell pane parked on a blank line between two rules (the audit's
# sleep-pane counterexample): the permissive rule read this empty; strict must
# defer.
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n strictblank -c "$ROOT" \
  -- bash -c 'printf "────────────────────────\n\n"; printf "\033[A"; exec sleep 300'
sleep 1
verdict=$(fm_tmux_composer_state "$SESSION:strictblank")
if [ "$verdict" = unknown ]; then
  if fm_pane_input_pending "$SESSION:strictblank"; then
    CHECKED=$((CHECKED + 1))
    pass "strict posture live: a blank shell row classifies unknown and injection defers"
  else
    FAILED=1
    printf 'not ok - strict posture live: pane_input_pending did not defer on an unknown verdict\n' >&2
  fi
else
  FAILED=1
  printf 'not ok - strict posture live: blank shell row classified %s, expected unknown\n' "${verdict:-unreadable}" >&2
fi
tmux -L "$SOCKET" kill-window -t "$SESSION:strictblank" 2>/dev/null || true

# --- 3. zellij: real classifier + the false-positive regression -------------
if command -v zellij >/dev/null 2>&1; then
  zj_version=$(zellij --version 2>/dev/null | head -1)
  [ -n "$zj_version" ] || zj_version='version-unknown'
  export FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source zellij 2>/dev/null \
    || fail "zellij ($zj_version): adapter source failed"

  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  zellij --session "$ZELLIJ_SESSION" options --default-shell bash >/dev/null 2>&1 &
  ZJ_BG=$!
  i=0
  while [ "$i" -lt 10 ] && ! fm_backend_zellij_session_exists "$ZELLIJ_SESSION"; do
    i=$((i + 1))
    sleep 0.5
  done
  fm_backend_zellij_session_exists "$ZELLIJ_SESSION" \
    || fail "zellij ($zj_version): probe session setup failed"
  panes=$(fm_backend_zellij_cli "$ZELLIJ_SESSION" action list-panes --json 2>/dev/null) \
    || fail "zellij ($zj_version): pane discovery command failed"
  pane_id=$(printf '%s' "$panes" | jq -r '.[]? | select(.is_plugin == false) | .id' 2>/dev/null | head -1)
  case "$pane_id" in
    ''|*[!0-9]*) fail "zellij ($zj_version): pane discovery returned no terminal pane" ;;
  esac
  target="$ZELLIJ_SESSION:$pane_id"

  fm_backend_zellij_send_literal "$target" 'while sleep 1; do date; done' \
    || fail "zellij ($zj_version): clock probe setup write failed"
  fm_backend_zellij_send_key "$target" Enter \
    || fail "zellij ($zj_version): clock probe setup submit failed"
  sleep 2
  probe='# audit-probe-never-submitted'
  fm_backend_zellij_send_literal "$target" "$probe" \
    || fail "zellij ($zj_version): false-positive probe write failed"
  sleep 0.5
  probe_capture=$(fm_backend_zellij_capture "$target" 40 2>/dev/null) \
    || fail "zellij ($zj_version): false-positive probe capture failed"
  case "$probe_capture" in
    *"$probe"*) ;;
    *) fail "zellij ($zj_version): false-positive probe text was not visible after typing" ;;
  esac
  verdict=$(fm_composer_submit_retry_core fm_backend_zellij_send_key fm_backend_zellij_composer_state \
    "$target" 2 0.5 2>/dev/null)
  case "$verdict" in
    pending|unknown)
      CHECKED=$((CHECKED + 1))
      pass "zellij ($zj_version): unrelated pane change never confirms delivery (verdict: $verdict)"
      ;;
    send-failed)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe text was not typed (send-failed)\n' "$zj_version" >&2
      ;;
    *)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe returned unexpected verdict %s (expected pending or unknown)\n' \
        "$zj_version" "${verdict:-none}" >&2
      ;;
  esac
  kill "$ZJ_BG" 2>/dev/null || true
  ZJ_BG=
  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
else
  note "harness absent, not verified here: zellij (false-positive regression not exercised)"
fi

# --- refuse a vacuous pass ---------------------------------------------------
[ "$FAILED" -eq 0 ] || fail "live composer-matrix guard observed failures above"
[ "$CHECKED" -gt 0 ] || fail "live composer-matrix guard verified nothing (no harness installed?); refusing a vacuous pass"
pass "live composer-matrix guard verified $CHECKED live surface(s)"
