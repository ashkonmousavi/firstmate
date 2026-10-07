---
name: retro
description: >-
  When the captain invokes /retro, $retro, or asks for a retro, bring the written rules and the sleeping work back in line with what the period taught, on every machine, without making the rulebook longer.
  Route each lesson to one owner at the decision point, cut rules that cost time, wake every sleeping item to its next step, reconcile disagreeing records, propagate to all mates, and report with the AGENTS.md line count before and after.
user-invocable: true
metadata:
  internal: true
---

# retro

After a push or any hard period, bring the written rules and the sleeping work back in line with what was learned, on every machine, without making the rulebook longer.
This skill writes only through the existing Firstmate ownership and write boundaries: shared tracked material through the PR path per `AGENTS.md` section 1, private records directly, mates through `secondmate-provisioning`.
Load `firstmate-coding-guidelines` before touching any shared tracked file; its placement tree and one-owner rule are the method here.

## What it covers

Firstmate's `AGENTS.md`, `data/captain.md`, `data/captain-shared.md`, `data/learnings.md`, hooks, skills, dispatch config, and brief templates.
Every second mate's inherited copies, and every machine (PC, server, laptop) read from its own files, never assumed from the PC.
Project `AGENTS.md` files are out of scope: they change only to correct text that is factually wrong, through a crewmate PR, never to add knowledge, because every line taxes every agent session of that project.

## Rules

Each lesson from the period becomes exactly one change at the point where the decision is made (a check, a brief line, a registry field, a skill, a hook), and the same lesson is removed from wherever else it was written, so nothing is said twice.
A rule that cost time in the period with no saved hour it can show is cut or made advisory; prefer removing a rule to adding one.
For fixes outside the [class-fix rule](../diagnostic-reasoning/SKILL.md#class-fix), review and test depth stays in proportion: a quick or surgical fix that a live journey walk or another checkpoint already tests gets no extra review or test round, and a rule that adds one is cut.
`AGENTS.md` may only shrink or stay the same length: new detail goes into a skill or hook that `AGENTS.md` points to with one line, and any added line replaces one.
Every sleeping item is woken and pushed to its next step or closed, on every machine: held, paused, done but not landed, landed but not installed, ready with no lane, or waiting on an answer that already exists.
Records that disagree (backlog against PR state, status against the served commit, two homes with different copies) are reconciled to the live truth.
The result is propagated to all mates and verified byte-identical where it should be.

## Method

Read the period's status logs, the captain file and the learnings once, write conclusions, and never re-read whole transcripts, because a retro that re-reads sessions costs more than the lessons save.
For each lesson, run the placement tree in `firstmate-coding-guidelines` and record where it now lives and what was removed.
For each sleeping item, use the owning lifecycle: `ship-landing` for landed work, `captain-hold-lifecycle` for held calls, `stuck-crewmate-recovery` for dead endpoints, the parent channel for a mate's work.
Propagate through the guarded fleet update and inherited-material paths, never by hand-copying files between homes.

## Report

Follow `AGENTS.md` section 9 and Captain Signal v2.
List each lesson, where it now lives, what was removed, the `AGENTS.md` line count before and after, every woken item with its next step, and "in effect on all machines" with the verification that proved it.
Keep it under 40 lines with each full `https://` link on its own line.
