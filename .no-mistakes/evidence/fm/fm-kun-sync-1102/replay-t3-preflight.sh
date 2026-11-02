#!/usr/bin/env bash
set -eu
source tests/fixtures.sh
base=$(mktemp -d "$TMPDIR/fm-t3-preflight.XXXXXX")
trap 'rm -rf "$base"' EXIT
parent="$base/parent"
mkdir "$parent"
bin/fm-lab-home.sh create "$parent" >/dev/null
printf '%s\n' "$base/unused-account" > "$parent/config/codex-accounts"
mkdir -p "$base/unused-account" "$base/project" "$base/mate/data" "$base/mate/bin"
git -C "$base/project" init -q
git -C "$base/mate" init -q
printf '# Firstmate\n' > "$base/mate/AGENTS.md"
printf 'charter\n' > "$base/mate/data/charter.md"
printf '999999 0\n' > "$parent/config/lane-capacity"
fm_test_machine_policy "$parent/config"
for role in ship scout secondmate; do
  id="t3-proof-$role"
  fm_test_spawn_brief "$parent" "$id"
  project="$base/project"
  args=(--harness codex --backend t3code)
  case "$role" in
    ship) args+=(--mode no-mistakes --yolo off) ;;
    scout) args+=(--scout) ;;
    secondmate) args+=(--secondmate); project="$base/mate"; printf '%s\n' "$id" > "$base/mate/.fm-secondmate-home" ;;
  esac
  set +e
  out=$(FM_HOME="$parent" .no-mistakes/runtime/bin/fm-spawn.sh "$id" "$project" "${args[@]}" 2>&1)
  rc=$?
  set -e
  printf '%s: exit=%s %s\n' "$role" "$rc" "$out"
  [ "$rc" = 1 ]
  [[ "$out" == *'backend=t3code cannot apply config/codex-accounts'* ]]
  [ ! -e "$parent/state/$id.meta" ]
  [ ! -e "$parent/data/$id/launch-brief.md" ]
done
printf 'All roles refused before task metadata or a rendered launch brief existed; no T3 server or credential was used.\n'
