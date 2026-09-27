#!/usr/bin/env bash
# Live lab driver: real bin/fm-control.sh exit against a REAL Claude CLI running
# in a pane of a named, non-default fm-lab-* Herdr session provisioned through
# bin/fm-herdr-lab.sh (via tests/herdr-test-safety.sh), torn down on exit.
# Usage: herdr-claude-exit-lab.sh <firstmate-root-for-fm-control> <worktree-root-for-lab-helpers> [verb]
set -u
CTL_ROOT=$(cd "$1" && pwd); ROOT=$(cd "$2" && pwd); VERB=${3:-exit}
# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
unset FM_GATE_REFUSE_BYPASS   # the marked lab home must authorise lifecycle on its own
herdr_forget_inherited_pane
SESSION="fm-lab-cexit-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { herdr_safe_stop_and_delete "$SESSION"; chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 99; }
"$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null || exit 99
mkdir -p "$LAB/home/data/t1"
PROJ="$LAB/proj"; WT="$LAB/wt"
git init -q "$PROJ"; printf '# p\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b task-t1 "$WT"
printf '# Task\n## Captain'"'"'s intent\nIdle.\n\n## Firstmate spec\nNone.\n' > "$LAB/home/data/t1/brief.md"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || exit 99
RAW=$(fm_backend_herdr_container_ensure "$WT") || { echo "container_ensure failed"; exit 99; }
CONTAINER=${RAW%%$'\t'*}; SEED=${RAW#*$'\t'}; WS=${CONTAINER#*:}
read -r TAB PANE <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" fm-t1 "$WT" "$SEED")
EOF
T="$SESSION:$PANE"
cat > "$LAB/home/state/t1.meta" <<EOF
window=$T
endpoint_task_id=t1
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
printf -v WTQ '%q' "$WT"
fm_backend_herdr_send_text_line "$T" "cd -- $WTQ && env ${LAB_CLAUDE_ENV_STRIP:-} claude" || { echo "launch send failed"; exit 99; }
ident() { herdr agent get "$PANE" --session "$SESSION" 2>/dev/null | jq -r '(.result.agent.agent // "")+" "+(.result.agent.agent_status // "")'; }
TRUSTED=0
for i in $(seq 1 90); do
  sleep 1
  scr=$(fm_backend_herdr_capture "$T" 40 2>/dev/null)
  [ -n "${LAB_DEBUG:-}" ] && { echo "== t=$i ident=$(ident)"; printf '%s\n' "$scr" | grep -v '^[[:space:]]*$' | tail -12; }
  if [ "$TRUSTED" = 0 ] && printf '%s' "$scr" | grep -q 'trust this folder\|Do you trust\|Yes, I trust'; then
    fm_backend_herdr_send_key "$T" Down; sleep 0.5; fm_backend_herdr_send_key "$T" Enter; TRUSTED=1; continue
  fi
  if printf "%s" "$scr" | grep -q "Try the new fullscreen renderer"; then fm_backend_herdr_send_key "$T" Escape; continue; fi
  case "$(ident)" in "claude idle"|"claude done") [ "$(fm_backend_composer_state herdr "$T")" = empty ] && break ;; esac
done
echo "--- herdr $(herdr --version | head -1), $(claude --version | head -1)"
echo "--- native identity before: $(ident)"
echo "--- agent state before: $(fm_backend_agent_state herdr "$T")"
echo "--- composer verdict before: $(fm_backend_composer_state herdr "$T")"
echo "--- pane before (tail) ---"; fm_backend_herdr_capture "$T" 40 | grep -v '^[[:space:]]*$' | tail -8
if [ -n "${LAB_SENDTRACE:-}" ]; then
  echo "--- send trace: the Claude pre/post-send composer proof steps of fm_backend_herdr_send_text_submit"
  ID=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$PANE"); echo "identity=[$ID]"
  PL=$(fm_backend_herdr_proof_lines "/exit"); echo "proof_lines=$PL"
  C0=$(fm_backend_herdr_composer_content "$T" "$PL" "$ID"); echo "pre-send content rc=$? [$C0]"
  fm_backend_herdr_send_literal "$T" "/exit"; echo "send_literal rc=$?"
  sleep 1.2
  C1=$(fm_backend_herdr_composer_content "$T" "$PL" "$ID"); echo "post-send content rc=$? [$C1]"
  fm_backend_herdr_composer_payload_shown "/exit" "$C1"; echo "payload_shown rc=$?"
  echo "composer_state after typing: $(fm_backend_composer_state herdr "$T")"
  echo "--- pane after typing /exit (not submitted) ---"; fm_backend_herdr_capture "$T" 40 | grep -v '^[[:space:]]*$' | tail -14
  echo "--- ansi capture of composer rows ---"; fm_backend_herdr_capture_ansi "$T" 40 | grep -n 'exit' | cat -v | head -8
  fm_backend_herdr_send_key "$T" Escape; sleep 0.5
  for _ in 1 2 3; do fm_backend_herdr_send_key "$T" C-u; sleep 0.3; done
  echo "composer_state after clearing: $(fm_backend_composer_state herdr "$T")"
  fm_backend_herdr_send_literal "$T" "hello"; sleep 1.2
  C2=$(fm_backend_herdr_composer_content "$T" "$PL" "$ID"); echo "plain text 'hello' typed: content rc=$? [$C2]"
  echo "composer_state with 'hello' typed: $(fm_backend_composer_state herdr "$T")"
  fm_backend_herdr_capture "$T" 40 | grep -n 'hello' | head -3
  exit 0
fi
echo "--- \$ fm-control.sh t1 $VERB   (fm-control from $CTL_ROOT)"
OUT=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB/home" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_CONTROL_EXIT_WAIT=20 \
  "$CTL_ROOT/bin/fm-control.sh" t1 $VERB 2>&1); RC=$?
printf '%s\n' "$OUT"; echo "--- rc=$RC"
sleep 1
echo "--- native identity after: $(ident)"
echo "--- agent state after: $(fm_backend_agent_state herdr "$T")"
echo "--- pane process state after: $(fm_backend_herdr_pane_process_state "$SESSION" "$PANE")"
echo "--- pane after (tail) ---"; fm_backend_herdr_capture "$T" 40 | grep -v '^[[:space:]]*$' | tail -8
