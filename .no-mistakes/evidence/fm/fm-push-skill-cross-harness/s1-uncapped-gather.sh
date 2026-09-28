#!/usr/bin/env bash
# Build a lab FM_HOME whose fleet exceeds the bearings default caps (20), then run
# the default bearings command and the exact /push Gather command from
# .agents/skills/push/SKILL.md, and compare what each shows.
set -u
WT=$1; N=${2:-24}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
printf '## Queued\n' > "$LAB/data/backlog.md"
i=1
while [ "$i" -le "$N" ]; do
  id="lane-$i"
  mkdir -p "$LAB/projects/$id" "$LAB/data/$id"
  printf -- '- [ ] gate-%s - Gate %s blocked-by: task-%s (repo: repo-%s) (kind: ship)\n' "$i" "$i" "$i" "$i" >> "$LAB/data/backlog.md"
  printf -- '- [ ] decision-%s - Decision %s (repo: repo-%s) (kind: captain) (hold: captain choice pending) (hold-kind: captain)\n' "$i" "$i" "$i" >> "$LAB/data/backlog.md"
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$LAB/projects/$id" "project=repo-$i" "harness=codex" "kind=ship" "mode=ship" > "$LAB/state/$id.meta"
  printf 'needs-decision [key=q%s]: choose %s\n' "$i" "$i" > "$LAB/state/$id.status"
  i=$((i+1))
done
run() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX= TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$WT/bin/fm-bearings-snapshot.sh" "$@"; }
summ='{in_flight: (.in_flight|length), decisions_open: (.decisions_open|length), gates: (.gates|length), omitted: [.omitted[] | {surface, reveal}]}'
echo "### fleet: $N ship lanes, each with a needs-decision status, a queued gate, and a captain hold"
echo; echo '### default: bin/fm-bearings-snapshot.sh --json'
run --json | jq "$summ"
echo; echo '### /push Gather: bin/fm-bearings-snapshot.sh --json --all-in-flight --all-decisions --all-secondmates --all-queued'
run --json --all-in-flight --all-decisions --all-secondmates --all-queued | jq "$summ"
rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
