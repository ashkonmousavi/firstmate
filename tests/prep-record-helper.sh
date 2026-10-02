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
# Writes an answered record for <id> under <data-dir>, plus the separate review
# a non-exempt ship spawn requires (fm_test_prep_review). The tier header answers
# default to three noes with the tier-1 sections and byte-bound review; pass yes to
# any of them to exercise a higher tier, where every section is answered.
# Idempotent: an existing record, and an existing review of it, are left alone
# so a test can write its own; a record with no review yet gets one.
# Returns non-zero if the scaffold fails.
fm_test_prep_record() {
  local data=$1 id=$2 q1=${3:-no} q2=${4:-no} ui=${5:-no} root prep
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  prep="$data/$id/prep.md"
  if [ ! -e "$prep" ]; then
    mkdir -p "$data/$id"
    FM_HOME="$data" FM_DATA_OVERRIDE="$data" "$root/bin/fm-brief.sh" "$id" --prep >/dev/null \
      || return 1
    sed -e "s/{Q1}/$q1/" -e "s/{Q2}/$q2/" \
        -e "s/{UI_WIRING}/$ui, spawn fixture./" \
        -e 's/{Q[12]_REASON}/Inspected spawn fixture./' \
        -e 's/^{[A-Z0-9_]*}$/n\/a: spawn fixture./' "$prep" > "$prep.filled" \
      && mv "$prep.filled" "$prep" || return 1
  fi
  [ -e "$data/$id/prep-review" ] && return 0
  fm_test_prep_review "$data" "$id"
}

# fm_test_prep_review <data-dir> <id>
# Writes the proof of a separate review that bin/fm-dod-lib.sh's
# fm_prep_review_reason accepts: data/<id>/prep-review naming the reviewer
# <id>-prep-review and author firstmate, and that reviewer's launch brief,
# report, and reviewed-prep.md copied from the current prep.md. Always
# refreshes, so a test that edits prep.md after review calls it again to
# re-approve the edited record.
fm_test_prep_review() {
  local data=$1 id=$2 reviewer
  reviewer="$id-prep-review"
  [ -f "$data/$id/prep.md" ] || return 1
  mkdir -p "$data/$reviewer" || return 1
  printf 'reviewer=%s\nauthor=firstmate\n' "$reviewer" > "$data/$id/prep-review" || return 1
  printf '# Current worker role contract\nPrep-review scout fixture.\n' > "$data/$reviewer/launch-brief.md" || return 1
  printf '## Standards\nChecked project conventions.\n## Spec\nReviewed the preparation record for %s.\n## Architecture\nChecked shared seams.\n' "$id" > "$data/$reviewer/report.md" || return 1
  cp "$data/$id/prep.md" "$data/$reviewer/reviewed-prep.md"
}
