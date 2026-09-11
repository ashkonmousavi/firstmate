#!/usr/bin/env bash
# Single owner of a ship task's shared rule-8 review contract, conditional
# integration-batch owner binding, and mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> <task-record>
# [batch-owner] [trusted-project-root] prints the block on stdout with no trailing
# blank line. A non-empty batch owner designates this task as that owner's
# constituent. The caller validates the mode;
# an unknown mode is refused rather than silently rendered as the pipeline contract.
# Every mode's block binds one canonical task worktree and fm/<task-id> ref from
# the task record, requires a clean worktree, requires every recursively referenced
# submodule to be initialized at its recorded commit, scans that ref and those
# submodule commits for unresolved FINALIZE-AFTER( sentinels, and binds later
# delivery actions to that worktree. An inspection or scan error is a delivery
# failure, never the same result as no matches.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# This file is the one owner of the no-mistakes `--intent` contract and its
# source-revision-bound validation invocation: separately attributed labeled
# parts in one string. `Captain intent:` carries the brief's
# `## Captain's intent` subsection plus later captain words, never Firstmate's
# specification or the worker's own tradeoffs. For a modern brief,
# `Firstmate implementation context:` carries the complete `## Firstmate spec`.
# When the brief carries a Proof bar section, `Agreed proof contract:` carries
# that section, filled in, verbatim. A legacy mixed Task has no separately
# attributable implementation section, so it remains captain-only plus any
# Proof bar instead of reclassifying unmarked text as Firstmate authority.
# The complete labeled input must be self-sufficient with the codebase while
# preserving those authority boundaries. A report, decision, or PR the
# captain's words invoke is written into the captain part as substance, never
# left as a bare pointer; Firstmate implementation sources stay in their own
# part.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# through the helpers below. A spawned no-mistakes worker's launch overlay carries
# one exact `run-validation` command bound to the effective brief's SHA-256.
# That command renders `--intent` from the current brief and refuses before the
# tool starts when the receipt is stale, so acknowledgement cannot substitute
# for validation consuming the refreshed contract. Before `no-mistakes axi run`
# it reads the current branch's `no-mistakes axi status`: an active run holding
# the branch at another head refuses with exit 4 (the installed tool would
# otherwise let that push supersede it), an unreadable status refuses with exit
# 5, and a same-head resubmission still reattaches. It also refuses with exit 6
# when the local branch and its locally known pushed origin branch have diverged,
# because rebasing then replays inherited main commits onto the stale PR head.
# Other mentions of `--intent` point here rather than restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

fm_dod_delivery_preflight_block() {  # <task-id> <task-record>
  local id=$1 task_record=$2
  cat <<EOF
Require a clean worktree and no unresolved \`FINALIZE-AFTER(\` sentinel in the one verified delivery target.
Bind this gate to task record \`$task_record\`, never to a repository resolved from the current directory.
Require that record to be readable and contain exactly one non-empty absolute \`worktree=\` value, canonicalize that value once as \`task_root\`, and set \`delivery_ref=refs/heads/fm/$id\`.
Refuse and report the concrete missing requirement unless canonical \`git -C "\$task_root" rev-parse --show-toplevel\` equals \`task_root\`, \`git -C "\$task_root" symbolic-ref --quiet HEAD\` returns exactly \`"\$delivery_ref"\`, and \`git -C "\$task_root" rev-parse --verify "\$delivery_ref^{commit}"\` succeeds.
Run \`git -C "\$task_root" status --porcelain=v1 --untracked-files=all\`; it must succeed and print nothing, and any output or command error blocks delivery.
With \`HEAD\` already proven to be \`delivery_ref\`, run \`git -C "\$task_root" submodule status --recursive\`; it must succeed, and every output line must begin with a space, proving every recursively referenced submodule is initialized at the commit recorded by its parent.
A leading \`-\`, \`+\`, or \`U\`, any other prefix, or any command error means a referenced submodule commit cannot be inspected and blocks delivery; report the affected path and condition, or the exact command error, rather than treating it as clean.
Then inspect that same committed delivery ref and every verified submodule commit with \`git -C "\$task_root" grep --recurse-submodules -n -F 'FINALIZE-AFTER(' "\$delivery_ref" -- .\`, never a current-directory, nested-repository, unrelated-checkout, or mutable-file scan.
Exit 1 with no output means no sentinel occurrence; exit 0 means inspect every match and resolve every open placeholder before delivery; any other exit means the scan failed and blocks delivery rather than counting as no matches.
Immediately before each subsequent delivery action that this mode permits - a later \`/no-mistakes\` invocation, a push, a PR command, or the local-only ready report - run \`cd -- "\$task_root"\` and require physical \`pwd -P\` to equal \`task_root\`.
If \`task_root\` is unavailable, rerun this entire preflight from the task record; if the directory change or equality check fails, refuse the action and report the concrete mismatch.
EOF
}

# Standing worker rule text shared between every generated ship brief's # Rules
# list (rule 9, rendered next to rule 8) and bin/fm-control.sh's relaunch
# progress note, so a replacement worker after a relaunch sees the identical
# standing rule its predecessor's original brief carried. Single owner; do not
# restate the sentence a second time anywhere else.
FM_CI_NO_RERUN_LINE="Never re-run a failed CI job or workflow unless the project's current retry contract expressly authorizes the designated dispatcher to retry the exact unchanged candidate under its required evidence and attempt limits. Otherwise fix the actual cause and publish a genuine reviewed repair; never create a filler head or retry a stale-head or code-failure result."

# fm_proof_bar_section prints the "# Proof bar" section: prep-tier definitions,
# the sibling "Resource:" RAM/disk envelope, the sibling "Surface:" dashboard-wiring
# placeholder, the sibling "Journey:" preparation, evidence contract, scope
# boundary, and the class-sweep rule B, one
# owner shared by bin/fm-brief.sh's ship scaffold and bin/fm-promote.sh's promoted
# ship instructions, so a promoted worker gets the same Prep, Resource, Surface,
# and Journey
# contract that fm_ship_batch_rule_block's rule 8 text points back at ("the Proof
# bar above"). Firstmate fills the "Prep: {PREP}", "Resource: {RESOURCE}",
# "Surface: {SURFACE}", and "Journey: {JOURNEY}"
# placeholders at intake (AGENTS.md section 11); bin/fm-spawn.sh
# refuses leftover placeholders per its own header. This section is also the one
# owner of the preparation list itself: AGENTS.md section 7 points here rather
# than restating the items, so the list cannot drift between the two files.
# Source of the tier text:
# data/firstmate-proof-bar-in-intent/prep-tiers.md (captain ruling 2026-09-04), a
# private record of the ruling, not a runtime pointer target - this section is the
# tier definitions' one worker-facing owner. The Surface line exists because the
# dashboard is the only way the operator, user, and admin work with the app
# (captain ruling 2026-09-05): a feature not wired into it is not built. The
# Journey line exists because a delivered change is not an accepted user outcome
# (captain ruling 2026-09-07): substantial or uncertain product-facing work is
# prepared against the user requirement before it is built, not justified
# afterwards by what the implementation happens to support.
fm_proof_bar_section() {
  cat <<'EOF'
# Proof bar
Prep: {PREP}
Resource: {RESOURCE}
Surface: {SURFACE}
Journey: {JOURNEY}

## Tier definitions and evidence contract
Tier 0, none. The default: human-only prose, cosmetic changes, one-site fixes with no callers. State "Prep: Tier 0 - {one reason}". Honesty test: if you would need a search to state that reason, it is not Tier 0.
Tier 1, mechanism sweep. The change fixes a pattern or mechanism at one site (a parser rule, a validation, a timestamp format, a malformed-input guard). Before your first run: search the whole repo for the same mechanism, using rg plus a task-selected symbol-family tool where it is useful; fix every site in one commit, list the sites. If the selected symbol tool is unavailable or does not index the relevant language, use direct callers, tests, and config reads and name the precise limitation.
Tier 2, wiring trace. The change alters something other code depends on (a signature, a contract, a record shape, a return value, a route, a config key or value). Before your first run: use the task-selected symbol/reference tool where it materially traces consumers, PLUS rg for the literal names and values changed - tests and checkers that read source or config as text can be invisible to symbol search. Confirm each site is handled, list them. If the selected tool is unavailable, stale, or inapplicable to the relevant language, fall back to rg on the symbol name plus direct caller, import, test, and config reads, and name the precise limitation.
Resource, the RAM/disk envelope this task may use for tests and builds. Firstmate fills it at intake with a concrete bound (for example "one test process at a time, no whole-repo lint or battery locally, PYTHONPYCACHEPREFIX under /dev/shm, read the available column of free -g with `free -g | awk '/^Mem:/ { print $7 }'` before any browser suite") or "N/A" when the task executes no tests or builds.
Surface, the page, component, or journey where the operator sees this change in the dashboard. Firstmate fills it at intake with the concrete surface (for example "the run-detail page's Evidence tab") or "none: {reason}" when the change has no operator-visible effect. When a real surface is named, the evidence contract requires real-browser proof at that surface, not just passing tests.
Journey, the preparation this task carries into the build. Firstmate fills it at intake for substantial or uncertain product-facing work with: the original user outcome and the current gap; preconditions, roles, meaningful choices and supported modes; numbered browser actions with independently justified expected results; the screenshot required at each meaningful result step; the relevant empty, loading, failed, stale, refusal and success states, each marked expected or defect so a log that is supposed to carry entries is not read as a fault and an empty one is not read as proof; the real producers, consumers, stores, API/CLI/scheduler callers and dependencies; the existing components to reuse; the relevant tests and the limits of their fixtures and mocks; the implementation sequence, parallel boundaries and integration owner; and the evidence required before claiming readiness. It is "none: {reason}" when the work is neither substantial nor uncertain, or has no product-facing journey. A design decision that parks or defers part of the outcome is named here: a parked design never silently justifies a required interaction that is missing. Firstmate reviews this preparation against the user requirement, not against what the current implementation happens to support.
When the Journey line names real preparation, append one status line before your first run stating in your own words what the requirement is, the failure modes you expect, and how you will prove it; "read and understood" does not satisfy it. A "none: {reason}" Journey owes no such line.
The cap: at 20 minutes or 15 sites, report a scope checkpoint to firstmate, list unreached consumers as evidence gaps, and continue with reached sites; the cap never proves omitted consumers irrelevant.
You may raise the stated tier by one with a one-line reason; you may never lower it.
The evidence contract: paste the prep output as a list, verbatim, under this Proof bar before your first run. One line per site: path and line or symbol, then exactly one disposition - fixed, confirmed unaffected with the reason, or out of scope with the reason and the item that owns it. A site with no disposition is not on the list. No list means no prep happened; "checked, all wired" is not evidence.
A reviewer finding at a site NOT on your list is both a real finding to fix and a prep miss; record the prep miss in your report.

## Scope boundary
A finding inside this task's stated bar is yours to fix in this run. A finding asking for proof machinery beyond the stated bar is answered out of scope by default, but the proof bar cannot exclude tests needed to keep already accepted behavior correct, as the Validate subsection of AGENTS.md section 7 requires. A settled family already answered in an earlier round is out of scope; do not reopen it without new evidence.

## Class-sweep rule (rule B)
The first finding of a family means sweep the whole repo for the mechanism under the same cap as the tiers above, give every site found one of the evidence contract's three dispositions - fixed, confirmed unaffected, or out of scope with an owner - and answer every finding in that family in one round with one fix command. Rule 8 under `# Rules` below is this same rule, extended to also apply before your first run whenever you already know the family in advance.

When you run /no-mistakes, copy this entire Proof bar section verbatim into `--intent`'s `Agreed proof contract:` part, alongside the separately attributed `Captain intent:` and `Firstmate implementation context:` parts described in the current intent contract section below.
EOF
}

