#!/usr/bin/env bash
# Live guard for the tmux endpoint-absence proof in bin/fm-control-lib.sh
# (fm_control_tmux_absence_verdict): a tmux window is proven gone only when no
# process of this user has a `comm` or argv0 basename beginning with `tmux`.
# That reads the process title the installed tmux sets for its server and
# client, a vendor-emitted fact, so this guard checks it against the real tmux
# on this host rather than a stub: the server must show up under that name
# while it runs (absence unproven), and nothing may be left under it once the
# server is killed (absence gone). While it runs, the server recorded the way
# a tmux rebind records it must account for itself through the format fields
# that record reads, so a window absent from it reads gone. It spends no model
# tokens, so it runs by
# default wherever tmux is installed, on a private socket that never touches
# the host's own sessions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_TMUX_ABSENCE_LIVE tmux ps

TMUX_VERSION=$(tmux -V 2>/dev/null || printf 'tmux (version unreadable)')
SOCKET="fm-tmux-absence-live-$$"
STATE_DIR=$(mktemp -d)
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$STATE_DIR"; }
trap cleanup EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

verdict_word() { local v; v=$(fm_control_tmux_absence_verdict); printf '%s' "${v%%$'\t'*}"; }

# Another tmux of this user would hold the gone leg at unproven, which is the
# proof refusing correctly but checks nothing about this tmux's titles.
if [ "$(verdict_word)" != gone ]; then
  echo "skip: live: another tmux process already runs for this user, so the gone leg cannot be checked ($TMUX_VERSION): $(fm_control_tmux_absence_verdict | cut -f2-)"
  exit 0
fi

tmux -L "$SOCKET" new-session -d -s absence 'sleep 60' \
  || fail "$TMUX_VERSION: could not start a tmux server on a private socket"

titles=$(LC_ALL=C ps -u "$(id -u)" -o comm= 2>/dev/null)
case "$titles" in
  *tmux*) ;;
  *) fail "$TMUX_VERSION: the running tmux server does not show a comm beginning with tmux; the absence proof would read it as gone"$'\n'"$titles" ;;
esac
[ "$(verdict_word)" = unproven ] \
  || fail "$TMUX_VERSION: absence read '$(fm_control_tmux_absence_verdict)' while a tmux server runs"
pass "live tmux ($TMUX_VERSION): a running server keeps absence unproven"

wid=$(tmux -L "$SOCKET" display-message -p -t absence: '#{window_id}') \
  || fail "$TMUX_VERSION: could not read the private server's window id"
# shellcheck disable=SC2329 # Invoked by fm_control_tmux_rebind_server_record.
tmux() { command tmux -L "$SOCKET" "$@"; }
fm_control_tmux_rebind_server_record "$STATE_DIR" "$wid" \
  || fail "$TMUX_VERSION: the running server's pid, start time and socket could not be recorded"
unset -f tmux
printf 'spawn_gen=s1000000000.1.1\n' > "$STATE_DIR/gone.meta"
verdict=$(fm_control_tmux_absence_verdict absence:fm-gone "$STATE_DIR/gone.meta")
[ "${verdict%%$'\t'*}" = gone ] \
  || fail "$TMUX_VERSION: a window absent from the recorded server read '$verdict'"
pass "live tmux ($TMUX_VERSION): the recorded server accounts for itself, so a window absent from it reads gone"

tmux -L "$SOCKET" kill-server >/dev/null 2>&1 \
  || fail "$TMUX_VERSION: kill-server failed on the private socket"
for _ in $(seq 1 50); do
  [ "$(verdict_word)" = gone ] && break
  sleep 0.1
done
[ "$(verdict_word)" = gone ] \
  || fail "$TMUX_VERSION: absence still reads '$(fm_control_tmux_absence_verdict)' after kill-server"
pass "live tmux ($TMUX_VERSION): with the server killed, absence reads gone"
