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
#   blocked    the fleet list (below) shows an open row with that id in another
#              home, or an open row with that id is in this home's backlog
#   satisfied  a done row with that id is in this home's backlog or its done
#              archive (evidence names which, plus the first pull request URL the
#              row cites), or a recorded mark cites the merged pull request
#   unknown    none of those; unknown work blocks and is reported, never cleared
# Checked in that order, so an open row anywhere the list covers beats a done
# row here and a mark. Local done/archive evidence or a mark can satisfy only
# an id held in the fleet list, even when that list is stale. No list or an id
# absent from it is unknown unless a visible open row already blocks it.
# A merged pull request is never looked up here and never clears an edge by
# itself: an id whose fm/<id> pull request merged can still be an open row (a
# contract row held open in another home until it lands), and reading the merge
# as satisfied would launch its dependents early. Only a manual mark recorded
# with bin/fm-blocked-by.sh mark can clear an edge on the strength of a merged PR.
# An edge written <home>:<id> is decided from the fleet list's rows for that
# home (open blocks, done or archive satisfies only from a fresh list, no row
# is unknown), or as a plain <id> when <home> is this home; with no fleet list
# its qualifier cannot be resolved and it is unknown.
#
# FLEET LIST. <data>/blocked-by-fleet-rows.tsv is optional, copied into each home
# by hand from the blocked-by census kit's `fleet-rows` output until the
# planned registered check refreshes it (nothing here fetches it):
#   self<TAB><this home's name>
#   generated<TAB><epoch the rows were read>
#   homes<TAB><comma-separated homes the rows cover>
#   row<TAB><home><TAB><id><TAB><open|done|archive>[<TAB><pull-request-urls>]
# with `#` comment lines allowed; the optional last field lists every full
# pull request URL the row cites, comma-separated (bin/fm-pr-owner.sh reads it).
# Self rows supply only membership for blocked-by decisions; this home's live
# backlog and archive decide its row states. A list older than
# 21600 seconds (six hours) is stale: its open rows still block and its done
# rows cannot satisfy remote-qualified edges. Local done/archive evidence and
# marks may satisfy a listed id only when no other home holds that id open.
# fm_blocked_by_fleet_note reports a missing or stale list on ready lists and
# digests, naming generation time, age and covered homes for a stale one.
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
# Returns 2 with a diagnostic on stderr when the backlog, the archive, the
# ledger, or the fleet list exists but cannot be read, or the fleet list lacks
# its self, generated, or homes line, so a caller refuses rather than clearing.

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

fm_blocked_by_fleet_file() {  # <data-dir>
  printf '%s/blocked-by-fleet-rows.tsv\n' "${1%/}"
}

# fm_blocked_by_fleet_header <file>: "<self><TAB><generated><TAB><homes><TAB><fresh 0|1>",
# or a diagnostic and 2 when a header line is missing or generated is not an epoch.
fm_blocked_by_fleet_header() {
  local file=$1 now header
  now=$(date +%s)
  header=$(awk -F '\t' -v now="$now" '
    $1 == "self" && NF >= 2 && $2 != "" { self = $2 }
    $1 == "generated" && $2 ~ /^[0-9]+$/ { gen = $2 }
    $1 == "homes" && NF >= 2 && $2 != "" { homes = $2 }
    END {
      if (self == "" || gen == "" || homes == "") exit 1
      print self "\t" gen "\t" homes "\t" (now - gen <= 21600 ? 1 : 0)
    }' "$file") || {
    printf 'blocked-by: the fleet list %s needs self, generated (epoch) and homes lines\n' "$file" >&2
    return 2
  }
  printf '%s\n' "$header"
}

fm_blocked_by_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s\n' "$1"
}

# fm_blocked_by_fleet_note <data-dir>: one line saying the fleet list is absent
# or stale, or nothing when a fresh list is present; 2 when it cannot be read.
fm_blocked_by_fleet_note() {
  local data=${1%/} fleet header gen homes
  fleet=$(fm_blocked_by_fleet_file "$data")
  fm_blocked_by_readable "$fleet" "fleet list" || return 2
  if [ ! -f "$fleet" ]; then
    printf 'fleet list absent: visible open rows still block; every other edge is unknown, including local done rows, archive rows and recorded marks\n'
    return 0
  fi
  header=$(fm_blocked_by_fleet_header "$fleet") || return 2
  [ "${header##*$'\t'}" = 1 ] && return 0
  IFS=$'\t' read -r _ gen homes _ <<<"$header"
  printf 'fleet list stale: generated %s (age %sh), covers %s; visible open rows still block; listed ids may be satisfied by local done rows, archive rows or recorded marks; remote done rows satisfy nothing\n' \
    "$(fm_blocked_by_iso "$gen")" "$(( ($(date +%s) - gen) / 3600 ))" "$homes"
}

