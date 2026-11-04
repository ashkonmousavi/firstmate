---
name: harness-adapters
description: Use at every intake and before steering, changing mid-task intent, spawning, recovery, trust handling, harness-specific skill invocation, interrupt, exit, resume, or adapter verification.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Firstmate operations.
Load this router first, then exactly the common reference and one harness reference selected below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Firstmate home, `state/` belongs to that home, and project settings such as `.claude/settings.json` belong to the target project.

## Non-negotiable safety

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names one, use firstmate's own verified runtime for current work, record that the requested runtime is not verified, and report that choice under `../../../AGENTS.md` section 9.
Do not pause current work to ask whether to verify it.

On `unknown`, use that same verified fallback, record the unknown reading, and report it.
Do not guess a harness.
A current captain override beats detection, while a per-task override governs only that dispatch.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never type an interrupt key or exit command through `fm-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.
Muse, Gemini, Devin, Command Code, Polytoken, Cortex, and Kiro are verified only for crewmate and scout work, never a secondmate or primary.

## Detection

`../../../bin/fm-harness.sh` prints firstmate's own harness from verified environment markers and process ancestry, and owns how they combine.
A marker names its harness, but a structural ancestor of a different harness outranks it, because a marker is ordinary environment state a child or a multiplexer can retain while ancestry is what proves who owns the process tree.
Only `FM_PI_HARNESS=pi-signed` at the launch boundary together with `PI_CODING_AGENT=true` selects Pi-signed; shared unmarked launcher ancestry remains Pi.
omp publishes no marker of its own; `FM_OMP_HARNESS=omp` is Firstmate's launch marker and the anchored process name `omp` is its ancestry evidence, as `references/harness/omp.md` records.
`../../../bin/fm-spawn.sh` owns worker marker establishment, while the README launch command owns the signed-primary boundary.
`../../../bin/fm-harness.sh crew` resolves `config/crew-harness`, where absent or `default` means firstmate's own harness.
[`docs/configuration.md`](../../../docs/configuration.md#choose-the-secondmate-harness) owns secondmate pin resolution, including per-mate overrides; [`bin/fm-harness.sh`](../../../bin/fm-harness.sh) owns the resolver commands.
`../../../bin/fm-spawn.sh` re-resolves on every spawn, and an explicit per-spawn argument wins for that spawn.
A new adapter's verified marker and command name must land in `../../../bin/fm-harness.sh`.

## Operation-to-reference matrix

Every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
`default` is the normal scenario when no narrower scenario applies.
Kimi establishes its unsupported primary boundary in its selected harness reference; Muse and Gemini follow Non-negotiable safety above.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land.

```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "secondmate": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-secondmate": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "claude": "references/harness/claude.md",
    "codex": "references/harness/codex.md",
    "opencode": "references/harness/opencode.md",
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "grok": "references/harness/grok.md",
    "kimi": "references/harness/kimi.md",
    "cursor": "references/harness/cursor.md",
    "gemini": "references/harness/gemini.md",
    "muse": "references/harness/muse.md",
    "rovo": "references/harness/rovo.md",
    "omp": "references/harness/omp.md",
    "agy": "references/harness/agy.md",
    "devin": "references/harness/devin.md",
    "commandcode": "references/harness/commandcode.md",
    "polytoken": "references/harness/polytoken.md",
    "cortex": "references/harness/cortex.md",
    "kiro": "references/harness/kiro.md"
  }
}
```

## Dispatch contract

- The verified harnesses are `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `omp`, and `agy`, plus `muse`, `gemini`, `rovo`, `devin`, `commandcode` (Command Code), `polytoken`, `cortex`, and `kiro` for crewmates and scouts only; never dispatch on an unverified adapter.
- If static `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, report it and fall back only to a verified adapter rather than launching it.
- For an exhausted Claude account, the machine's firstmate switches `config/claude-account` and its own secondmate session to the next already signed-in Claude account through the existing checkpoint-and-relaunch route, preserving task state and model class.
- This machine-wide account switch is the only autonomous pin change; a lane relaunch never changes a pin, other pin choices remain the captain's, and a missing signed-in account is reported rather than bypassed.

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Firstmate alone resolves a matched profile array: begin with `quota-axi`'s default TOON at that intake, using the skill's narrow TOON-then-`--json` fallback only for genuine ambiguity, evaluate every configured candidate against that current output, and choose under the skill's `preferred_provider` procedure with inspectable `spendPriority` as the one quota-perspective ranker after its eligibility, reasoning-class, and runway-feasibility gates.
Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, and the spendPriority and runway evidence used in selection; never omit a candidate, guess, fall back silently, or call the result quota-informed without them.
Establish model support and provider family from that harness's own authoritative catalog, then apply the [account and scope matching rules in `quota-array-dispatch`](../quota-array-dispatch/SKILL.md#1-eligibility).
When the home's `config/crew-dispatch.json` declares `"shared_quota": true`, make no quota-axi call and apply no quota gate or ranking: choose by the matched rule's declared profile order and reasoning class (`preferred_provider` still narrows the pool; declared order then picks within it), accounting for every candidate with quota ranking off by home declaration (schema: `docs/configuration.md` "Crew dispatch profiles").
Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is disclosed uncertainty that keeps a candidate eligible, never a credential or login escalation.
Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupported or proof that the credential selected for that surface is unusable; never infer a credential store, provider family, or quota mapping from a harness, model, or source name, and never launch another harness's CLI to judge a candidate.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
Break genuine evidence ties without array-order or harness bias.
`quota-axi` owns how model or product windows relate to bounding account windows and remains data-only.
Load `quota-array-dispatch` before choosing among a matched profile array; that skill is the single owner of the TOON-first spendPriority selection procedure.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn` unless you state a reason to override; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
The [model-and-effort reference](references/common/model-and-effort.md#axes-and-precedence) owns generic effort fallback and precedence; do not add model-specific versions of that policy.

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on a backend that `fm-spawn` validates as spawn-capable; pass an explicit per-spawn `--backend` only under that exact task's own authority, never as later-task precedent (selection contract: [`docs/configuration.md`](../../../docs/configuration.md) "Runtime backend").
A missing dependency, authentication failure, unsupported backend, or version refusal is a blocker; never silently retry on another backend.

## Dispatch and supervision handoff

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in this skill's [Dispatch contract](#dispatch-contract).
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember; a manual-backend home retains the hand-editing contract in `docs/configuration.md`.
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a constant doorbell line, with the watcher re-ringing an unacknowledged message and escalating a stuck one (`bin/fm-task-inbox-lib.sh`; `bin/fm-send.sh` owns the typed-plane carve-outs).
A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication (`bin/fm-send.sh` header).
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `bin/fm-send.sh` header).
`fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.
When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker; Firstmate build constraints stay in `## Firstmate spec` or the steer.
Supervise all live work under [`AGENTS.md` section 8](../../../AGENTS.md#8-supervision-protocol).
