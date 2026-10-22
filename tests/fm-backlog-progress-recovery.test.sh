#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required for progress recovery'
TMP_ROOT=$(fm_test_tmproot fm-progress-recovery)

upload() {
  bytes=$(LC_ALL=C wc -c < "$source/data/backlog.md" | tr -d ' ')
  if command -v shasum >/dev/null 2>&1; then
    hash=$(shasum -a 256 "$source/data/backlog.md" | awk '{print $1}')
  else
    hash=$(sha256sum "$source/data/backlog.md" | awk '{print $1}')
  fi
  FM_HOME="$target" "$ROOT/bin/fm-remote-file.sh" put state/handoff/mate.outbox.md \
    1048576 "$bytes" "$hash" "$generation" < "$source/data/backlog.md" >/dev/null
  generation=$((generation + 1))
}

retry() {
  case "$route" in
    receipt)
      upload
      FM_HOME="$target" "$ROOT/bin/fm-backlog-receive.sh" state/handoff/mate.outbox.md \
        "$bytes" "$hash" "$((generation - 1))"
      ;;
    registered) FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" mate progress-parent progress-second progress-child progress-bare ;;
    peer) FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$target" progress-parent progress-second progress-child progress-bare ;;
  esac
}

for lifecycle in since merged reported 'done' closed; do
  printf '## Queued\n- [ ] parser-child - child blocked-by: parser-parent - waits (%s 2026-10-21) (since 2026-10-22)\n' \
    "$lifecycle" > "$TMP_ROOT/lifecycle.md"
  edges=$(bash -c '. "$1"; fm_tasks_axi_item_edges "$2" parser-child' _ \
    "$ROOT/bin/fm-tasks-axi-lib.sh" "$TMP_ROOT/lifecycle.md")
  [ "$edges" = $'blocked-by\tparser-parent\twaits' ] \
    || fail "$lifecycle leaked into the dependency reason: $edges"
done
pass 'recognized trailing lifecycle tags do not become dependency reasons'

for route in receipt registered peer; do
  for progress in start 'done'; do
    source="$TMP_ROOT/$route-$progress-source"
    target="$TMP_ROOT/$route-$progress-target"
    mkdir -p "$source/data" "$source/state" "$target/data" "$target/state" "$target/bin"
    printf '# Firstmate\n' > "$target/AGENTS.md"
    printf 'mate\n' > "$target/.fm-secondmate-home"
    printf -- '- mate - work (home: %s; scope: work; projects: alpha; added 2026-07-09)\n' \
      "$target" > "$source/data/secondmates.md"
    cat > "$source/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] progress-parent - keep parent (repo: alpha)
- [ ] progress-second - keep second (repo: alpha)
- [ ] progress-child - keep child (repo: alpha) blocked-by: progress-parent - needs report (since 2026-10-21) blocked-by: progress-second - needs second (done 2026-10-22)
  first body paragraph

  state: this is payload, not lifecycle metadata
  prep: data/progress/prep.md
- [ ] progress-bare - bare edge blocked-by: progress-parent (repo: alpha)

