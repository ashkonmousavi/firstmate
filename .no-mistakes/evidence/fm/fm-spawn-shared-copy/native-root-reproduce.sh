#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.root-proof
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/user" "$LAB/root"
. "$ROOT/tests/git-config-helpers.sh"
export TREEHOUSE_NO_UPDATE_CHECK=1
export HOME=$LAB/user TREEHOUSE_ROOT=$LAB/root SHELL=/bin/bash
export XDG_CONFIG_HOME=$LAB/user/.config XDG_STATE_HOME=$LAB/user/.state XDG_CACHE_HOME=$LAB/user/.cache
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
printf 'VERSION: '; treehouse --version
git init -qb main "$LAB/project"
printf 'native lease proof\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name=Proof -c user.email=proof@example.invalid commit -qm seed
cd "$LAB/project"
ALLOC=$(treehouse get --lease --lease-holder proof --no-fetch --json)
printf 'ALLOCATED: %s\n' "$ALLOC"
SLOT=$(printf '%s\n' "$ALLOC" | jq -er .path)
POOL=$(dirname "$(dirname "$SLOT")")
HELPER_ROOT=$(dirname "$POOL")
printf 'ENV ROOT: %s\nHELPER DERIVED ROOT: %s\n' "$TREEHOUSE_ROOT" "$HELPER_ROOT"
printf '\nDEFAULT STATUS (actual configured pool):\n'; treehouse status --json
printf '\nHELPER STATUS (--root dirname(pool)):\n'; treehouse --root "$HELPER_ROOT" status --json
printf '\nCORRECT EXPLICIT ROOT STATUS:\n'; treehouse --root "$TREEHOUSE_ROOT" status --json
[ "$(treehouse status --json | jq 'length')" = 1 ]
[ "$(treehouse --root "$HELPER_ROOT" status --json | jq 'length')" = 0 ]
[ "$(treehouse --root "$TREEHOUSE_ROOT" status --json | jq 'length')" = 1 ]
printf '\nCONFIRMED: helper root observes an empty different pool despite a real registered lease.\n'