# fm_blocked_by_row_states <file> <backlog|archive>:
#   <id><TAB><open|done|archive><TAB><first PR URL or -><TAB><every PR URL, comma-separated, or ->
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
    my @prs = $tail =~ m{(https?://[^\s)<>",]+/pull/\d+)}g;
    my %seen; @prs = grep { !$seen{$_}++ } @prs;
    print join("\t", $id, $state, (@prs ? $prs[0] : "-"), (@prs ? join(",", @prs) : "-")), "\n";
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

# fm_blocked_by_fleet_rows <data-dir>: every row this home can see, as
#   <home><TAB><id><TAB><open|done|archive><TAB><PR URLs, comma-separated, or ->
# this home's live backlog and archive first, named by the fleet list's self
# line (or `.` without a list), then the fleet list's rows for every other home.
# Returns 2 like fm_blocked_by_verdicts when an input cannot be read.
fm_blocked_by_fleet_rows() {
  local data=${1%/} backlog archive fleet header self=. rows
  backlog=$data/backlog.md
  archive=$(fm_blocked_by_archive_file "$data")
  fleet=$(fm_blocked_by_fleet_file "$data")
  fm_blocked_by_readable "$backlog" backlog || return 2
  fm_blocked_by_readable "$archive" archive || return 2
  fm_blocked_by_readable "$fleet" "fleet list" || return 2
  if [ -f "$fleet" ]; then
    header=$(fm_blocked_by_fleet_header "$fleet") || return 2
    self=${header%%$'\t'*}
  fi
  if [ -f "$backlog" ]; then
    rows=$(fm_blocked_by_row_states "$backlog" backlog) || return 2
    [ -z "$rows" ] || printf '%s\n' "$rows" | awk -F '\t' -v h="$self" '{ print h "\t" $1 "\t" $2 "\t" $4 }'
  fi
  if [ -f "$archive" ]; then
    rows=$(fm_blocked_by_row_states "$archive" archive) || return 2
    [ -z "$rows" ] || printf '%s\n' "$rows" | awk -F '\t' -v h="$self" '{ print h "\t" $1 "\t" $2 "\t" $4 }'
  fi
  if [ -f "$fleet" ]; then
    awk -F '\t' -v self="$self" '$1 == "row" && NF >= 4 && $2 != self { print $2 "\t" $3 "\t" $4 "\t" (NF >= 5 && $5 != "" ? $5 : "-") }' "$fleet" || return 2
  fi
}

fm_blocked_by_verdicts() {  # <data-dir>
  local data=${1%/} backlog archive marks fleet edges rows archived ledger listed header
  local self='' gen='' homes='' fresh=0 when='' gap
  backlog=$data/backlog.md
  archive=$(fm_blocked_by_archive_file "$data")
  marks=$(fm_blocked_by_marks_file "$data")
  fleet=$(fm_blocked_by_fleet_file "$data")
  fm_blocked_by_readable "$backlog" backlog || return 2
  fm_blocked_by_readable "$archive" archive || return 2
  fm_blocked_by_readable "$marks" "mark ledger" || return 2
  fm_blocked_by_readable "$fleet" "fleet list" || return 2
  gap=$(fm_blocked_by_fleet_note "$data") || return 2
  listed=
  if [ -f "$fleet" ]; then
    header=$(fm_blocked_by_fleet_header "$fleet") || return 2
    IFS=$'\t' read -r self gen homes fresh <<<"$header"
    when=$(fm_blocked_by_iso "$gen")
    listed=$(awk -F '\t' '$1 == "row" && NF >= 4' "$fleet") || return 2
  fi
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
    [ -z "$listed" ] || printf '%s\n' "$listed" | sed 's/^/L\t/'
    [ -z "$edges" ] || printf '%s\n' "$edges" | sed 's/^/E\t/'
  } | awk -F '\t' -v self="$self" -v homes="$homes" -v fresh="$fresh" -v when="$when" -v gap="$gap" '
    BEGIN { n = split(homes, hs, ","); for (i = 1; i <= n; i++) covered[hs[i]] = 1; list = (self != "") }
    $1 == "R" {
      if ($3 == "open") open[$2] = 1
      else if (!($2 in done)) done[$2] = ($3 == "archive" ? "archive row" : "done row") ($4 != "-" ? " " $4 : "")
      next
    }
    $1 == "M" && ($2 == "mark" || $2 == "unmark") && NF >= 6 {
      mark[$4 SUBSEP $5] = ($2 == "mark" ? "marked " $6 " at " $3 : "")
      next
    }
    $1 == "L" && ($5 == "open" || $5 == "done" || $5 == "archive") {
      listedid[$4] = 1
      if ($3 == self) next
      key = $3 SUBSEP $4
      if (!(key in fl) || $5 == "open") fl[key] = $5
      if ($5 == "open") openin[$4] = ($4 in openin ? openin[$4] "," : "") $3
      else donein[$4] = ($4 in donein ? donein[$4] "," : "") $3
      next
    }
    $1 == "E" && $4 == "blocked-by" {
      row = $2; closed = $3; target = $5; id = target; home = ""
      if (index(target, ":")) {
        home = substr(target, 1, index(target, ":") - 1); id = substr(target, index(target, ":") + 1)
        if (list && home == self) home = ""
      }
      if (home != "") {
        if (fresh && !(home in covered)) {
          verdict = "unknown"; why = "names home " home ", which the fleet list from " when " does not cover"
        } else if (fl[home SUBSEP id] == "open") {
          verdict = "blocked"; why = "open in " home " per fleet list " when
        } else if (!fresh) {
          verdict = "unknown"; why = "names home " home "; " gap
        } else if (fl[home SUBSEP id] != "") {
          verdict = "satisfied"; why = (fl[home SUBSEP id] == "archive" ? "archive row" : "done row") " in " home " per fleet list " when
        } else {
          verdict = "unknown"; why = "no row in " home " per fleet list " when
        }
      } else if (id in open) {
        verdict = "blocked"; why = "open row" (id in openin ? "; also open in " openin[id] " per fleet list " when : "")
      } else if (id in openin) {
        verdict = "blocked"; why = "open in " openin[id] " per fleet list " when
      } else if (!list) {
        verdict = "unknown"; why = gap
      } else if (!(id in listedid)) {
        verdict = "unknown"; why = "id " id " absent from fleet list " when
        if (!fresh) why = why "; " gap
      } else if (id in done) {
        verdict = "satisfied"; why = done[id]
      } else if (mark[row SUBSEP target] != "") {
        verdict = "satisfied"; why = mark[row SUBSEP target]
      } else {
        verdict = "unknown"; why = "no row in this home backlog or archive and no recorded mark"
        if (id in donein) why = why "; done in " donein[id] " per fleet list " when " (an edge on it is written <home>:" id ")"
      }
      print row "\t" closed "\t" target "\t" verdict "\t" why
    }'
}

# fm_blocked_by_filter_ready <verdicts> [<fleet-note>]: filter `tasks-axi ready`
# output on stdin. A ready row with any open edge whose verdict is not satisfied
# moves to a ready_withheld[N]{id,target,verdict,evidence} group printed right
# after the ready rows, one line per such edge; count: and ready[N] are rewritten
# to the rows that remain, and every other line passes through unchanged. When
# the home has an edge on an open row and fm_blocked_by_fleet_note printed a
# note, a `blocked_by_fleet_list: "<note>"` line follows the ready rows too.
fm_blocked_by_filter_ready() {
  local verdicts=$1 note=${2:-}
  awk -F '\t' -v verdicts="$verdicts" -v note="$note" '
    BEGIN {
      n = split(verdicts, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (split(lines[i], f, "\t") >= 5 && f[2] == "0") edged = 1
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
          if (edged && note != "") print "blocked_by_fleet_list: \"" note "\""
          i = stop - 1
          continue
        }
        print line[i]
      }
    }'
}
