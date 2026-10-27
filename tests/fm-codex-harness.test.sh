#!/usr/bin/env bash
# Behavior tests for the verified Codex CLI crewmate adapter's typed launch
# brief. codex-cli 0.163.0 never runs the positional launch prompt, so
# bin/fm-spawn.sh starts codex bare and delivers `FIRSTMATE_OP: v1
# launch-brief` through fm_backend_send_text_submit after a readiness gate
# that answers codex's own launch dialogs (Enter for the folder-trust dialog,
# Escape for the update dialog, whose Enter would run a global npm install).
# These tests drive that whole gate against a state-machine fake tmux, the
# same shape tests/fm-kimi-harness.test.sh uses for kimi's gates; the real
# harness is proven by the opt-in live guard
# tests/fm-codex-brief-typed-herdr-lab-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh answers from environment markers and process ancestry. A
# suite run from inside Cursor, Claude, Pi, or Grok inherits those markers and
# its own real ancestry, either of which can decide a case the detection cases
# meant to control. Drop the ambient markers so the asserted verdict does not
# depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-harness)
CODEX_RUNTIME_TASK_TMP=
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_codex_harness() {
  [ -z "$CODEX_RUNTIME_TASK_TMP" ] || fm_test_remove_tree "$CODEX_RUNTIME_TASK_TMP"
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup_codex_harness EXIT

# The fake tmux is a codex 0.163.0 screen state machine driven by
# FM_FAKE_CODEX_STATE, byte-shaped like the live codex fixtures in
# tests/fm-composer-lib.test.sh: the ready screen's SGR-2 dim placeholder
# behind the bold glyph row is what the shared classifier reads as an empty
# composer with the cursor on the glyph row, and the typed screen is that row
# holding the envelope, which reads pending. Dialog screens are plain text
# with the exact option rows the gates match.
# FM_FAKE_CODEX_LAUNCH_DIALOGS picks the first screen codex shows after its
# launch line is submitted: "update,trust" (default) or "trust" walks the
# gate through answering them, "partial" parks on an incomplete dialog draw,
# and "none" leaves codex on a blank boot screen forever.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_CODEX_STATE" 2>/dev/null || true)
ESC=$'\033'
bg="${ESC}[48;2;57;57;57m"
composer_row() {  # <content-after-glyph>
  printf '%s%s%s%s %s%s%s' "${ESC}[1m" "$bg" '›' "${ESC}[0m${bg}" "$1" "${ESC}[0m"
}
dim_placeholder='Ask Codex to do anything'
footer="  ${ESC}[38;2;246;226;183mGPT-6.1-Sol default${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;171;223;167m~/wt${ESC}[0m"
NL=$'\n'
update_dialog="  Update available · 0.163.0 → 0.164.0${NL}  Release notes: https://github.com/openai/codex/releases/latest${NL}${NL}› 1. Update now (runs \`npm install -g @openai/codex\`)${NL}  2. Skip${NL}  3. Skip until next version${NL}${NL}  enter continue · esc skip"
trust_dialog="  Folder access${NL}  /wt/scatch${NL}${NL}  Trust this folder? Codex can read, edit, and run files here.${NL}${NL}› 1. Trust and continue${NL}  2. Quit${NL}${NL}  enter continue · esc quit"
update_partial="  Update available · 0.163.0 → 0.164.0${NL}${NL}  enter continue · esc skip"
fake_screen() {
  case "$state" in
    update)
      printf '%s\n' "$update_dialog" ;;
    update-partial)
      printf '%s\n' "$update_partial" ;;
    trust)
      printf '%s\n' "$trust_dialog" ;;
    ready|typed|delivered|working)
      printf 'transcript line\n\n'
      case "$state" in
        ready) composer_row "${ESC}[2m${bg}${dim_placeholder}${ESC}[0m" ;;
        typed) composer_row ' FIRSTMATE_OP: v1 launch-brief: Read the brief at /wt/launch-brief.md and follow it exactly.' ;;
        delivered)
          printf '%s\n\n' '› FIRSTMATE_OP: v1 launch-brief: Read the brief at /wt/launch-brief.md and follow it exactly.'
          printf '%s\n' '• Worked for 6s • 2:39 AM'
          composer_row "${ESC}[2m${bg}${dim_placeholder}${ESC}[0m" ;;
        working)
          printf '%s\n' '• Working (1s • esc to interrupt)'
          composer_row "${ESC}[2m${bg}${dim_placeholder}${ESC}[0m" ;;
      esac
      printf '\n'
      printf '%s\n%s\n' "$footer" '  ? for shortcuts' ;;
    *)
      : ;;
  esac
}
fake_cursor_y() {
  # The composer row index of each screen: the classifier anchors on the
  # pane cursor, so it must point at the glyph row of the state's screen.
  case "$state" in
    ready|typed) printf '2\n' ;;
    working) printf '3\n' ;;
    delivered) printf '5\n' ;;
    *) printf '1\n' ;;
  esac
}
first_dialog_state() {
  case "${FM_FAKE_CODEX_LAUNCH_DIALOGS:-update,trust}" in
    *update*) printf 'update\n' ;;
    *trust*) printf 'trust\n' ;;
    *partial*) printf 'update-partial\n' ;;
    *) printf '\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' node; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
