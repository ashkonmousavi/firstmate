#!/usr/bin/env bash
# Per-task pre-push ruff format check for a project listed in
# config/prepush-ruff-format (docs/configuration.md owns the list).
#
# Usage:
#   fm-git-ruff-format-check.sh enabled <list-file> <project>
#       Exit 0 when <project> is a line of <list-file>, nonzero when the file is
#       absent or does not name it. Blank lines and #-comments are ignored.
#   fm-git-ruff-format-check.sh <remote-name> <remote-url>
#       Pre-push mode. Git's pre-push arguments are accepted and ignored, and
#       git's "<local-ref> <local-oid> <remote-ref> <remote-oid>" lines arrive on
#       stdin. For each pushed commit, runs `ruff format --check` on the .py
#       files the push adds or changes, read from the pushed commit rather than
#       the working tree. The comparison base is the merge base with the remote
#       ref's current commit, or with the project's default branch
#       (origin/HEAD, else origin/main or origin/master, else main or master)
#       when the push creates the ref. Exits 0 to let the push proceed, nonzero
#       naming each unformatted file and the exact `ruff format` fix command.
#
# bin/fm-git-strip-ai-trailers.sh install --ruff-format makes the pre-push
# wrapper run this check beside the push guard (bin/fm-git-push-guard.sh); each
# refuses on its own so neither hides the other.
#
# ruff is the project's own .venv/bin/ruff or venv/bin/ruff in the worker copy,
# else ruff on PATH. With neither, or when ruff itself errors on a file, the
# check prints one warning naming the problem and ALLOWS the push: a missing
# tool never blocks work, and it is never skipped silently. The files are passed
# with --force-exclude so the project's own ruff `exclude` settings apply the
# way they do in CI's `ruff format --check .`.
set -u

ZERO_OID_RE='^0+$'

warn() {  # <message>
  printf 'fm-ruff-format: WARNING: %s\n' "$1" >&2
}

enabled() {  # <list-file> <project>
  local list=$1 project=$2 line
  [ -f "$list" ] && [ -r "$list" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in '' | '#'*) continue ;; esac
    [ "$line" != "$project" ] || return 0
  done <"$list"
  return 1
}

# Prints the default-branch ref a new branch is compared against, else nothing.
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

# Sets RUFF to a runnable ruff, else returns nonzero.
find_ruff() {
  local top candidate
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
  for candidate in "$top/.venv/bin/ruff" "$top/venv/bin/ruff"; do
    if [ -n "$top" ] && [ -x "$candidate" ]; then
      RUFF=$candidate
      return 0
    fi
  done
  RUFF=$(command -v ruff 2>/dev/null) || return 1
  [[ "$RUFF" = /* ]] || RUFF="$PWD/$RUFF"
  [ -n "$RUFF" ]
}

check_ref() {  # <local-oid> <remote-ref> <remote-oid>; appends to BAD
  local oid=$1 remote_ref=$2 remote_oid=$3 base='' default path out rc
  git cat-file -e "$oid^{commit}" 2>/dev/null || return 0
  if ! [[ "$remote_oid" =~ $ZERO_OID_RE ]] && git cat-file -e "$remote_oid^{commit}" 2>/dev/null; then
    base=$(git merge-base "$remote_oid" "$oid" 2>/dev/null) || base=$remote_oid
  else
    if default=$(default_base); then
      base=$(git merge-base "$default" "$oid" 2>/dev/null) || base=
    fi
    if [ -z "$base" ]; then
      warn "cannot find the default branch to compare $remote_ref against, so its .py files were not format-checked and the push is allowed"
      return 0
    fi
  fi
  while IFS= read -r -d '' path; do
    if [ -z "${RUFF:-}" ] && ! find_ruff; then
      warn "ruff was not found (no .venv or venv in this copy, none on PATH), so the format check was skipped and the push is allowed; install ruff to enforce it"
      NO_RUFF=1
      return 0
    fi
    if [ -z "$SNAPSHOT" ]; then
      SNAPSHOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ruff-format.XXXXXX") || return 1
      SNAPSHOT=$(cd "$SNAPSHOT" && pwd -P) || return 1
      if ! { mkdir "$SNAPSHOT/.git" &&
        GIT_INDEX_FILE="$SNAPSHOT/.git/index" git read-tree "$oid" &&
        GIT_INDEX_FILE="$SNAPSHOT/.git/index" git --work-tree="$SNAPSHOT" checkout-index --all --prefix="$SNAPSHOT/"; }; then
        printf 'fm-ruff-format: refused: could not read the pushed tree for %s\n' "$remote_ref" >&2
        return 1
      fi
    fi
    out=$(git show "$oid:$path" | (cd "$SNAPSHOT" && "$RUFF" format --check --force-exclude --stdin-filename "$path" -) 2>&1)
    rc=$?
    case "$rc" in
      0) ;;
      1) BAD+=("$path") ;;
      *) warn "ruff could not check $path (exit $rc), so it was not format-checked and the push is allowed: $out" ;;
    esac
  done < <(git diff -z --name-only --no-renames --diff-filter=ACMR "$base" "$oid" -- '*.py')
  if [ -n "$SNAPSHOT" ]; then
    rm -rf -- "$SNAPSHOT"
    SNAPSHOT=
  fi
}

case "${1:-}" in
  enabled)
    [ "$#" -eq 3 ] || { echo "usage: fm-git-ruff-format-check.sh enabled <list-file> <project>" >&2; exit 2; }
    enabled "$2" "$3"
    exit $?
    ;;
  -h | --help)
    echo "usage: fm-git-ruff-format-check.sh enabled <list-file> <project> | <remote-name> <remote-url> (refs on stdin)" >&2
    exit 2
    ;;
esac

RUFF=
NO_RUFF=0
CHECK_FAILED=0
SNAPSHOT=
trap '[ -z "$SNAPSHOT" ] || rm -rf -- "$SNAPSHOT"' EXIT
BAD=()
while read -r _ local_oid remote_ref remote_oid; do
  [ -n "${local_oid:-}" ] || continue
  [[ "$local_oid" =~ $ZERO_OID_RE ]] && continue
  [ "$NO_RUFF" = 0 ] || break
  check_ref "$local_oid" "${remote_ref:-}" "${remote_oid:-0}" || { CHECK_FAILED=1; break; }
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
