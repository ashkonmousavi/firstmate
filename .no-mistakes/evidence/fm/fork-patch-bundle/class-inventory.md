# Validation handoff class inventory

Reader: supervising firstmate and the designated no-mistakes validation agent.
Branch: `fm/fork-patch-bundle`, based on `curated` at `ed4ae352ad9084ae5a3bfeec4c771f66357cd438`.
Five separate commits end at `6efa18d637d12c94febe54abd482109edf689a88`.
Heartbeat is explicitly out of this bundle under firstmate steering 001.
Fleet-ops owns its current-curated rebase and fresh judge in `heartbeat-phase2`.
That patch expects watcher blob `329b2074` and `check_run_record()`, absent in current blob `c2cf2e13`; it was never applied.

## Changed call paths and executable proof

| Patch/class | Affected paths and transitions | Executable regression or unaffected reason |
| --- | --- | --- |
| Owl park summary | `print_status_presentation` -> `print_status_sections` -> `print_open_decisions_section`; empty queue, normal drain and held-branch fallback all reach the shared presenter | Existing `fm-wake-drain-open-decisions.test.sh` and cursor suite; task-local `owl-public-proof.test.sh` executes the full drain twice with valid/invalid/date/symlink/extra-line parks, verifies unchanged durable decision, then unpark visibility. No decision is closed by filtering. |
| C4 tester completion grammar | `Slice.tester_ready` consumed by initial tests-ready continuation and changed-cut delivery; `child_files` generates the two literal canonical forms | Three added `Steps.test_tests_ready_*` / `test_tester_brief_spells_literal_commit_forms` methods exercise hex, `commit=none`, legacy `none`, rejection of malformed/stale/unadmitted evidence, unchanged revision/walk/check/model admission and one-time delivery. |
| F1 scheduler boundary | `--print-timer` plain and `--print-timer --steps-only`; generated user service and cron alternatives carry caller PATH/home and selected scope | Five added `Timer` cases execute emitted environment/argv against a held real task store, validate missing-tool failure and rejected extra flags. Generator exits before backend/quota/lifecycle imports. |
| O2 launch admission | `prep_read` called by `check_item` for run, dry, prepared listing and private step-dispatch; backfill also derives through `prep_read`; existing check consumes prepared listing | Existing shell suite gains public CLI refusal/correction/Markdown/linked-prep/grace/usage cases. Only NOT_Q ship prep is subject to declarations; scouts return earlier and other projects bypass this validator. Direct manual spawn and step-owner continuation remain outside this gate, as the judged report states. |
| Reply shape | `fm-turnend-guard.sh --claude --state-claims` retains primary scope, then guard `main` evaluates opt-in reply rules before transcript-dependent claims; identical next continuation consumes the existing exemption | Extended `fm-state-claim-guard.test.sh` exercises executable and tracked Stop registration, three rule families, quoting, optional-config failures, compatibility stand-down and unchanged state claims. Task-local `reply-limit-proof.py` proves the accepted limitation via stdin Stop JSON. |

## Task, harness, backend, platform and account axes

| Axis | Applicability and inspected reason |
| --- | --- |
| Primary firstmate and persistent secondmate | Owl filters summaries based on the calling home's validated owner-park records; reply policy is home opt-in. No private config is installed. |
| Ship/scout roles | C4 consumes tester done receipts; O2 checks NOT_Q ships only. Existing Stop wrapper worker exemptions remain unchanged and are exercised by the portable state-claim suite. |
| Claude | Only the existing Claude primary Stop entry calls the reply policy. Actual final-message/continuation event proof is a separate live guard; portable proof uses documented Stop JSON plus actual tracked command execution. |
| Codex, opencode, grok, cursor, pi, pi-signed, kimi, omp, muse, gemini, rovo, agy, devin, commandcode, polytoken, cortex, kiro | Shared autolaunch preparation/receipt interfaces transport their existing model/profile strings without adapter edits. No new vendor output or process-name classifier is added. Reply policy is outside native non-Claude entrypoints; existing foreign compatibility stand-down cases are retained. |
| tmux, Herdr, Rex, zellij, Orca, cmux, Paseo, tern, t3code, hc, Codex App | No backend implementation, capture predicate, spawn command, continuation capability or isolation boundary changes. Step tests substitute agent/control/spawn/send at existing fixture seams; this task drives no real Herdr lifecycle. Spawn-capability and unsupported-backend refusal stay with current backend owners. |
| PC WSL, server Linux, laptop Linux | Identical per-home path selection; validation uses a laptop scratch archive with clean child environments and real local task storage. No machine schedules, accounts, live-home endpoints or shared pool state are touched. |
| Darwin, x86_64, arm64 | Python grammar/admission has no platform selector. Park validation reuses existing GNU/BSD date owner. F1 service output is Linux-specific and the cron alternative is shell-replayed; no native Darwin/arm64 proof is claimed. |
| Claude/Pi account pins, other authentication, providers and quota | Unchanged selection owners; no credential file read, sign-in, provider call, account-pin edit or quota mutation. Autolaunch fixture snapshots replace quota reads. Timer replay uses a held fixture owner, not an account or model request. |
| Lifecycle transitions | C4 changes only acceptance of structured tester completion for initial/cut continuation; O2 refuses deficient prep before normal or step-dispatch spawn. No actual launch, exit, restart, teardown, recovery, merge or deploy behavior is newly implemented. Owl only changes presentation. |

## Live guards and evidence gaps

`tests/fm-state-claim-guard-live-e2e.test.sh` is the existing real-Claude Stop payload/continuation guard.
It sends two model prompts, so this task's explicit no-spend instruction excludes running it here.
The designated validation owner must follow that guard's authorization/gate before running it; otherwise retain UNKNOWN for current real-Claude payload proof.
Before claiming live proof, refresh the date, actual harness version, exact command/output and exit status in the owning verification record.
No portable fixture result establishes current vendor payload behavior.

`docs/verification/autolaunch.md` and `docs/verification/runtime-backends.md` own existing live entrypoints and their limits.
Liveness-drift, worker-account, typed-Codex-brief, Polytoken and backend-smoke guards are unchanged and do not by themselves prove this task's scheduled pass or reply admission.
Actual schedule installation/activation, current native macOS/arm64 behavior, all installed accounts, and fleet-wide timer runs remain UNKNOWN.
No broad live-harness parity claim is made.

Reply ask-first limitation is explicit in the production header and PR draft: detection catches only a pointing-hand line or the phrase list; a plain late question still passes.
The existing task-local after-merge record names `reply-shape-late-question` for broader question-mark/request-sentence detection; direct read of the fleet-ops backlog confirms the native follow-up is filed with `blocked-by: fork-patch-bundle`; firstmate owns dispatch after landing.
The wrapper cannot prove Pacific wall-clock correctness, URL provenance or all semantic asks.
Optional config inheritance for other homes and activation remain with fleet-ops.
O2 skills-master payload is excluded and remains a post-merge fleet-ops task.

## Documentation classification

`docs/configuration.md` is the public configuration reference and now points to the launcher header as the single prep-contract owner.
`docs/verification/autolaunch.md` is maintainer verification and adds the current admission regression map with its fixture-only limit.
Incident chronology, preimage mismatch, machine admission readings, commands and handoff evidence remain in this private task directory and the PR draft.
No unique safety fact was removed; `fm-doc-audience-check.sh` passed with `surfaces=142 local_links=1468`.
