#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block and of
# the named-head reachability gate that accepts a ship `done:` claim.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [branch] [<forge>]
# prints the block on stdout with no trailing blank line. The caller validates the
# mode; an unknown mode is refused rather than silently rendered as the pipeline
# contract.
# The optional third argument is the task's full ship-branch name (a project's
# registered prefix may replace the legacy `fm/` one); it defaults to `fm/<task-id>`
# and is the immutable task branch rendered in every delivery contract.
# Callers of the gate are bin/fm-crew-state.sh (current-state done),
# bin/fm-pr-check.sh (PR registration), and bin/fm-inactive-reconcile.sh
# (secondmate ledger-first publish of a child done). A ship `done:` is not
# accepted while the named head exists only in the worker's disposable copy.
# The check tests that head, not whether some branch moved. In no-mistakes
# mode the pre-validation `done: {summary}` is the pipeline handoff and is
# not gated; only the later CI-ready `done: PR <url> checks green` is, or on a
# Gerrit project the later `done: PR <change url> published for review`. The
# named head is the worker copy's HEAD, except that a done naming the task's
# recorded pr= passes when the forge holds that head: a forge-reported
# pr_head= in no-mistakes mode, or a recorded merge
# (state/<id>.pr-poll-merge-notified). A push to Gerrit's refs/for/ leaves no
# ref a fetch can see, so a done naming a Gerrit change skips the remote-tracking
# reachability test entirely: it passes when that change is already the task's
# recorded pr=, which bin/fm-pr-check.sh writes only after this gate accepted it
# at arming, and otherwise only when a live read shows the change's current
# patch set carrying the worker copy's HEAD tree. A published-for-review report
# whose URL is not a canonical Gerrit change is refused outright. A squash is a new commit on the
# server's base, so the tree rather than the commit is what names the published
# content. In no-mistakes mode that live read is preceded by
# fm_dod_nm_custody_returned: a copy that publishes before recovering the
# pipeline's fix commits agrees with its own unfixed patch set, so the copy must
# also hold the result of a passed run. These live reads are the one check at the ready
# decision; a later rebase or patch set on the server does not revoke an armed
# task's done. Teardown's landed-work test remains the complete discard gate.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against; a forge=gerrit block
# appends " forge=gerrit shape=squash" to that line. The "Ship branch: <branch>"
# line under it is machine-readable the same way: bin/fm-spawn.sh refuses a ship
# whose spawn-selected branch disagrees with it.
# forge is none|gerrit and defaults to none; bin/fm-project-mode.sh's header owns
# what the registry binding means, and this file owns what gerrit changes for a
# WORKER (docs/gerrit-forge-integration.md is the design). A forge composes with
# the two modes that publish and is refused on local-only, which publishes
# nothing. On gerrit the worker publishes one squashed change with
# `gerrit-axi publish --squash` instead of opening a pull request: direct-PR does
# that straight away, and no-mistakes first runs the pipeline with its three
# forge-facing steps skipped and recovers the pipeline's own fix commits into its
# branch, because a passed run whose fixes stayed in the gate looks exactly like
# one whose fixes arrived and publishing it ships the unfixed code. Either mode's
# ready report is `done: PR <change url> published for review`; under
# no-mistakes a `note:` line listing each pipeline finding and its fix comes
# first, because the squash's description never shows the fix commits. A stack of
# changes is refused until it can be watched by its membership pinned when its
# watch is armed, because the merge poll watches one change. No contract here
# lets a worker submit, vote on, or abandon a change.
# The two PR-based blocks require a non-draft pull request before the done
# report, read back from the forge; a lane that deliberately holds a draft
# declares a paused wait instead. bin/fm-pr-check.sh refuses to arm merge
# monitoring on a draft through the same reading bin/fm-pr-merge.sh uses.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# That selector skips fenced blocks and indented examples like the heading
# reader, so a quoted `Captain:` sample is never authorized intent.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# This file also renders and validates the task preparation record that
# bin/fm-brief.sh --prep scaffolds and bin/fm-spawn.sh gates a ship launch on.
# The canonical section list lives here once so the writer and the validator
# cannot drift; bin/fm-brief.sh's header owns the prose contract for the record.
# A V4 destination (UI wiring yes, and the reason names V4 as its own token)
# additionally owes the traveling-layer answer schema in section 3 and the kit
# side-by-side demo receipt in section 10; fm_prep_unfilled_reason is the one
# gate. A deferred-to id is proven against the dispatching home's backlog only
# when the caller passes that data directory (bin/fm-spawn.sh); discovery and
# install keep syntax-only checks.
# fm_nav_prep_filled_source owns discovery of a filled secondmate
# data/nav-preps/<task-id>.md; bin/fm-prep-install.sh installs it, and a ship
# spawn names that path when this home's data/<task-id>/prep.md is missing or
# unfilled. The install helper's header owns flags and overwrite rules.
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.
# It takes the same optional trailing forge argument, because the rule that keeps
# a worker off a remote is exactly the rule that changes when the forge does.
# fm_brief_advisor_line owns the exact legacy line that bin/fm-spawn.sh strips
# from source briefs and conditionally emits for eligible workers.

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-brief-heading-lib.sh"

fm_brief_worker_role() {  # <state-dir> <task-id>
  local state=$1 task_id=$2
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
}

fm_brief_advisor_line() {
  cat <<'EOF'
Call your built-in Opus advisor tool at every design fork, before each commit, and before answering a validation gate or writing `needs-decision`.
EOF
}

