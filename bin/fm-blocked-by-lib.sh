# shellcheck shell=bash
# fm-blocked-by-lib.sh - the one rule that decides whether a blocked-by edge
# still blocks, shared by `fm-tasks-axi.sh ready` (and so bin/fm-autolaunch.sh,
# which launches only from that list) and bin/fm-fleet-snapshot.sh.
# Usage: . bin/fm-tasks-axi-lib.sh; . bin/fm-blocked-by-lib.sh
#
# fm_blocked_by_verdicts <data-dir> prints one line per blocked-by edge of every
# backlog row, in backlog order:
#   <row-id><TAB><closed 0|1><TAB><target><TAB><verdict><TAB><evidence>
# where <target> is the edge exactly as written and <verdict> is one of:
#   blocked    an open row with that id is in this home's backlog
#   satisfied  a done row with that id is in this home's backlog or its done
#              archive (evidence names which, plus the first pull request URL the
#              row cites), or a recorded mark cites the merged pull request
#   unknown    none of those, or the edge names another home (<home>:<id>);
#              unknown work blocks and is reported, never cleared
# Checked in that order, so an open row beats a done row and a mark.
# Only this home is read: a blocker that is open in another home is invisible
# here, so its absence reads unknown and blocks. That is also why a merged pull
# request is never looked up here: an id whose fm/<id> pull request merged can
# still be open in another home (a contract row held there until it lands), and
# reading the merge as satisfied would launch its dependents early.
# Edges come from bin/fm-tasks-axi-lib.sh fm_tasks_axi_dependency_edges and rows
# from the same row grammar (`- [ ] <id> - ...`, `- [x] <id> - ...`,
# `- **<id>** - ...`; a checked row or any row under `## Done` is done, and every
# row of the archive is done).
# The archive is the `archive` path in the backlog root's .tasks.toml
# `[markdown]` table (relative to that root), else <data>/done-archive.md, which
# is tasks-axi's own default; an absent archive holds no rows.
#
# MARKS. <data>/blocked-by-marks.tsv is an append-only ledger written only by
# bin/fm-blocked-by.sh mark|unmark:
#   mark<TAB><epoch><TAB><row-id><TAB><target><TAB><pull-request-url>
#   unmark<TAB><epoch><TAB><row-id><TAB><target><TAB>-
# The last line for a row and target wins, so unmark reverses a mark and the
# ledger keeps both. A mark never overrides an open row.
#
# Returns 2 with a diagnostic on stderr when the backlog, the archive, or the
# ledger exists but cannot be read, so a caller refuses rather than clearing.

