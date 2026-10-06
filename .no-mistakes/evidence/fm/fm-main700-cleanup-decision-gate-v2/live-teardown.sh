#!/usr/bin/env bash
set -euo pipefail
umask 022
ROOT=$PWD
for key in "${!FM_@}"; do
  case "$key" in *_OVERRIDE) unset "$key" ;; esac
done
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND TMUX TMUX_PANE || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
LAB=$(mktemp -d "$ROOT/.test-live-main700/fm-lab.XXXXXX")
BASELINE="$ROOT/bin/.test-main700-baseline-teardown.sh"
cleanup() {
  TMUX_TMPDIR=/tmp tmux -L fm-lab kill-server 2>/dev/null || true
  rm -f "$BASELINE"
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" TMPDIR="$LAB" TMUX_TMPDIR=/tmp
cp .tasks.toml "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
tmux -L fm-lab new-session -d -s fm-lab-main700 -n anchor -x 120 -y 40 -c "$ROOT" 'exec sleep 900'
export TMUX=$(tmux -L fm-lab display-message -p -t fm-lab-main700 '#{socket_path},#{pid},0')
seed() {
  local id=$1 report=$2
  bin/fm-tasks-axi.sh add "$id" "Disposable scout $id" --kind scout --repo sample
  bin/fm-tasks-axi.sh start "$id"
  mkdir -p "$LAB/data/$id"
  tmux -L fm-lab new-window -d -t fm-lab-main700 -n "fm-$id" -c "$ROOT" 'exec sleep 900'
  printf 'window=fm-lab-main700:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nbackend=tmux\nspawn_gen=lab-%s\n' "$id" "$LAB" "$id" "$LAB" "$id" > "$LAB/state/$id.meta"
  printf 'done: investigation finished\n' > "$LAB/state/$id.status"
  if [ "$report" = yes ]; then
    printf '# Scout report\n\nInvestigation complete. Choose north or south before follow-up.\n' > "$LAB/data/$id/report.md"
  fi
}
run_cleanup() {
  local executable=$1 id=$2 expected=$3 rc
  printf '\n$ bash %s %s\n' "$executable" "$id"
  set +e
  bash "$executable" "$id"
  rc=$?
  set -e
  printf 'exit=%s\n' "$rc"
  if [ "$expected" = success ]; then [ "$rc" = 0 ]; else [ "$rc" != 0 ]; fi
}
seed report-only yes
git show a86dcd88a937e3f12b5911f5249e23bed0e87a2e:bin/fm-teardown.sh > "$BASELINE"
printf '\nBASELINE: report present, no completion attestation\n'
run_cleanup "$BASELINE" report-only refusal
[ -f "$LAB/state/report-only.meta" ]
tmux -L fm-lab has-session -t '=fm-lab-main700:=fm-report-only'
printf 'baseline retained metadata and window\n'
rm -f "$BASELINE"
printf '\nTARGET: report present, no completion attestation\n'
run_cleanup bin/fm-teardown.sh report-only success
[ ! -e "$LAB/state/report-only.meta" ]
! tmux -L fm-lab has-session -t '=fm-lab-main700:=fm-report-only' 2>/dev/null
[ -f "$LAB/data/report-only/report.md" ]
printf 'metadata absent; window absent; report retained\n'
bin/fm-tasks-axi.sh show report-only --full
seed missing-report no
printf '\nTARGET: report absent\n'
run_cleanup bin/fm-teardown.sh missing-report refusal
[ -f "$LAB/state/missing-report.meta" ]
tmux -L fm-lab has-session -t '=fm-lab-main700:=fm-missing-report'
printf 'metadata retained; window retained; report absent\n'
bin/fm-tasks-axi.sh show missing-report --full
seed captain-held yes
bin/fm-captain-hold.sh hold captain-held --reason 'Choose north or south before follow-up'
printf '\nTARGET: unanswered captain-held task, no completion attestation\n'
bin/fm-tasks-axi.sh show captain-held --full
run_cleanup bin/fm-teardown.sh captain-held success
[ ! -e "$LAB/state/captain-held.meta" ]
! tmux -L fm-lab has-session -t '=fm-lab-main700:=fm-captain-held' 2>/dev/null
[ -f "$LAB/data/captain-held/report.md" ]
bin/fm-captain-hold.sh open captain-held
printf 'open predicate exit=0; metadata absent; window absent; report retained\n'
bin/fm-tasks-axi.sh show captain-held --full
bin/fm-bearings-snapshot.sh --json > "$LAB/bearings.json"
jq -e '.decisions_open | any(.id == "captain-held" and .verb == "captain-hold")' "$LAB/bearings.json"
jq '{decisions_open: .decisions_open, reports: .reports}' "$LAB/bearings.json"
printf '\nAll live CLI scenarios passed; lab server and home removed by EXIT trap.\n'
