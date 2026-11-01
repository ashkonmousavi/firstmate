# Auto-launch verification inventory

The [launcher header](../../bin/fm-autolaunch.sh) owns selection, dispatch, prep, and records; the [check header](../../bin/fm-autolaunch-check.sh) owns stall detection and notification.
This inventory maps their affected classes to executable regressions or an inspected reason the underlying integration is unchanged.
It is a validation handoff, not evidence of a real worker launch on every machine.

## Focused verification

Run `bash tests/fm-autolaunch.test.sh` from the repository root.
The [suite](../../tests/fm-autolaunch.test.sh) executes both scripts against a real markdown backlog and the shared quota gate, with capacity and spawn replaced at their executable boundaries.
Its oracle is the operator contract above: prepared ready work fills admitted lanes in backlog priority order, then ready-queue order, dispatch uses defaults only, and each decision is recorded.
It checks emitted commands, spawn arguments, persisted records, notification delivery, and failures rather than implementation text.
The model-request regression places a refusing `curl` at the external network boundary and enables a synthetic key; either a real or dry pass requesting a model would create an observable failure record.

| Affected class | Regression or inspected disposition |
| --- | --- |
| Real pass: ready queue, item checks, dispatch, spawn, records, capacity refresh | `free lanes launch in ready-queue order, one launched record per lane`; lane count, task order, UTC record fields, stdout, and spawn arguments are asserted together. |
| Dry pass | `dry run prints decisions and commands and writes nothing`; default-only dispatch also runs dry with a configured key and checks that no model request occurs. |
| Prepared listing and check consumer | The ready-order and literal deferred-identity cases call `--list-prepared`; the stall case consumes that same interface and checks the first item. |
| Ready eligibility | Stale blocked-by edges to finished work clear, live blockers stay blocked, and held/parked items never enter selection; missing brief, missing prep file, non-ship/scout kind, and invalid override record refusals. The ready-queue owner remains `fm-tasks-axi.sh`. |
| Launch-record derivation | `the launch record derives from override, brief lines, backlog row and project registry in that order` checks brief contract lines over the registry, registry-only fallback, and a partial override; the laptop-layout case covers a body-linked prep file, `data/<id>/prep.md`, priority order, a bare branch, and every named refusal. |
| Backfill and scaffold record | `backfill prints first, writes only on --apply, and is idempotent` covers dry output, apply, kept records, and skip reasons; `fm-brief.sh writes the launch record for every ship and scout it scaffolds` covers both scaffold kinds. |
| Deferred identity | `foo.bar` remains launchable with an unrelated `task=foo-bar` record; an exact queued identity is excluded from both listing and launch. |
| No dispatch file, one default, default array, no default | Static dispatch, optional-field cases, ranked defaults, and `static dispatch applies only when the dispatch file is absent` cover each representation. Natural-language rules do not supply candidates. |
| Passing, uncertain, exhausted, short-runway profiles | Ranked defaults use the real gate verdicts; known passes precede uncertain profiles, uncertain profiles retain declared order, and exhausted or short-runway profiles never reach spawn. |
| Spawn quota refusal and all profiles refused | `a quota refusal advances through ranked defaults and all refused records quota`; the first rejection must leave the lane available for the next profile. |
| Harness/model/effort transport | Single-field and omitted-field profiles verify exact spawn arguments through the remaining TSV reader; static dispatch omits all three flags. Provider-family inference receives default profiles only. |
| Ship delivery arguments | `ship and scout dispatch preserve their distinct argument contracts` exercises `no-mistakes`, `direct-PR`, and `local-only`, both yolo values, branch prefix, and base branch; the dry case separately checks upstream consent. Spawn retains delivery-contract validation. |
| Scout arguments | The argument case requires `--scout` and shared base branch without ship flags; eligibility cases run for both ship and scout. Secondmate provisioning is outside the launcher's accepted task kinds. |
| No account pin, invalid Claude root, Pi provider restriction | The default-eligibility matrix covers these before ranking with a valid snapshot and with an unavailable snapshot. Vendor sign-in remains owned by spawn and the worker-account library. |
| Full machine, project deferral, spawn error, exhausted queue | Existing capacity, deferral/error, and no-prepared-item cases assert records and whether the lane advances; admission remains owned by capacity and spawn. |
| Log availability and lifetime | An unwritable existing log must prevent spawn; a rename during spawn must leave the launch record on the descriptor opened before dispatch. |
| Lock acquisition, busy refusal, release | A live lock holder prevents a second launch and record; the next pass succeeds after release and removes its own lock. |
| Main-home stall episodes | Missing, recent, and stale records; no lane; no prepared work; initial alert, suppression, hourly repeat, and quiet-marker removal are exercised. |
| Secondmate notification | Invalid identity, missing binding, and append failure remain retryable; recovery delivers to the parent exactly once and only then publishes the episode marker. |
| Arm, re-arm, disarm, repeated disarm | Registration and trust artifacts are checked; unwritable state and unsafe trust artifacts must fail without reporting success. Retirement stays with `fm-check-unregister.sh`. |
| Help and schedule proposal | `--print-timer` emits an explicitly bound home and five-minute timer. These early exits do not dispatch; schedule installation and fleet machinery are untouched. |

