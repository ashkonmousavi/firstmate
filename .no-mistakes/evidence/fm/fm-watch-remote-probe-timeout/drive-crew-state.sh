#!/usr/bin/env bash
# drive-crew-state.sh <bin-root>: run the real bin/fm-crew-state.sh for a remote
# secondmate in a disposable lab home against a stalled host and a responsive one.
set -u
ROOTDIR=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOTDIR/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || mkdir -p "$LAB/state" "$LAB/data"
cat > "$LAB/state/rsm.meta" <<M
window=remote:rsm
endpoint_task_id=rsm
harness=claude
kind=secondmate
mode=secondmate
remote_host=remote-mac
remote_root=/remote/root
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
M
cat > "$LAB/data/secondmates.md" <<R
- rsm - remote mate (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-10-02)
R
printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 150\n' > "$LAB/stall-ssh"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s\\n" "${FM_FAKE_REPLY:-alive}"\n' > "$LAB/ok-ssh"
chmod +x "$LAB/stall-ssh" "$LAB/ok-ssh"
run() {  # <label> <env...>
  local label=$1 s e out rc; shift
  s=$(date +%s)
  out=$(env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$LAB" "$@" timeout 200 "$ROOTDIR/bin/fm-crew-state.sh" rsm 2>&1); rc=$?
  e=$(date +%s)
  printf '== %s\n$ %s fm-crew-state.sh rsm\nexit=%s elapsed=%ss\n%s\n\n' "$label" "$*" "$rc" "$((e - s))" "$out"
  pkill -f "$LAB/stall-ssh" 2>/dev/null
}
run "stalled host, budget 3" FM_SSH_BIN="$LAB/stall-ssh" FM_CREW_STATE_REMOTE_BUDGET=3
run "stalled host, default budget" FM_SSH_BIN="$LAB/stall-ssh"
run "stalled host, invalid budget -5" FM_SSH_BIN="$LAB/stall-ssh" FM_CREW_STATE_REMOTE_BUDGET=-5
run "responsive host answering alive" FM_SSH_BIN="$LAB/ok-ssh" FM_FAKE_REPLY=alive
run "responsive host answering dead" FM_SSH_BIN="$LAB/ok-ssh" FM_FAKE_REPLY=dead
rm -rf "$LAB"
