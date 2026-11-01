LABROOT=/tmp/fmlab-01M6
LAB=$LABROOT/home
ID=$(sed -n 's/^mate_id=//p' $LABROOT/.fm-live-lab)
TD=$(sed -n 's/^tmux_dir=//p' $LABROOT/.fm-live-lab)
EV=~/.no-mistakes/evidence/01M6AWZVJ2RSEM60AGZWZKN33K
labenv() { env -u TMUX -u FM_SECONDMATE_WAKE_STALL_SECS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE TMUX_TMPDIR="$TD" FM_HOME="$LAB" FM_BACKEND=tmux CLAUDE_CONFIG_DIR=/tmp/fm-cc.tsgv63 DISABLE_AUTOUPDATER=1 "$@"; }
ltmux() { env -u TMUX TMUX_TMPDIR="$TD" tmux "$@"; }
