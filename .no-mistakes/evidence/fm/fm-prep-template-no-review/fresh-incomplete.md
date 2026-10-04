# Task prep: incomplete

## Tier
<!-- Answer all three. UI wiring yes, or Q1 yes: tier 2, every numbered section below. Q1 no, Q2 yes: tier 1, sections 1, 4, 6, 8 and 11 only - delete the rest. All no: retain tier 1 sections. A complete surgical certificate replaces numbered sections. Both formats require Author checks and Expected outcomes and how to check each; no separate prep review is required. -->
- Q1 does this change alter what a user sees or can do: {Q1}
- Q2 does this change touch a shared module or a contract: {Q2}
- UI wiring: {UI_WIRING}
<!-- UI wiring answers `yes, <the step and control the user meets>` or `no, <why the user never meets this change>`. A change that lets a user configure or choose something is always yes, and a yes is tier 2 whatever Q1 and Q2 say. -->

Answer every section your tier requires. One that genuinely does not apply is answered `n/a: <one-line reason>`.
Use primary-source citations (documentation, source code or specification) beside every external fact; choices between options follow the project research-first decision procedure.
This record is the specification beneath the brief: the expected-outcomes table and applicable sections 2 and 11 are the acceptance list for builders and post-implementation verifiers.

## Author checks

<!-- Quote relevant rulings and their source, or give reasoned n/a for no additional ruling; state task intent here when surgical, otherwise in section 1. -->
- Captain rulings: {CAPTAIN_RULINGS}

<!-- For UI work name the exact screen, region and project map/design reference; otherwise give reasoned n/a. -->
- Screen and region: {SCREEN_AND_REGION}

<!-- For each planned behavioral test name the public seam, failing setup or mutation, exact expected failure and RED evidence to record before passing code; never invent an observed result; for each new or changed high-risk test, name the user-visible outcome, the independent source of its expected answer, the real production boundary it exercises, and one realistic fault witness that makes it fail; record baseline pass -> injected fault fails -> restored pass with the command; if no executable test applies, give the reason and alternative check. -->
- Red-first proof: {RED_FIRST_PROOF}

<!-- For each calculated assertion give fixture inputs, recomputation command and derived expected value; otherwise give reasoned n/a. -->
- Fixture arithmetic: {FIXTURE_ARITHMETIC}

<!-- Trace source to consumer with paths and command/output or direct tracing evidence of reachability; otherwise give reasoned n/a. -->
- Data path reachability: {DATA_PATH_REACHABILITY}

<!-- Tie each proposed behavior to the quoted task intent and state the exclusions. -->
- Scope only as asked: {SCOPE_ONLY_AS_ASKED}

<!-- Name the exact bash command sourcing bin/fm-dod-lib.sh and calling fm_prep_unfilled_reason on this record; run it on final bytes before handoff and paste the actual command, empty output and raw exit 1 into the handoff; reason with raw exit 0 refuses; execution evidence belongs in the handoff, not a recursive pass receipt here. -->
- Author gate check: {AUTHOR_GATE_CHECK}

## Expected outcomes and how to check each
<!-- The author writes at least one substantive row; builders and post-implementation verifiers check every row against the same explicit result, concrete command/public seam or screen and region, and expected value; every cell is required; n/a and examples alone are not answers. -->
| Outcome | Exact observable result | Where and how to check | Expected value |
| --- | --- | --- | --- |
| {OUTCOME} | {OBSERVABLE_RESULT} | {WHERE_AND_HOW} | {EXPECTED_VALUE} |

## 1. Intent and boxes
<!-- tier 1+. The captain's words, and each task item this work completes in the project's own record, verified against the current base with the command used as its instructions require. -->
{INTENT_AND_BOXES}

## 2. Behaviour spec
<!-- tier 2+. Every state (empty, loading, ready, running, refused, failed, terminal), every control and when it is enabled, every action and its result, the copy the user sees, restart and reopen behaviour. -->
{BEHAVIOUR_SPEC}

## 3. UI/UX
<!-- tier 2+. START WITH THE COMPONENT CHECK: for each screen element this lane touches, name the matching component and its path in the project's design system or UI record as its instructions name it. Then which step or screen, the journey walked as the user step by step, what done looks like on screen, responsiveness and accessibility notes. -->
{UI_UX}

## 4. Blast radius
<!-- tier 1+. PASTE TOOL OUTPUT, not prose: the GitNexus impact result (gitnexus impact, or the MCP impact tool, against the ~/.gitnexus clone) for every module touched, and the Serena find_referencing_symbols counts for every symbol whose signature changes; reach for claude-context semantic search only when a name is unknown. -->
{BLAST_RADIUS}

## 5. Data and contracts
<!-- tier 2+. Name the module, its public seams, request/response shapes, versions and migrations; apply the deletion test: where would its complexity move if removed? -->
{DATA_AND_CONTRACTS}

## 6. Tests
<!-- tier 1+. Name public seams (interfaces, never internals), red-first order and proof owed (direct proof, integrated journey or stage acceptance), journey tests, mutation witnesses, existing tests that change and why, the changed-file/test-module mapping, tests requiring a real installation, and failures already on the base (or unknown when unmeasured). -->
{TESTS}

## 7. Records
<!-- tier 2+. Project task items to complete, verification records, and other records its instructions require; answer the surfaces checklist (agent instructions/skills/tool docs, journeys/user docs, reference/help/changelog, plans, architecture, UI states and tests), each updated or n/a with reason; if a component lands ahead of its consumer, record and clear the pending integration as the project's instructions specify. -->
{RECORDS}

## 8. Out of scope and follow-ups
<!-- tier 1+. What this task deliberately leaves alone and the follow-up work it creates; paste the project's git grep -n 'FINALIZE-AFTER(incomplete)' -- . output and say which markers this task resolves; write any pre-staged value inline as FINALIZE-AFTER(<trigger task>): <what>, and resolve every marker whose trigger has landed. -->
{OUT_OF_SCOPE}

## 9. Risks, dependencies, merge order
<!-- tier 2+. Risks, dependencies, sibling lanes touching the same files, and the order these must land in. -->
{RISKS}

## 10. Demo receipt plan
<!-- tier 2+. Name the evidence class each claim rests on (fixture/synthetic, admitted-data mirror or live deployment), never promoting one into another, and what the worker walks and records before validation, including the project's required visual comparison and states as its instructions name them. -->
{DEMO_RECEIPT}

## 11. Definition of done
<!-- tier 1+. The done criteria, checked line by line against the intent above, with no marker whose trigger has landed. -->
{DEFINITION_OF_DONE}

## 12. Size
<!-- tier 2+. Split by one visible, independently testable behaviour, about 300 changed real lines, excluding tests, docs and generated outputs. Keep tiny fixes bundled; design shared structure first under one integration owner. This is a planning guide, not an automatic threshold. -->
{SIZE}
