#!/usr/bin/env bash
# Drives the real firstmate merge entrypoints (bin/fm-pr-merge.sh,
# bin/fm-watch.sh, bin/fm-wake-drain.sh, bin/fm-merge-local.sh) in throwaway
# sandbox homes, with only the forge CLI (gh / gh-axi) replaced by a fake so no
# real GitHub PR is touched. Prints a transcript of what each landing path
# tells firstmate. Usage: drive-post-merge-reminder.sh <firstmate-worktree>
set -u
WT=${1:?usage: $0 <firstmate-worktree>}
# shellcheck source=/dev/null
. "$WT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
TMP_ROOT=$(fm_test_tmproot fm-post-merge-drive)
REMINDER_RE='not yet landed'

section() { printf '\n===== %s =====\n' "$*"; }
show() { printf -- '--- %s\n' "$1"; if [ -s "$2" ]; then cat "$2"; else echo '(empty)'; fi; }

make_sandbox() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$dir/fakebin" "$dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/fm-guard.sh"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_DRIVE_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' "state=${GH_OUTCOME_STATE:-MERGED}" "merged=${GH_OUTCOME_MERGED:-true}" \
      "queued=${GH_OUTCOME_QUEUED:-false}" 'base=main'
    exit 0 ;;
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"0123456789abcdef0123456789abcdef01234567","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
        exit 0 ;;
    esac ;;
  "pr merge")
    if [ "${GH_MERGE_RC:-0}" != 0 ]; then echo 'GraphQL: Pull request is not mergeable' >&2; exit "$GH_MERGE_RC"; fi
    exit 0 ;;
esac
case " $* " in
  *" headRefOid "*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
  *" state "*) printf '%s\n' "${GH_POLL_STATE:-OPEN}" ;;
esac
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi" "$dir/root/bin/fm-guard.sh"
  : > "$dir/gh.log"
  fm_write_meta "$dir/home/state/task-a.meta" "window=firstmate:fm-task-a" "endpoint_task_id=task-a" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "$dir"
}

entry() {  # <dir> <script> args...
  local dir=$1 script=$2; shift 2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_DRIVE_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$WT/bin/$script" "$@"
}

drain() {  # <dir> : what firstmate is actually handed on its next wake
  FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" "$WT/bin/fm-wake-drain.sh" \
    > "$1/drain.out" 2> "$1/drain.err" || true
  show 'fm-wake-drain.sh stdout (delivered to firstmate)' "$1/drain.out"
  grep -v '^WAKE_ACK_REQUIRED' "$1/drain.err" > "$1/drain.err.shown" || true
  show 'fm-wake-drain.sh stderr (minus ack token)' "$1/drain.err.shown"
}

verdict() {  # <label> <expect: present|absent> <file...>
  local label=$1 expect=$2 hit=absent; shift 2
  if cat "$@" 2>/dev/null | grep -q "$REMINDER_RE"; then hit=present; fi
  if [ "$hit" = "$expect" ]; then echo "RESULT PASS: $label (reminder $hit)"; else echo "RESULT FAIL: $label (reminder $hit, expected $expect)"; fi
}

url=https://github.com/example/repo/pull/51

section "S1 main home: firstmate merges a green PR itself (bin/fm-pr-merge.sh)"
d=$(make_sandbox s1)
entry "$d" fm-pr-merge.sh task-a "$url" > "$d/merge.out" 2> "$d/merge.err"; echo "exit=$?"
show 'fm-pr-merge.sh stdout' "$d/merge.out"
show 'fm-pr-merge.sh stderr' "$d/merge.err"
verdict 'S1 self-merge stdout names merged-not-landed' present "$d/merge.out"
drain "$d"
verdict 'S1 durable wake delivered to firstmate carries reminder' present "$d/drain.out"

section "S1b same PR merged again after the outcome was already recorded"
entry "$d" fm-pr-merge.sh task-a "$url" > "$d/merge2.out" 2> "$d/merge2.err"; echo "exit=$?"
show 'fm-pr-merge.sh stdout (repeat)' "$d/merge2.out"
show 'fm-pr-merge.sh stderr (repeat)' "$d/merge2.err"
printf -- '--- merge-landed rows in durable queue: %s\n' "$(grep -c 'merge landed' "$d/home/state/.wake-queue")"

