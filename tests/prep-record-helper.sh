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

# fm_test_prep_record <data-dir> <id> [<q1>] [<q2>] [<ui-wiring>]
# Writes an answered record for <id> under <data-dir>. The tier header answers
# default to three noes - tier 0, the cheapest record a ship spawn accepts - so
# a fixture that only needs the gate satisfied pays nothing for it; pass yes to
# any of them to exercise a higher tier, where every section is answered.
# Idempotent: an existing record is left alone so a test can write its own.
# Returns non-zero if the scaffold fails.
fm_test_prep_record() {
  local data=$1 id=$2 q1=${3:-no} q2=${4:-no} ui=${5:-no} root prep
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  prep="$data/$id/prep.md"
  [ -e "$prep" ] && return 0
  mkdir -p "$data/$id"
  FM_HOME="$data" FM_DATA_OVERRIDE="$data" "$root/bin/fm-brief.sh" "$id" --prep >/dev/null \
    || return 1
  sed -e "s/{Q1}/$q1/" -e "s/{Q2}/$q2/" \
      -e "s/{UI_WIRING}/$ui, spawn fixture./" \
      -e 's/^{[A-Z0-9_]*}$/n\/a: spawn fixture./' "$prep" > "$prep.filled" \
    && mv "$prep.filled" "$prep"
}
