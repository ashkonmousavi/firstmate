#!/usr/bin/env bash
set -eu
source tests/lib.sh
source .no-mistakes/runtime/tests/rex-test-safety.sh
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "$*"; }
wt=''
cleanup() {
  rex_test_stop_server
  if [ -n "$wt" ]; then (cd "$proj" && treehouse return --force "$wt") >/dev/null 2>&1 || true; fi
  chmod -R u+w "$REX_TEST_WORK"
  rex_test_cleanup
}
trap cleanup EXIT
rex_test_prepare
pair=$(rex_test_new_session carrier)
read -r sid bid <<< "$pair"
lab="$REX_TEST_WORK/lab"
mkdir "$lab"
bin/fm-lab-home.sh create "$lab" >/dev/null
mkdir -p "$lab/data/rex-carrier"
printf '999999 0\n' > "$lab/config/lane-capacity"
fm_test_machine_policy "$lab/config"
cat > "$lab/data/rex-carrier/brief.md" <<'EOF'
# Task
## Captain's intent
Reply with exactly: rex-carrier-ok, and nothing else.

## Firstmate spec
One reply, no tools, no file changes.
EOF
proj="$REX_TEST_WORK/project"
mkdir "$proj"
git -C "$proj" init -q
printf '# scratch\n' > "$proj/README.md"
git -C "$proj" add .
git -C "$proj" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$proj" "$REX_TEST_WORK/origin.git"
git -C "$proj" remote add origin "file://$REX_TEST_WORK/origin.git"
export FM_HOME="$lab" FM_CODEX_TYPED_LAUNCH=1 FM_SPAWN_NO_GUARD=1
export TERM_PROGRAM=rex REX_SESSION="$sid" REX_BLOCK="$bid"
bin/fm-spawn.sh rex-carrier "$proj" --scout --harness codex --backend rex
meta="$lab/state/rex-carrier.meta"
wt=$(fm_meta_get "$meta" worktree)
target=$(fm_meta_get "$meta" window)
found=0
trusted=0
for ((i=0;i<150;i++)); do
  pane=$(fm_backend_capture rex "$target")
  if [[ "$pane" == *"Trust this folder?"* && "$trusted" = 0 ]]; then fm_backend_rex_send_key "$target" Enter; trusted=1; printf "Test driver confirmed trust for its disposable scratch project\n"; fi
  if printf '%s\n' "$pane" | awk '$1 == "•" && $2 == "rex-carrier-ok" && NF == 2 {f=1} END {exit !f}'; then found=1; break; fi
  sleep 1
done
printf '%s\n' "$pane" > ~/.no-mistakes/evidence/01M6EPD9Q923ZVBVRY6T3MMGP9/rex-codex-pane.txt
[ "$found" = 1 ] || fail 'real Codex did not answer its positional brief on Rex'
printf 'Real Codex answered rex-carrier-ok on Rex with FM_CODEX_TYPED_LAUNCH=1\n'
fm_backend_rex_kill "$target"
fm_task_record_endpoint_confirmed_gone "$meta" || fail 'actual spawned task absence not proven'
printf 'Spawned Rex task: recorded-server metadata proves its killed endpoint absent\n'
