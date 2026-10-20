#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COMPOSER_GROK_WEEKLY_LIVE grok tmux

version=$(grok --version)
auth=${FM_GROK_AUTH_FILE:-$HOME/.grok/auth.json}
[ -f "$auth" ] || fail "grok ($version): missing managed auth file: $auth"
lab=$(mktemp -d "$ROOT/.grok-weekly-live.XXXXXX")
real_tmux=$(command -v tmux)
socket="fm-grok-weekly-$$"
cleanup() {
  local pid i
  pid=$("$real_tmux" -L "$socket" display-message -p -t weekly '#{pane_pid}' 2>/dev/null || true)
  "$real_tmux" -L "$socket" kill-server 2>/dev/null || true
  if [ -n "$pid" ]; then
    for ((i=0; i<50; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -rf -- "$lab"
}
trap cleanup EXIT
mkdir -p "$lab/home" "$lab/grok" "$lab/bin"
chmod 700 "$lab" "$lab/grok"
cp "$auth" "$lab/grok/auth.json"
chmod 600 "$lab/grok/auth.json"
cat > "$lab/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$real_tmux" -L "$socket" "\$@"
EOF
chmod +x "$lab/bin/tmux"
export PATH="$lab/bin:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux new-session -d -s weekly -x 80 -y 30 -c "$ROOT" \
  env HOME="$lab/home" GROK_HOME="$lab/grok" GROK_DISABLE_AUTOUPDATER=1 \
  GROK_AUTO_UPDATE=0 grok --always-approve
pane=''
trusted=0
for ((i=0; i<45; i++)); do
  pane=$(tmux capture-pane -p -t weekly)
  case "$pane" in
    *'Weekly limit left:'*) break ;;
    *'Do you trust the contents of this directory?'*)
      if [ "$trusted" -eq 0 ]; then
        tmux send-keys -t weekly Enter
        trusted=1
      fi
      ;;
  esac
  sleep 1
done
case "$pane" in
  *'Weekly limit left:'*) ;;
  *) fail "grok ($version): weekly-limit border not rendered; live coverage unavailable" ;;
esac

check_state() {
  local expected=$1 actual caps screen
  actual=$(fm_tmux_composer_state weekly)
  [ "$actual" = "$expected" ] \
    || fail "grok ($version): weekly-limit tmux composer is $actual, expected $expected"
  screen=$(fm_tmux_composer_capture weekly)
  for caps in \
    $'styled=1\ncursor=0\nidentity=0\nrows=0' \
    $'styled=0\ncursor=0\nidentity=0\nrows=0'; do
    actual=$(fm_composer_classify_screen "$caps" "$screen")
    [ "$actual" = "$expected" ] \
      || fail "grok ($version): weekly-limit cursorless composer is $actual, expected $expected"
  done
  pass "grok ($version): real weekly-limit composer is $expected through tmux and cursorless reads"
}

check_state empty
tmux send-keys -t weekly -l 'weekly-limit-unsent-probe'
for ((i=0; i<20; i++)); do
  pane=$(tmux capture-pane -p -t weekly)
  case "$pane" in
    *'weekly-limit-unsent-probe'*) break ;;
  esac
  sleep 0.1
done
case "$pane" in
  *'weekly-limit-unsent-probe'*) ;;
  *) fail "grok ($version): unsent probe was not rendered" ;;
esac
check_state pending