# Closed-set gate shared by every forge-aware renderer and bin/fm-brief.sh, so a
# caller cannot reach a half-rendered contract. local-only is refused rather than
# rendered with an inert annotation: it publishes nothing, and its landing
# fast-forwards local main with content the review server has never seen.
fm_forge_valid_for_mode() {  # <forge> <mode> <caller>
  local forge=$1 mode=$2 caller=$3
  case "$forge" in
    none|gerrit) ;;
    *)
      echo "error: $caller: unknown forge '$forge' (expected none or gerrit)" >&2
      return 1 ;;
  esac
  if [ "$forge" != none ] && [ "$mode" = local-only ]; then
    echo "error: $caller: forge=$forge cannot ship mode=local-only - that mode publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; ship no-mistakes or direct-PR, which publish through the forge" >&2
    return 1
  fi
  return 0
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id> [branch] [<forge>]
  local mode=$1 id=$2 forge=${4:-none}
  local branch=${3:-fm/$id}
  fm_forge_valid_for_mode "$forge" "$mode" fm_ship_rule_one || return 1
  if [ "$forge" = gerrit ]; then
    printf '%s\n' "1. Never push with git and never create a change except through the one \`gerrit-axi publish --squash\` your Definition of done names. Never run \`gerrit-axi submit\`, never vote or review a change by any path, including \`gerrit review\` or a label option on a push, and never abandon one: a human reviewer approves and submits it on the server."
    return 0
  fi
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to the default branch (push only your \`$branch\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`$branch\` branch; firstmate handles the merge into local \`main\`."
      ;;
    no-mistakes)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Print the words of every provenance-marked line in a legacy `# Task` body.
# The marker is read the way bin/fm-brief-heading-lib.sh reads a heading: a
# line inside a ``` or ~~~ fenced block, or indented four spaces or a tab as an
# indented example, is never a marked line, so a fenced `Captain:` sample cannot
# pass the provenance gate as the ship contract's intent (issue 3608).
fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    {
      scan = $0
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      if (marker_len >= 3) {
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && substr(scan, marker_len + 1) ~ /^[[:space:]]*$/) {
          fenced = 0
        }
        next
      }
      if (fenced || substr(scan, 1, 1) ~ /^[ \t]$/) next
      if (match(scan, /^(\[captain\]|Captain('\''s (words|ask|intent))?:)[[:space:]]*/)) {
        words = substr(scan, RLENGTH + 1)
        if (words ~ /[^[:space:]]/) print words
      }
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# Task preparation record (bin/fm-brief.sh --prep). This file renders the
# template and validates a filled one; bin/fm-brief.sh's header owns the prose
# contract for what belongs in each section, and bin/fm-spawn.sh refuses a ship
# launch whose record is missing or unanswered.
#
# The record is TIERED, never flat, so preparation costs what the change is
# worth. Its `## Tier` header answers two yes-or-no questions and those answers
# alone decide which sections are required:
#   Q1 yes                  -> tier 2, every section (an `n/a: <reason>` answer
#                              still settles one that does not apply)
#   Q1 no and Q2 yes        -> tier 1, sections 1, 4, 6, 8 and 11 only; the rest
#                              may be omitted entirely
#   both no                 -> tier 0, the header IS the whole record
#
# The canonical section list lives here exactly once, with the tier each section
# becomes required at, so the writer and the validator cannot drift: within a
# declared tier, a section the author deleted is as refusable as one left
# unanswered. Each section carries a one-line `<!-- ... -->` guide and a single
# `{PLACEHOLDER}` the author replaces.
FM_PREP_TIER_HEADING='## Tier'
# heading|placeholder|required-from-tier|guide|evidence-tokens
# A row with evidence tokens owes tool output rather than prose: once that
# section is filled it must name one of those tokens, or be answered n/a with a
# reason. Rows without them are prose and are only checked for being answered.
FM_PREP_SECTIONS='## 1. Intent and boxes|INTENT_AND_BOXES|1|The captain'"'"'s words, and each Change box this task discharges, VERIFIED still open against origin/main with the command used.
## 2. Behaviour spec|BEHAVIOUR_SPEC|2|Every state (empty, loading, ready, running, refused, failed, terminal), every control and when it is enabled, every action and its result, the copy the user sees, restart and reopen behaviour.
## 3. UI/UX|UI_UX|2|START WITH THE COMPONENT CHECK: for each screen element this lane touches, name the V4 component or kit piece with its path. For a V4 destination, answer every traveling-layer item (__TRAVELING_LAYERS__) as present, not-applicable-because-<named kit rule>, or deferred-to-<existing task id>; exists, imported unchanged and a bare later are not answers. Then which step or screen, the journey walked as the user step by step, what done looks like on screen, responsiveness and accessibility notes.
## 4. Blast radius|BLAST_RADIUS|1|PASTE TOOL OUTPUT, not prose: the GitNexus impact result (gitnexus impact, or the MCP impact tool, against the ~/.gitnexus clone) for every module touched, and the Serena find_referencing_symbols counts for every symbol whose signature changes; reach for claude-context semantic search only when a name is unknown.|gitnexus serena
## 5. Data and contracts|DATA_AND_CONTRACTS|2|Request and response shapes, versions, migrations.
## 6. Tests|TESTS|1|The red-first list, journey tests, mutation witnesses, existing tests that change and why.
## 7. Records|RECORDS|2|Boxes to tick, verification records, log-book entries. By convention a lane that lands a component ahead of its consumer adds it to the project unwired-export allowlist, and the lane that wires it up removes it again.
## 8. Out of scope and follow-ups|OUT_OF_SCOPE|1|What this task deliberately leaves alone, and the follow-up work it creates.
## 9. Risks, dependencies, merge order|RISKS|2|Risks, dependencies, sibling lanes touching the same files, and the order these must land in.
## 10. Demo receipt plan|DEMO_RECEIPT|2|What the worker walks and records before validation. For a V4 destination the receipt includes the kit screen beside the shipped screen at the same viewport, with Explain on and Explain off.
## 11. Definition of done|DEFINITION_OF_DONE|1|The done criteria, checked line by line against the intent above.
## 12. Size|SIZE|2|Files expected to change; more than about eight files means split the slice.'
# label - traveling-layer roll-call owned here once so the scaffold guide and the
# V4 destination gate cannot drift. Each item is one component-check line.
FM_PREP_TRAVELING_LAYERS='explain
provenance
verdict
pills
gate-bar
readout
legend
meter
switches'

# fm_prep_path <data-dir> <task-id>
fm_prep_path() {
  printf '%s/%s/prep.md\n' "$1" "$2"
}

# fm_nav_prep_path <secondmate-home> <task-id>
fm_nav_prep_path() {
  printf '%s/data/nav-preps/%s.md\n' "$1" "$2"
}

# fm_prep_file_absolute <file>
# Prints the physical path of an existing readable file.
fm_prep_file_absolute() {
  local file=$1 dir base
  dir=$(CDPATH='' cd -- "$(dirname -- "$file")" && pwd -P) || return 1
  base=$(basename -- "$file")
  printf '%s/%s\n' "$dir" "$base"
}

# fm_nav_prep_filled_source <registry> <task-id>
# Prints the first filled nav-prep path: each parseable home= in registry
# order is tried at <home>/data/nav-preps/<task-id>.md. A missing, unreadable,
# or unfilled candidate is skipped. Exit 1 when none pass the prep gate.
fm_nav_prep_filled_source() {
  local registry=$1 id=$2 line home candidate abs seen='|'
  [ -n "$id" ] || return 1
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    home=$SECONDMATE_REGISTRY_HOME
    case "$home" in /*) ;; *) continue ;; esac
    candidate=$(fm_nav_prep_path "$home" "$id")
    [ -f "$candidate" ] && [ -r "$candidate" ] || continue
    abs=$(fm_prep_file_absolute "$candidate") || continue
    case "$seen" in *"|$abs|"*) continue ;; esac
    seen="${seen}${abs}|"
    if fm_prep_unfilled_reason "$candidate" >/dev/null; then
      continue
    fi
    printf '%s\n' "$abs"
    return 0
  done < "$registry"
  return 1
}

# fm_prep_traveling_layer_list
# Comma-separated traveling-layer labels from the one owner string, used by the
# scaffold guide so it cannot drift from the gate.
fm_prep_traveling_layer_list() {
  printf '%s\n' "$FM_PREP_TRAVELING_LAYERS" | awk 'NF { if (n++) printf ", "; printf "%s", $0 }'
}

# fm_prep_template <task-id> - the scaffold written to data/<task-id>/prep.md.
# The tier header comes first, because its three answers decide how much of the
# rest this task owes.
fm_prep_template() {
  local id=$1 heading placeholder tier guide evidence layers
  layers=$(fm_prep_traveling_layer_list)
  printf '# Task prep: %s\n\n' "$id"
  printf '%s\n' "$FM_PREP_TIER_HEADING"
  printf '<!-- Answer all three. UI wiring yes, or Q1 yes: tier 2, every section below. Q1 no, Q2 yes: tier 1, sections 1, 4, 6, 8 and 11 only - delete the rest. All no: tier 0, this header is the whole record - delete every section. -->\n'
  printf -- '- Q1 does this change alter what a user sees or can do: {Q1}\n'
  printf -- '- Q2 does this change touch a shared module, a contract, or more than about eight files: {Q2}\n'
  printf -- '- UI wiring: {UI_WIRING}\n'
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal template text
  printf '<!-- UI wiring answers `yes, <the V4 step and control the user meets>` or `no, <why the user never meets this change>`. A V4 destination answers yes and names that V4 step. A change that lets a user configure or choose something is always yes, and a yes is tier 2 whatever Q1 and Q2 say. -->\n'
  printf '\n'
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal template text
  printf 'Answer every section your tier requires. One that genuinely does not apply is answered `n/a: <one-line reason>`.\n'
  printf 'This record is the specification beneath the brief: sections 2 and 11 are the acceptance criteria the reviewer holds the work to.\n'
  while IFS='|' read -r heading placeholder tier guide evidence; do
    [ -n "$heading" ] || continue
    guide=${guide/__TRAVELING_LAYERS__/$layers}
    printf '\n%s\n<!-- tier %s+. %s -->\n{%s}\n' "$heading" "$tier" "$guide" "$placeholder"
  done <<EOF
$FM_PREP_SECTIONS
EOF
}

# fm_prep_ui_wiring_line <file> - raw text after the tier header's UI wiring
# label, including leading space. Empty when the line is missing.
fm_prep_ui_wiring_line() {  # <file>
  fm_brief_heading_body "$1" "$FM_PREP_TIER_HEADING" | awk '
    index($0, "- UI wiring:") == 1 { print substr($0, length("- UI wiring:") + 1); exit }
  '
}

# fm_prep_answer <file> <Qn> - the yes/no answer recorded in the tier header, or
# empty when the question is unanswered, left placeheld, or not yes/no. The
# answer is whatever follows the final colon on that question's line.
fm_prep_answer() {  # <file> <Q1|Q2>
  local file=$1 question=$2 answer
  answer=$(fm_brief_heading_body "$file" "$FM_PREP_TIER_HEADING" | awk -v q="$question" '
    index($0, "- " q " ") == 1 {
      pos = 0
      for (i = length($0); i > 0; i--) { if (substr($0, i, 1) == ":") { pos = i; break } }
      if (pos == 0) next
      print substr($0, pos + 1)
      exit
    }
  ' | tr -d '[:space:].' | tr '[:upper:]' '[:lower:]')
  case "$answer" in
    yes|no) printf '%s\n' "$answer" ;;
    *) printf '\n' ;;
  esac
}

# fm_prep_ui_wiring <file> - yes or no when the tier header's UI wiring line
# answers in its required "<yes|no>, <reason>" form, empty otherwise. The reason
# is mandatory in both directions: a yes has to name the step and control the
# user meets, and a no has to say why the user never meets the change, so the
# answer cannot be given without looking at the interface.
fm_prep_ui_wiring() {  # <file>
  local file=$1 line verdict reason
  line=$(fm_prep_ui_wiring_line "$file")
  verdict=$(printf '%s' "$line" | sed 's/,.*//' | tr -d '[:space:].' | tr '[:upper:]' '[:lower:]')
  reason=$(printf '%s' "$line" | sed 's/^[^,]*,*//' | tr -d '[:space:].')
  case "$verdict" in
    yes|no) ;;
    *) printf '\n'; return 0 ;;
  esac
  [ -n "$reason" ] || { printf '\n'; return 0; }
  printf '%s\n' "$verdict"
}

