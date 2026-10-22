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
    registered) FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" mate progress-parent progress-child ;;
    peer) FM_HOME="$source" "$ROOT/bin/fm-backlog-handoff.sh" --to "$target" progress-parent progress-child ;;
  esac
}

for route in receipt registered peer; do
  for progress in start done; do
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
- [ ] progress-child - keep child (repo: alpha) blocked-by: progress-parent - needs report
  first body paragraph

  state: this is payload, not lifecycle metadata
  prep: data/progress/prep.md

## Done
EOF
    cp "$source/data/backlog.md" "$source/queued.expected"
    generation=1
    if [ "$route" = receipt ]; then
      retry > "$source/first-receipt.out" 2>&1 || fail 'initial receipt failed'
    else
      cp "$source/data/backlog.md" "$target/data/backlog.md"
    fi
    for key in progress-parent progress-child; do
      tasks-axi "$progress" "$key" --file "$target/data/backlog.md" --backend markdown >/dev/null
    done
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
    retry > "$source/retry.out" 2>&1 || fail "$route recovery after $progress failed: $(cat "$source/retry.out")"
    cmp -s "$target/progress.expected" "$target/data/backlog.md" \
      || fail "$route recovery rewrote target progress"
    if [ "$route" = receipt ]; then
      assert_contains "$(cat "$source/retry.out")" 'moved=0 already=2' 'receipt duplicated progressed items'
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

echo 'ALL TESTS PASSED'
