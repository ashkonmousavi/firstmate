---
name: task-intake
description: >-
  Agent-only reference for preparing a ship or scout task.
  Load before writing a ship or scout preparation record or brief, and before spawning one.
user-invocable: false
metadata:
  internal: true
---

# task-intake

`AGENTS.md` sections 7 and 11 keep the always-loaded intake rules and this skill's load trigger.

## Preparation record

Write the preparation record before the brief with `bin/fm-brief.sh <task-id> --prep [--surgical]`; `bin/fm-dod-lib.sh` owns the common author checks, outcome table, tier completeness and surgical certainty.
The preparation author fills the common checks and explicit expected outcomes, then runs that owner's completeness gate on final bytes and records its actual result in the handoff; separate prep review is optional when explicitly requested.
A ship spawn refuses a task whose preparation record is missing, whose tier header is unanswered, where a section that tier requires is missing, still placeheld, or empty, or whose common checks or outcome table fail the completeness contract in `bin/fm-dod-lib.sh`.
When a secondmate already filled `data/nav-preps/<id>.md`, install that sheet into this home's `data/<id>/prep.md` with `bin/fm-prep-install.sh` before spawn; an empty local `--prep` scaffold must not hide a filled nav-prep.

## Spawn backlog gate

When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember; a manual-backend home retains the hand-editing contract in `docs/configuration.md`.

## Brief task subsections

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to; never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; a generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
When a step in that spec has a tool that clearly serves it, name that tool for that step rather than leaving the worker to guess or appending a bare list of available tools.
`bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
