set -euo pipefail
ROOT=$PWD
export PATH="$ROOT/.phase-lab/herdrbin:$PATH"
export FM_HOME="$ROOT/.phase-lab/herdrhome"
. bin/fm-task-inbox-lib.sh
. bin/fm-backend.sh
fm_backend_source herdr
v=$(fm_backend_herdr_composer_state fm-lab-ghost-final:w2:p1)
echo "After clearing the whole draft, composer=$v"
fm_task_inbox_ring herdr fm-lab-ghost-final:w2:p1 "$FM_HOME/state/ring.inbox/001.msg" fm-ring claude
