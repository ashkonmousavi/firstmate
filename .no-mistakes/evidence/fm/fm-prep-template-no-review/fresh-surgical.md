# Task prep: surgical

## Tier
<!-- Answer all three. UI wiring yes, or Q1 yes: tier 2, every numbered section below. Q1 no, Q2 yes: tier 1, sections 1, 4, 6, 8 and 11 only - delete the rest. All no: retain tier 1 sections. A complete surgical certificate replaces numbered sections. Both formats require Author checks and Expected outcomes and how to check each; no separate prep review is required. -->
- Q1 does this change alter what a user sees or can do: {Q1}
Reason: {Q1_REASON}
- Q2 does this change touch a shared module or a contract: {Q2}
Reason: {Q2_REASON}
- UI wiring: {UI_WIRING}
<!-- UI wiring answers `yes, <the step and control the user meets>` or `no, <why the user never meets this change>`. A change that lets a user configure or choose something is always yes, and a yes is tier 2 whatever Q1 and Q2 say. -->
- Preparation format: surgical

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

## Certainty
Every answer must be exactly yes with concrete evidence. Any no, unsure or incomplete answer requires full prep: delete the Preparation format line and answer every section the tier requires.

- C1 Exact changed files and line locations are known: {C1}
Evidence: {C1_EVIDENCE}
<!-- File:line targets at the inspected base. -->

- C2 Impact lookup finds no caller outside the change and no shared module or contract: {C2}
Evidence: {C2_EVIDENCE}
<!-- Actual lookup command and result, with source path traced; unknown is not empty. -->

- C3 Stored data, security, permissions, money, install and server paths are untouched: {C3}
Evidence: {C3_EVIDENCE}
<!-- Scope reason covering every exclusion. -->

- C4 The cause and the complete fix are known: {C4}
Evidence: {C4_EVIDENCE}
<!-- Reproduced cause and concrete fix. -->

- C5 One focused regression covers the entire changed behaviour: {C5}
Evidence: {C5_EVIDENCE}
<!-- Executable test seam and red-first reproduction. -->