# fm_ship_batch_rule_block <rule-8-number> <rule-9-number> <rule-10-number>
# prints rule 8 (the pre-run mechanism sweep plus the post-review
# batch-findings response), rule 9 (FM_CI_NO_RERUN_LINE's bounded project-owned
# retry contract), and rule 10 (test quality: a new/changed test must name the behavior it independently proves
# and be shown failure-capable, and a test deletion/weakening in the same diff
# must carry a stated approved-contract-change reason) for a ship brief's
# # Rules list. The pre-run sweep is the Proof bar's Tier 1 prep
# (data/firstmate-proof-bar-in-intent/prep-tiers.md, rule B) done proactively
# instead of only after a review surfaces it. Rule 10 mirrors XAUUSD's
# AGENTS.md "Change method" red-first/failure-capable rule, scoped to
# firstmate's own DoD text (verification scout finding V08, firstmate half).
fm_ship_batch_rule_block() {  # <n8> <n9> <n10>
  local n8=$1 n9=$2 n10=$3
  cat <<EOF
$n8. Before your first run, if you already know a fix pattern applies to more than the one site you were asked to change (a parser rule, a validation, a timestamp format, a malformed-input guard), sweep the whole repo for that mechanism under the same cap as the Proof bar's tiers, give every site found one of the evidence contract's three dispositions - fixed, confirmed unaffected, or out of scope with an owner - in one commit, and paste the site list into the Proof bar's Prep line before starting (rule B in the Proof bar above; this is Tier 1 prep done before the run instead of only after a review finds it).
   When a review, verification run, or test pass fails anyway, never fix and resubmit the first defect you find.
   Enumerate the COMPLETE finding set first, then check the surfaces that can share each defect's mechanism -
   same pattern, same generator, same template, sibling files - and report or repair the whole batch at once
   so one re-review covers all of it. One-at-a-time stop-fix-rereview loops are forbidden.
$n9. $FM_CI_NO_RERUN_LINE
$n10. A new or changed test must name, in its own name or docstring, the behavior it independently proves, and must be shown failure-capable: red before the change, green after, or an equivalent neuter.
   A test deletion, skip, or weakened assertion in the same diff must carry a stated reason naming the approved contract change that makes the old expectation wrong; it must never exist only to obtain green.
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

fm_dod_shell_quote() {  # <text>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_dod_sha256_file() {  # <file>
  local file=$1 digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum -- "$file") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 -- "$file") || return 1
  else
    return 1
  fi
  digest=${digest%% *}
  case "$digest" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf 'sha256:%s\n' "$digest"
}

