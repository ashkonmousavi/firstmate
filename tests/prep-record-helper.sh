#!/usr/bin/env bash
# tests/prep-record-helper.sh - the task preparation record every ship spawn
# requires (bin/fm-brief.sh --prep, gated by bin/fm-spawn.sh).
#
# It lives in its own file because both test worlds need it and neither can
# source the other: tests/lib.sh installs EXIT traps the real-Herdr suites own
# themselves, so tests/herdr-test-safety.sh deliberately stays out of it.
#
# The record is scaffolded through bin/fm-brief.sh itself rather than written
# here, so a fixture follows the template instead of pinning a stale copy of its
# sections.

# fm_test_prep_record <data-dir> <id>
# Writes an answered record for <id> under <data-dir>. Idempotent: an existing
# record is left alone so a test can write its own. Returns non-zero if the
# scaffold fails.
fm_test_prep_record() {
  local data=$1 id=$2 root prep
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  prep="$data/$id/prep.md"
  [ -e "$prep" ] && return 0
  mkdir -p "$data/$id"
  FM_HOME="$data" FM_DATA_OVERRIDE="$data" "$root/bin/fm-brief.sh" "$id" --prep >/dev/null \
    || return 1
  sed 's/^{[A-Z0-9_]*}$/n\/a: spawn fixture./' "$prep" > "$prep.filled" \
    && mv "$prep.filled" "$prep"
}
