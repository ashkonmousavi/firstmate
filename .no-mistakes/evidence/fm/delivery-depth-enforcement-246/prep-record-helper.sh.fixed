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

# fm_test_prep_record <data-dir> <id> [<q1>] [<q2>] [<ui-wiring>] [<depth-mode>]
# Writes an answered record for <id> under <data-dir>. The tier header answers
# default to three noes with the tier-1 sections; pass yes to
# any of them to exercise a higher tier, where every section is answered.
# Idempotent: an existing record is left alone so a test can write its own.
# Returns non-zero if the scaffold fails.
fm_test_prep_record() {
  local data=$1 id=$2 q1=${3:-no} q2=${4:-no} ui=${5:-no} depth_mode=${6:-no-mistakes} root prep
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  prep="$data/$id/prep.md"
  if [ ! -e "$prep" ]; then
    mkdir -p "$data/$id"
    FM_HOME="$data" FM_DATA_OVERRIDE="$data" "$root/bin/fm-brief.sh" "$id" --prep >/dev/null \
      || return 1
    sed -e "s/{Q1}/$q1/" -e "s/{Q2}/$q2/" \
        -e "s/{UI_WIRING}/$ui, spawn fixture./" \
        -e 's/^{INTENT_AND_BOXES}$/Exercise the delivery contract in an isolated fixture./' \
        -e 's/^{[A-Z0-9_]*}$/n\/a: spawn fixture./' "$prep" > "$prep.filled" \
      && mv "$prep.filled" "$prep" || return 1
    fm_test_fill_prep_common "$prep" "$depth_mode" || return 1
    if [ "$ui" = yes ]; then
      sed 's/^- Screen and region:.*$/- Screen and region: Settings, configuration region, fixture design map./' "$prep" > "$prep.ui" \
        && mv "$prep.ui" "$prep" || return 1
    fi
  fi
  return 0
}

# Fill the real scaffold's common fields with concrete fixture checks.
fm_test_fill_prep_common() {  # <prep-file> [<depth-mode>]
  local prep=$1 depth
  # Shared spawn fixtures exercise no-mistakes unless a caller authors another choice.
  case "${2:-no-mistakes}" in
    direct-PR) depth='checks-only (direct-PR)' ;;
    no-mistakes) depth='checks + AI review (no-mistakes)' ;;
    *) return 1 ;;
  esac
  awk -v depth="$depth" '
    { gsub(/\{DELIVERY_DEPTH\}/, depth ", exercise the declared fixture delivery contract.")
      gsub(/\{CAPTAIN_RULINGS\}/, "Intent: exercise delivery admission; ruling: use an isolated fixture (test brief).")
      gsub(/\{STILL_VALID\}/, "proceed: inspected fixture base and task sources; delivery admission remains needed with no dependency.")
      gsub(/\{SIBLINGS_NAMED\}/, "Not a defect; searched fixture task records and delivery owners, none found.")
      gsub(/\{VALIDATION_ROUTE\}/, "bash bin/fm-test-run.sh tests/fm-task-delivery.test.sh; Bash fixture runtime, isolated home, baseline timing unknown; worker measures this bounded run, CI owns final regression.")
      gsub(/\{SCREEN_AND_REGION\}/, "n/a: no product screen is changed.")
      gsub(/\{RED_FIRST_PROOF\}/, "bash tests/fm-task-delivery.test.sh; remove the record; expect a preparation refusal; record observed RED before implementation.")
      gsub(/\{FIXTURE_ARITHMETIC\}/, "n/a: no calculated assertions.")
      gsub(/\{DATA_PATH_REACHABILITY\}/, "brief --prep writes data/id/prep.md; spawn reads that path; launch rendering is the fixture witness.")
      gsub(/\{SCOPE_ONLY_AS_ASKED\}/, "Exercise the requested delivery admission only; real endpoints and product changes are outside scope.")
      gsub(/\{AUTHOR_GATE_CHECK\}/, "bash -c '\'' . bin/fm-dod-lib.sh; fm_prep_unfilled_reason \"$1\" '\'' _ data/id/prep.md; run on final bytes before handoff and paste empty output and raw exit 1 (reason with exit 0 refuses).")
      gsub(/\{OUTCOME\}/, "Delivery admission")
      gsub(/\{OBSERVABLE_RESULT\}/, "Launch brief exists before the refusing backend")
      gsub(/\{WHERE_AND_HOW\}/, "bash tests/fm-task-delivery.test.sh; fixture spawn and launch-brief.md")
      gsub(/\{EXPECTED_VALUE\}/, "Brief present; no real endpoint created")
      print
    }' "$prep" > "$prep.common" && mv "$prep.common" "$prep"
}

# Set an explicit fixture decision, independent of tier and surgical format.
fm_test_prep_depth() {  # <prep-file> <direct-PR|no-mistakes>
  local prep=$1 depth
  case "$2" in
    direct-PR) depth='checks-only (direct-PR)' ;;
    no-mistakes) depth='checks + AI review (no-mistakes)' ;;
    *) return 1 ;;
  esac
  awk -v depth="$depth" '
    /^- Delivery depth:/ { next }
    { print }
    $0 == "## Tier" { print "- Delivery depth: " depth ", exercise the declared fixture delivery contract." }
  ' "$prep" > "$prep.depth" && mv "$prep.depth" "$prep"
}