# Bind revision admission to the capability decision the source owner actually
# used. Spawn supplies the trusted project root before metadata exists; later
# validation derives it from the task record. An unresolved project or config is
# represented explicitly as unknown and therefore cannot impersonate a prior
# supported receipt.
fm_dod_capability_receipt() {  # <effective-brief>
  local brief=$1 project=${FM_DOD_TRUSTED_PROJECT_ROOT:-} id meta config config_hash version build
  local support binary_hash install_receipt install_receipt_hash
  if [ -z "$project" ] && [ -n "${FM_HOME:-}" ]; then
    id=$(basename -- "$(dirname -- "$brief")")
    meta="$FM_HOME/state/$id.meta"
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      project=$(sed -n 's/^project=//p' "$meta" | head -1)
    fi
  fi
  config=${project:+$project/.no-mistakes.yaml}
  if [ -n "$config" ] && [ -f "$config" ] && [ ! -L "$config" ] && [ -r "$config" ]; then
    config_hash=$(fm_dod_sha256_file "$config") || config_hash=unreadable
  else
    config_hash=unknown
  fi
  version=$(no-mistakes --version 2>/dev/null || printf unknown)
  build=$(fm_dod_document_correction_build "$version" 2>/dev/null || printf unknown)
  binary_hash=$(fm_dod_no_mistakes_executable_sha256 2>/dev/null || printf unknown)
  install_receipt=$(fm_dod_document_correction_receipt_path 2>/dev/null || printf unknown)
  if [ "$install_receipt" != unknown ] && [ -f "$install_receipt" ] \
    && [ ! -L "$install_receipt" ] && [ -r "$install_receipt" ]; then
    install_receipt_hash=$(fm_dod_sha256_file "$install_receipt" 2>/dev/null || printf unreadable)
  else
    install_receipt_hash=unknown
  fi
  support=unsupported
  fm_dod_document_correction_receipt_supported && support=supported
  printf 'document=%s;build=%s;executable=%s;install_receipt=%s;project_config=%s\n' \
    "$support" "$build" "$binary_hash" "$install_receipt_hash" "$config_hash"
}

