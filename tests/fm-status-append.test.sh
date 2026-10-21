#!/usr/bin/env bash
# The status command writes report text as data.
# A generated brief that still used the double-quoted echo form would run
# backticks and command substitutions in that text; these cases fail there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-append)
APPEND="$ROOT/bin/fm-status-append.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
CORR=0123456789abcdef

# The worker-facing command from a scaffold. Falls back to the historical
# echo form so a brief that still evaluates its text fails these cases.
extract_status_command() { # <brief>
  local brief=$1
  if grep -q 'fm-status-append.sh' "$brief"; then
    awk '
      index($0, "fm-status-append.sh") && !found { found = 1 }
      found { print }
      found && $0 == "EOF" { exit }
    ' "$brief"
    return 0
  fi
  # shellcheck disable=SC2016 # Match literal shell syntax without expanding it.
  sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$brief" | head -1
}

scaffold_ship() { # <home> <id>
  mkdir -p "$1/state"
  FM_HOME="$1" "$ROOT/bin/fm-brief.sh" "$2" sample --mode no-mistakes >/dev/null
}

test_report_text_is_literal_and_one_line() {
  local home=$TMP_ROOT/literal id=literal-text brief cmd payload touch_a touch_b line
  local marker_home=$TMP_ROOT/not-the-home
  touch_a=$TMP_ROOT/touched-by-backtick
  touch_b=$TMP_ROOT/touched-by-dollar
  rm -f "$touch_a" "$touch_b"
  scaffold_ship "$home" "$id"
  brief=$home/data/$id/brief.md
  assert_grep 'The report text is data, never shell.' "$brief" \
    "the brief does not say why the report text is data"
  cmd=$(extract_status_command "$brief")
  [ -n "$cmd" ] || fail "scaffold has no status command"
  IFS= read -r payload <<'END'
`touch TOUCH_A` $(touch TOUCH_B) $HOME 'quote
END
  payload=${payload//TOUCH_A/$touch_a}
  payload=${payload//TOUCH_B/$touch_b}
  cmd=${cmd//\{state\}/done}
  cmd=${cmd//\{one short line\}/$payload}
  env -i PATH="$PATH" HOME="$marker_home" bash -c "$cmd" \
    || fail "status command failed on literal text"
  [ ! -e "$touch_a" ] || fail "backticks in the report text ran"
  [ ! -e "$touch_b" ] || fail "a command substitution in the report text ran"
  line=$(cat "$home/state/$id.status")
  [ "$(wc -l < "$home/state/$id.status" | tr -d ' ')" = 1 ] || fail "status log is not one line: $line"
  # shellcheck disable=SC2016 # Match literal command substitutions and $HOME.
  case "$line" in
    *'`touch '"$touch_a"'`'*'$(touch '"$touch_b"')'*'$HOME'*"'quote"*) ;;
    *) fail "report text was not stored literally: $line" ;;
  esac
  case "$line" in
    *"$marker_home"*) fail "dollar HOME was expanded: $line" ;;
  esac
  [ "$(status_line_note "$line")" = "$payload" ] || fail "note does not match the report text: $line"

  cmd=$(extract_status_command "$brief")
  cmd=${cmd//\{state\}/working}
  cmd=${cmd//\{one short line\}/$'alpha\nbeta'}
  : > "$home/state/$id.status"
  bash -c "$cmd" || fail "multi-line status command failed"
  line=$(cat "$home/state/$id.status")
  [ "$(wc -l < "$home/state/$id.status" | tr -d ' ')" = 1 ] || fail "multi-line text stayed multi-line: $line"
  [ "$(status_line_note "$line")" = 'alpha beta' ] || fail "newlines were not folded: $line"
  pass "report text is written literally, and a multi-line report becomes one line"
}

test_key_and_corr_keep_their_places() {
  local home=$TMP_ROOT/tokens line key verb
  mkdir -p "$home/state"
  printf 'kept\n' | "$APPEND" "$home/state/tokens.status" needs-decision \
    --key api-shape --corr "$CORR" || fail "status append with key and corr failed"
  line=$(cat "$home/state/tokens.status")
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line")
  [ "$verb" = needs-decision ] || fail "verb moved: $line"
  [ "$key" = api-shape ] || fail "key moved: $line"
  case "${line%%:*}" in
    "needs-decision [key=api-shape] [corr=$CORR] [at="*) ;;
    *) fail "key, corr, and time are not in the documented order: $line" ;;
  esac
  [ "$(status_line_note "$line")" = kept ] || fail "note changed around the tokens: $line"
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_text_has_corr "$line" "$CORR" || fail "corr token is not the bracketed form readers already accept: $line"
  pass "key and corr stay in the documented before-colon order"
}

test_ledger_hook_fires_once() {
  local home=$TMP_ROOT/ledger id=ledger-once cmd rows
  scaffold_ship "$home" "$id"
  mkdir -p "$home/config" "$home/state"
  : > "$home/config/fleet-ledger"
  cmd=$(extract_status_command "$home/data/$id/brief.md")
  cmd=${cmd//\{state\}/done}
  cmd=${cmd//\{one short line\}/recorded once}
  bash -c "$cmd" || fail "status command failed with the ledger flag on"
  rows=$(jq -c '[.event, .state, .text]' "$home/state/fleet-ledger.jsonl")
  assert_equals '["task.status","done"," recorded once"]' "$rows" "one ledger record"
  cmd=$(extract_status_command "$home/data/$id/brief.md")
  cmd=${cmd//\{state\}/done}
  cmd=${cmd//\{one short line\}/recorded twice}
  bash -c "$cmd" || fail "second status command failed"
  [ "$(wc -l < "$home/state/fleet-ledger.jsonl" | tr -d ' ')" = 2 ] \
    || fail "each status command did not record exactly one ledger row"
  pass "the ledger hook records each new status line once"
}

seed_mate() { # <parent> <mate>
  mkdir -p "$1/state" "$2"
  printf 'mate-id\n' > "$2/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$1" \
    > "$2/.fm-secondmate-parent"
}

untimed() { # <line>
  local out
  _fm_status_untimed "$1" out
  printf '%s\n' "$out"
}

test_secondmate_note_from_stdin_is_literal() {
  local parent=$TMP_ROOT/parent-literal mate=$TMP_ROOT/mate-literal status touch_a line argv stdin
  touch_a=$TMP_ROOT/report-touched
  rm -f "$touch_a"
  parent=$(cd "$TMP_ROOT" && mkdir -p parent-literal && cd parent-literal && pwd -P)
  mate=$TMP_ROOT/mate-literal
  seed_mate "$parent" "$mate"
  status=$parent/state/mate-id.status
  FM_HOME="$mate" "$REPORT" "done" "$CORR" "audit clean" || fail "argument note failed"
  argv=$(cat "$status")
  FM_HOME="$mate" "$REPORT" "done" "$CORR" <<'EOF' || fail "stdin note failed"
audit clean
EOF
  stdin=$(tail -n 1 "$status")
  assert_equals "$(untimed "$argv")" "$(untimed "$stdin")" \
    "stdin note does not match the argument note"
  : > "$status"
  FM_HOME="$mate" "$REPORT" "done" "$CORR" <<EOF || fail "dangerous stdin note failed"
\`touch $touch_a\` \$(touch $touch_a) \$HOME '
alpha
beta
EOF
  [ ! -e "$touch_a" ] || fail "a stdin note ran"
  line=$(cat "$status")
  [ "$(wc -l < "$status" | tr -d ' ')" = 1 ] || fail "stdin note became more than one status line: $line"
  # shellcheck disable=SC2016 # Match literal $HOME without expanding it.
  case "$line" in
    *"\`touch $touch_a\`"*'$HOME'*"' alpha beta (via-helper)") ;;
    *) fail "stdin note was not stored literally on one line: $line" ;;
  esac
  case "$line" in
    "done [corr=$CORR] [at="*) ;;
    *) fail "stdin note moved the corr token: $line" ;;
  esac
  pass "a second-mate note from stdin is literal, one line, and keeps the corr token"
}

test_report_text_is_literal_and_one_line
test_key_and_corr_keep_their_places
test_ledger_hook_fires_once
test_secondmate_note_from_stdin_is_literal