window_file="$(dirname "$0")/.spawn-window"
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "$window_file" ] || cat "$window_file"
    exit 0
    ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0
    ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = "-l" ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'")
          staged=${literal#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || literal=$(cat "$staged")
          ;;
      esac
      # The launch literal is the resolved staged command, matched on its
      # own flags: a task id like codex-success-z1 contains "codex" too, so a
      # name match would swallow the typed envelope below.
      case "$literal" in
        *'--dangerously-bypass-approvals-and-sandbox'*|*'--prompt-interactive'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          # The launch line itself is submitted by its own Enter; codex shows
          # its first screen only after that Enter, so an intermediate
          # 'launched' state keeps the launch's own Enter from being read as
          # a dialog answer.
          printf 'launched\n' > "$FM_FAKE_CODEX_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_CODEX_TYPED_LOG"
          case "$state" in
            ready)
              case "$literal" in
                *'FIRSTMATE_OP: v1 launch-brief:'*) printf 'typed\n' > "$FM_FAKE_CODEX_STATE" ;;
              esac
              ;;
          esac
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        printf '%s\n' "$state" >> "$FM_FAKE_CODEX_ENTER_LOG"
        case "$state" in
          launched)
            # The launch line's own Enter: codex boots and shows its first
            # screen. Enter on a COMPLETE update dialog would confirm the
            # preselected global npm install, so that transition is modeled
            # as never reaching a composer (update-stuck below).
            first_dialog_state > "$FM_FAKE_CODEX_STATE"
            ;;
          update)
            printf 'update-stuck\n' > "$FM_FAKE_CODEX_STATE"
            ;;
          trust)
            case "${FM_FAKE_CODEX_TRUST_CLEARS:-yes}" in
              yes) printf 'ready\n' > "$FM_FAKE_CODEX_STATE" ;;
              no) printf 'trust\n' > "$FM_FAKE_CODEX_STATE" ;;
            esac
            ;;
          typed)
            case "${FM_FAKE_CODEX_DELIVERY:-delivered}" in
              delivered) printf 'delivered\n' > "$FM_FAKE_CODEX_STATE" ;;
              working) printf 'working\n' > "$FM_FAKE_CODEX_STATE" ;;
              swallow) : ;;
            esac
            ;;
          ready|delivered|working)
            printf '%s\n' "$state" >> "$FM_FAKE_CODEX_STRAY_ENTER_LOG"
            ;;
        esac
        ;;
      *' Escape '*)
        printf '%s\n' "$state" >> "$FM_FAKE_CODEX_ESCAPE_LOG"
        case "$state" in
          update)
            case "${FM_FAKE_CODEX_LAUNCH_DIALOGS:-update,trust}" in
              *trust*) printf 'trust\n' > "$FM_FAKE_CODEX_STATE" ;;
              *) printf 'ready\n' > "$FM_FAKE_CODEX_STATE" ;;
            esac
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" = yes ]; then
      case " $* " in
        *' -S -0 '*)
          echo "can't find pane" >&2
          exit 1
          ;;
      esac
    fi
    fake_screen
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh codex
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Codex dispatch.