fm_brief_source_revision() {  # <effective-brief> [frozen-capability-receipt]
  local file=$1 capability=${2:-} digest canonical source_hash
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  canonical=$(mktemp "${TMPDIR:-/tmp}/fm-brief-contract.XXXXXX") || return 1
  if ! awk '
    /^# (Progress|Progress history|History)([[:space:]]|$)/ { skip = 1; next }
    /^# / { skip = 0 }
    !skip { print }
  ' "$file" > "$canonical"; then
    rm -f -- "$canonical"
    return 1
  fi
  source_hash=$(fm_dod_sha256_file "${BASH_SOURCE[0]}") || {
    rm -f -- "$canonical"
    echo "error: no SHA-256 tool is available for the effective brief receipt" >&2
    return 1
  }
  if [ -z "$capability" ]; then
    capability=$(fm_dod_capability_receipt "$file") || {
      rm -f -- "$canonical"
      return 1
    }
  fi
  printf '\nsource_contract=%s\ncapability=%s\n' "$source_hash" "$capability" >> "$canonical" \
    || { rm -f -- "$canonical"; return 1; }
  digest=$(fm_dod_sha256_file "$canonical") || { rm -f -- "$canonical"; return 1; }
  rm -f -- "$canonical"
  digest=${digest#sha256:}
  printf 'sha256:%s' "$digest"
}

fm_brief_validation_intent() {  # <effective-brief>
  local file=$1 captain spec proof legacy
  fm_brief_task_content_valid "$file" || {
    echo "error: effective brief has no valid Task content: $file" >&2
    return 1
  }
  if fm_brief_task_heading_present "$file" "## Captain's intent"; then
    captain=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  else
    legacy=$(fm_brief_heading_body "$file" "# Task")
    captain=$(fm_brief_marked_captain_words "$legacy")
  fi
  [ -n "$(printf '%s' "$captain" | tr -d '[:space:]')" ] || {
    echo "error: effective brief has no provenance-marked captain intent: $file" >&2
    return 1
  }
  printf 'Captain intent:\n%s' "$captain"
  if fm_brief_task_heading_present "$file" "## Firstmate spec"; then
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || {
      echo "error: effective brief has no Firstmate implementation context: $file" >&2
      return 1
    }
    printf '\n\nFirstmate implementation context:\n%s' "$spec"
  fi
  if fm_brief_heading_present "$file" "# Proof bar"; then
    if grep -Eq '^(Prep|Resource|Surface|Journey): \{[A-Z]+\}$' "$file"; then
      echo "error: effective brief contains an unfilled Proof bar input: $file" >&2
      return 1
    fi
    proof=$(fm_brief_heading_body "$file" "# Proof bar")
    [ -n "$(printf '%s' "$proof" | tr -d '[:space:]')" ] || {
      echo "error: effective brief has an empty Proof bar: $file" >&2
      return 1
    }
    printf '\n\nAgreed proof contract:\n# Proof bar\n%s' "$proof"
  fi
  printf '\n'
}

# fm_dod_active_run_guard holds a fresh submission while an active no-mistakes
# run holds the current branch at another head. The installed tool lets a push
# of a different head supersede (cancel) an active run whose pipeline head has
# not moved, so without this entry-boundary check run-validation would replace
# the run a worker was told not to touch. Only the branch's structured
# `no-mistakes axi status` decides: the run's own head or submitted head
# reattaches as before, no run or a terminal run proceeds, an active run at
# another head refuses with exit 4, and a status that cannot be read refuses
# with exit 5. no-mistakes itself is unchanged; the supported release is the
# abort, a confirmed stop, then branch_sync.next_action.
fm_dod_active_run_guard() {
  local status rc parsed has_run run_id run_status run_head submitted known head
  if status=$(no-mistakes axi status 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    printf "error: run-validation cannot read \`no-mistakes axi status\` (exit %s): %s\nRefusing to start a run without knowing whether one already holds this branch.\n" \
      "$rc" "$(printf '%s' "$status" | tr '\n' ' ' | cut -c1-400)" >&2
    return 5
  fi
  parsed=$(printf '%s\n' "$status" | awk '
    function val(line) { sub(/^[^:]*:[ ]*/, "", line); gsub(/^"|"$/, "", line); return line }
    /^[^ ]/ { section = $0; sub(/:.*/, "", section); sub_section = "" }
    /^current_branch:/ || /^runs_on_current_branch:/ { known = 1 }
    section == "run" && /^  id:/ { id = val($0) }
    section == "run" && /^  status:/ { status = val($0); has_run = 1 }
    section == "run" && /^  head_sha:/ { head = val($0) }
    section == "branch_sync" && /^  [^ ]/ { sub_section = $0; sub(/^  /, "", sub_section); sub(/:.*/, "", sub_section) }
    section == "branch_sync" && sub_section == "pipeline" && /^    submitted_head:/ { submitted = val($0) }
    END { printf "%s|%s|%s|%s|%s|%s\n", has_run + 0, id, status, head, submitted, known + 0 }
  ')
  IFS='|' read -r has_run run_id run_status run_head submitted known <<EOF
$parsed
EOF
  if [ "$has_run" != 1 ]; then
    [ "$known" = 1 ] && return 0
    printf "error: run-validation cannot read \`no-mistakes axi status\`: its output names neither a run nor the current branch (%s)\nRefusing to start a run without knowing whether one already holds this branch.\n" \
      "$(printf '%s' "$status" | tr '\n' ' ' | cut -c1-400)" >&2
    return 5
  fi
  case "$run_status" in
    completed|failed|cancelled|ci_monitor_interrupted) return 0 ;;
  esac
  if [ -z "$run_head" ]; then
    printf "error: run-validation cannot read \`no-mistakes axi status\`: active run %s (status %s) reports no head_sha\nRefusing to start a run without knowing which head it holds.\n" \
      "${run_id:-unknown}" "${run_status:-unknown}" >&2
    return 5
  fi
  head=$(git rev-parse HEAD 2>&1) || {
    printf 'error: run-validation cannot resolve HEAD to compare with active run %s: %s\n' "${run_id:-unknown}" "$head" >&2
    return 5
  }
  if [ "$head" = "$run_head" ] || { [ -n "$submitted" ] && [ "$head" = "$submitted" ]; }; then
    return 0
  fi
  printf "error: run-validation refuses to start a run: active no-mistakes run %s (status %s) holds this branch at %s (submitted %s) but HEAD is %s, and submitting a different head would supersede that run.\nIf replacing it is authorized, abort it with the supported \`no-mistakes axi abort\`, confirm through \`no-mistakes axi status\` that it has stopped, follow its \`branch_sync.next_action\`, then rerun this same run-validation command.\n" \
    "${run_id:-unknown}" "$run_status" "$run_head" "${submitted:-unknown}" "$head" >&2
  return 4
}

# fm_dod_remote_pr_head_guard refuses only incomparable local and locally known
# origin branch heads. An absent remote-tracking ref and a detached HEAD proceed
# unchanged. This deliberately makes no network call: the local origin ref is
# the pushed-PR evidence available before no-mistakes starts.
fm_dod_remote_pr_head_guard() {
  local branch remote_ref remote_head head
  if ! branch=$(git symbolic-ref --quiet --short HEAD); then
    return 0
  fi
  remote_ref="refs/remotes/origin/$branch"
  git rev-parse --verify --quiet "$remote_ref^{commit}" >/dev/null || return 0
  remote_head=$(git rev-parse "$remote_ref^{commit}") || return 0
  head=$(git rev-parse HEAD) || return 0
  if git merge-base --is-ancestor "origin/$branch" HEAD \
    || git merge-base --is-ancestor HEAD "origin/$branch"; then
    return 0
  fi
  # shellcheck disable=SC2016 # Backticks are literal worker-facing Markdown.
  printf 'error: run-validation refuses to start a run: local HEAD %s and pushed origin/%s %s have diverged.\nRemedy: merge origin/main in when HEAD lacks it; after `git range-diff` proves the stale PR head content is carried, run `git merge -s ours --no-ff origin/%s`; never rebase and never force-push.\n' \
    "$head" "$branch" "$remote_head" "$branch" >&2
  return 6
}

# Strict launch receipts are an executable capability, not a version-label
# inference. Require both paired flags from the installed command and reject a
# claimed per-run agent selector: Firstmate's agent/model route comes from the
# trusted global configuration, not an unsupported run argument.
fm_dod_strict_launch_supported() {
  local help
  help=$(NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes axi run --help 2>/dev/null) || return 1
  printf '%s\n' "$help" | grep -F -- '--launch-nonce' >/dev/null || return 1
  printf '%s\n' "$help" | grep -F -- '--validation-generation' >/dev/null || return 1
  ! printf '%s\n' "$help" | grep -Eq '^[[:space:]]+--agent([[:space:]=]|$)'
}

fm_dod_run_validation() {  # <effective-brief> <expected-revision> [axi-run-arg...]
  local brief=$1 expected=$2 actual intent arg snapshot capability receipt_digest launch_nonce validation_generation
  shift 2
  case "${expected#sha256:}" in
    ''|*[!0-9A-Fa-f]*) echo "error: --expect-revision must be a sha256 receipt" >&2; return 2 ;;
  esac
  case "$expected" in sha256:*) ;; *) echo "error: --expect-revision must be a sha256 receipt" >&2; return 2 ;; esac
  [ "${#expected}" -eq 71 ] || {
    echo "error: --expect-revision must be a sha256 receipt" >&2
    return 2
  }
  capability=$(fm_dod_capability_receipt "$brief") || {
    echo "error: cannot resolve the effective capability/config receipt: $brief" >&2
    return 2
  }
  actual=$(fm_brief_source_revision "$brief" "$capability") || {
    echo "error: cannot read the effective brief revision: $brief" >&2
    return 2
  }
  if [ "$actual" != "$expected" ]; then
    echo "advisor discrepancy: effective brief revision changed (expected $expected, current $actual); refuse stale validation and obtain a refreshed launch package" >&2
    return 3
  fi
  for arg in "$@"; do
    case "$arg" in
      --intent|--intent=*|--launch-nonce|--launch-nonce=*|--validation-generation|--validation-generation=*|-y|--yes)
        echo "error: run-validation owns --intent and strict launch receipts, and refuses automatic gate approval" >&2
        return 2
        ;;
    esac
  done
  snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-validation-brief.XXXXXX") || {
    echo "error: cannot stage the effective brief for validation" >&2
    return 2
  }
  if ! cp "$brief" "$snapshot"; then
    rm -f -- "$snapshot"
    echo "error: cannot stage the effective brief for validation" >&2
    return 2
  fi
  actual=$(fm_brief_source_revision "$snapshot" "$capability") || {
    rm -f -- "$snapshot"
    return 2
  }
  if [ "$actual" != "$expected" ]; then
    rm -f -- "$snapshot"
    echo "advisor discrepancy: effective brief changed while validation was being prepared; refuse stale validation and obtain a refreshed launch package" >&2
    return 3
  fi
  intent=$(fm_brief_validation_intent "$snapshot") || {
    rm -f -- "$snapshot"
    return 2
  }
  rm -f -- "$snapshot"
  actual=$(fm_brief_source_revision "$brief" "$capability") || {
    echo "error: cannot recheck the effective brief revision: $brief" >&2
    return 2
  }
  if [ "$actual" != "$expected" ]; then
    echo "advisor discrepancy: effective brief changed while validation was being prepared; refuse stale validation and obtain a refreshed launch package" >&2
    return 3
  fi
  fm_dod_active_run_guard || return
  fm_dod_remote_pr_head_guard || return
  if ! fm_dod_strict_launch_supported; then
    echo "error: run-validation requires installed no-mistakes support for paired --launch-nonce and --validation-generation receipts, with agent routing owned by trusted global configuration" >&2
    return 7
  fi
  receipt_digest=${expected#sha256:}
  launch_nonce="firstmate-$receipt_digest"
  validation_generation="brief-$receipt_digest"
  no-mistakes axi run --intent "$intent" \
    --launch-nonce "$launch_nonce" \
    --validation-generation "$validation_generation" "$@"
}