fm_blocked_by_root() {  # <data-dir>
  local data=${1%/}
  case "$data" in
    */*) printf '%s\n' "${data%/*}" ;;
    *) printf '.\n' ;;
  esac
}

fm_blocked_by_archive_file() {  # <data-dir>
  local data=${1%/} root toml archive
  root=$(fm_blocked_by_root "$data")
  toml=$root/.tasks.toml
  archive=
  if [ -f "$toml" ]; then
    archive=$(awk '
      /^[[:space:]]*\[/ { table = $0; gsub(/[[:space:]]/, "", table); next }
      table == "[markdown]" && /^[[:space:]]*archive[[:space:]]*=/ {
        value = $0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*(#.*)?$/, "", value)
        if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) value = substr(value, 2, length(value) - 2)
        print value; exit
      }' "$toml") || archive=
  fi
  case "$archive" in
    '') printf '%s/done-archive.md\n' "$data" ;;
    /*) printf '%s\n' "$archive" ;;
    *) printf '%s/%s\n' "$root" "$archive" ;;
  esac
}

fm_blocked_by_marks_file() {  # <data-dir>
  printf '%s/blocked-by-marks.tsv\n' "${1%/}"
}

# fm_blocked_by_row_states <file> <backlog|archive>: <id><TAB><open|done|archive><TAB><first PR URL or ->
fm_blocked_by_row_states() {
  FM_BLOCKED_BY_SOURCE=$2 perl -ne '
    BEGIN { $archive = $ENV{FM_BLOCKED_BY_SOURCE} eq "archive" }
    if (/^##\s+(.+?)\s*$/) { $done = lc($1) eq "done"; next }
    my ($state, $id, $tail);
    if (/^- \[([ x])\]\s+(\S+)\s+-\s+(.*)$/) {
      ($state, $id, $tail) = ($1 eq "x" || $done ? "done" : "open", $2, $3);
    } elsif (/^- \*\*([A-Za-z0-9][A-Za-z0-9._-]*)\*\*\s+-\s+(.*)$/) {
      ($state, $id, $tail) = ($done ? "done" : "open", $1, $2);
    } else { next }
    $state = "archive" if $archive;
    my $pr = $tail =~ m{(https?://[^\s)<>"]+/pull/\d+)} ? $1 : "-";
    print join("\t", $id, $state, $pr), "\n";
  ' "$1"
}

fm_blocked_by_readable() {  # <file> <what>
  [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
  if [ -f "$1" ] && [ -r "$1" ]; then
    return 0
  fi
  printf 'blocked-by: the %s %s cannot be read\n' "$2" "$1" >&2
  return 2
}

fm_blocked_by_verdicts() {  # <data-dir>
  local data=${1%/} backlog archive marks edges rows archived ledger
  backlog=$data/backlog.md
  archive=$(fm_blocked_by_archive_file "$data")
  marks=$(fm_blocked_by_marks_file "$data")
  fm_blocked_by_readable "$backlog" backlog || return 2
  fm_blocked_by_readable "$archive" archive || return 2
  fm_blocked_by_readable "$marks" "mark ledger" || return 2
  [ -f "$backlog" ] || return 0
  edges=$(fm_tasks_axi_dependency_edges "$backlog") || return 2
  rows=$(fm_blocked_by_row_states "$backlog" backlog) || return 2
  archived=
  if [ -f "$archive" ]; then
    archived=$(fm_blocked_by_row_states "$archive" archive) || return 2
  fi
  ledger=
  if [ -f "$marks" ]; then
    ledger=$(cat "$marks") || return 2
  fi
  {
    [ -z "$rows" ] || printf '%s\n' "$rows" | sed 's/^/R\t/'
    [ -z "$archived" ] || printf '%s\n' "$archived" | sed 's/^/R\t/'
    [ -z "$ledger" ] || printf '%s\n' "$ledger" | sed 's/^/M\t/'
    [ -z "$edges" ] || printf '%s\n' "$edges" | sed 's/^/E\t/'
  } | awk -F '\t' '
    $1 == "R" {
      if ($3 == "open") open[$2] = 1
      else if (!($2 in done)) done[$2] = ($3 == "archive" ? "archive row" : "done row") ($4 != "-" ? " " $4 : "")
      next
    }
    $1 == "M" && ($2 == "mark" || $2 == "unmark") && NF >= 6 {
      mark[$4 SUBSEP $5] = ($2 == "mark" ? "marked " $6 " at " $3 : "")
      next
    }
    $1 == "E" && $4 == "blocked-by" {
      row = $2; closed = $3; target = $5; id = target
      if (index(target, ":")) {
        home = substr(target, 1, index(target, ":") - 1)
        verdict = "unknown"; why = "names home " home ", which this home cannot read"
      } else if (id in open) {
        verdict = "blocked"; why = "open row"
      } else if (id in done) {
        verdict = "satisfied"; why = done[id]
      } else if (mark[row SUBSEP target] != "") {
        verdict = "satisfied"; why = mark[row SUBSEP target]
      } else {
        verdict = "unknown"; why = "no row in this home backlog or archive and no recorded mark"
      }
      print row "\t" closed "\t" target "\t" verdict "\t" why
    }'
}

# fm_blocked_by_filter_ready <verdicts>: filter `tasks-axi ready` output on
# stdin. A ready row with any open edge whose verdict is not satisfied moves to
# a ready_withheld[N]{id,target,verdict,evidence} group printed right after the
# ready rows, one line per such edge; count: and ready[N] are rewritten to the
# rows that remain, and every other line passes through unchanged.
fm_blocked_by_filter_ready() {
  local verdicts=$1
  awk -F '\t' -v verdicts="$verdicts" '
    BEGIN {
      n = split(verdicts, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (split(lines[i], f, "\t") < 5 || f[2] != "0" || f[4] == "satisfied") continue
        held[f[1]] = held[f[1]] sprintf("  %s,%s,%s,%s\n", f[1], q(f[3]), f[4], q(f[5]))
      }
    }
    function q(s) { gsub(/"/, "\\\"", s); return (s ~ /[ ,:"]/ ? "\"" s "\"" : s) }
    { line[++total] = $0 }
    END {
      for (i = 1; i <= total; i++) {
        if (line[i] ~ /^ready\[[0-9]+\]/) { start = i; header = line[i]; continue }
        if (start && !stop && line[i] ~ /^  [^ ]/ && i == start + kept + dropped + 1) {
          id = line[i]; sub(/^  /, "", id); sub(/,.*/, "", id)
          if (id in held) { dropped++; withheld = withheld held[id] ; wrows++ } else { kept++; keep[kept] = line[i] }
          continue
        }
        if (start && !stop) stop = i
      }
      if (start && !stop) stop = total + 1
      for (i = 1; i <= total; i++) {
        if (line[i] ~ /^count: [0-9]+$/ && start) { print "count: " kept; continue }
        if (i == start) {
          if (kept) { sub(/^ready\[[0-9]+\]/, "ready[" kept "]", header); print header }
          else print "ready: 0 unblocked queued tasks"
          for (k = 1; k <= kept; k++) print keep[k]
          if (withheld != "") {
            c = split(withheld, wl, "\n") - 1
            print "ready_withheld[" c "]{id,target,verdict,evidence}:"
            printf "%s", withheld
          }
          i = stop - 1
          continue
        }
        print line[i]
      }
    }'
}
