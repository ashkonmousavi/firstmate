# Task prep: prep-surgical

## Tier
<!-- Answer all three. UI wiring yes, or Q1 yes: tier 2, every numbered section below. Q1 no, Q2 yes: tier 1, sections 1, 4, 6, 8 and 11 only - delete the rest. All no: retain tier 1 sections. A complete surgical certificate replaces numbered sections. Both formats require Author checks and Expected outcomes and how to check each; no separate prep review is required. -->
- Q1 does this change alter what a user sees or can do: no
Reason: No product screen or user action changes.
- Q2 does this change touch a shared module or a contract: no
Reason: The isolated certificate names only one file.
- UI wiring: no, operator-facing document admission only.
<!-- UI wiring answers `yes, <the step and control the user meets>` or `no, <why the user never meets this change>`. A change that lets a user configure or choose something is always yes, and a yes is tier 2 whatever Q1 and Q2 say. -->
- Preparation format: surgical

## Author checks

<!-- Quote relevant rulings and their source, or give reasoned n/a for no additional ruling; state task intent here when surgical, otherwise in section 1. -->
- Captain rulings: Intent: validate the prep and generated-brief interface in a disposable home.

<!-- Before marking ready and again before dispatch, compare the item as filed with current main, landed and open changes, redesigns, root-cause reports, decisions and newer related items. Record the check time, inspected base and sources, changed assumptions, and remaining work. Begin with proceed: only when the work is still needed and its dependencies permit dispatch; otherwise record refresh:, covered:, superseded: or blocked: and return it to its existing owner. Refresh only the affected preparation. -->
- Still valid: proceed: checked target b4f967e6 against base 24be0cf9 and related delivery records on 2026-10-04; this validation is still needed and no dependency blocks it.

<!-- For a defect, name the reproduced shared cause, confirmed and suspected affected uses, existing repair owner and root-cause evidence. List related bug/report/backlog IDs with closes or remains open, each linked to an outcome row and its required evidence class; closure waits for that evidence. Record none found with the searched sources when appropriate. For other work, state that it is not a defect and name related work checked. Related symptoms alone never authorize a broader repair. -->
- Siblings named: Not a defect; searched the isolated backlog and generated delivery records, none found; no broader repair authorized.

<!-- For UI work name the exact screen, region and project map/design reference; otherwise give reasoned n/a. -->
- Screen and region: n/a: command and Markdown output only.

<!-- For each planned behavioral test name the public seam, failing setup or mutation, exact expected failure and RED evidence to record before passing code; never invent an observed result; for each new or changed high-risk test, name the user-visible outcome, the independent source of its expected answer, the real production boundary it exercises, and one realistic fault witness that makes it fail; record baseline pass -> injected fault fails -> restored pass with the command; if no executable test applies, give the reason and alternative check. -->
- Red-first proof: Call fm_prep_unfilled_reason after blanking each required field; expect exit 0 naming the field; restore complete bytes and expect empty output with exit 1.

<!-- For each calculated assertion give fixture inputs, recomputation command and derived expected value; otherwise give reasoned n/a. -->
- Fixture arithmetic: n/a: no calculated result.

<!-- Trace source to consumer with paths and command/output or direct tracing evidence of reachability; otherwise give reasoned n/a. -->
- Data path reachability: bin/fm-brief.sh --prep writes data/task/prep.md; fm_prep_unfilled_reason reads that exact generated record.

<!-- Tie each proposed behavior to the quoted task intent and state the exclusions. -->
- Scope only as asked: Exercise preparation admission and generated walk guidance only; fleet lifecycle and private operator records excluded.

<!-- Name the exact focused and final validation commands, pinned runtime and required setup, changed-file/test mapping, known base failures or unmeasured baseline, and each execution owner. Record measured or prior timings against the applicable step budget, or unknown with the first bounded measurement. Name dependency/base integration and remaining acceptance owners; for walks include actor, candidate, data and verified diagnostic access. A missing resource blocks its dependent step, never becomes a pass; use existing admission and recovery owners rather than adding a local policy. -->
- Validation route: python3 drive-public-interfaces.py for focused commands; Bash 5 isolated home; baseline unmeasured, first bounded run now; test phase owns execution and outer executor owns final CI acceptance.

<!-- Name the exact bash command sourcing bin/fm-dod-lib.sh and calling fm_prep_unfilled_reason on this record; run it on final bytes before handoff and paste the actual command, empty output and raw exit 1 into the handoff; reason with raw exit 0 refuses; execution evidence belongs in the handoff, not a recursive pass receipt here. -->
- Author gate check: bash -c source bin/fm-dod-lib.sh then fm_prep_unfilled_reason on this final prep; handoff retains the actual empty output and raw exit 1.

## Expected outcomes and how to check each
<!-- Write at least one substantive row with a stable outcome ID. For a user journey, state what the person expects to accomplish in their words; name the starting actor/state, user actions through the final visible or reopened result, and the independent expected answer or source. Put the environment, evidence class and execution owner in Where and how to check. Internal tooling may use its operator-facing command and result. Builders and verifiers record actual observations and evidence against these IDs in the existing task report or delivery evidence, never as invented results in this plan. Every cell is required; n/a and examples alone are not answers. -->
| Outcome | Exact observable result | Where and how to check | Expected value |
| --- | --- | --- | --- |
| O1: A researcher opens the assigned study, saves the comparison and reopens it | The researcher starting from the study page selects both candidates, saves their comparison, returns home and reopens the same saved comparison with both candidates retained. | Execution owner: test phase; disposable local home; fixture evidence class; inspect generated prep and accepted-spec overlay, then cite actual observation in the existing evidence directory. | The independently requested task is to retain both candidates after reopen; actual walked observation belongs in delivery evidence, with permitted console and network diagnosis on failure. |

## Certainty
Every answer must be exactly yes with concrete evidence. Any no, unsure or incomplete answer requires full prep: delete the Preparation format line and answer every section the tier requires.

- C1 Exact changed files and line locations are known: yes
Evidence: bin/owned.sh:12 inspected; lookup found no outside callers; no stored data, security, permission, money, install or server changes; cause reproduced and one focused regression covers the entire change.
<!-- File:line targets at the inspected base. -->

- C2 Impact lookup finds no caller outside the change and no shared module or contract: yes
Evidence: bin/owned.sh:12 inspected; lookup found no outside callers; no stored data, security, permission, money, install or server changes; cause reproduced and one focused regression covers the entire change.
<!-- Actual lookup command and result, with source path traced; unknown is not empty. -->

- C3 Stored data, security, permissions, money, install and server paths are untouched: yes
Evidence: bin/owned.sh:12 inspected; lookup found no outside callers; no stored data, security, permission, money, install or server changes; cause reproduced and one focused regression covers the entire change.
<!-- Scope reason covering every exclusion. -->

- C4 The cause and the complete fix are known: yes
Evidence: bin/owned.sh:12 inspected; lookup found no outside callers; no stored data, security, permission, money, install or server changes; cause reproduced and one focused regression covers the entire change.
<!-- Reproduced cause and concrete fix. -->

- C5 One focused regression covers the entire changed behaviour: yes
Evidence: bin/owned.sh:12 inspected; lookup found no outside callers; no stored data, security, permission, money, install or server changes; cause reproduced and one focused regression covers the entire change.
<!-- Executable test seam and red-first reproduction. -->