fm_brief_intent_overlay() {  # <captain-intent> <effective-brief> <source-revision> <runner>
  local captain_intent=$1 brief=$2 revision=$3 runner=$4
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about how to build the labeled parts of `--intent`, but not later clarifications actually supplied by the captain and not the Proof bar section's own instruction when one exists.
Use the serialized captain intent below plus any later words the captain actually supplied as the `Captain intent:` part; never include Firstmate specification or other mixed Task content in that part.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$captain_intent"
  cat <<'EOF'

Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent, and stay out of the `Captain intent:` part.
The source-revision-bound consumer carries the effective brief's complete `## Firstmate spec` under the separate `Firstmate implementation context:` label.
The complete labeled input must be self-sufficient with the codebase while retaining that attribution: resolve any report, decision, or PR the captain intent above invokes into its substance rather than passing a bare pointer, and keep Firstmate implementation sources in their own part.
EOF
  cat <<'EOF'

## Validation instruction source receipt

Start validation only through the exact revision-bound command below.
It builds the actual `--intent` input from the effective brief and refuses before no-mistakes starts when that brief no longer matches this launch package.
The source brief, generated launch, serialized intent, strict launch receipt, candidate head, and pipeline base form one binding. An ordinary progress/history edit does not invalidate an otherwise matching same-head launch; a changed instruction source, capability/config receipt, candidate head, base, or custody does. Regenerate derived output from its owner after a source replacement, and never call a parked prior run consumption of replacement instructions.
EOF
  printf '%s%s%s\n' 'Effective brief: `' "$brief" '`'
  printf '%s%s%s\n' 'Source revision: `' "$revision" '`'
  printf '    %s run-validation --brief %s --expect-revision %s\n' \
    "$(fm_dod_shell_quote "$runner")" "$(fm_dod_shell_quote "$brief")" \
    "$(fm_dod_shell_quote "$revision")"
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

# fm_dod_evidence_rules_block <pr|local> prints the two rules every mode's
# Definition of done carries: a delivery signal is not product acceptance
# (AGENTS.md section 9 owns what a product-facing feature needs before it is
# offered for acceptance), and journey evidence never enters the source tree.
# One owner for both, so the three mode blocks below cannot drift; before this
# helper the screenshot rule was written out twice and local-only carried
# neither. The destination clause is the only mode-specific part: a local-only
# worker has no PR body to upload into, and its own delivery preflight requires
# a worktree clean of untracked files, so its evidence must live outside the
# repository entirely.
fm_dod_evidence_rules_block() {  # <pr|local>
  local dest
  case "$1" in
    pr) dest='the actual images go into the PR body, uploaded through GitHub' ;;
    local) dest='the actual images stay outside the repository and your ready report names their path' ;;
    *) echo "error: fm_dod_evidence_rules_block: unknown destination '$1'" >&2; return 1 ;;
  esac
  cat <<EOF
