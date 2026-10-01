# Sourced by the live lab driver: one disposable firstmate lab home on a
# private tmux socket dir, a throwaway bare-origin project, and a private
# Treehouse pool. Everything lives under $LAB and is removed at teardown.
WT=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M3VZF72MYDKFSVPWF8SMTY11
EV=/home/tegris/.no-mistakes/evidence/01M3VZF72MYDKFSVPWF8SMTY11
LAB=$(cat "$EV/.lab-path" 2>/dev/null)
PROJ=$LAB/src/demo
# Run a firstmate entrypoint the way an operator shell would, inside the lab:
# no gate or path overrides, FM_HOME is the marked lab home, every bare tmux
# call addresses the lab's private socket dir, and Treehouse uses the lab pool.
fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
      -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
      FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TREEHOUSE_ROOT="$LAB/pool" FM_SPAWN_NO_GUARD=1 \
      "$@"
}
labtmux() { TMUX_TMPDIR="$LAB/tmux" tmux "$@"; }
tmuxprocs() { LC_ALL=C ps -u "$(id -u)" -o pid=,comm=,args= | awk '$2 ~ /^tmux/'; }
claim() { find "$LAB/pool" -maxdepth 5 -name .fm-slot-owner | while read -r f; do printf "%s: %s\n" "${f#"$LAB"/}" "$(tr "\n" " " < "$f")"; done; }
step() { printf '\n===== %s =====\n' "$*"; }