## Done
EOF
    cp "$source/data/backlog.md" "$source/queued.expected"
    generation=1
    if [ "$route" = receipt ]; then
      retry > "$source/first-receipt.out" 2>&1 || fail 'initial receipt failed'
    else
      cp "$source/data/backlog.md" "$target/data/backlog.md"
    fi
    for key in progress-parent progress-second progress-child progress-bare; do
      tasks-axi "$progress" "$key" --file "$target/data/backlog.md" --backend markdown >/dev/null
    done
    sed 's/needs report (since 2026-10-21)/needs report/; s/needs second (done 2026-10-22)/needs second/' \
      "$target/data/backlog.md" > "$target/repositioned.md"
    mv "$target/repositioned.md" "$target/data/backlog.md"
    cp "$target/data/backlog.md" "$target/progress.expected"
    for changed_field in body reason; do
      if [ "$changed_field" = body ]; then
        tasks-axi update progress-child --body 'different body' \
          --file "$target/data/backlog.md" --backend markdown >/dev/null
      else
        sed 's/needs report/needs rep/' "$target/progress.expected" > "$target/data/backlog.md"
      fi
      if retry > "$source/mismatch.out" 2>&1; then
        fail "$route accepted a changed $changed_field after $progress"
      fi
      cmp -s "$source/queued.expected" "$source/data/backlog.md" \
        || fail "$route closed a mismatched source after $progress"
      cp "$target/progress.expected" "$target/data/backlog.md"
    done
    if [ "$route" != receipt ]; then
      tasks-axi add outside-child 'outside dependent' --file "$source/data/backlog.md" --backend markdown >/dev/null
      tasks-axi block outside-child --by progress-parent --file "$source/data/backlog.md" --backend markdown >/dev/null
      for outside_state in queued in-flight; do
        if [ "$outside_state" = in-flight ]; then
          tasks-axi start outside-child --file "$source/data/backlog.md" --backend markdown >/dev/null
        fi
        cp "$source/data/backlog.md" "$source/dependent.expected"
        if retry > "$source/dependent.out" 2>&1; then
          fail "$route closed a blocker with an outside $outside_state dependent"
        fi
        cmp -s "$source/dependent.expected" "$source/data/backlog.md" || fail 'dependency refusal changed source'
      done
      cp "$source/queued.expected" "$source/data/backlog.md"
    fi
    retry > "$source/retry.out" 2>&1 || fail "$route recovery after $progress failed: $(cat "$source/retry.out")"
    cmp -s "$target/progress.expected" "$target/data/backlog.md" \
      || fail "$route recovery rewrote target progress"
    if [ "$route" = receipt ]; then
      assert_contains "$(cat "$source/retry.out")" 'moved=0 already=4' 'receipt duplicated progressed items'
      assert_absent "$target/state/handoff/mate.outbox.md" 'confirmed receipt kept its scratch outbox'
    else
      assert_no_grep '- [ ] progress-' "$source/data/backlog.md" 'matching source stayed queued'
      assert_grep 'moved to ' "$source/data/backlog.md" 'matching source has no completion note'
      assert_grep 'prep: data/progress/prep.md' "$source/data/backlog.md" 'closure lost the prep link'
    fi
    cp "$source/queued.expected" "$source/data/backlog.md"
    tasks-axi start progress-child --file "$source/data/backlog.md" --backend markdown >/dev/null
    cp "$source/data/backlog.md" "$source/inflight.expected"
    if retry > "$source/inflight.out" 2>&1; then
      fail "$route accepted an in-flight source"
    fi
    cmp -s "$source/inflight.expected" "$source/data/backlog.md" \
      || fail "$route changed an in-flight source"
    pass "$route recovers after target $progress while rejecting changed payloads"
  done
done

source="$TMP_ROOT/local-identity-source"
first="$TMP_ROOT/local-a/home"
second="$TMP_ROOT/local-b/home"
mkdir -p "$source/data" "$source/state" "$first/bin" "$second/bin"
printf '# Firstmate\n' > "$first/AGENTS.md"
printf '# Firstmate\n' > "$second/AGENTS.md"
printf '## Queued\n- [ ] same-name - one destination (repo: alpha)\n\n## Done\n' > "$source/data/backlog.md"
FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$first" same-name >/dev/null \
  || fail 'first local home did not receive its item'
FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$first" same-name >/dev/null \
  || fail 'same-home local retry was not idempotent'
if FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$second" same-name > "$source/second.out" 2>&1; then
  fail 'same basename reported success for a different local home'
fi
assert_absent "$second/data/backlog.md" 'wrong local home received a completed item'
assert_grep "moved to home ($first)" "$source/data/backlog.md" 'local completion lost its full home identity'
tasks-axi reopen same-name --file "$source/data/backlog.md" --backend markdown >/dev/null
FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$second" same-name >/dev/null \
  || fail 'reopened item did not move to the second home'
if FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$first" same-name > "$source/former.out" 2>&1; then
  fail 'historical completion note authorized the former home'
fi
pass 'same-named local homes have distinct completion identities'

echo 'ALL TESTS PASSED'