## Firstmate spec
Verify typed launch-brief delivery.
EOF
  printf 'codex\n' > "$home/config/crew-harness"
  printf '999999 0\n' > "$home/config/lane-capacity"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/typed.log"
  : > "$case_dir/codex.state"
  : > "$case_dir/enter.log"
  : > "$case_dir/escape.log"
  : > "$case_dir/stray-enter.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_CODEX_STATE="$case_dir/codex.state" \
    FM_FAKE_CODEX_TYPED_LOG="$case_dir/typed.log" \
    FM_FAKE_CODEX_ENTER_LOG="$case_dir/enter.log" \
    FM_FAKE_CODEX_ESCAPE_LOG="$case_dir/escape.log" \
    FM_FAKE_CODEX_STRAY_ENTER_LOG="$case_dir/stray-enter.log" \
    FM_FAKE_CODEX_LAUNCH_DIALOGS="${FM_FAKE_CODEX_LAUNCH_DIALOGS:-update,trust}" \
    FM_FAKE_CODEX_TRUST_CLEARS="${FM_FAKE_CODEX_TRUST_CLEARS:-yes}" \
    FM_FAKE_CODEX_DELIVERY="${FM_FAKE_CODEX_DELIVERY:-delivered}" \
    FM_FAKE_TMUX_VISIBLE_FAILS="${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_CODEX_READY_POLLS="${FM_CODEX_READY_POLLS:-12}" FM_CODEX_PROCESSING_POLLS=6 \
    FM_CODEX_POLL_INTERVAL=0 FM_CODEX_SUBMIT_SLEEP=0 FM_CODEX_SUBMIT_SETTLE=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness codex --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_codex_launches_bare_and_delivers_typed_brief() {
  local id rec out rc launch typed brief_real
  id="codex-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "verified codex typed-brief launch should succeed"
  assert_contains "$out" "spawned $id harness=codex" "codex spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" " codex --dangerously-bypass-approvals-and-sandbox --disable hooks" \
    "codex launch lost its bare crewmate shape (bypass + hook-disable)"
  assert_contains "$launch" "notify=" "codex launch lost its turn-end notify program"
  assert_not_contains "$launch" "encode launch-brief" \
    "codex launch still carried the positional brief"

  # The update dialog was skipped with Escape and the trust dialog answered
  # with Enter, and no Enter ever went to the update dialog.
  [ "$(grep -cx update "$CASE_DIR/escape.log")" -eq 1 ] \
    || fail "the update dialog was not skipped exactly once: $(cat "$CASE_DIR/escape.log")"
  [ "$(grep -cx trust "$CASE_DIR/enter.log")" -eq 1 ] \
    || fail "the trust dialog was not answered exactly once: $(cat "$CASE_DIR/enter.log")"
  assert_no_grep '^update$' "$CASE_DIR/enter.log" "an Enter confirmed the update dialog's npm install"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  typed=$(cat "$CASE_DIR/typed.log")
  case "$typed" in
    *$'\xe2\x81\xa3'"FIRSTMATE_OP: v1 launch-brief: Read the brief at $brief_real and follow it exactly.") : ;;
    *) fail "codex typed envelope was not the exact launch-brief pointer: $typed" ;;
  esac
  [ ! -s "$CASE_DIR/stray-enter.log" ] \
    || fail "a stray Enter reached the live composer: $(cat "$CASE_DIR/stray-enter.log")"
  pass "fm-spawn: codex launches bare, answers its dialogs, and types its launch brief"
}