# fm_prep_kit_destination <file>
# True when this record is a V4 destination: UI wiring answers yes, and the
# reason names V4 as its own token. Non-screen and non-V4 records are untouched.
# Matching uses the unsquashed reason so "the V4 Profiles step" counts and
# "v4destination" does not.
fm_prep_kit_destination() {  # <file>
  local line reason
  [ "$(fm_prep_ui_wiring "$1")" = yes ] || return 1
  line=$(fm_prep_ui_wiring_line "$1")
  reason=$(printf '%s' "$line" | sed 's/^[^,]*,[[:space:]]*//')
  printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | grep -Eq '(^|[^a-z0-9])v4([^a-z0-9]|$)'
}

# fm_prep_section_body <file> <heading>
# Comment-stripped section body. Reuses the same single-line comment strip as
# fm_prep_section_state so a guide cannot satisfy a later check by itself.
fm_prep_section_body() {  # <file> <heading>
  fm_brief_heading_body "$1" "$2" | sed 's/<!--.*-->//'
}

# fm_prep_n_a_answer <body>
# True when the section's first non-empty line is an n/a decision with a reason.
# Later n/a notes (accessibility, a sub-control) do not turn a filled roll-call
# into a whole-section dismissal.
fm_prep_n_a_answer() {  # <body>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*$/ { next }
    { print; exit }
  ' | tr '[:upper:]' '[:lower:]' | grep -q '^[[:space:]]*n/a:[[:space:]]*[^[:space:]]'
}