## Harness, backend, and platform inventory

| Axis | Inspected integration and coverage |
| --- | --- |
| `claude`, `codex`, `opencode`, `grok`, `cursor` | Profiles cross the same literal argument boundary; no adapter implementation changed. The focused suite covers Claude/Codex quota requeue, OpenCode uncertainty, Grok ranking, and Codex optional effort. Cursor uses that shared path; [dispatch-profile regressions](../../tests/fm-spawn-dispatch-profile.test.sh) own its downstream validation. |
| `pi`, `pi-signed`, `omp` | Account/provider selection and tool-exclusion checks retain their shared owners. Focused Pi cases exercise a restricted provider and a usable alternative; pi-signed uses the same account/exclusion helpers. OMP family selection remains in the quota library; [quota-gate regressions](../../tests/fm-quota-gate.test.sh) cover these sibling paths. |
| `kimi` and typed `codex` | The focused eligibility matrix rejects unsupported visible-capture placement before either known-quota ranking or unavailable-quota ordering. Readiness and brief delivery remain in their adapters. |
| `commandcode`, `polytoken` | Focused cases reject unsupported Command Code placement and an incomplete Polytoken profile. Concrete Polytoken model/effort validation and vendor catalog handling remain with spawn and the [Polytoken adapter suite](../../tests/fm-polytoken-harness.test.sh). |
| `gemini`, `muse`, `rovo`, `agy`, `devin` | The launcher does not branch on these adapters; it transports their configured strings through the same spawn argument builder. Their catalog, readiness, hook, and launch behavior is unchanged and is not proven by a mocked autolaunch spawn. |
| `tmux`, `herdr`, `zellij` | Backend selection stays with `fm_backend_name`; the launcher passes no backend override. tmux is the ordinary focused fixture, zellij exercises Command Code exclusion, and the [quota-gate suite](../../tests/fm-quota-gate.test.sh) owns supported capture/backend combinations including herdr. |
| `orca`, `cmux`, `paseo` | Focused cases reject Kimi on Orca and typed Codex on Paseo. cmux shares the inspected unsupported-capture set in `fm_backend_visible_capture_supported`; its adapter is untouched. These backends retain their experimental status. |
| `codex-app` | No launch capability is added; spawn continues to own rejection of unsupported placement. This inventory makes no Codex App launch claim. |
| PC/WSL, server/Linux, laptop/Linux | Each instance selects its own `FM_HOME`; the suite uses a synthetic home with isolated backlog, projects, config, records, and parent destination. No machine inventory, schedule, account, or global configuration is changed. |
| Linux and Darwin; x86_64 and arm64 | Queue order and default dispatch add no OS/CPU selector. The check's existing GNU/BSD `stat` branches, Bash interfaces, locks, and scheduler proposals remain in place. Local portable tests do not establish native Darwin or fleet-wide runtime parity. |

## Live-proof gaps and entry points

The focused suite proves orchestration across controlled executable boundaries, not installed harness behavior, real authentication, or a scheduled pass on PC, server, and laptop.
The designated validation owner must record actual date, command, OS/architecture, harness/backend versions, output, and exit status before claiming that live coverage.
The [runtime-backend record](runtime-backends.md) owns dated vendor/backend evidence and the guards' individual limits.

| Live guard | Evidence it can add |
| --- | --- |
| [Harness liveness drift](../../tests/fm-harness-liveness-drift-live-e2e.test.sh) | Process identity and ancestry for its installed harness list; it does not prove every adapter or backend. |
| [Worker accounts](../../tests/fm-worker-account-live-e2e.test.sh) | Installed Claude/Pi sign-in-check behavior under disposable roots, rather than every production account. |
| [Codex launch brief](../../tests/fm-codex-brief-typed-live-e2e.test.sh) | Real positional and typed brief delivery when invoked for each transport with its opt-in flag. |
| [Polytoken signals](../../tests/fm-polytoken-signals-live-e2e.test.sh) | That adapter's real prompt, turn, and control surfaces under its opt-in contract. |
| Backend smoke guards linked from the [runtime-backend record](runtime-backends.md) | Their named backend surfaces; these do not collectively establish a scheduled autolaunch on every fleet machine. |

Live guards may spend tokens or require tooling and isolation beyond this review phase.
Absent tools, skipped harnesses, native-platform gaps, and unrun fleet schedules remain explicit gaps rather than inferred passes.