Your delivery signal reports delivery, never product acceptance: it says this change is committed and its checks passed, not that the user outcome is accepted. Firstmate offers the work for acceptance separately, with the journey evidence.
No binary screenshots or other media enter the repository tree: prose evidence (for example \`fidelity-check.md\`) cites each one by filename, and $dest.
EOF
}

# Return 0 only when the consuming project's trusted config explicitly enables
# bounded Document correction and the install-owned private receipt binds the
# exact executable bytes to independently accepted consuming proof. The project
# file is supplied from the firstmate-owned clone, never from the candidate
# worktree. A missing, symlinked, malformed, duplicate, or unreadable setting,
# receipt, executable, or checksum mismatch all fail closed. The version banner
# build remains diagnostic identity only; it never grants capability.
fm_dod_document_correction_build() {  # <version-output>
  printf '%s\n' "$1" | sed -n 's/^no-mistakes version [^ ]* (\([0-9A-Fa-f][0-9A-Fa-f]*\))\( .*$\|$\)/\1/p'
}

fm_dod_no_mistakes_executable_sha256() {
  local executable
  executable=$(command -v no-mistakes 2>/dev/null) || return 1
  case "$executable" in /*) ;; *) return 1 ;; esac
  [ -f "$executable" ] && [ -r "$executable" ] || return 1
  fm_dod_sha256_file "$executable"
}

fm_dod_document_correction_receipt_path() {
  case "${FM_HOME:-}" in /*) ;; *) return 1 ;; esac
  printf '%s/config/no-mistakes-document-correction.receipt\n' "$FM_HOME"
}

fm_dod_document_correction_receipt_supported() {
  local receipt schema executable_line proof_line extra expected actual
  receipt=$(fm_dod_document_correction_receipt_path) || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ -r "$receipt" ] || return 1
  IFS= read -r schema < "$receipt" || return 1
  executable_line=$(sed -n '2p' "$receipt") || return 1
  proof_line=$(sed -n '3p' "$receipt") || return 1
  extra=$(sed -n '4,$p' "$receipt") || return 1
  [ "$schema" = 'schema=fm-no-mistakes-document-correction.v1' ] || return 1
  [ -z "$extra" ] || return 1
  case "$executable_line" in executable_sha256=sha256:*) ;; *) return 1 ;; esac
  case "$proof_line" in proof_sha256=sha256:*) ;; *) return 1 ;; esac
  expected=${executable_line#executable_sha256=}
  case "${expected#sha256:}" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#expected}" -eq 71 ] || return 1
  case "${proof_line#proof_sha256=sha256:}" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
  [ "${#proof_line}" -eq 84 ] || return 1
  actual=$(fm_dod_no_mistakes_executable_sha256) || return 1
  [ "$actual" = "$expected" ]
}

# Installation owner only: after independent review accepts a real consuming
# proof for the currently installed executable, publish the private receipt
# atomically. Merely installing a new binary does not grant the capability.
fm_dod_record_document_correction_capability() {  # <accepted-proof-file>
  local proof=$1 receipt config_dir executable_hash proof_hash tmp
  [ -f "$proof" ] && [ ! -L "$proof" ] && [ -r "$proof" ] || {
    echo "error: accepted Document correction proof must be a readable regular non-symlink file: $proof" >&2
    return 1
  }
  receipt=$(fm_dod_document_correction_receipt_path) || {
    echo 'error: FM_HOME must be an absolute path for the private Document correction receipt' >&2
    return 1
  }
  executable_hash=$(fm_dod_no_mistakes_executable_sha256) || {
    echo 'error: cannot hash the installed no-mistakes executable' >&2
    return 1
  }
  proof_hash=$(fm_dod_sha256_file "$proof") || {
    echo "error: cannot hash accepted Document correction proof: $proof" >&2
    return 1
  }
  config_dir=${receipt%/*}
  mkdir -p -- "$config_dir" || return 1
  tmp=$(umask 077; mktemp "$config_dir/.no-mistakes-document-correction.receipt.XXXXXX") || return 1
  if ! {
    printf '%s\n' 'schema=fm-no-mistakes-document-correction.v1'
    printf 'executable_sha256=%s\n' "$executable_hash"
    printf 'proof_sha256=%s\n' "$proof_hash"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$receipt" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$receipt"
}

fm_dod_document_correction_enabled() {  # <trusted-project-root>
  local project_root=$1 config value
  [ -n "$project_root" ] && [ -d "$project_root" ] || return 1
  config="$project_root/.no-mistakes.yaml"
  [ -f "$config" ] && [ ! -L "$config" ] && [ -r "$config" ] || return 1
  # This is intentionally a conservative mapping reader, not a partial YAML
  # implementation. Admit only plain, unquoted top-level keys and exactly one
  # block-form auto_fix mapping whose unique, plain, unquoted children are
  # integer scalars at one direct-child indentation. Inline, quoted, nested,
  # non-integer, duplicate, or inconsistent shapes are ambiguous to this reader
  # and therefore preserve report-only behavior.
  value=$(LC_ALL=C awk '
    BEGIN {
      valid = 1
      auto_fix_count = 0
      document_count = 0
    }
    /^[[:space:]]*($|#)/ { next }
    index($0, "\t") { valid = 0; next }
    /^[^ ]/ {
      in_auto_fix = ($0 ~ /^auto_fix:[[:space:]]*(#.*)?$/)
      if (in_auto_fix) {
        auto_fix_count++
      } else {
        # Quoted or otherwise complex root keys can decode to auto_fix, and an
        # inline auto_fix value is outside the one supported block grammar.
        if ($0 !~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/ ||
            $0 ~ /^auto_fix:[[:space:]]*/) valid = 0
      }
      child_indent = 0
      next
    }
    !in_auto_fix { next }
    {
      match($0, /^ +/)
      indent = RLENGTH
      if (child_indent == 0) child_indent = indent
      if (indent != child_indent) {
        valid = 0
        next
      }
      line = substr($0, indent + 1)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/) {
        valid = 0
        next
      }
      child_key = line
      sub(/:.*/, "", child_key)
      if (seen_child[child_key]++) {
        valid = 0
        next
      }
      child_value = line
      sub(/^[^:]*:[[:space:]]*/, "", child_value)
      if (child_value !~ /^[0-9]+([[:space:]]+#.*|[[:space:]]*)$/) {
        valid = 0
        next
      }
      sub(/[[:space:]]+#.*$/, "", child_value)
      sub(/[[:space:]]*$/, "", child_value)
      if (child_key == "document") {
        document_count++
        document_value = child_value
      }
    }
    END {
      if (valid && auto_fix_count == 1 && document_count == 1) {
        print document_value
        exit 0
      }
      exit 1
    }
  ' "$config") || return 1
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -gt 0 ] 2>/dev/null || return 1
  fm_dod_document_correction_receipt_supported
}

fm_dod_document_instruction_block() {  # <trusted-project-root>
  if fm_dod_document_correction_enabled "$1"; then
    cat <<'EOF'
Determine Document correction from the installed, supported implementation capability, never from a historical label. The consuming project's trusted configuration selects bounded in-run document correction and the installed no-mistakes build supports it: the pipeline's correction turn applies an accepted documentation fix in-run. Record the actual changed source, regenerated derived documents, and final-head proof. You owe an honest completed Test recheck and a valid attestation, never a skipped Test step and never your own out-of-band commit plus a fresh run for that accepted finding. Independent review is still required at the resulting head; attestation alone is never reviewer approval.
EOF
  else
    cat <<'EOF'
Determine Document correction from the installed, supported implementation capability, never from a historical label. The current trusted capability/config receipt does not prove enabled in-run correction, so use the supported custody-preserving manual repair path. The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed. That record names the changed source, regenerated derived documents, and final-head proof.
EOF
  fi
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# fm_integration_batch_dod_block <mode> [batch-owner] prints the exact extra completion and
# pull-request-body binding for a task designated as an integration batch's
# owner. The integration-batch-delivery skill owns when and how batching is
# selected and performed; this block owns only the worker-facing DoD mechanics
# and the table shapes rendered in every ship mode: the route-specific membership
# records that bind each constituent, the join review that states what the joins
# actually did to each constituent's reviewed work, and the landing record
# naming which commit the pipeline tested and which commit the merge produced.
# The landing record's two commits differ under a squash-merge contract, so it
# records both rather than asserting one. A local-only owner
# must be re-briefed onto a PR-based path because a batch lands through one
# combined PR.
fm_integration_batch_dod_block() {  # <mode> [batch-owner]
  local mode=$1 batch_owner=${2:-}
  if [ -n "$batch_owner" ]; then
    cat <<EOF
## Conditional integration-batch definition of done

Firstmate designated this task as a batch constituent for integration owner \`$batch_owner\`.
When your branch is prepared, deliver your exact reviewed head and focused evidence to the named integration owner \`$batch_owner\` and stop.
Do not start a standalone no-mistakes pipeline merely to become a batch member.
Still satisfy any independently required publication obligation imposed by the selected delivery route.
EOF
    return 0
  fi
  cat <<'EOF'
## Conditional integration-batch definition of done

If firstmate designates this task as an integration owner, load `integration-batch-delivery` and satisfy that skill before using this task's normal delivery signal.
Use exactly one of the following two record routes for each constituent.
Never fabricate a constituent pull request or mark one merged merely to make it eligible for the batch.
Preserve every independently required publication obligation imposed by the constituent's selected delivery route.
The combined pull request's body is pipeline output only: never run `gh pr edit` or `gh-axi pr edit` on it, and get every required row and table below into the body through the run's intent, never a hand-edit.

For every PR-backed constituent, the combined pull request body must contain this row shape:

| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |
| --- | --- | --- | --- | --- |
| `<task-id>` | `<branch>` | `<full-sha>` | `<https://...>` | `Closed as superseded; not merged.` |

Close each original pull request with that disposition.
Before the combined pull request lands, bind each PR-backed constituent with `bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>` under the existing pre-landing checks.

For every PR-less constituent, the combined pull request body must contain this row shape:

| PR-less constituent task | Branch | Exact reviewed head | Disposition |
| --- | --- | --- | --- |
| `<task-id>` | `<branch>` | `<full-sha>` | `No original pull request.` |

After the combined pull request merges, bind each PR-less constituent with the same `bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>` command under its stricter merged state, default-branch landing, and permanent-head containment checks.

The body must also contain this complete join review, one row per constituent, written from the actual comparison of the candidate against that constituent's own reviewed head:

| Constituent task | Changes missing from the candidate | Deliberate replacements | Join repairs |
| --- | --- | --- | --- |
| `<task-id>` | `<what is absent, or None>` | `<what replaced what, and why, or None>` | `<what the join itself had to change, or None>` |

An unchanged tree after a binding merge is not evidence that every constituent behavior survived, so this review is stated explicitly rather than inferred from any tree, diff, or range comparison.
A row that cannot be filled from a real comparison is a candidate whose verification is not finished.

The body must also contain this complete landing record, one row, completed after the merge:

| Pipeline-tested head | Landed squash commit |
| --- | --- |
| `<full-sha>` | `<full-sha>` |

These are two different commits, and the record states both honestly. The pipeline-tested head is the exact combined head the delivery process proved. The landed squash commit is the commit the merge itself produced on the default branch, read from the forge rather than inferred, because a pull request head that exists is not evidence that it landed.
Land the combined pull request through `bin/fm-pr-merge.sh` under the project's own landing shape; its squash default is correct wherever the project's contract makes every commit on its default branch a squash merge. `--merge` remains available but is not prescribed here.
Every applicable binding command must succeed, and the completed constituent records, join-review table, and landing table stay in the combined pull request body as the delivery record.
EOF
  if [ "$mode" = local-only ]; then
    cat <<'EOF'
A local-only task cannot own a combined pull request; report the mismatch and stop until firstmate supplies a PR-based delivery mode.
EOF
  fi
}