# fm_prep_traveling_verdict <body> <label>
# Prints the first token after `<label>:` on a component-check line, or empty
# when that label is absent.
fm_prep_traveling_verdict() {  # <body> <label>
  printf '%s\n' "$1" | awk -v label="$2" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/^[-*][[:space:]]+/, "", line)
      prefix = tolower(label) ":"
      if (index(tolower(line), prefix) != 1) next
      rest = substr(line, length(prefix) + 1)
      sub(/^[[:space:]]+/, "", rest)
      if (rest == "") exit
      split(rest, tok, /[[:space:]]+/)
      gsub(/[.,;:)]+$/, "", tok[1])
      verdict = tok[1]
      if (match(tolower(verdict), /^deferred-to-/)) verdict = "deferred-to-" substr(verdict, RLENGTH + 1)
      else verdict = tolower(verdict)
      print verdict
      exit
    }
  '
}

# fm_prep_traveling_id <verdict>
# Prints the task id in a deferred-to-<id> verdict, or empty.
fm_prep_traveling_id() {  # <verdict>
  local verdict=$1
  case "$verdict" in
    deferred-to-?*) printf '%s\n' "${verdict#deferred-to-}" ;;
  esac
}

# fm_prep_demo_receipt_ok <body>
# True when a V4 destination demo-receipt body plants the kit side-by-side
# phrases the scaffold asks for. Proves the author wrote the plan, not that
# the receipt is photographically correct.
fm_prep_demo_receipt_ok() {  # <body>
  local lowered
  lowered=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$lowered" | grep -q 'kit' || return 1
  printf '%s' "$lowered" | grep -Eq 'side-by-side|side by side|beside' || return 1
  printf '%s' "$lowered" | grep -q 'same viewport' || return 1
  printf '%s' "$lowered" | grep -q 'explain on' || return 1
  printf '%s' "$lowered" | grep -q 'explain off' || return 1
  return 0
}

# fm_prep_tier <file> - the declared tier (0, 1 or 2), or empty when the header
# is missing or any of its three answers is malformed. A UI wiring yes is tier 2
# whatever Q1 and Q2 say, because a change the user meets owes its behaviour and
# its interface in writing. Never guesses a tier: an unreadable header is a
# refusal, not a default.
fm_prep_tier() {  # <file>
  local file=$1 q1 q2 ui
  fm_brief_heading_present "$file" "$FM_PREP_TIER_HEADING" || { printf '\n'; return 0; }
  q1=$(fm_prep_answer "$file" Q1)
  q2=$(fm_prep_answer "$file" Q2)
  ui=$(fm_prep_ui_wiring "$file")
  if [ -z "$q1" ] || [ -z "$q2" ] || [ -z "$ui" ]; then printf '\n'; return 0; fi
  if [ "$ui" = yes ] || [ "$q1" = yes ]; then printf '2\n'
  elif [ "$q2" = yes ]; then printf '1\n'
  else printf '0\n'
  fi
}

# fm_prep_section_state <file> <heading> <placeholder>
# Prints missing|unfilled|empty|filled for one section. Guide comments and blank
# lines never count as an answer; an exact leftover placeholder is unfilled.
# Matching stays per-section and exact, so a filled section that quotes a
# placeholder token as example text is still accepted.
fm_prep_section_state() {  # <file> <heading> <placeholder>
  local file=$1 heading=$2 placeholder=$3 body stripped
  fm_brief_heading_present "$file" "$heading" || { printf 'missing\n'; return 0; }
  body=$(fm_brief_heading_body "$file" "$heading" | sed 's/<!--.*-->//')
  stripped=$(printf '%s' "$body" | tr -d '[:space:]')
  if [ -z "$stripped" ]; then
    printf 'empty\n'
  elif [ "$stripped" = "{$placeholder}" ]; then
    printf 'unfilled\n'
  else
    printf 'filled\n'
  fi
}

# fm_prep_evidence_ok <file> <heading> <token>...
# True when a filled section that owes tool output carries it: its body names one
# of the tool tokens, or answers `n/a: <reason>`. Deliberately the cheapest check
# that can tell evidence from prose - it reads what tool was run, never whether
# the output is right.
fm_prep_evidence_ok() {  # <file> <heading> <token>...
  local file=$1 heading=$2 body lowered token
  shift 2
  body=$(fm_brief_heading_body "$file" "$heading" | sed 's/<!--.*-->//')
  lowered=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')
  # `n/a: <reason>` is a decision already taken, so it needs no tool output.
  printf '%s' "$lowered" | grep -q 'n/a:[[:space:]]*[^[:space:]]' && return 0
  for token in "$@"; do
    case "$lowered" in *"$token"*) return 0 ;; esac
  done
  return 1
}

