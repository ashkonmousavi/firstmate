#!/usr/bin/env bash
# Per-task pre-push Ruff format check for repositories declaring Ruff.
# Usage: fm-git-ruff-format-check.sh <remote-name> <remote-url> (refs on stdin).
# Checks committed .py, .pyi and .ipynb content and configuration with
# --force-exclude. New refs use the default branch's merge base; without a
# comparison base, every tracked supported file is checked.
set -u
set -o pipefail
unset CDPATH

ZERO_OID_RE='^0+$'

refuse() {
  printf 'fm-ruff-format: refused: %s\n' "$1" >&2
}

default_base() {
  local ref
  ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || ref=
  for ref in "$ref" refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
    [ -n "$ref" ] || continue
    if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

declares_ruff() {
  local oid=$1 path content line declared=1
  local requirement_re='^[[:space:]]*[Rr][Uu][Ff][Ff]([[:space:]]|[<>=!~;]|\[|$)'
  local pin_re='^[[:space:]]*[Rr][Uu][Ff][Ff][[:space:]]*==[[:space:]]*([[:alnum:]_.+!-]+)([[:space:];#]|$)'
  RUFF_PACKAGE=ruff
  while IFS= read -r -d '' path; do
    case "$path" in
      ruff.toml | .ruff.toml | */ruff.toml | */.ruff.toml) declared=0 ;;
      pyproject.toml | */pyproject.toml)
        content=$(git show "$oid:$path") || return 2
        if printf '%s\n' "$content" | grep -E '^[[:space:]]*\[[[:space:]]*tool\.ruff([.]|[[:space:]]*])' >/dev/null; then
          declared=0
        fi
        ;;
      requirements-dev.txt | */requirements-dev.txt)
        content=$(git show "$oid:$path") || return 2
        while IFS= read -r line || [ -n "$line" ]; do
          if [[ "$line" =~ $requirement_re ]]; then
            declared=0
            if [[ "$line" =~ $pin_re ]]; then
              RUFF_PACKAGE="ruff==${BASH_REMATCH[1]}"
            fi
          fi
        done <<<"$content"
        ;;
    esac
  done <"$SNAPSHOT/.git/files"
  return "$declared"
}

find_ruff() {
  local top candidate tool
  top=$(git rev-parse --show-toplevel) || return 1
  for candidate in "$top/.venv/bin/ruff" "$top/venv/bin/ruff"; do
    if [ -x "$candidate" ]; then
      RUFF=("$candidate")
      return 0
    fi
  done
  for tool in ruff uvx uv; do
    if candidate=$(command -v "$tool"); then
      [[ "$candidate" = /* ]] || candidate="$PWD/$candidate"
      case "$tool" in
        ruff) RUFF=("$candidate") ;;
        uvx) RUFF=("$candidate" --from "$RUFF_PACKAGE" ruff) ;;
        uv) RUFF=("$candidate" tool run --from "$RUFF_PACKAGE" ruff) ;;
      esac
      return 0
    fi
  done
  refuse 'Ruff was not found in .venv, venv, PATH, uvx or uv tool run'
  printf 'Install: python3 -m pip install %q\n' "$RUFF_PACKAGE" >&2
  return 1
}

check_ref() {
  local oid=$1 remote_ref=$2 remote_oid=$3 base='' default path out rc
  git cat-file -e "$oid^{commit}" 2>/dev/null || {
    refuse "could not read the pushed commit for $remote_ref"
    return 1
  }
  SNAPSHOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ruff-format.XXXXXX") || return 1
  SNAPSHOT=$(cd "$SNAPSHOT" && pwd -P) || return 1
  if ! { mkdir "$SNAPSHOT/.git" && git ls-tree -rz --name-only "$oid" >"$SNAPSHOT/.git/files"; }; then
    refuse "could not list the pushed tree for $remote_ref"
    return 1
  fi
  declares_ruff "$oid"
  rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) refuse "could not read Ruff declarations for $remote_ref"; return 1 ;;
  esac
  if ! { GIT_INDEX_FILE="$SNAPSHOT/.git/index" git read-tree "$oid" &&
    GIT_INDEX_FILE="$SNAPSHOT/.git/index" git --work-tree="$SNAPSHOT" checkout-index --all --prefix="$SNAPSHOT/"; }; then
    refuse "could not read the pushed tree for $remote_ref"
    return 1
  fi
  if ! [[ "$remote_oid" =~ $ZERO_OID_RE ]]; then
    if git cat-file -e "$remote_oid^{commit}" 2>/dev/null; then
      base=$(git merge-base "$remote_oid" "$oid" 2>/dev/null) || base=
    fi
  elif default=$(default_base); then
    base=$(git merge-base "$default" "$oid" 2>/dev/null) || base=
  fi
  if [ -n "$base" ]; then
    git diff -z --name-only --no-renames --diff-filter=ACMR "$base" "$oid" -- '*.py' '*.pyi' '*.ipynb' >"$SNAPSHOT/.git/candidates" || return 1
  else
    GIT_INDEX_FILE="$SNAPSHOT/.git/index" git ls-files -z -- '*.py' '*.pyi' '*.ipynb' >"$SNAPSHOT/.git/candidates" || return 1
  fi
  [ -s "$SNAPSHOT/.git/candidates" ] || return 0
  find_ruff || return 1
  while IFS= read -r -d '' path; do
    out=$(git show "$oid:$path" | (cd "$SNAPSHOT" && "${RUFF[@]}" format --check --force-exclude --stdin-filename "$path" -) 2>&1)
    rc=$?
    case "$rc" in
      0) ;;
      1) BAD+=("$path") ;;
      *)
        refuse "Ruff could not check $path (exit $rc): $out"
        printf 'Install: python3 -m pip install %q\n' "$RUFF_PACKAGE" >&2
        CHECK_FAILED=1
        ;;
    esac
  done <"$SNAPSHOT/.git/candidates"
}

case "${1:-}" in
  -h | --help)
    echo 'usage: fm-git-ruff-format-check.sh <remote-name> <remote-url> (refs on stdin)' >&2
    exit 2
    ;;
esac

RUFF=()
RUFF_PACKAGE=ruff
CHECK_FAILED=0
SNAPSHOT=
trap '[ -z "$SNAPSHOT" ] || rm -rf -- "$SNAPSHOT"' EXIT
BAD=()
while read -r _ local_oid remote_ref remote_oid; do
  [ -n "${local_oid:-}" ] || continue
  [[ "$local_oid" =~ $ZERO_OID_RE ]] && continue
  check_ref "$local_oid" "${remote_ref:-}" "${remote_oid:-0}" || CHECK_FAILED=1
  if [ -n "$SNAPSHOT" ]; then
    rm -rf -- "$SNAPSHOT"
    SNAPSHOT=
  fi
done

[ "${#BAD[@]}" -gt 0 ] || exit "$CHECK_FAILED"
SORTED=()
while IFS= read -r -d '' path; do SORTED+=("$path"); done < <(printf '%s\0' "${BAD[@]}" | sort -zu)
{
  printf 'fm-ruff-format: refused: ruff format --check would reformat %s changed file(s), and CI fails the PR on them:\n' "${#SORTED[@]}"
  printf '  %s\n' "${SORTED[@]}"
  printf 'Fix: ruff format'
  printf ' %q' "${SORTED[@]}"
  printf '\nThen commit the formatting and push again.\n'
} >&2
exit 1
