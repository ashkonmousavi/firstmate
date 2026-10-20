# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router's detection and safety sections for static crew and secondmate harness resolution and all explicit overrides.
`config/crew-dispatch.json` can override that static default for one crewmate or scout with concrete harness, model, and effort axes.
Follow "Intake routing" below for the resolver and selection-mode routing after establishing harness and provider facts here.
When the opt-in `bin/fm-dispatch-resolve.sh` is on, `docs/configuration.md` "Typed dispatch resolution" owns how its answer feeds that routing.

`../secondmate-provisioning/SKILL.md` owns inherited local material.
Its harness consequence is that a secondmate's workers receive literal `config/crew-harness` and `config/crew-dispatch.json`, while the primary-only `config/secondmate-harness` is never inherited because secondmates do not spawn secondmates.
A concrete crew value such as `codex` carries that runtime into the secondmate home.
Unset or `default` carries no concrete value, so its workers use that home's own or detected harness rather than the primary's effective crew harness.
The inherited dispatch file applies the same best-fit profiles there.

## Intake routing

`AGENTS.md` section 4 keeps the always-loaded dispatch boundary and points here at every crewmate or scout intake.

Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Firstmate alone chooses the matching rule; resolve its profile object or array with `bin/fm-dispatch-select.sh` under the selection contract in `docs/configuration.md` ("Crew dispatch profiles").
Pass that rule to `fm-spawn` as `--dispatch-rule` (omit it for `default`); spawn refuses a ship or scout harness, model, and effort that match none of that rule's candidate profiles (with no configured `default`, the static crewmate harness passes for `default`) unless `data/<id>/dispatch-override` records an explicit captain override.
A selected Grok Bot target is never spawned; send it through `bin/fm-grok-bot-dispatch.sh` under that same section's Grok Bot contract.
Ordered selection is the default intake: configured list order wins unless a candidate is unavailable; quota-balanced selection applies only where `select` explicitly requests it.
Supply concrete unavailability facts and retain the selector's choice and skip reasons; if every candidate is unavailable, stop and report it rather than falling through to another rule.
Establish model support and provider family from that harness's own authoritative catalog, then apply the [account and scope matching rules in `quota-array-dispatch`](../../../quota-array-dispatch/SKILL.md#1-eligibility).
Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is disclosed uncertainty that keeps a candidate eligible, never a credential or login escalation.
Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupported or proof that the credential selected for that surface is unusable; never infer a credential store, provider family, or quota mapping from a harness, model, or source name, and never launch another harness's CLI to judge a candidate.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
`quota-axi` owns how model or product windows relate to bounding account windows and remains data-only.
Load `quota-array-dispatch` only for an explicit `quota-balanced` rule; that skill owns its TOON-first spendPriority procedure, every-candidate accounting, strongest-reasoning protection, and tie escalation.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight; on `clear` take its matched rule and resolve that rule's profile as above, while `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").

## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate, while scripts receive concrete axes.

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered delivery signals, and the `empty` / `pending` / `pending-unproven` / `unknown` decision belong only to `../../../bin/fm-composer-lib.sh`.
Tool references record empirical knowledge for those executable owners.

## Adapter verification

For an approved new adapter check, use the spawn owner's raw-launch escape hatch only for a trivial supervised task.
Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, busy state in `../../../bin/fm-busy-lib.sh`, shared composer behavior in `../../../bin/fm-composer-lib.sh`, lifecycle in `../../../bin/fm-control-lib.sh`, and tmux liveness in `../../../bin/backends/tmux.sh` when secondmate use is supported.
Also verify primary integration through `references/common/primary-hooks.md`, model discovery through `references/common/model-and-effort.md`, and one tool record.
A value remains unreachable until its executable owner, portable regression, applicable credentialed live guard, and verification record land together.
`../firstmate-coding-guidelines/SKILL.md` owns harness-dependent proof.