# fm_prep_unfilled_reason <file> [<resolved-data-dir>]
# Prints the first refusal reason and exits 0; exits 1 when the record answers
# everything its declared tier requires. A missing file and an unreadable tier
# header are refusals of their own; a section below the declared tier is not
# checked at all, so omitting it entirely is legitimate rather than a hole.
# The optional data directory is the dispatching home's data dir; when a V4
# destination defers a traveling-layer item, that id is proven there with
# fm_backlog_row_probe. Discovery and install omit it and check syntax only.
# Passing a data directory without sourcing the backlog stack is a programming
# error, not a skip.
fm_prep_unfilled_reason() {  # <file> [<resolved-data-dir>]
  local file=$1 data_dir=${2-} tier heading placeholder required guide evidence state
  local body label verdict deferred_ids deferred_id rest
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'no preparation record at %s\n' "$file"
    return 0
  fi
  if ! fm_brief_heading_present "$file" "$FM_PREP_TIER_HEADING"; then
    printf 'its %s header is missing from %s\n' "$FM_PREP_TIER_HEADING" "$file"
    return 0
  fi
  if [ -z "$(fm_prep_ui_wiring "$file")" ]; then
    # shellcheck disable=SC2016 # single quotes are deliberate: the answer format is literal
    printf 'its %s header does not answer `UI wiring: yes, <the step and control the user meets>` or `UI wiring: no, <why the user never meets this change>` in %s\n' \
      "$FM_PREP_TIER_HEADING" "$file"
    return 0
  fi
  tier=$(fm_prep_tier "$file")
  if [ -z "$tier" ]; then
    printf 'its %s header does not answer both Q1 and Q2 yes or no in %s\n' \
      "$FM_PREP_TIER_HEADING" "$file"
    return 0
  fi
  [ "$tier" != 0 ] || return 1
  while IFS='|' read -r heading placeholder required guide evidence; do
    [ -n "$heading" ] || continue
    [ "$required" -le "$tier" ] || continue
    state=$(fm_prep_section_state "$file" "$heading" "$placeholder")
    case "$state" in
      missing) printf 'tier %s requires %s, which is missing from %s\n' "$tier" "$heading" "$file"; return 0 ;;
      unfilled) printf 'tier %s requires %s, which still carries its {%s} placeholder in %s\n' "$tier" "$heading" "$placeholder" "$file"; return 0 ;;
      empty) printf 'tier %s requires %s, which is empty in %s\n' "$tier" "$heading" "$file"; return 0 ;;
    esac
    [ -n "$evidence" ] || continue
    # shellcheck disable=SC2086 # the token list is deliberately word-split
    if ! fm_prep_evidence_ok "$file" "$heading" $evidence; then
      # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal answer text
      printf 'tier %s requires %s to paste the tool output behind it, naming %s, or to answer `n/a: <reason>`, in %s\n' \
        "$tier" "$heading" "$(printf '%s' "$evidence" | sed 's/ / or /g')" "$file"
      return 0
    fi
  done <<EOF
$FM_PREP_SECTIONS
EOF
  fm_prep_kit_destination "$file" || return 1
  body=$(fm_prep_section_body "$file" '## 3. UI/UX')
  if fm_prep_n_a_answer "$body"; then
    printf 'a V4 destination cannot answer %s with n/a in %s\n' '## 3. UI/UX' "$file"
    return 0
  fi
  deferred_ids='|'
  while IFS= read -r label || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    verdict=$(fm_prep_traveling_verdict "$body" "$label")
    if [ -z "$verdict" ]; then
      printf 'a V4 destination requires traveling-layer item %s in %s answered present, not-applicable-because-<named kit rule>, or deferred-to-<existing task id> in %s\n' \
        "$label" '## 3. UI/UX' "$file"
      return 0
    fi
    case "$verdict" in
      present) ;;
      not-applicable-because-?*) ;;
      deferred-to-?*)
        deferred_id=$(fm_prep_traveling_id "$verdict")
        case "$deferred_ids" in
          *"|$deferred_id|"*) ;;
          *) deferred_ids="${deferred_ids}${deferred_id}|" ;;
        esac
        ;;
      *)
        printf 'a V4 destination traveling-layer item %s answers %s in %s; only present, not-applicable-because-<named kit rule>, or deferred-to-<existing task id> are accepted\n' \
          "$label" "$verdict" "$file"
        return 0
        ;;
    esac
  done <<EOF