fm_dod_block() {  # <mode> <task-id> <task-record> [batch-owner] [trusted-project-root]
  local mode=$1 id=$2 task_record=$3 batch_owner=${4:-} project_root=${5:-}
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
EOF
      fm_integration_batch_dod_block "$mode" "$batch_owner"
      fm_dod_evidence_rules_block pr
      cat <<EOF
Determine Document correction from the installed, supported implementation capability, never from a historical label. Direct-PR mode uses the supported custody-preserving manual repair path. The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed. That record names the changed source, regenerated derived documents, and final-head proof.
Before you push, pass this delivery preflight:
EOF
      fm_dod_delivery_preflight_block "$id" "$task_record"
      cat <<EOF
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
EOF
      fm_integration_batch_dod_block "$mode" "$batch_owner"
      fm_dod_evidence_rules_block local
      cat <<EOF
Before you report it ready, pass this delivery preflight:
EOF
      fm_dod_delivery_preflight_block "$id" "$task_record"
      cat <<EOF
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The branch is prepared when committed on your branch; being prepared is not the same as the task being done.
Before you hand the branch to validation, pass this delivery preflight:
EOF
      fm_dod_delivery_preflight_block "$id" "$task_record"
      fm_integration_batch_dod_block "$mode" "$batch_owner"
      cat <<EOF
When you believe it is prepared, append \`working: prepared - {summary}\` to the status file and stop (\`prepared:\` is not a recognized status verb in bin/fm-classify-lib.sh, so \`working:\` carries it here).
EOF
      if [ -z "$batch_owner" ]; then
        cat <<'EOF'
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
      fi
      cat <<EOF

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When a spawned worker's launch overlay supplies a source-revision-bound \`run-validation\` command, start the run only through that exact command: it renders the real \`--intent\` from the effective brief and refuses a stale launch package before no-mistakes starts.
That command also refuses and starts no run while an active no-mistakes run holds your branch at a head other than your current HEAD, or when \`no-mistakes axi status\` cannot be read: if replacing that run is authorized, abort it with the supported \`no-mistakes axi abort\`, confirm through \`no-mistakes axi status\` that it stopped, follow its \`branch_sync.next_action\`, then rerun the same command.
A branch whose pushed PR head has diverged from local HEAD is reconciled by merge, never rebase, before a run, and run-validation refuses otherwise.
When starting no-mistakes from a current subsection brief, pass \`--intent\` as separately attributed labeled parts in one string: \`Captain intent:\`, \`Firstmate implementation context:\`, and, when this brief carries a Proof bar section, \`Agreed proof contract:\`. The source-revision-bound consumer renders these parts from the effective brief; no one part substitutes for another.
Build the \`Captain intent:\` part from this brief's \`## Captain's intent\` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled \`Captain:\`, \`Captain's words:\`, \`Captain's ask:\`, or \`Captain's intent:\`; never copy its mixed \`# Task\` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs in the \`Captain intent:\` part.
For a current subsection brief, the source-revision-bound consumer builds the \`Firstmate implementation context:\` part from the complete \`## Firstmate spec\` subsection. A legacy brief without that subsection carries no separately invented implementation context.
Build the \`Agreed proof contract:\` part per the Proof bar section's own instruction, when this brief carries one: copy that entire Proof bar section, filled in as you completed it, verbatim. A current subsection brief with no Proof bar section still carries its distinct Captain intent and Firstmate implementation context parts; a legacy brief carries only the labeled parts its authoritative source actually provides.
The complete labeled input must be self-sufficient with the codebase while retaining those authority boundaries: it must let a reader reconstruct roughly the same specification without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into the \`Captain intent:\` part in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.
The PR body is pipeline output only: never run \`gh pr edit\` or \`gh-axi pr edit\` on it, and required body content goes through the run's intent, never a hand-edit.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

Rule F: your \`done: PR {url} checks green\` report requires check conclusions verified at the exact current head sha of the PR branch, never a conclusion recorded against an earlier or stale head.
If the branch moved after checks last ran, confirm CI reran and passed at the new head before reporting done; per rule 9, a red result at a stale head is never re-run as a shortcut past that.

EOF
      fm_dod_evidence_rules_block pr
      fm_dod_document_instruction_block "$project_root"
      cat <<EOF
After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
\`done:\` means checks green at the exact head; it is never used for the pre-validation \`working: prepared\` handoff above.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}

# fm_batch_owner_record_subsection <combined-pr-url> <designated-date>
# <pr-backed-items> <pr-less-items> <join-items> [landing-tested] [landing-commit]
# prints the "## Combined candidate record (integration batch)" subsection body
# (no leading blank line; the caller inserts one). Each *-items argument is zero
# or more newline-separated rows, each row's fields "|"-delimited in the same
# order as that row's table below; an empty items argument omits that table.
# The table shapes are byte-identical to the ones fm_integration_batch_dod_block
# renders as an unfilled template, so a worker's later /no-mistakes intent
# (fm_brief_validation_intent) carries the real values through the Proof bar
# without a second, drifting copy of the same header row.
fm_batch_owner_record_subsection() {  # <combined-pr> <designated-date> <pr-backed> <pr-less> <joins> [landing-tested] [landing-commit]
  local combined_pr=$1 designated=$2 pr_backed=$3 pr_less=$4 joins=$5 landing_tested=${6:-} landing_commit=${7:-}
  local bt='`'
  echo '## Combined candidate record (integration batch)'
  printf 'Firstmate designated this task on %s as the integration owner of one combined candidate, under the captain'"'"'s recovery instruction to choose compatible batches before unnecessary constituent pipelines, review their joins, and verify the final combined candidate.\n' "$designated"
  printf 'The combined pull request is %s.\n' "$combined_pr"
  echo 'Its body must carry the tables below verbatim, and they reach it only through this run'"'"'s intent, never through a pull-request edit.'

  if [ -n "$pr_backed" ]; then
    echo
    echo '| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |'
    echo '| --- | --- | --- | --- | --- |'
    printf '%s\n' "$pr_backed" | while IFS='|' read -r task branch head prurl; do
      [ -n "$task" ] || continue
      printf "| %s%s%s | %s%s%s | %s%s%s | %s%s%s | %sClosed as superseded; not merged.%s |\\n" \
        "$bt" "$task" "$bt" "$bt" "$branch" "$bt" "$bt" "$head" "$bt" "$bt" "$prurl" "$bt" "$bt" "$bt"
    done
  fi

  if [ -n "$pr_less" ]; then
    echo
    echo '| PR-less constituent task | Branch | Exact reviewed head | Disposition |'
    echo '| --- | --- | --- | --- |'
    printf '%s\n' "$pr_less" | while IFS='|' read -r task branch head; do
      [ -n "$task" ] || continue
      printf "| %s%s%s | %s%s%s | %s%s%s | %sNo original pull request.%s |\\n" \
        "$bt" "$task" "$bt" "$bt" "$branch" "$bt" "$bt" "$head" "$bt" "$bt" "$bt"
    done
  fi

  echo
  echo '| Constituent task | Changes missing from the candidate | Deliberate replacements | Join repairs |'
  echo '| --- | --- | --- | --- |'
  printf '%s\n' "$joins" | while IFS='|' read -r task missing replacements repairs; do
    [ -n "$task" ] || continue
    printf "| %s%s%s | %s | %s | %s |\\n" "$bt" "$task" "$bt" "$missing" "$replacements" "$repairs"
  done

  echo
  echo '| Pipeline-tested head | Landed squash commit |'
  echo '| --- | --- |'
  printf "| %s%s%s | %s%s%s |\\n" \
    "$bt" "${landing_tested:-<full-sha>}" "$bt" "$bt" "${landing_commit:-<full-sha>}" "$bt"
}

