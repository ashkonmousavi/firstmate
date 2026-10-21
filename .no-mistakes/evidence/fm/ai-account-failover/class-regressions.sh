#!/usr/bin/env bash
set -eu
repo=$PWD
fixture=$(mktemp -d "$PWD/.test-tmp/class-check.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/codex-1" "$fixture/state" "$fixture/control"
cat > "$fixture/bin/quota-axi" <<'TOOL'
#!/usr/bin/env bash
[ ! -f "$CODEX_HOME/slow" ] || sleep 3
cat "$CODEX_HOME/quota.json"
TOOL
cat > "$fixture/control/fm-control.sh" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROBE_CONTROL_LOG"
TOOL
chmod +x "$fixture/bin/quota-axi" "$fixture/control/fm-control.sh"
export PATH="$fixture/bin:$PATH" TMPDIR="$fixture" PROBE_CONTROL_LOG="$fixture/control.log"
cat > "$fixture/codex-1/quota.json" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"codex","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}},{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}
JSON
printf 'account_explicit=1\naccount=%s/codex-1\nharness=codex\nkind=ship\nmodel=gpt-5.3-codex-spark\n' "$fixture" > "$fixture/state/t.meta"
for variant in before after; do
  if [ "$variant" = before ]; then code="$repo/.test-tmp/before"; else code="$repo"; fi
  (
    . "$code/bin/fm-worker-account-lib.sh"
    . "$repo/bin/fm-backend.sh"
    echo "=== $variant: Spark 50% account + 0% Bengalfox (oracle: dispatch-auth.md) ==="
    fm_worker_account_quota codex "$fixture/codex-1" gpt-5.3-codex-spark
    echo 'Unrelated gpt-5.5 (expected healthy):'
    fm_worker_account_quota codex "$fixture/codex-1" gpt-5.5
    touch "$fixture/codex-1/slow"
    echo '=== Quota probe: 3-second provider, 1-second checkpoint ==='
    start=$SECONDS
    FM_CHECKPOINT_DEADLINE=$(( $(date +%s) + 1 )) fm_worker_account_quota codex "$fixture/codex-1" gpt-5.3-codex-spark
    echo "elapsed_seconds=$((SECONDS-start))"
    rm "$fixture/codex-1/slow"
    # All-model exhaustion independently exercises admission, with no alias dependency.
    jq '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining=0 | .providers[0].quotaSemantics.effectiveAvailability[0].runway.status="exhausted_now"' "$fixture/codex-1/quota.json" > "$fixture/quota-zero.json"
    cp "$fixture/codex-1/quota.json" "$fixture/original.json"
    cp "$fixture/quota-zero.json" "$fixture/codex-1/quota.json"
    fm_wake_queued_keys() { :; }
    fm_wake_append() { printf '%s\n' "$*" >> "$fixture/queue.log"; }
    echo '=== Bounded checkpoint admission (oracle: defer recovery, never launch) ==='
    rc=0
    FM_CHECKPOINT_DEADLINE=$(( $(date +%s) + 30 )) fm_worker_account_recover "$fixture/state/t.meta" "$fixture/control" || rc=$?
    echo "return=$rc"
    if [ -f "$fixture/control.log" ]; then cat "$fixture/control.log"; else echo 'no relaunch invoked'; fi
    if [ -f "$fixture/queue.log" ]; then cat "$fixture/queue.log"; else echo 'no recovery queued'; fi
    cp "$fixture/original.json" "$fixture/codex-1/quota.json"
  )
  rm -f "$fixture/state/.t.account-check" "$fixture/control.log" "$fixture/queue.log"
done
