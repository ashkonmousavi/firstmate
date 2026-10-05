<!-- Previous preparation example
## Tier
- Q1 does this change alter what a user sees or can do: no
- Q2 does this change touch a shared module or a contract: no
- UI wiring: no, old isolated example.
- Delivery depth: checks + AI review (no-mistakes), old shared example.

-->
# Task prep: commented-full-direct-PR-reader

## Tier
- Delivery depth: checks-only (direct-PR), exercise the declared fixture delivery contract.
<!-- Answer Q1, Q2 and UI wiring, plus Delivery depth below. UI wiring yes, or Q1 yes: tier 2, every numbered section below. Q1 no, Q2 yes: tier 1, sections 1, 4, 6, 8 and 11 only - delete the rest. All no: retain tier 1 sections. A complete surgical certificate replaces numbered sections. Both formats require Author checks and Expected outcomes and how to check each; no separate prep review is required. -->
- Q1 does this change alter what a user sees or can do: no
- Q2 does this change touch a shared module or a contract: no
- UI wiring: no, spawn fixture.
<!-- Delivery depth answers checks-only (direct-PR), <one-line reason> for surgical or low-harm changes; checks + AI review (no-mistakes), <one-line reason> for shared code, money, privacy, permissions, security or uncertainty. The author chooses; neither choice nor reason is prefilled. -->
<!-- UI wiring answers `yes, <the step and control the user meets>` or `no, <why the user never meets this change>`. A change that lets a user configure or choose something is always yes, and a yes is tier 2 whatever Q1 and Q2 say. -->

Answer every section your tier requires. One that genuinely does not apply is answered `n/a: <one-line reason>`.
Use primary-source citations (documentation, source code or specification) beside every external fact; choices between options follow the project research-first decision procedure.
This record is the specification beneath the brief: the expected-outcomes table and applicable sections 2 and 11 are the acceptance list for builders and post-implementation verifiers.

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

## 1. Intent and boxes
<!-- tier 1+. The captain's words, and each task item this work completes in the project's own record, verified against the current base with the command used as its instructions require. -->
Exercise the delivery contract in an isolated fixture.

## 2. Behaviour spec
<!-- tier 2+. Every state (empty, loading, ready, running, refused, failed, terminal), every control and when it is enabled, every action and its result, the copy the user sees, restart and reopen behaviour. -->
n/a: spawn fixture.

## 3. UI/UX
<!-- tier 2+. START WITH THE COMPONENT CHECK: for each screen element this lane touches, name the matching component and its path in the project's design system or UI record as its instructions name it. Then which step or screen, the journey walked as the user step by step, what done looks like on screen, responsiveness and accessibility notes. -->
n/a: spawn fixture.

## 4. Blast radius
<!-- tier 1+. PASTE TOOL OUTPUT, not prose: the GitNexus impact result (gitnexus impact, or the MCP impact tool, against the ~/.gitnexus clone) for every module touched, and the Serena find_referencing_symbols counts for every symbol whose signature changes; reach for claude-context semantic search only when a name is unknown. -->
n/a: spawn fixture.

## 5. Data and contracts
<!-- tier 2+. Name the module, its public seams, request/response shapes, versions and migrations; apply the deletion test: where would its complexity move if removed? -->
n/a: spawn fixture.

## 6. Tests
<!-- tier 1+. Name public seams (interfaces, never internals), red-first order and proof owed (direct proof, integrated journey or stage acceptance), journey tests, mutation witnesses, existing tests that change and why, the changed-file/test-module mapping, tests requiring a real installation, and failures already on the base (or unknown when unmeasured). -->
n/a: spawn fixture.

## 7. Records
<!-- tier 2+. Project task items to complete, verification records, and other records its instructions require; answer the surfaces checklist (agent instructions/skills/tool docs, journeys/user docs, reference/help/changelog, plans, architecture, UI states and tests), each updated or n/a with reason; if a component lands ahead of its consumer, record and clear the pending integration as the project's instructions specify. -->
n/a: spawn fixture.

## 8. Out of scope and follow-ups
<!-- tier 1+. What this task deliberately leaves alone and the follow-up work it creates; paste the project's git grep -n 'FINALIZE-AFTER(commented-full-direct-PR-reader)' -- . output and say which markers this task resolves; write any pre-staged value inline as FINALIZE-AFTER(<trigger task>): <what>, and resolve every marker whose trigger has landed. -->
n/a: spawn fixture.

## 9. Risks, dependencies, merge order
<!-- tier 2+. Risks, dependencies, sibling lanes touching the same files, and the order these must land in. -->
n/a: spawn fixture.

## 10. Demo receipt plan
<!-- tier 2+. Name the existing report or delivery-evidence destination for actual results against each outcome ID, the journey execution owner and authorized environment, and the evidence class (fixture/synthetic, admitted-data mirror or live deployment), never promoting one into another; include the project's required visual comparison and states as its instructions name them. -->
n/a: spawn fixture.

## 11. Definition of done
<!-- tier 1+. The done criteria, checked line by line against the intent above, with no marker whose trigger has landed. -->
n/a: spawn fixture.

## 12. Size
<!-- tier 2+. Split by one visible, independently testable behaviour, about 300 changed real lines, excluding tests, docs and generated outputs. Keep tiny fixes bundled; design shared structure first under one integration owner. This is a planning guide, not an automatic threshold. -->
n/a: spawn fixture.
