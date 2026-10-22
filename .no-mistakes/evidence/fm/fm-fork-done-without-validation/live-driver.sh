#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$ROOT/.live-validation/home
EVIDENCE=~/.no-mistakes/evidence/01M5H2SM3HDX42BARZ024HGTK2
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR=$SOCKET_DIR
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB"; rm -rf "$LAB"; }
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB NM_HOME=$ROOT/.live-validation/nm
mkdir -p "$LAB/main/state"
printf 'mate\n' > "$LAB/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/main" > "$LAB/.fm-secondmate-parent"
WT=$ROOT/.live-validation/repo
git -C "$WT" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m private-head
SHA=$(git -C "$WT" rev-parse HEAD)
tmux -L fm-lab new-session -d -s lab -n fm-child -x 120 -y 40 -c "$WT" 'sleep 300'
# The private socket environment keeps every backend read on the disposable server.
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0
printf 'window=lab:fm-child\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nharness=claude\nspawn_gen=live-1\npr_head=%s\n' "$WT" "$WT" "$SHA" > "$LAB/state/child.meta"
GEN=$(bin/fm-busy-event.sh arm "$LAB/state" child)
bin/fm-busy-event.sh apply "$LAB/state" child idle --gen "$GEN" --source claude-hook --event stop
printf 'done: implementation complete\n' > "$LAB/state/child.status"
printf '\nUnreadable/uninitialized validation inventory, real crew-state CLI:\n'
bin/fm-crew-state.sh child
printf '\nMissing validation binary (PATH=/usr/bin:/bin), real crew-state CLI:\n'
PATH=/usr/bin:/bin bin/fm-crew-state.sh child
printf '\nNamed-head gate accepts handoff even for private head:\n'
. bin/fm-dod-lib.sh
fm_dod_accept_ship_done ship no-mistakes "$WT" "$WT" 'done: implementation complete'
printf 'handoff accepted (exit 0)\n'
printf '\nChild handoff report, real reconciliation CLI:\n'
bin/fm-inactive-reconcile.sh report child
if [ -s "$LAB/main/state/mate.status" ]; then cat "$LAB/main/state/mate.status"; exit 1; fi
printf 'No parent status append; no handoff published\n'
printf 'done: CI is green https://github.com/o/r/pull/9\n' > "$LAB/state/child.status"
printf '\nCI-ready private head, real crew-state CLI:\n'
bin/fm-crew-state.sh child
printf '\nPreserve named head on remote-tracking ref, then re-read ready report:\n'
git -C "$WT" update-ref refs/remotes/origin/fm/live-handoff "$SHA"
bin/fm-crew-state.sh child
printf '\nPublish the now-preserved child ready report:\n'
bin/fm-inactive-reconcile.sh report child
cat "$LAB/main/state/mate.status"
printf '\nRepeat report to verify exactly-once publication:\n'
bin/fm-inactive-reconcile.sh report child
wc -l "$LAB/main/state/mate.status"
