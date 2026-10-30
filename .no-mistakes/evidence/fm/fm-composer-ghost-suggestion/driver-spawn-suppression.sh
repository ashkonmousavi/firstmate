set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M673MNWZ5DED50AB7RTVNT98
export FM_HOME="$ROOT/.phase-lab/spawnhome"
bin/fm-lab-home.sh create "$FM_HOME"
mkdir -p "$ROOT/.phase-lab/proj" "$FM_HOME/data/suppress" "$ROOT/.phase-lab/claude-config"
git -C "$ROOT/.phase-lab/proj" init -q -b main
printf '# Disposable launch test\n' > "$ROOT/.phase-lab/proj/README.md"
git -C "$ROOT/.phase-lab/proj" add README.md
git -C "$ROOT/.phase-lab/proj" -c user.name='Live validation' -c user.email='test@example.invalid' commit -qm initial
printf '# Task\n\n## Captain\x27s intent\nValidate launch environment only; do not change files.\n\n## Firstmate spec\nWait for instructions.\n' > "$FM_HOME/data/suppress/brief.md"
printf '999999 0\n' > "$FM_HOME/config/lane-capacity"
printf '{"schema":"fm-machine-admission.v1","memory_floor_gib":0,"memory_full_avg60_max":5,"disk_floor_gib":0,"disk_paths":["%s"]}\n' "$ROOT" > "$FM_HOME/config/machine-admission.json"
SOCKDIR=$(cat .phase-lab/home/state/.fm-lab-tmux-dir)
export TMUX_TMPDIR=$SOCKDIR
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
export CLAUDE_CONFIG_DIR="$ROOT/.phase-lab/claude-config"
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true
bin/fm-spawn.sh suppress "$ROOT/.phase-lab/proj" --scout --harness claude --backend tmux