$FM_PREP_TRAVELING_LAYERS
EOF
  if [ -n "$data_dir" ] && [ "$deferred_ids" != '|' ]; then
    if ! type fm_backlog_row_probe >/dev/null 2>&1; then
      printf 'a V4 destination deferred-to id cannot be checked because fm_backlog_row_probe is not loaded\n'
      return 0
    fi
    rest=${deferred_ids#|}
    while [ -n "$rest" ]; do
      deferred_id=${rest%%|*}
      rest=${rest#*|}
      [ -n "$deferred_id" ] || continue
      if fm_backlog_row_probe "$data_dir" "$deferred_id"; then
        continue
      fi
      if [ "${FM_BACKLOG_ROW_RESULT:-}" = not_found ]; then
        printf 'a V4 destination defers a traveling-layer item to %s, which is absent from this home'\''s backlog\n' \
          "$deferred_id"
        return 0
      fi
      printf 'a V4 destination deferred-to id %s could not be read from this home'\''s backlog (%s)\n' \
        "$deferred_id" "${FM_BACKLOG_ROW_ERROR:-unreadable}"
      return 0
    done
  fi
  body=$(fm_prep_section_body "$file" '## 10. Demo receipt plan')
  if fm_prep_n_a_answer "$body"; then
    printf 'a V4 destination cannot answer %s with n/a in %s\n' '## 10. Demo receipt plan' "$file"
    return 0
  fi
  if ! fm_prep_demo_receipt_ok "$body"; then
    printf 'a V4 destination %s must include the kit screen beside the shipped screen at the same viewport, with Explain on and Explain off, in %s\n' \
      '## 10. Demo receipt plan' "$file"
    return 0
  fi
  return 1
}

# fm_brief_prep_overlay <prep-path> - launch-brief section pointing the worker
# at the preparation record as the specification beneath the brief.
fm_brief_prep_overlay() {  # <prep-path>
  printf '\n# Task preparation record\n'
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal brief text
  printf 'This task has a preparation record at `%s`.\n' "$1"
  cat <<'EOF'
Read it in full before you plan or write anything: it is the specification beneath this brief, and it supersedes your own reconstruction of what the change should do.
Its `## Tier` header decides how much the record says; a section it does not carry was ruled out there, not forgotten.
Where the record carries `## 2. Behaviour spec` and `## 11. Definition of done`, those are the acceptance criteria the reviewer will hold this work to, alongside `## Captain's intent` above.
A section answered `n/a: <reason>` is a decision already taken, not an invitation to fill the gap yourself.
If the record is wrong or incomplete for what you find in the code, say so through the status file rather than silently building something else.
EOF
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

# The `nm-<run>-<step>` decision key this block mandates is load-bearing beyond
# the brief itself: the watcher binds an open `needs-decision` to the run a
# crew's current state reports by matching exactly that shape
# (wedge_wait_evidence in bin/fm-watch.sh, through
# status_has_open_needs_decision in bin/fm-classify-lib.sh), which is what buys
# a lane parked at a human-owed gate the long recheck cadence instead of a
# wedge escalation. A gate escalated under any other key still reads as a
# suspected wedge.
fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# The forge-independent middle of the no-mistakes contract: how a worker drives
# the pipeline, what `--intent` may carry, and the two firstmate-specific rules.
# Written once; only the two sentences about a green PR depend on the forge,
# because on gerrit the ci step is skipped and there is no PR to report.
fm_nm_driving_block() {  # <forge>
  local pr_return_line='' pr_reattach_clause=';'
  if [ "$1" != gerrit ]; then
    pr_return_line="Only a drive call's return reports the green PR: \`no-mistakes axi status\` shows progress but never reports \`checks-passed\` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
"
    pr_reattach_clause="; once checks are green it returns \`checks-passed\` immediately, and"
  fi
  cat <<EOF
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
${pr_return_line}Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running \`no-mistakes axi run\` without flags, backgrounded the same way${pr_reattach_clause} if it refuses because no run is active, read the finished outcome from \`no-mistakes axi status\`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
}

# How a worker on a forge=gerrit project publishes, shared by both publishing
# modes so the one push, the Change-Id rule, and the ready report are written
# once. gerrit-axi owns the squash mechanics; this names the one call and what
# to read back from it.
fm_gerrit_publish_block() {
  cat <<EOF
Publish from this copy with \`gerrit-axi\`, never with \`git push\`:
1. Run \`git fetch origin\` so the server's branch tip is in this repository; \`gerrit-axi\` reads its base off the server and refuses when that tip is not here.
2. Run \`gerrit-axi publish --squash --json\`, adding \`--branch <b>\` only when the task names a target branch other than the server's default.
   It is one push to \`refs/for/<branch>\` that turns every commit since your branch left the server's branch into ONE change carrying the oldest commit's message, so that message is the review description: make it the one you want reviewed.
   It keeps any \`Change-Id\` a commit already carries and stamps one into the oldest commit when it has none, rewriting your local branch's messages only.
   Never edit, remove, or regenerate a \`Change-Id\`: a different one creates a different change and orphans the first one's review, while the same one adds a patch set to it.
   Never pass \`--stack\`: a stack of changes is not published from this fleet until it can be watched by its membership pinned when its watch is armed, and the watch follows exactly one change.
3. Read the record it prints: \`ok\` must be \`true\`, and the one row of its \`changes\` table is your change. Its \`url\` is the change URL; when \`url\` is null, write \`https://<host>/c/<project>/+/<change>\` from your \`origin\` remote's host and that row's \`project\` and \`change\`.
   A failure prints a typed error record instead; fix what it names and publish again, which updates the same change rather than creating another.
Then append \`done [at=<epoch>]: PR {change url} published for review\` to the status file and stop. You are finished.
That \`done:\` is accepted only when the change's current patch set on the server carries this copy's HEAD tree, so commit nothing after publishing; if you must change the work, commit it and publish again before reporting done.
A \`done:\` whose URL is not the canonical \`https://<host>/c/<project>/+/<number>\` change URL is refused.
There is no pull request, no \`gh-axi\` call, and no forge CI result to report: a human reviewer approves and submits the change on the server, and firstmate relays that outcome.
EOF
}

fm_dod_block() {  # <mode> <task-id> [branch] [<forge>]
  local mode=$1 id=$2 forge=${4:-none}
  local branch=${3:-fm/$id}
  fm_forge_valid_for_mode "$forge" "$mode" fm_dod_block || return 1
  case "$mode:$forge" in
    direct-PR:gerrit)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR forge=gerrit shape=squash
Ship branch: $branch
This task ships **direct-PR** to a Gerrit review server: you publish the change yourself, without the no-mistakes pipeline.
Gerrit has no pull requests, so there is nothing to open; publishing creates the change.
The task is complete only when committed on your branch.
When it is implemented and committed, publish it.
EOF
      fm_gerrit_publish_block
      cat <<EOF
Do NOT run /no-mistakes.
EOF
      ;;
    no-mistakes:gerrit)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes forge=gerrit shape=squash
Ship branch: $branch
This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so **no-mistakes runs here as a review pass that ends at a ready branch**, and you then publish that branch as one change.
Pass \`--skip push,pr,ci\` on every \`no-mistakes axi run\` for this task, and skip nothing else: \`review\`, \`test\`, \`document\`, and \`lint\` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.
The task is complete only when committed on your branch.
When you believe it is complete, append \`done [at=<epoch>]: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate.
That first \`done:\` is the handoff that starts the pipeline; it is not a request to publish.

EOF
      fm_nm_driving_block "$forge"
      cat <<EOF

Because \`push\` is skipped, the pipeline's fixes DO NOT arrive in your checkout: each fix round commits onto a branch inside no-mistakes' own local gate repository, and with no push nothing carries those commits back to you.
Your tree never goes dirty and nothing interrupts you, so a passed run whose fixes are still in the gate looks exactly like a passed run whose fixes you already have.
You may not publish until you have closed that gap:
1. After the run reaches its outcome, read \`branch_sync.next_action\` from \`no-mistakes axi status\`.
2. When its code is \`recover_custody\`, run the exact command that status prints - \`no-mistakes axi sync --recover\` - and confirm \`branch_sync.state\` comes back \`custody_returned\` on a clean tree. The printed command is authoritative if it differs. The \`run_pipeline\` next action status reports after recovery is not an instruction to run again: the recovered head is the one the passed run validated, so publish it.
3. Confirm with \`git log\` that \`$branch\` now carries every fix commit the run made, whether or not step 2 was needed.
An unrecovered fix round is an unfinished task, never housekeeping: publishing without it is how the UNFIXED code reaches review.
Your ready report is refused while the run still holds your branch, while its outcome is missing or not passing, or while your HEAD's tree differs from the run's result.

When the run's outcome is passed, passed-with-skips, or passed-with-override and step 3 holds, publish.
The squashed change carries only the oldest commit's message, so the pipeline's own fix commits never reach the reviewer's description; your report is how they reach the captain.
After publishing and immediately before your ready report, append one line \`note [at=<epoch>]: pipeline changes: {finding} - {fix it made}; {finding} - {fix it made}\` to the status file, one short clause per finding the run fixed, taken from the run's \`fixes\` table and the gate findings its drive calls returned (\`no-mistakes axi logs --step <step> --full\` has the detail); write \`note [at=<epoch>]: pipeline changes: none\` when it fixed nothing.
EOF
      fm_gerrit_publish_block
      ;;
    direct-PR:*)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
Ship branch: $branch
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\` that is ready for review, not a draft.
Before you report done, read the PR back from the forge and confirm it is not a draft (\`gh pr view <url> --json isDraft\` must print false); if it is a draft, mark it ready with \`gh-axi pr ready\`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append \`done [at=<epoch>]: PR {url}\` to the status file and stop.
That \`done:\` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append \`paused [at=<epoch>]: {why the draft is held}\` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only:*)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
Ship branch: $branch
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`$branch\`. Do NOT push, do NOT open a PR, do NOT merge.
A \`done:\` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done [at=<epoch>]: ready in branch $branch\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes:*)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: $branch
The task is complete only when committed on your branch.
When you believe it is complete, append \`done [at=<epoch>]: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
That first \`done:\` is the handoff that starts the pipeline, which owns the push; it is not a request to push from this copy.

EOF
      fm_nm_driving_block "$forge"
      cat <<EOF

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (\`gh pr view <url> --json isDraft\` must print false); if it is a draft, mark it ready with \`gh-axi pr ready\`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append \`done [at=<epoch>]: PR {url} checks green\` and stop. You are finished.
That CI-ready \`done:\` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append \`paused [at=<epoch>]: {why the draft is held}\` instead of done.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}

# 0 when <sha> is contained in a ref under <namespace> in <repo>.
# --contains tests that exact commit, so a branch that moved to a different
# tip does not count.
fm_dod_ref_contains() {  # <repo> <ref-namespace> <sha>
  local repo=$1 ns=$2 sha=$3 hit
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  [ -n "$sha" ] || return 1
  hit=$(git -C "$repo" for-each-ref --format='%(refname)' --contains="$sha" --count=1 "$ns" 2>/dev/null) || return 1
  [ -n "$hit" ]
}

# 0 when a done: note reports the no-mistakes CI-ready PR (`PR <url> checks
# green`, with any surrounding text). bin/fm-crew-state.sh takes its CI-ready
# path on this same test, so every CI-ready line it acts on is gated.
fm_dod_note_reports_ci_ready() {  # <note>
  case "$1" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
  esac
  return 1
}

# 0 when a done: note reports a change published to a Gerrit review server
# (`PR <change url> published for review`), which is the ready report of both
# publishing modes on that forge.
fm_dod_note_reports_published_change() {  # <note>
  case "$1" in
    *PR*"published for review"*) return 0 ;;
  esac
  return 1
}

# 0 when this ship done: is one the named-head gate must accept or refuse.
# no-mistakes pre-validation done: is the pipeline handoff and is not gated.
# Empty mode is treated as no-mistakes, the unregistered-project default.
fm_dod_should_gate_ship_done() {  # <kind> <mode> <line>
  local note
  [ "$1" = ship ] || return 1
  [ "$(status_line_verb "$3")" = "done" ] || return 1
  note=$(status_line_note "$3")
  case "$2" in
    direct-PR|local-only) return 0 ;;
    no-mistakes|'')
      fm_dod_note_reports_ci_ready "$note" || fm_dod_note_reports_published_change "$note" ;;
    *) return 1 ;;
  esac
}

