#!/usr/bin/env bash
# Behavior tests for bin/fm-prep-install.sh and the ship-spawn hint that names
# a filled secondmate nav-prep without installing it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-prep-install.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-prep-install)

write_registry() {  # <primary-home> <secondmate-home>
  local primary=$1 sm=$2
  printf -- '- nav - navigation (home: %s; scope: wayfinding; projects: firstmate; added 2026-09-16)\n' \
    "$sm" > "$primary/data/secondmates.md"
}

place_filled_nav_prep() {  # <secondmate-home> <id>
  local sm=$1 id=$2
  mkdir -p "$sm/data/nav-preps" "$sm/data/$id"
  fm_test_prep_record "$sm/data" "$id" no no no direct-PR || fail "could not scaffold filled nav-prep for $id"
  mv "$sm/data/$id/prep.md" "$sm/data/nav-preps/$id.md"
}

make_primary() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

make_spawn_world() {  # <name>
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  git -C "$projects/proj" init -q || fail "could not initialize project fixture"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_script_parses() {
  local out rc
  out=$(bash -n "$INSTALL" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-prep-install.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-prep-install.sh emitted unexpected output: $out"
  pass "fm-prep-install.sh: bash -n succeeds"
}

test_installs_filled_nav_prep_into_primary_prep() {
  local home sm id dest src out status
  home=$(make_primary install-ok)
  sm="$TMP_ROOT/install-ok/secondmate"
  id=profiles
  mkdir -p "$sm"
  sm=$(CDPATH='' cd -- "$sm" && pwd -P)
  write_registry "$home" "$sm"
  place_filled_nav_prep "$sm" "$id"
  src="$sm/data/nav-preps/$id.md"
  dest="$home/data/$id/prep.md"

  status=0
  out=$(FM_HOME="$home" "$INSTALL" "$id") || status=$?
  expect_code 0 "$status" "install filled nav-prep"
  assert_present "$dest" "install did not write primary prep.md"
  cmp -s "$src" "$dest" || fail "installed prep.md did not match the nav-prep"
  assert_contains "$out" "installed: $dest" "install success line omitted the destination"
  assert_contains "$out" "(from $src)" "install success line omitted the source"

  pass "fm-prep-install.sh: copies a filled nav-prep into data/<id>/prep.md"
}

test_refuses_overwrite_of_filled_primary_without_force() {
  local home sm id dest src before after out status
  home=$(make_primary overwrite-refuse)
  sm="$TMP_ROOT/overwrite-refuse/secondmate"
  id=results
  mkdir -p "$sm"
  sm=$(CDPATH='' cd -- "$sm" && pwd -P)
  write_registry "$home" "$sm"
  place_filled_nav_prep "$sm" "$id"
  src="$sm/data/nav-preps/$id.md"
  mkdir -p "$home/data/$id"
  fm_test_prep_record "$home/data" "$id" || fail "could not fill primary prep"
  dest="$home/data/$id/prep.md"
  printf 'primary-original\n' >> "$dest"
  cp "$dest" "$TMP_ROOT/overwrite-refuse/before.md"
  before=$(cat "$TMP_ROOT/overwrite-refuse/before.md")

  status=0
  out=$(FM_HOME="$home" "$INSTALL" "$id" 2>&1) || status=$?
  expect_code 1 "$status" "overwrite without --force"
  assert_contains "$out" "already passes the preparation gate" \
    "filled-destination refusal did not name the gate"
  assert_contains "$out" "--force" "filled-destination refusal did not name --force"
  after=$(cat "$dest")
  [ "$before" = "$after" ] || fail "install overwrote a filled primary prep without --force"

  status=0
  out=$(FM_HOME="$home" "$INSTALL" --force "$id" 2>&1) || status=$?
  expect_code 0 "$status" "overwrite with --force"
  cmp -s "$src" "$dest" || fail "--force did not replace the filled primary prep"

  pass "fm-prep-install.sh: refuses a filled destination unless --force"
}

test_replaces_unfilled_primary_scaffold() {
  local home sm id dest src status
  home=$(make_primary replace-scaffold)
  sm="$TMP_ROOT/replace-scaffold/secondmate"
  id=coverage
  mkdir -p "$sm"
  sm=$(CDPATH='' cd -- "$sm" && pwd -P)
  write_registry "$home" "$sm"
  place_filled_nav_prep "$sm" "$id"
  src="$sm/data/nav-preps/$id.md"
  mkdir -p "$home/data/$id"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-brief.sh" "$id" --prep >/dev/null \
    || fail "could not scaffold empty primary prep"
  dest="$home/data/$id/prep.md"

  status=0
  FM_HOME="$home" "$INSTALL" "$id" >/dev/null || status=$?
  expect_code 0 "$status" "replace unfilled scaffold"
  cmp -s "$src" "$dest" || fail "unfilled primary scaffold was left in place"

  pass "fm-prep-install.sh: replaces an empty local --prep scaffold"
}

test_refuses_missing_or_unfilled_source() {
  local home sm id out status
  home=$(make_primary missing-source)
  sm="$TMP_ROOT/missing-source/secondmate"
  id=absent
  mkdir -p "$sm/data/nav-preps"
  sm=$(CDPATH='' cd -- "$sm" && pwd -P)
  write_registry "$home" "$sm"

  status=0
  out=$(FM_HOME="$home" "$INSTALL" "$id" 2>&1) || status=$?
  expect_code 1 "$status" "missing nav-prep"
  assert_contains "$out" "no filled nav-prep for $id" "missing-source refusal was unclear"

  mkdir -p "$sm/data/$id"
  FM_HOME="$sm" FM_DATA_OVERRIDE="$sm/data" "$ROOT/bin/fm-brief.sh" "$id" --prep >/dev/null \
    || fail "could not scaffold unfilled nav-prep"
  mv "$sm/data/$id/prep.md" "$sm/data/nav-preps/$id.md"

  status=0
  out=$(FM_HOME="$home" "$INSTALL" "$id" 2>&1) || status=$?
  expect_code 1 "$status" "unfilled discovered nav-prep"
  assert_contains "$out" "no filled nav-prep for $id" \
    "unfilled discovered source was treated as installable"

  pass "fm-prep-install.sh: refuses a missing or unfilled source"
}

test_spawn_names_filled_nav_prep_and_does_not_install() {
  local rec home proj fakebin sm id dest src out status
  rec=$(make_spawn_world spawn-hint)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  sm="$TMP_ROOT/spawn-hint/secondmate"
  id=navhint
  mkdir -p "$sm" "$home/data/$id"
  sm=$(CDPATH='' cd -- "$sm" && pwd -P)
  write_registry "$home" "$sm"
  place_filled_nav_prep "$sm" "$id"
  src="$sm/data/nav-preps/$id.md"
  dest="$home/data/$id/prep.md"
  printf 'You are a crewmate.\n\n# Task\n## Captain'"'"'s intent\nShip something.\n\n## Firstmate spec\nBuild it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' \
    > "$home/data/$id/brief.md"

  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn with missing primary prep should exit non-zero"
  assert_contains "$out" "cannot ship without its preparation record" \
    "prep-gate refusal was omitted"
  assert_contains "$out" "$src" "spawn hint omitted the filled nav-prep path"
  assert_contains "$out" "bin/fm-prep-install.sh $id" \
    "spawn hint omitted the install command"
  assert_absent "$dest" "spawn installed a nav-prep on its own"
  assert_absent "$home/state/$id.meta" "a prep-gated spawn wrote task metadata"

  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-brief.sh" "$id" --prep >/dev/null \
    || fail "could not scaffold empty primary prep for spawn hint"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn with an empty primary prep should exit non-zero"
  assert_contains "$out" "$src" "empty-scaffold spawn omitted the filled nav-prep path"
  assert_contains "$out" "bin/fm-prep-install.sh $id" \
    "empty-scaffold spawn omitted the install command"
  grep -F "Q1 does this change" "$dest" >/dev/null \
    || fail "empty primary scaffold was replaced during spawn"

  mkdir -p "$home/data/filledok"
  fm_test_prep_record "$home/data" filledok no no no direct-PR || fail "could not fill primary prep for success path"
  printf 'You are a crewmate.\n\n# Task\n## Captain'"'"'s intent\nShip something.\n\n## Firstmate spec\nBuild it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' \
    > "$home/data/filledok/brief.md"
  place_filled_nav_prep "$sm" filledok
  out=$(run_spawn "$home" "$fakebin" filledok "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "cannot ship without its preparation record" \
    "a filled primary prep was refused"
  assert_not_contains "$out" "fm-prep-install.sh filledok" \
    "a filled primary prep still printed the nav-prep install hint"
  assert_present "$home/data/filledok/launch-brief.md" \
    "a filled primary prep did not get past the preparation gates"

  pass "fm-spawn: names a filled nav-prep on prep refusal and never auto-installs"
}

# A complete nav-prep installs byte-identically and is admitted without review.
test_installed_nav_prep_admits_without_review() {
  local rec home proj fakebin sm id dest out status
  rec=$(make_spawn_world install-unreviewed)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  sm="$TMP_ROOT/install-unreviewed/secondmate"
  id=navunreviewed
  mkdir -p "$sm"
  sm=$(CDPATH='' cd -- "$sm" && pwd -P)
  write_registry "$home" "$sm"
  place_filled_nav_prep "$sm" "$id"
  dest="$home/data/$id/prep.md"
  status=0
  out=$(FM_HOME="$home" "$INSTALL" "$id" 2>&1) || status=$?
  expect_code 0 "$status" "install filled nav-prep"
  cmp -s "$sm/data/nav-preps/$id.md" "$dest" || fail "installed bytes differ"
  assert_absent "$home/data/$id/prep-review" "install fabricated review"
  printf 'You are a crewmate.\n\n# Task\n## Captain'"'"'s intent\nShip something.\n\n## Firstmate spec\nBuild it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' \
    > "$home/data/$id/brief.md"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" 'cannot ship without its preparation record' "installed prep refused: $out"
  assert_present "$home/data/$id/launch-brief.md" "installed unreviewed prep did not reach rendering: $out"
  assert_absent "$home/state/$id.meta" "fixture created real task"
  cmp -s "$sm/data/nav-preps/$id.md" "$dest" || fail "spawn migrated installed bytes"
  # A malformed new common field is refused through the executable install seam.
  sed '/^- Scope only as asked:/d' "$dest" > "$sm/data/nav-preps/$id.md"
  status=0
  out=$(FM_HOME="$home" "$INSTALL" "$id" --force 2>&1) || status=$?
  [ "$status" != 0 ] || fail "install accepted malformed common source"
  assert_contains "$out" 'no filled nav-prep' "install failed for unrelated reason: $out"
  pass "nav-prep: byte-identical complete preparation admits without review; malformed common fields do not install"
}

test_surgical_nav_prep_installation() {
  local task_home sm id src dest out rc
  task_home=$(make_primary surgical-nav)
  sm="$TMP_ROOT/surgical-nav/secondmate"
  id=surgical-nav
  mkdir -p "$sm/data/nav-preps"
  write_registry "$task_home" "$sm"
  FM_HOME="$sm" "$ROOT/bin/fm-brief.sh" "$id" --prep --surgical >/dev/null || fail "compact nav scaffold"
  src="$sm/data/nav-preps/$id.md"
  sed -E -e 's/\{Q1\}/yes/' -e 's/\{Q2\}/no/' -e 's/\{Q[12]_REASON\}/Confined output inspected./' \
    -e 's/\{UI_WIRING\}/no, confined output./' -e 's/\{C[1-5]\}/yes/' \
    -e 's/\{C[1-5]_EVIDENCE\}/bin\/own.sh:1; rg own returned only owned file; all excluded paths untouched; cause reproduced; bash tests\/own.test.sh red-first regression covers fix./' \
    "$sm/data/$id/prep.md" > "$src"
  dest="$task_home/data/$id/prep.md"
  fm_test_fill_prep_common "$src" || fail "compact common fixture"
  out=$(FM_HOME="$task_home" "$INSTALL" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "complete compact nav installation"
  cmp -s "$src" "$dest" || fail "compact bytes changed during installation"
  assert_absent "$task_home/data/$id/prep-review" "compact install invented approval"
  sed 's/^- C2 .*: yes$/- C2 unknown: unsure/' "$src" > "$src.uncertain"
  mv "$src.uncertain" "$src"
  out=$(FM_HOME="$task_home" "$INSTALL" "$id" --force 2>&1); rc=$?
  expect_code 1 "$rc" "uncertain compact nav installation"
  assert_contains "$out" 'no filled nav-prep' "uncertain compact nav treated as filled"
  pass "nav-prep: complete compact bytes install unchanged; uncertainty does not install"
}

test_large_prep_pipefail() (
  set -o pipefail
  . "$ROOT/bin/fm-dod-lib.sh"
  local task_home sm id src dest out rc format position mode full
  task_home=$(make_primary large-prep)
  sm="$TMP_ROOT/large-prep/secondmate"
  mkdir -p "$sm/data/nav-preps"
  write_registry "$task_home" "$sm"
  fm_test_prep_record "$sm/data" large-full yes no no direct-PR || fail "large full fixture"
  full="$sm/data/large-full/prep.md"
  awk 'BEGIN { for (i = 0; i < 8192; i++) print "regression pass" }' > "$TMP_ROOT/regression-output"
  for format in full surgical; do
    for position in appendix tier; do
      id="large-$format-$position"
      src="$sm/data/nav-preps/$id.md"
      if [ "$format" = full ]; then
        cp "$full" "$src"
      else
        FM_HOME="$sm" "$ROOT/bin/fm-brief.sh" "$id" --prep --surgical >/dev/null || fail "large compact scaffold"
        sed -E -e 's/\{Q1\}/yes/' -e 's/\{Q2\}/no/' -e 's/\{Q[12]_REASON\}/Confined output inspected./' \
          -e 's/\{UI_WIRING\}/no, confined output./' -e 's/\{C[1-5]\}/yes/' \
          -e 's/\{C[1-5]_EVIDENCE\}/bin\/own.sh:1; rg own found only owned code; excluded paths untouched; cause reproduced; bash tests\/own.test.sh covers the fix./' \
          "$sm/data/$id/prep.md" > "$src"
        fm_test_fill_prep_common "$src" direct-PR || fail "large compact common fields"
      fi
      if [ "$position" = appendix ]; then
        printf '\n## Regression output\n' >> "$src"
        cat "$TMP_ROOT/regression-output" >> "$src"
      else
        awk -v output="$TMP_ROOT/regression-output" '
          /^## Tier$/ { tier = 1 }
          tier && /^## / && $0 != "## Tier" {
            while ((getline line < output) > 0) print line
            close(output); tier = 0
          }
          { print }
        ' "$src" > "$src.large"
        mv "$src.large" "$src"
      fi
      for mode in direct-PR no-mistakes; do
        fm_test_prep_depth "$src" "$mode" || fail "large prep depth"
        out=$(fm_prep_delivery_mode "$src"); rc=$?
        expect_code 0 "$rc" "$id depth reader with pipefail"
        [ "$out" = "$mode" ] || fail "$id read wrong depth: $out"
        out=$(fm_prep_ui_wiring_line "$src"); rc=$?
        expect_code 0 "$rc" "$id UI reader with pipefail"
        assert_contains "$out" 'no,' "$id UI answer"
        [ "$(fm_prep_tier "$src")" = 2 ] || fail "$id wrong tier"
        out=$(fm_prep_unfilled_reason "$src"); rc=$?
        expect_code 1 "$rc" "$id $mode completeness with pipefail (got: $out)"
        [ -z "$out" ] || fail "$id unexpectedly incomplete: $out"
      done
      dest="$task_home/data/$id/prep.md"
      out=$(FM_HOME="$task_home" "$INSTALL" "$id" 2>&1); rc=$?
      expect_code 0 "$rc" "$id public nav installation (got: $out)"
      cmp -s "$src" "$dest" || fail "$id installed bytes changed"
      if [ "$format" = surgical ]; then
        cp "$dest" "$src.installed"
        awk '/^## [0-9]+\./ { sections = 1 } sections { print }' "$full" >> "$src"
        sed 's/^- C2 .*: yes$/- C2 unknown: unsure/' "$src" > "$src.uncertain"
        mv "$src.uncertain" "$src"
        out=$(fm_prep_unfilled_reason "$src"); rc=$?
        expect_code 0 "$rc" "$id must retain surgical gate with full sections"
        assert_contains "$out" 'C2' "$id invalid certificate was rescued by numbered sections"
        out=$(FM_HOME="$task_home" "$INSTALL" "$id" --force 2>&1); rc=$?
        expect_code 1 "$rc" "$id invalid hybrid installation"
        assert_contains "$out" 'no filled nav-prep' "$id invalid source accepted"
        cmp -s "$src.installed" "$dest" || fail "$id rejected source replaced installed bytes"
      fi
      pass "$id: pipefail preserves both depths, tier, completeness and installation"
    done
  done
)

test_large_prep_pipefail || exit 1