# fm_dod_append_batch_owner_record <brief> <combined-pr> <designated-date>
# <runner> <pr-backed-items> <pr-less-items> <join-items> [landing-tested]
# [landing-commit] inserts fm_batch_owner_record_subsection's output at the end
# of the brief's "# Proof bar" section (immediately before the next top-level
# heading, or at end of file when none follows) and prints the refreshed
# revision-bound run-validation command for the rewritten brief. This is the
# supported path for a task Firstmate designates as an integration batch owner
# after that brief was already dispatched: fm_integration_batch_dod_block's own
# owner-side "## Conditional integration-batch definition of done" template
# stays unfilled prose, and this is what turns it into the worker's real,
# revision-bound constituent record without a hand-edit.
fm_dod_append_batch_owner_record() {  # <brief> <combined-pr> <designated-date> <runner> <pr-backed> <pr-less> <joins> [landing-tested] [landing-commit]
  local brief=$1 combined_pr=$2 designated=$3 runner=$4 pr_backed=$5 pr_less=$6 joins=$7
  local landing_tested=${8:-} landing_commit=${9:-}
  local subsection tmp revision
  [ -f "$brief" ] && [ ! -L "$brief" ] && [ -r "$brief" ] && [ -w "$brief" ] || {
    echo "error: brief is not a writable regular file: $brief" >&2
    return 1
  }
  fm_brief_heading_present "$brief" "# Proof bar" || {
    echo "error: brief has no # Proof bar section to carry the batch-owner record: $brief" >&2
    return 1
  }
  fm_brief_heading_present "$brief" "## Combined candidate record (integration batch)" && {
    echo "error: brief already carries a Combined candidate record subsection: $brief" >&2
    return 1
  }
  [ -n "$pr_backed" ] || [ -n "$pr_less" ] || {
    echo "error: render-batch-owner-record requires at least one --pr-backed or --pr-less row" >&2
    return 1
  }
  [ -n "$joins" ] || {
    echo "error: render-batch-owner-record requires at least one --join row" >&2
    return 1
  }

  subsection=$(fm_batch_owner_record_subsection "$combined_pr" "$designated" "$pr_backed" "$pr_less" "$joins" "$landing_tested" "$landing_commit") || return 1

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-brief-batch-record.XXXXXX") || {
    echo "error: cannot stage the updated brief" >&2
    return 1
  }
  if ! printf '%s\n' "$subsection" | awk -v brief="$brief" '
    BEGIN {
      while ((getline line < brief) > 0) { n++; src[n] = line }
      close(brief)
    }
    { m++; sub_lines[m] = $0 }
    END {
      seen_proof = 0
      inserted = 0
      for (i = 1; i <= n; i++) {
        line = src[i]
        if (!inserted && seen_proof && line ~ /^# / && line != "# Proof bar") {
          print ""
          for (j = 1; j <= m; j++) print sub_lines[j]
          print ""
          inserted = 1
        }
        print line
        if (line == "# Proof bar") seen_proof = 1
      }
      if (!inserted) {
        print ""
        for (j = 1; j <= m; j++) print sub_lines[j]
      }
    }
  ' > "$tmp"; then
    rm -f -- "$tmp"
    echo "error: cannot render the updated brief" >&2
    return 1
  fi
  mv -- "$tmp" "$brief" || {
    rm -f -- "$tmp"
    echo "error: cannot write the updated brief: $brief" >&2
    return 1
  }

  revision=$(fm_brief_source_revision "$brief") || {
    echo "error: cannot compute the refreshed brief revision: $brief" >&2
    return 1
  }
  printf 'Refreshed revision-bound run-validation command:\n'
  printf '    %s run-validation --brief %s --expect-revision %s\n' \
    "$(fm_dod_shell_quote "$runner")" "$(fm_dod_shell_quote "$brief")" "$(fm_dod_shell_quote "$revision")"
}

fm_dod_cli() {
  local command=${1:-} brief='' expected='' proof=''
  [ -n "$command" ] || {
    echo "usage: fm-dod-lib.sh run-validation --brief FILE --expect-revision sha256:HEX [-- AXI-RUN-ARGS...]" >&2
    echo "       fm-dod-lib.sh render-batch-owner-record --brief FILE --combined-pr URL --designated DATE --runner RUNNER [--pr-backed 'task|branch|head|pr-url']... [--pr-less 'task|branch|head']... --join 'task|missing|replacements|repairs' [...] [--landing-tested SHA] [--landing-commit SHA]" >&2
    echo "       fm-dod-lib.sh record-document-correction-capability --proof ACCEPTED-PROOF-FILE" >&2
    return 2
  }
  shift
  case "$command" in
    record-document-correction-capability)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --proof)
            [ "$#" -ge 2 ] || { echo "error: --proof requires a value" >&2; return 2; }
            proof=$2
            shift 2
            ;;
          *)
            echo "error: unknown record-document-correction-capability argument: $1" >&2
            return 2
            ;;
        esac
      done
      [ -n "$proof" ] || { echo "error: record-document-correction-capability requires --proof" >&2; return 2; }
      fm_dod_record_document_correction_capability "$proof"
      ;;
    run-validation)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --brief)
            [ "$#" -ge 2 ] || { echo "error: --brief requires a value" >&2; return 2; }
            brief=$2
            shift 2
            ;;
          --expect-revision)
            [ "$#" -ge 2 ] || { echo "error: --expect-revision requires a value" >&2; return 2; }
            expected=$2
            shift 2
            ;;
          --)
            shift
            break
            ;;
          *)
            echo "error: unknown run-validation argument: $1" >&2
            return 2
            ;;
        esac
      done
      [ -n "$brief" ] || { echo "error: run-validation requires --brief" >&2; return 2; }
      [ -n "$expected" ] || { echo "error: run-validation requires --expect-revision" >&2; return 2; }
      fm_dod_run_validation "$brief" "$expected" "$@"
      ;;
    render-batch-owner-record)
      local combined_pr='' designated='' runner='' pr_backed='' pr_less='' joins='' landing_tested='' landing_commit='' nl
      printf -v nl '\n'
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --brief)
            [ "$#" -ge 2 ] || { echo "error: --brief requires a value" >&2; return 2; }
            brief=$2; shift 2 ;;
          --combined-pr)
            [ "$#" -ge 2 ] || { echo "error: --combined-pr requires a value" >&2; return 2; }
            combined_pr=$2; shift 2 ;;
          --designated)
            [ "$#" -ge 2 ] || { echo "error: --designated requires a value" >&2; return 2; }
            designated=$2; shift 2 ;;
          --runner)
            [ "$#" -ge 2 ] || { echo "error: --runner requires a value" >&2; return 2; }
            runner=$2; shift 2 ;;
          --pr-backed)
            [ "$#" -ge 2 ] || { echo "error: --pr-backed requires a value" >&2; return 2; }
            pr_backed="${pr_backed:+$pr_backed$nl}$2"; shift 2 ;;
          --pr-less)
            [ "$#" -ge 2 ] || { echo "error: --pr-less requires a value" >&2; return 2; }
            pr_less="${pr_less:+$pr_less$nl}$2"; shift 2 ;;
          --join)
            [ "$#" -ge 2 ] || { echo "error: --join requires a value" >&2; return 2; }
            joins="${joins:+$joins$nl}$2"; shift 2 ;;
          --landing-tested)
            [ "$#" -ge 2 ] || { echo "error: --landing-tested requires a value" >&2; return 2; }
            landing_tested=$2; shift 2 ;;
          --landing-commit)
            [ "$#" -ge 2 ] || { echo "error: --landing-commit requires a value" >&2; return 2; }
            landing_commit=$2; shift 2 ;;
          *)
            echo "error: unknown render-batch-owner-record argument: $1" >&2
            return 2
            ;;
        esac
      done
      [ -n "$brief" ] || { echo "error: render-batch-owner-record requires --brief" >&2; return 2; }
      [ -n "$combined_pr" ] || { echo "error: render-batch-owner-record requires --combined-pr" >&2; return 2; }
      [ -n "$designated" ] || { echo "error: render-batch-owner-record requires --designated" >&2; return 2; }
      [ -n "$runner" ] || { echo "error: render-batch-owner-record requires --runner" >&2; return 2; }
      fm_dod_append_batch_owner_record "$brief" "$combined_pr" "$designated" "$runner" \
        "$pr_backed" "$pr_less" "$joins" "$landing_tested" "$landing_commit"
      ;;
    *)
      echo "error: unknown fm-dod-lib command: $command" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -eu
  fm_dod_cli "$@"
fi