# The PR/MR URL from a `done: PR <url>...` note, or empty.
fm_dod_pr_url_from_done_note() {  # <note>
  local note=$1 url
  case "$note" in
    PR\ https://*|PR\ http://*) ;;
    *) return 1 ;;
  esac
  url=${note#PR }
  url=${url%% *}
  printf '%s\n' "$url"
}

# The last recorded <key>= value in <meta>, or empty.
fm_dod_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# 0 when the forge's head for a PR is the head the done names. In no-mistakes
# mode the pipeline pushes it, possibly with commits the worker clone never
# fetched. A direct-PR worker pushes from its own copy, so its named head stays
# that copy's HEAD and a later unpushed commit is refused.
fm_dod_forge_head_is_named_head() {  # <mode>
  case "$1" in
    no-mistakes|'') return 0 ;;
  esac
  return 1
}

# 0 when <url> is the task's recorded pr= and the forge holds its head:
# bin/fm-pr-check.sh recorded the forge's pr_head= for it in no-mistakes mode,
# or the merge poll recorded it merged (<state>/<id>.pr-poll-merge-notified,
# bin/fm-pr-lib.sh). That head is stored outside the worker copy even when
# this clone never fetched it or fleet sync pruned its branch after a squash
# merge. A recorded Gerrit change needs neither: its pr= is written only after
# the live published-tree check accepted it.
fm_dod_recorded_pr_on_forge() {  # <state> <id> <meta> <mode> <url>
  local state=$1 id=$2 meta=$3 mode=$4 url=$5
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  [ "$(fm_dod_meta_value "$meta" pr)" = "$url" ] || return 1
  if fm_dod_forge_head_is_named_head "$mode" && [ -n "$(fm_dod_meta_value "$meta" pr_head)" ]; then
    return 0
  fi
  ( fm_pr_url_parse "$url" \
    && { [ "$FM_PR_PROVIDER" = gerrit ] \
      || fm_pr_poll_merge_already_notified "$state" "$id" \
        "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; } )
}

# 0 when <url> names a Gerrit change whose current patch set carries the tree of
# the worktree's HEAD. The revision is read live and bounded, because the server
# is the only place a refs/for/ push leaves it, and it must already be an object
# in the worktree - the publish that made it ran there - so a patch set pushed
# from elsewhere matches only once this copy holds it.
fm_dod_gerrit_change_carries_head() {  # <worktree> <url>
  local wt=$1 url=$2 revision head_tree revision_tree lib
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = gerrit ] || return 1
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  revision=$(fm_run_timed 10 bash -c '
    . "$1"
    fm_pr_gerrit_read_revision "$2" "$3" || exit 1
    printf "%s\n" "$FM_PR_RECORD_REVISION"
  ' _ "$lib" "$FM_PR_HOST" "$FM_PR_NUMBER" 2>/dev/null) || return 1
  fm_pr_head_valid "$revision" || return 1
  head_tree=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || return 1
  revision_tree=$(git -C "$wt" rev-parse --verify --quiet "$revision^{tree}" 2>/dev/null) || return 1
  [ -n "$head_tree" ] && [ "$head_tree" = "$revision_tree" ]
}

# 0 when the worker copy holds the result of its own passed no-mistakes run:
# the run's outcome is passed, passed-with-skips or passed-with-override (the
# passing set bin/fm-crew-state.sh reads), that pipeline owns no unreturned work (branch_sync.next_action.code is neither
# recover_custody nor continue_active_run) and HEAD's tree equals the tree of the
# pipeline's current head resolved in this copy. On a Gerrit project push is
# skipped, so a fix round's commits stay in the gate until custody is recovered,
# and a copy that publishes before recovering has a server patch set that agrees
# with its own unfixed HEAD - the published-tree check alone accepts it. Trees
# are compared rather than ancestry because the publish stamps a Change-Id and
# rewrites the branch's messages. An unreadable status refuses, as an unreadable
# change does. 1 when refused; stdout then holds a one-line reason.
fm_dod_nm_custody_returned() {  # <worktree>
  local wt=$1 out outcome code pipeline_head head_tree pipeline_tree
  if ! out=$(fm_nm_run_checked "$wt" 15 axi status) || ! printf '%s\n' "$out" | grep -q '^run:'; then
    printf '%s\n' "the no-mistakes run for this copy could not be read, so its fixes cannot be proven recovered"
    return 1
  fi
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    passed|passed-with-skips|passed-with-override) ;;
    *)
      printf '%s\n' "the no-mistakes run for this copy has outcome ${outcome:-(none)}, not a pass, so the published work is not validated"
      return 1 ;;
  esac
  code=$(fm_nm_branch_sync_nested "$out" next_action code)
  case "$code" in
    recover_custody|continue_active_run)
      printf '%s\n' "the no-mistakes run still holds this copy's branch (next action $code), so its fixes are not recovered into the published work"
      return 1 ;;
  esac
  pipeline_head=$(fm_nm_branch_sync_nested "$out" pipeline current_head)
  [ -n "$pipeline_head" ] || pipeline_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)")
  head_tree=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || head_tree=
  pipeline_tree=
  if fm_pr_head_valid "$pipeline_head"; then
    pipeline_tree=$(git -C "$wt" rev-parse --verify --quiet "$pipeline_head^{tree}" 2>/dev/null) || pipeline_tree=
  fi
  if [ -z "$head_tree" ] || [ -z "$pipeline_tree" ] || [ "$head_tree" != "$pipeline_tree" ]; then
    printf '%s\n' "this copy's HEAD does not carry the no-mistakes run's result ${pipeline_head:-(unknown head)}, so the pipeline's fixes are not in the published work"
    return 1
  fi
  return 0
}

