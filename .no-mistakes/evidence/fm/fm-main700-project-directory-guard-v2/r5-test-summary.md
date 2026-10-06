# Project-directory guard Test result

Target: 57f3c69ceef750a4977072f1c388a6a408f0e038.
Verdict: go for the MAIN732 supported-coverage boundary, with native gaps below left untested.
No source, documentation, persistent test, pipeline, delivery, or operator-state changes were made.

## Current product evidence

The base transport denied nonproject `cd bin` and `cd ..`; the target permits those moves while retaining project denial.
The real public transport was driven against a disposable primary with protected relative and absolute targets, pushd, unrelated directories, execution-cwd overrides, preceding literal moves, child-process and quoted-data carve-outs, initial tilde quoting and escaping, and the Cursor deny object.
An actual Bash shell reproduced the backlog leak, then the real guard denied the exact move before execution; the protected clone backlog stayed absent and the allowed home backlog update persisted.
The linked gate worktree stayed inert while a cloned secondmate primary remained guarded.
These direct product results are in r5-public-hook-transcript.json, r5-base-hook-transcript.json and r5-checkout-scope.json.

Native Codex 0.160.0 issued seven real exec_command calls with explicit workdir parameters.
All captured hook payloads omitted workdir and supplied the session cwd.
Protected absolute and home-anchored destinations were denied and created no sentinel; unrelated anchored targets, both relative targets, and the control write succeeded.
The protected relative allowance is intentional supported partial coverage, not universal protection.
Evidence: r5-codex-result.log, r5-codex-payloads.jsonl and r5-codex-state.json.

Native Claude Code 2.1.292 issued four real Bash calls and its payload cwd updated after allowed moves.
The protected relative destination was denied; the unrelated relative destination and control write succeeded.
Evidence: r5-claude-result.log, r5-claude-payloads.jsonl and r5-claude-state.json.

Native Pi 1.0.0 loaded the current extension and supplied ctx.cwd in actual tool_call callbacks.
The protected write was blocked while unrelated and control writes succeeded.
Evidence: pi-r5-native-result.log, pi-r5-native-events.jsonl and pi-r5-native-state.json.

Retained round-3 native Codex payloads reproduced the pre-fix allow/false-deny/control results against 7db4987, then all three allowed under the accepted omitted-workdir boundary.
Retained Claude payloads preserved the protected denial and unrelated/control allows.
Evidence: r5-retained-payload-replay.json.
The original native witnesses were left untouched.

## Targeted checks and accepted follow-up

TMPDIR="$PWD/.gate-cd-validation/tmp" bash tests/.gate-cd-behavior.test.sh exited 0.
TMPDIR="$PWD/.gate-cd-validation/tmp" bash tests/.gate-arm-behavior.test.sh exited 0.
These temporary runners copied the corresponding tracked suites and omitted only each final lint invocation, which this Test phase forbids.
The cd runner exercised the acceptance matrix, registered hooks, adapter callbacks, supplied cwd overrides, branch-state execution, leak regression, scope and fail-open checks, plus Codex supported coverage.
The arm runner checked the shared lexer consumer's existing behavior and output contracts.
Both runners were removed.
Evidence: r5-cd-behavior.log and r5-arm-behavior.log.

TMPDIR="$PWD/.gate-cd-validation/tmp" bash tests/fm-cursor-primary.test.sh exited 1 at the previously declined R-cursor-o5 missing-cwd assertion.
That known follow-up remains unchanged under the later MAIN732 decision.
The supplied-cwd Cursor transport independently returned its proper deny object and missing-cwd transport retained its accepted allowance.
Evidence: r5-cursor-behavior.log and r5-public-hook-transcript.json.
No new finding is raised for the declined case.

## Native gaps

Cursor and Grok launched with workspace-contained user data but stopped at Authentication required and Not signed in before any tool call.
This does not establish that their normal operator login is unavailable.
They need lab-authorized authentication or an authorized existing-login route preserving the workspace boundary.
Evidence: cursor-r5-isolated-result.log and grok-r5-isolated-result.log.

Omp 18.2.7 loaded the extension in both default auto-approval and explicit cursor/claude-4.5-sonnet attempts, but emitted no tool calls within the 55/75-second bounds.
The current catalog lists Cursor models and three Ollama embedding model names, not an available local generative tool-calling route.
Provide a responsive Omp provider/model route and rerun the native probes.
Evidence: omp-r5-native-state.json, omp-r5-model-native-state.json and r5-omp-model-catalog.json.

OpenCode was absent from PATH and was installed only under the disposable worktree.
Its package generator materialized the workspace-local binary after the initial ignore-scripts install.
The real plugin initialized in headless and 120x35 TUI runs, but both free-provider attempts were refused before bash callbacks by the free-tier provider restriction; headless reported HTTP 403.
Provide an allowed OpenCode provider/model route and rerun.
Evidence: r5-opencode-native-result.log, r5-opencode-native-events.jsonl, r5-opencode-tui-pane.log and r5-opencode-tui-events.jsonl.
The downloaded test dependencies and caches were removed.

Pi-signed is absent from PATH; no repository-local genuine signed launcher is supplied.
Ordinary Pi is not a substitute for signed-launcher proof.
Provide the genuine launcher on PATH to rerun that scenario.

The read-only native Windows probe reached PowerShell but Test-Path could not resolve the exact required worktree path.
It found Claude and Node, but no Codex, Cursor, jq or tmux commands.
Native proof needs an authorized Windows-accessible worktree under the source path contract plus supported dependencies and harness setup.
Evidence: r5-windows-boundary.log.

## Evidence setup and cleanup

Early recorder setup receipts are retained separately as r5-claude-setup*, r5-claude-setup2* and r5-codex-setup*.
They are setup failures, not product verdicts: the Claude wrapper first selected the inert gate root and then consumed stdin ahead of the multi-statement hook; the Codex recorder name initially failed the registered-hook root check.
The corrected wrapper forwards stdin through a child bash with the disposable Claude project root, and the Codex recorder name satisfies the registration check.
A direct corrected Claude hook preflight denied the protected relative target before repeating native validation.
Evidence: r5-claude-recorder-preflight.json and the subsequent successful native results.

All native labs used marked disposable homes, separate fm-lab sockets and 120x35 grids, and were stopped and removed in their evidence turns.
No default tmux server, Herdr session, live fleet, operator checkout, credential store, or global tool configuration was changed.
All recorded lab paths and lab-owned processes are gone, transient worktree runners/dependencies are removed, and git status is empty.
Evidence: r5-cleanup.json.

The public cd-guard contract and runtime coverage record were read directly; no documentation checker, linter, formatter, static analysis, or full repository suite was run.
This change has no renderer or UI layout surface, so product evidence uses CLI transcripts, native payloads and persisted sentinel/backlog state rather than screenshots.
Publication, hosted CI, merge, every-home placement and adoption remain the outer executor's phases and were not claimed.
