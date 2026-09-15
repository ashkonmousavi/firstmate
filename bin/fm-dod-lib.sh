#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# This file also renders and validates the task preparation record that
# bin/fm-brief.sh --prep scaffolds and bin/fm-spawn.sh gates a ship launch on.
# The canonical section list lives here once so the writer and the validator
# cannot drift; bin/fm-brief.sh's header owns the prose contract for the record.
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it to every ship/scout launch brief and never to a
# secondmate charter. Like fm_brief_intent_overlay it is a distinctly titled
# launch section that states its own precedence for Firstmate tasks, so a brief
# that authors its own role wording is superseded rather than duplicated.

fm_brief_worker_role() {
  cat <<'EOF'
# Current worker role contract
When this task works on Firstmate itself, this section supersedes every earlier brief instruction about your role and identity.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is the primary/secondmate supervisor's contract: follow this brief instead of that supervisor contract.
For that Firstmate task, do the assigned work yourself and report to firstmate; do not adopt the supervisor identity, delegate the task, run fleet supervision, or address the captain.
This exception preserves this brief's safety and authority boundaries and applicable contributor guidance, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
Other projects retain their own instructions unchanged.
EOF
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

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
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
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*Captain('\''s (words|ask|intent))?:[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use the serialized captain intent below plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
  cat <<'EOF'

Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent above refers to into its substance rather than passing the pointer.
EOF
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
# launch whose record is missing or unfilled. The canonical heading list lives
# here exactly once so the writer and the validator cannot drift: a section the
# author deleted is as refusable as one left unfilled.
# Each section carries a one-line `<!-- ... -->` guide and a single
# `{PLACEHOLDER}` the author replaces. Any section may instead be answered
# `n/a: <one-line reason>`, so a one-file fix costs a few lines and a UI slice
# costs a page.
FM_PREP_SECTIONS='## 1. Intent and boxes|INTENT_AND_BOXES|The captain'"'"'s words, and each Change box this task discharges, VERIFIED still open against origin/main with the command used.
## 2. Behaviour spec|BEHAVIOUR_SPEC|Every state (empty, loading, ready, running, refused, failed, terminal), every control and when it is enabled, every action and its result, the copy the user sees, restart and reopen behaviour.
## 3. UI/UX|UI_UX|Which step or screen, the journey walked as the user step by step, what done looks like on screen, responsiveness and accessibility notes.
## 4. Blast radius|BLAST_RADIUS|Modules touched with their GitNexus impact result, callers found with Serena for any signature change, contracts and generated files affected, records and docs that cite the changed behaviour.
## 5. Data and contracts|DATA_AND_CONTRACTS|Request and response shapes, versions, migrations.
## 6. Tests|TESTS|The red-first list, journey tests, mutation witnesses, existing tests that change and why.
## 7. Records|RECORDS|Boxes to tick, verification records, log-book entries.
## 8. Out of scope and follow-ups|OUT_OF_SCOPE|What this task deliberately leaves alone, and the follow-up work it creates.
## 9. Risks, dependencies, merge order|RISKS|Risks, dependencies, sibling lanes touching the same files, and the order these must land in.
## 10. Demo receipt plan|DEMO_RECEIPT|What the worker walks and records before validation.
## 11. Definition of done|DEFINITION_OF_DONE|The done criteria, checked line by line against the intent above.
## 12. Size|SIZE|Files expected to change; more than about eight files means split the slice.'

# fm_prep_path <data-dir> <task-id>
fm_prep_path() {
  printf '%s/%s/prep.md\n' "$1" "$2"
}

# fm_prep_template <task-id> - the scaffold written to data/<task-id>/prep.md.
fm_prep_template() {
  local id=$1 heading placeholder guide
  printf '# Task prep: %s\n\n' "$id"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal template text
  printf 'Answer every section. A section that genuinely does not apply is answered `n/a: <one-line reason>`.\n'
  printf 'This record is the specification beneath the brief: sections 2 and 11 are the acceptance criteria the reviewer holds the work to.\n'
  while IFS='|' read -r heading placeholder guide; do
    [ -n "$heading" ] || continue
    printf '\n%s\n<!-- %s -->\n{%s}\n' "$heading" "$guide" "$placeholder"
  done <<EOF
$FM_PREP_SECTIONS
EOF
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

# fm_prep_unfilled_reason <file>
# Prints the first refusal reason naming its section and exits 0; exits 1 when
# every section is answered. A missing file is its own refusal.
fm_prep_unfilled_reason() {  # <file>
  local file=$1 heading placeholder guide state
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'no preparation record at %s\n' "$file"
    return 0
  fi
  while IFS='|' read -r heading placeholder guide; do
    [ -n "$heading" ] || continue
    state=$(fm_prep_section_state "$file" "$heading" "$placeholder")
    case "$state" in
      missing) printf '%s is missing from %s\n' "$heading" "$file"; return 0 ;;
      unfilled) printf '%s still carries its {%s} placeholder in %s\n' "$heading" "$placeholder" "$file"; return 0 ;;
      empty) printf '%s is empty in %s\n' "$heading" "$file"; return 0 ;;
    esac
  done <<EOF
$FM_PREP_SECTIONS
EOF
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
Its `## 2. Behaviour spec` and `## 11. Definition of done` are the acceptance criteria the reviewer will hold this work to, alongside `## Captain's intent` above.
A section answered `n/a: <reason>` is a decision already taken, not an invitation to fill the gap yourself.
If the record is wrong or incomplete for what you find in the code, say so through the status file rather than silently building something else.
EOF
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

fm_dod_block() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled \`Captain:\`, \`Captain's words:\`, \`Captain's ask:\`, or \`Captain's intent:\`; never copy its mixed \`# Task\` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll \`no-mistakes axi status\` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