test_codex_positional_probe_restores_the_positional_launch() {
  local id rec out rc launch
  id="codex-positional-z2-$$"
  rec=$(make_spawn_case positional "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  out=$(FM_CODEX_POSITIONAL_LAUNCH=1 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "the positional probe launch should succeed without the typed gates"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "encode launch-brief" \
    "the positional probe launch did not carry the positional brief"
  [ ! -s "$CASE_DIR/typed.log" ] \
    || fail "the typed gate ran under the positional probe: $(cat "$CASE_DIR/typed.log")"
  pass "fm-spawn: FM_CODEX_POSITIONAL_LAUNCH=1 keeps the positional launch and skips the typed gates"
}

test_codex_never_ready_reports_codex_did_not_take_the_brief() {
  local id rec out rc
  id="codex-neverready-z3-$$"
  rec=$(make_spawn_case neverready "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  # A codex that never draws a composer: its boot screen stays blank forever.
  out=$(FM_FAKE_CODEX_LAUNCH_DIALOGS=none FM_CODEX_READY_POLLS=3 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a codex that never showed a ready composer spawned anyway"
  assert_contains "$out" "codex did not take the brief" \
    "the never-ready failure did not report that codex did not take the brief"
  assert_grep "codex did not take the brief" "$HOME_DIR/state/$id.status" \
    "the never-ready spawn did not record its failed status line"
  [ ! -s "$CASE_DIR/typed.log" ] \
    || fail "the envelope was typed into a pane that was never ready"
  pass "fm-spawn: a codex that never readies reports 'codex did not take the brief'"
}

test_codex_answering_the_update_dialog_with_enter_never_readies() {
  local id rec out rc
  id="codex-updates-z4-$$"
  rec=$(make_spawn_case updates "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  # The fake parks codex on the update path when Enter confirms "Update now",
  # so any gate that loses the escape-key discipline never readies: only
  # Escape reaches the composer here.
  out=$(FM_FAKE_CODEX_LAUNCH_DIALOGS=update FM_CODEX_READY_POLLS=4 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "an update-only launch should skip the dialog and spawn"
  assert_not_contains "$(cat "$CASE_DIR/enter.log")" "update" \
    "an Enter confirmed the update dialog's npm install"
  pass "fm-spawn: the update dialog is skipped, never confirmed"
}

test_codex_trust_dialog_that_never_clears_fails() {
  local id rec out rc
  id="codex-truststuck-z5-$$"
  rec=$(make_spawn_case truststuck "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  out=$(FM_FAKE_CODEX_LAUNCH_DIALOGS=trust FM_FAKE_CODEX_TRUST_CLEARS=no FM_CODEX_READY_POLLS=4 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a trust dialog that never cleared still spawned"
  assert_contains "$out" "codex did not take the brief" \
    "the stuck-trust failure did not report that codex did not take the brief"
  assert_contains "$out" "trust dialog was answered" \
    "the stuck-trust failure did not name the answered trust dialog"
  [ "$(grep -cx trust "$CASE_DIR/enter.log")" -ge 1 ] \
    || fail "the stuck trust dialog was never answered with Enter"
  pass "fm-spawn: a trust dialog that never clears fails the spawn"
}

test_codex_partial_dialog_text_is_never_answered_or_trusted() {
  local id rec out rc
  id="codex-partial-z6-$$"
  rec=$(make_spawn_case partial "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  out=$(FM_FAKE_CODEX_LAUNCH_DIALOGS=partial FM_CODEX_READY_POLLS=4 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "partial dialog text alone read as a ready composer"
  assert_contains "$out" "codex did not take the brief" \
    "the partial-dialog failure did not report that codex did not take the brief"
  [ ! -s "$CASE_DIR/escape.log" ] || fail "a partial dialog was answered with Escape: $(cat "$CASE_DIR/escape.log")"
  [ ! -s "$CASE_DIR/typed.log" ] || fail "the envelope was typed over partial dialog text"
  pass "fm-spawn: partial dialog text never receives a key and never reads ready"
}

test_codex_unconfirmed_submit_refuses_the_spawn() {
  local id rec out rc
  id="codex-swallow-z7-$$"
  rec=$(make_spawn_case swallow "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  # Every Enter is swallowed forever: the envelope stays pending in the
  # composer, the submit verdict never reads empty, and the spawn must refuse
  # rather than launch a worker whose brief never ran.
  out=$(FM_FAKE_CODEX_DELIVERY=swallow FM_CODEX_SUBMIT_RETRIES=2 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a submit that never confirmed still spawned"
  assert_contains "$out" "codex did not take the brief" \
    "the unconfirmed-submit failure did not report that codex did not take the brief"
  pass "fm-spawn: an unconfirmed brief submit refuses the spawn"
}

test_codex_processing_confirmation_accepts_the_busy_footer() {
  local id rec out rc
  id="codex-working-z8-$$"
  rec=$(make_spawn_case working "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  # The turn is still running when processing is polled: the completed-turn
  # marker never appears and only the busy footer (`esc to interrupt`)
  # confirms processing.
  out=$(FM_FAKE_CODEX_DELIVERY=working run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a busy footer should confirm processing"
  pass "fm-spawn: the working footer confirms brief processing"
}

test_codex_readiness_capture_failure_fails_loudly() {
  local id rec out rc
  id="codex-capturefail-z9-$$"
  rec=$(make_spawn_case capturefail "$id")
  read_spawn_record "$rec"
  CODEX_RUNTIME_TASK_TMP="/tmp/fm-$id"
  rm -rf "$CODEX_RUNTIME_TASK_TMP"
  out=$(FM_FAKE_TMUX_VISIBLE_FAILS=yes FM_CODEX_READY_POLLS=3 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable viewport still spawned"
  assert_contains "$out" "codex did not take the brief" \
    "the capture failure did not report that codex did not take the brief"
  assert_contains "$out" "could not read the visible viewport" \
    "the capture failure did not name the unreadable viewport"
  pass "fm-spawn: a viewport read failure fails the codex spawn loudly"
}

test_codex_refuses_a_backend_without_a_viewport_capture() {
  local id rec out rc
  id="codex-no-viewport-z10-$$"
  rec=$(make_spawn_case no-viewport "$id")
  read_spawn_record "$rec"
  fm_fake_exit0 "$FAKEBIN_DIR" cmux
  rc=0
  out=$(FM_BACKEND=cmux run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a codex spawn on a backend without a viewport capture should refuse"
  assert_contains "$out" "backend 'cmux' has no verified viewport-bounded capture" \
    "codex refusal did not name the backend and the missing viewport capability"
  [ ! -s "$CASE_DIR/launch.log" ] \
    || fail "codex was launched on a backend without a viewport capture"
  pass "fm-spawn: codex refuses a backend that cannot read the viewport, before launching"
}

test_codex_launches_bare_and_delivers_typed_brief
test_codex_positional_probe_restores_the_positional_launch
test_codex_never_ready_reports_codex_did_not_take_the_brief
test_codex_answering_the_update_dialog_with_enter_never_readies
test_codex_trust_dialog_that_never_clears_fails
test_codex_partial_dialog_text_is_never_answered_or_trusted
test_codex_unconfirmed_submit_refuses_the_spawn
test_codex_processing_confirmation_accepts_the_busy_footer
test_codex_readiness_capture_failure_fails_loudly
test_codex_refuses_a_backend_without_a_viewport_capture