section "S2 merge-queue landing: queued by fm-pr-merge.sh, later detected by the watcher poll"
d=$(make_sandbox s2)
entry "$d" fm-pr-check.sh task-a "$url" > "$d/check.out" 2> "$d/check.err"; echo "fm-pr-check exit=$?"
GH_OUTCOME_STATE=OPEN GH_OUTCOME_MERGED=false GH_OUTCOME_QUEUED=true \
  entry "$d" fm-pr-merge.sh task-a "$url" > "$d/merge.out" 2> "$d/merge.err"; echo "fm-pr-merge exit=$?"
show 'fm-pr-merge.sh stdout (queued)' "$d/merge.out"
show 'fm-pr-merge.sh stderr (queued)' "$d/merge.err"
verdict 'S2a queued merge does not claim a landing' absent "$d/merge.out" "$d/merge.err" "$d/home/state/.wake-queue"
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$d/home/state/z-stop.check.sh"
chmod 0700 "$d/home/state/z-stop.check.sh"
FM_HOME="$d/home" "$WT/bin/fm-check-register.sh" z-stop >/dev/null
perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
  env FM_HOME="$d/home" FM_ROOT_OVERRIDE="$WT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=1 FM_POLL=0.02 \
    FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 GH_POLL_STATE=MERGED FM_DRIVE_GH_LOG="$d/gh.log" \
    PATH="$d/fakebin:$BASE_PATH" "$WT/bin/fm-watch.sh" > "$d/watch.out" 2> "$d/watch.err"
echo "fm-watch exit=$?"
show 'fm-watch.sh stdout (one cycle)' "$d/watch.out"
drain "$d"
verdict 'S2b poll-detected landing delivered to firstmate carries reminder' present "$d/drain.out"

section "S3 secondmate home merges its own PR: parent channel + own stdout"
d=$(make_sandbox s3)
printf '%s\n' mate-x > "$d/home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$d/home/.fm-secondmate-parent"
entry "$d" fm-pr-merge.sh task-a "$url" > "$d/merge.out" 2> "$d/merge.err"; echo "exit=$?"
show 'fm-pr-merge.sh stdout' "$d/merge.out"
show 'parent channel (state/parent-replies.status)' "$d/home/state/parent-replies.status"
verdict 'S3 secondmate self-merge stdout names merged-not-landed' present "$d/merge.out"

section "S4 adversarial: the forge refuses the merge"
d=$(make_sandbox s4)
GH_MERGE_RC=1 GH_OUTCOME_STATE=OPEN GH_OUTCOME_MERGED=false \
  entry "$d" fm-pr-merge.sh task-a "$url" > "$d/merge.out" 2> "$d/merge.err"; echo "exit=$?"
show 'fm-pr-merge.sh stdout' "$d/merge.out"
show 'fm-pr-merge.sh stderr' "$d/merge.err"
verdict 'S4 refused merge produces no landing reminder or merge-landed wake' absent "$d/merge.out" "$d/merge.err" "$d/home/state/.wake-queue"

section "S5 local-only landing (bin/fm-merge-local.sh): only the local outcome"
d=$(make_sandbox s5)
proj="$d/project"
git init -q -b main "$proj" && git -C "$proj" commit -q --allow-empty -m base
git -C "$proj" branch fm/task-a && git -C "$proj" checkout -q fm/task-a
git -C "$proj" commit -q --allow-empty -m 'task work' && git -C "$proj" checkout -q main
fm_write_meta "$d/home/state/task-a.meta" "window=firstmate:fm-task-a" "endpoint_task_id=task-a" \
  "worktree=$d/wt" "project=$proj" "kind=ship" "mode=local-only"
entry "$d" fm-merge-local.sh task-a > "$d/merge.out" 2> "$d/merge.err"; echo "exit=$?"
show 'fm-merge-local.sh stdout' "$d/merge.out"
show 'fm-merge-local.sh stderr' "$d/merge.err"
printf -- '--- project main now at: %s\n' "$(git -C "$proj" log --oneline -1 main)"
verdict 'S5 local-only landing reports only the local outcome' absent "$d/merge.out" "$d/merge.err" "$d/home/state/.wake-queue"