# 0 when <sha> is reachable from a ref that survives the disposable worktree:
# any remote-tracking ref, or - for local-only - heads in the project clone.
fm_dod_named_head_reachable_outside_worktree() {  # <worktree> <project> <mode> <sha>
  local wt=$1 project=$2 mode=$3 sha=$4
  fm_dod_ref_contains "$wt" refs/remotes "$sha" && return 0
  fm_dod_ref_contains "$project" refs/remotes "$sha" && return 0
  [ "$mode" = local-only ] && fm_dod_ref_contains "$project" refs/heads "$sha"
}

# 0 when <line> is not a ship done: to gate, when it names the task's recorded
# PR whose head the forge holds, when it names a Gerrit change whose current
# patch set carries the worker copy's HEAD tree, or otherwise when its named
# head - the worker copy's HEAD - is reachable outside that disposable copy. A
# published-for-review report that names no Gerrit change is refused.
# There is no free-text SHA scan: a SHA that happens to appear in the note is
# not the named head. 1 when
# the claim is refused; stdout then holds a one-line reason and no other
# output. <state> <id> <meta> supply pr=,
# pr_head=, and the merge-notified marker; <meta> may be a captured copy
# (bin/fm-fleet-snapshot.sh), so the marker is read from <state>.
fm_dod_accept_ship_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  local kind=$1 mode=$2 wt=$3 project=$4 line=$5 state=${6:-} id=${7:-} meta=${8:-} url sha gerrit
  fm_dod_should_gate_ship_done "$kind" "$mode" "$line" || return 0
  if url=$(fm_dod_pr_url_from_done_note "$(status_line_note "$line")") \
    && fm_dod_recorded_pr_on_forge "$state" "$id" "$meta" "$mode" "$url"; then
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf '%s\n' "named head cannot be verified: worktree missing"
    return 1
  fi
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "named head cannot be verified: worktree is not a git copy"
    return 1
  fi
  sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || {
    printf '%s\n' "named head could not be resolved"
    return 1
  }
  gerrit=0
  [ -n "$url" ] && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gerrit ] && gerrit=1
  if [ "$gerrit" = 0 ] && fm_dod_note_reports_published_change "$(status_line_note "$line")"; then
    printf '%s\n' "the published-for-review report does not name a Gerrit change in the canonical https://<host>/c/<project>/+/<number> form"
    return 1
  fi
  if [ "$gerrit" = 1 ]; then
    case "$mode" in
      no-mistakes|'')
        fm_dod_nm_custody_returned "$wt" || return 1 ;;
    esac
    if fm_dod_gerrit_change_carries_head "$wt" "$url"; then
      return 0
    fi
    printf '%s\n' "named head $sha is not the published content of $url: the change's current patch set does not carry this copy's HEAD tree, or it could not be read"
    return 1
  fi
  if fm_dod_named_head_reachable_outside_worktree "$wt" "$project" "$mode" "$sha"; then
    return 0
  fi
  printf '%s\n' "named head $sha is unreachable outside the worker copy"
  return 1
}
