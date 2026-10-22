---
name: ask-user-authority
description: >-
  Single owner of ask-user finding policy.
  Load before deciding any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment and decides any finding that is unambiguous toward the accepted design.
It also decides technical ambiguity, scope disposition, and a repeated-theme correction, records that choice, and reports it.
It escalates to the captain only a finding `AGENTS.md` section 9 reserves.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.
That route is not owner permission.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Decide, record, and report, without asking the captain, when the finding is technical ambiguity, scope disposition, or a repeated-theme correction:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent, when the unsettled part is technical rather than taste
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects: choose with the advisor whether to revert to the minimal fix or change the abstraction
   - a security call that is not a secret or credential
5. Escalate to the captain only when `AGENTS.md` section 9 reserves the ask.
   That set includes taste, a secret or credential, and a destructive or irreversible choice.
   A merge-authority choice stays with the captain under section 7, which this skill does not relax.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task or to ask the captain.

## Recorded decision

When this skill says to decide, record four elements where the work's note will keep them, then report the decision:

1. The original requirement or accepted task criterion.
2. The choice and the alternative that lost.
3. The concrete consequence of the choice.
4. The reason it best serves the accepted intent.

Do not wait for the captain.
Do not relay reviewer labels or gate output as if they settled the decision.

## Captain-facing escalation

Use this only for a finding section 9 reserves.
State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof is scope disposition: firstmate decides, records the choice, and reports it.
- A new finding in the same causal theme is a repeated-theme correction: firstmate chooses with the advisor whether to revert to the minimal fix or change the abstraction, records that choice, and reports it.
- A secret or credential action requires the captain even when it is otherwise within scope.
- Any other security call is firstmate's to decide, record, and report.
- A destructive or irreversible action still requires the captain.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
