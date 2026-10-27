# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Launch brief | Typed after launch, never positional: codex-cli 0.163.0 opens at an empty composer ("Ask Codex to do anything") and never runs the positional prompt, in a new folder (after the trust dialog is answered) and in an already trusted folder, with and without the `-c`/`--disable` overrides (verified live 2026-10-27). `bin/fm-spawn.sh` starts codex bare, waits for the ready composer while answering the launch dialogs, then delivers `FIRSTMATE_OP: v1 launch-brief` (a one-line pointer naming `data/<id>/launch-brief.md`) through `fm_backend_send_text_submit` and confirms the turn started; every failure reports "codex did not take the brief". `FM_CODEX_POSITIONAL_LAUNCH=1` restores the positional form (`fm_spawn_codex_positional_brief_probe` owns that verdict). |
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh\|max>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertised only the first four values while omitting `max`; current codex-cli 0.153.4 catalog data at `${CODEX_HOME:-~/.codex}/models_cache.json` advertises `max` for `gpt-5.6-luna`, which Firstmate passes for that model. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Marker | None; identity comes from ancestry, and `../../../bin/fm-harness.sh` is what keeps a retained foreign `CLAUDECODE` from renaming it. Verified on 2026-09-01 with codex-cli 0.152.0: the pane process is the `node` npm shim and the native `codex` binary runs as its foreground child, so a tool subprocess reaches the native name directly while the shim itself is identified from its script path. |

## Launch dialogs

A directory trust dialog appears on the first run for a repository root.
codex-cli 0.163.0 renders it as "Folder access" over the path, the question "Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.", the preselected option `1. Trust and continue`, `2. Quit`, and the hint `enter continue · esc quit` (verified live 2026-10-27; 0.139.0 asked "Do you trust the contents of this directory?").
Enter selects the preselected affirmative and codex saves the decision itself, so later launches in the same folder skip the dialog.
`bin/fm-spawn.sh`'s typed-brief readiness gate answers it with Enter, the same preselected-safe-default answer the kimi and agy gates give their folder-trust dialogs.

A second dialog, "Update available · <from> → <to>" with `1. Update now (runs \`npm install -g @openai/codex\`)`, `2. Skip`, `3. Skip until next version`, and the hint `enter confirm · esc skip`, renders whenever an update is pending and the operator has not chosen "Skip until next version" (verified live 2026-10-27, 0.163.0 → 0.164.0).
Enter would run a global npm install over the shared toolchain, so the gate answers it with Escape, which skips the dialog for that launch only and leaves the operator's update choice untouched.
Option 3 persists a skip and is the operator's own choice to make.
The dialog is matched on its option rows (`Update now`, `Skip until next version`), never on its "Update available" heading, because the persistent post-skip banner box carries that heading over a healthy ready composer.

A third dialog, "Hooks need review", is covered below.

## Hook trust

A second dialog, "Hooks need review - N hooks are new or changed", appears whenever the machine's `~/.codex/hooks.json` or a project's own `.codex/hooks.json` carries a hook Codex has not persisted trust for.
It is unanswerable rather than merely inconvenient: its selection starts on "Review hooks", which is neither trusting nor declining, and Firstmate's key plane carries Enter, Escape and Ctrl-C with no arrow navigation.
Writing Codex's own trust store to pre-accept it would manufacture an operator consent that was never given.
So crewmate and scout launches disable Codex's hook layer outright (`bin/fm-spawn.sh`'s launch template owns the flag), which is the opposite of `--dangerously-bypass-hook-trust` - that flag RUNS the untrusted hooks.
A crewmate loses nothing: its turn-end signal is the `-c notify=` program on the same launch, and the Firstmate hooks in a project's `.codex/hooks.json` are primary-session infrastructure that stands down in a child worktree.
A secondmate is a primary in its own home and keeps its hooks, so an unanswerable modal there is still possible and is the operator's own hook review to settle.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
In a home with `config/supervision-host` and no `config/supervision-host-off` the checkpoint runs the supervision host instead of the watcher, with Claude's print mode as its headless engine, and holds for at least an hour while away; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host and that bound.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
