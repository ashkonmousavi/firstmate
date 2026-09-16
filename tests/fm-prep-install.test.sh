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
  fm_test_prep_record "$sm/data" "$id" || fail "could not scaffold filled nav-prep for $id"
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
  fm_test_prep_record "$home/data" filledok || fail "could not fill primary prep for success path"
  printf 'You are a crewmate.\n\n# Task\n## Captain'"'"'s intent\nShip something.\n\n## Firstmate spec\nBuild it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' \
    > "$home/data/filledok/brief.md"
  place_filled_nav_prep "$sm" filledok
  out=$(run_spawn "$home" "$fakebin" filledok "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "cannot ship without its preparation record" \
    "a filled primary prep was refused"
  assert_not_contains "$out" "fm-prep-install.sh filledok" \
    "a filled primary prep still printed the nav-prep install hint"

  pass "fm-spawn: names a filled nav-prep on prep refusal and never auto-installs"
}

test_script_parses
test_installs_filled_nav_prep_into_primary_prep
test_refuses_overwrite_of_filled_primary_without_force
test_replaces_unfilled_primary_scaffold
test_refuses_missing_or_unfilled_source
test_spawn_names_filled_nav_prep_and_does_not_install
echo "# all fm-prep-install tests passed"
