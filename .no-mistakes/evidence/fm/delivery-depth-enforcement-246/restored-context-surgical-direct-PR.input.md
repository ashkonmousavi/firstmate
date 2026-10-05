<!-- Previous preparation example
## Tier
- Q1 does this change alter what a user sees or can do: no
- Q2 does this change touch a shared module or a contract: no
- UI wiring: no, old isolated example.
- Delivery depth: checks + AI review (no-mistakes), old shared example.

-->
# Task prep: commented-surgical-direct-PR-local

## Tier
- Delivery depth: checks-only (direct-PR), exercise the declared fixture delivery contract.
<!-- Answer Q1, Q2 and UI wiring, plus Delivery depth below. UI wiring yes, or Q1 yes: tier 2, every numbered section below. Q1 no, Q2 yes: tier 1, sections 1, 4, 6, 8 and 11 only - delete the rest. All no: retain tier 1 sections. A complete surgical certificate replaces numbered sections. Both formats require Author checks and Expected outcomes and how to check each; no separate prep review is required. -->
- Q1 does this change alter what a user sees or can do: yes
Reason: Inspected confined output.
- Q2 does this change touch a shared module or a contract: no
Reason: Inspected confined output.
- UI wiring: no, confined CLI output.
<!-- Delivery depth answers checks-only (direct-PR), <one-line reason> for surgical or low-harm changes; checks + AI review (no-mistakes), <one-line reason> for shared code, money, privacy, permissions, security or uncertainty. The author chooses; neither choice nor reason is prefilled. -->
<!-- UI wiring answers `yes, <the step and control the user meets>` or `no, <why the user never meets this change>`. A change that lets a user configure or choose something is always yes, and a yes is tier 2 whatever Q1 and Q2 say. -->
- Preparation format: surgical

## Author checks

<!-- Quote relevant rulings and their source, or give reasoned n/a for no additional ruling; state task intent here when surgical, otherwise in section 1. -->
- Captain rulings: Intent: exercise delivery admission; ruling: use an isolated fixture (test brief).

<!-- Before marking ready and again before dispatch, compare the item as filed with current main, landed and open changes, redesigns, root-cause reports, decisions and newer related items. Record the check time, inspected base and sources, changed assumptions, and remaining work. Begin with proceed: only when the work is still needed and its dependencies permit dispatch; otherwise record refresh:, covered:, superseded: or blocked: and return it to its existing owner. Refresh only the affected preparation. -->
- Still valid: proceed: inspected fixture base and task sources; delivery admission remains needed with no dependency.

<!-- For a defect, name the reproduced shared cause, confirmed and suspected affected uses, existing repair owner and root-cause evidence. List related bug/report/backlog IDs with closes or remains open, each linked to an outcome row and its required evidence class; closure waits for that evidence. Record none found with the searched sources when appropriate. For other work, state that it is not a defect and name related work checked. Related symptoms alone never authorize a broader repair. -->
- Siblings named: Not a defect; searched fixture task records and delivery owners, none found.

<!-- For UI work name the exact screen, region and project map/design reference; otherwise give reasoned n/a. -->
- Screen and region: n/a: no product screen is changed.

<!-- For each planned behavioral test name the public seam, failing setup or mutation, exact expected failure and RED evidence to record before passing code; never invent an observed result; for each new or changed high-risk test, name the user-visible outcome, the independent source of its expected answer, the real production boundary it exercises, and one realistic fault witness that makes it fail; record baseline pass -> injected fault fails -> restored pass with the command; if no executable test applies, give the reason and alternative check. -->
- Red-first proof: bash tests/fm-task-delivery.test.sh; remove the record; expect a preparation refusal; record observed RED before implementation.

<!-- For each calculated assertion give fixture inputs, recomputation command and derived expected value; otherwise give reasoned n/a. -->
- Fixture arithmetic: n/a: no calculated assertions.

<!-- Trace source to consumer with paths and command/output or direct tracing evidence of reachability; otherwise give reasoned n/a. -->
- Data path reachability: brief --prep writes data/id/prep.md; spawn reads that path; launch rendering is the fixture witness.

<!-- Tie each proposed behavior to the quoted task intent and state the exclusions. -->
- Scope only as asked: Exercise the requested delivery admission only; real endpoints and product changes are outside scope.

<!-- Name the exact focused and final validation commands, pinned runtime and required setup, changed-file/test mapping, known base failures or unmeasured baseline, and each execution owner. Record measured or prior timings against the applicable step budget, or unknown with the first bounded measurement. Name dependency/base integration and remaining acceptance owners; for walks include actor, candidate, data and verified diagnostic access. A missing resource blocks its dependent step, never becomes a pass; use existing admission and recovery owners rather than adding a local policy. -->
- Validation route: bash bin/fm-test-run.sh tests/fm-task-delivery.test.sh; Bash fixture runtime, isolated home, baseline timing unknown; worker measures this bounded run, CI owns final regression.

<!-- Name the exact bash command sourcing bin/fm-dod-lib.sh and calling fm_prep_unfilled_reason on this record; run it on final bytes before handoff and paste the actual command, empty output and raw exit 1 into the handoff; reason with raw exit 0 refuses; execution evidence belongs in the handoff, not a recursive pass receipt here. -->
- Author gate check: bash -c ' . bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1" ' _ data/id/prep.md; run on final bytes before handoff and paste empty output and raw exit 1 (reason with exit 0 refuses).

## Expected outcomes and how to check each
<!-- Write at least one substantive row with a stable outcome ID. For a user journey, state what the person expects to accomplish in their words; name the starting actor/state, user actions through the final visible or reopened result, and the independent expected answer or source. Put the environment, evidence class and execution owner in Where and how to check. Internal tooling may use its operator-facing command and result. Builders and verifiers record actual observations and evidence against these IDs in the existing task report or delivery evidence, never as invented results in this plan. Every cell is required; n/a and examples alone are not answers. -->
| Outcome | Exact observable result | Where and how to check | Expected value |
| --- | --- | --- | --- |
| Delivery admission | Launch brief exists before the refusing backend | bash tests/fm-task-delivery.test.sh; fixture spawn and launch-brief.md | Brief present; no real endpoint created |

## Certainty
Every answer must be exactly yes with concrete evidence. Any no, unsure or incomplete answer requires full prep: delete the Preparation format line and answer every section the tier requires.

- C1 Exact changed files and line locations are known: yes
Evidence: owned.sh:12; callers confined; cause reproduced; regression covers output; no sensitive paths.
<!-- File:line targets at the inspected base. -->

- C2 Impact lookup finds no caller outside the change and no shared module or contract: yes
Evidence: owned.sh:12; callers confined; cause reproduced; regression covers output; no sensitive paths.
<!-- Actual lookup command and result, with source path traced; unknown is not empty. -->

- C3 Stored data, security, permissions, money, install and server paths are untouched: yes
Evidence: owned.sh:12; callers confined; cause reproduced; regression covers output; no sensitive paths.
<!-- Scope reason covering every exclusion. -->

- C4 The cause and the complete fix are known: yes
Evidence: owned.sh:12; callers confined; cause reproduced; regression covers output; no sensitive paths.
<!-- Reproduced cause and concrete fix. -->

- C5 One focused regression covers the entire changed behaviour: yes
Evidence: owned.sh:12; callers confined; cause reproduced; regression covers output; no sensitive paths.
<!-- Executable test seam and red-first reproduction. -->
