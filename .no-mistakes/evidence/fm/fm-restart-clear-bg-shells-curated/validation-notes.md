# Secondmate restart live validation

Acceptance oracle: the supplied intent and the recorded R2 decision require cleanup of the mate's own harmless waits, preservation of substantive validation/build/test work, bounded refusal while background shells remain, and refusal to confirm an exit picker blindly.

Installed surfaces: Claude Code 2.1.316, tmux 3.4, Herdr 0.9.5.
All model evaluations used the existing Claude login with Haiku and isolated fixtures; no credential stores, fleet homes, or default Herdr panes were changed.
Herdr was provisioned and torn down only through `bin/fm-herdr-lab.sh`, with its default-session tripwire intact.
The helper's `provision` includes preparation; separately calling both prepare and provision was a driver setup error and was corrected.

## Evidence and independent checks

- `tmux-live-transcript.log`, `live-transcript.log`: a real Claude Bash task runs a harmless sleep; the production parser observes one shell; the cleanup sentence from the shared agent-facing request causes the task to stop; its PID is independently checked dead; the shell indicator disappears; `/exit` closes Claude without a picker.
- `substantive-transcript.log`: the real `fm-secondmate-restart.sh sm` delivers the complete generated request through its durable inbox, receives Claude's correlated parent reply, and refuses relaunch while the real Python unittest workload remains running. The harmless sleep dies; the unittest PID remains alive and its progress counter increases after refusal. No relaunch transaction exists.
- `picker-transcript.log`: `/exit` with a live background task deliberately opens Claude's actual exit picker. `fm-control.sh sm exit` refuses to type Enter. The picker stays visible and the task remains alive.
- `unreadable-transcript.log`: a real Claude mate publishes its correlated persist reply and immediately closes its private tmux endpoint. The restart reports that the screen could not be read and refuses relaunch without opening a relaunch transaction.
- `terminal-gallery.html`: renders the actual terminal captures for review; these are text captures rather than pixel screenshots.

These observations would reject the prior broad cancellation request, a restart that sends `/exit` before harmless cleanup, a guard that ignores remaining substantive work, or a control plane that blindly confirms the picker.
The executable workload and evaluation drivers are retained alongside this note.
To reproduce them, copy `launch.sh`, `drive.sh`, `substantive.sh`, `substantive-test.py`, `dialog.sh`, and `unreadable.sh` into `.no-mistakes/live-validation/` in the tested checkout, retaining their relative paths, then run the commands recorded in the test-phase result.

## Targeted regression

`bash tests/fm-secondmate-restart.test.sh` and `bash tests/fm-composer-lib.test.sh` both exited 0.
These deterministic checks cover the emitted request, persist correlation and ordering, remaining or unreadable shells through local and remote routes, capture failure propagation, transcript-versus-footer parsing, and dialog safety.
Their transport fixtures are not live fleet or SSH evidence.
No remote fleet host was touched; successful replacement launch and SSH routing were covered by those regression fixtures, while the real Claude prompt, screen, and exit behavior were evaluated on isolated local tmux and Herdr endpoints.
No full suite, lint, formatter, static analysis, push, PR, or CI phase was run.

## Resolved test setup issues

Putting an existing regression's secondmate fixture under the source checkout triggers its intentional home-boundary refusal; rerunning with the suite's ordinary disposable temp location passed.
The live evaluator was corrected to route library calls to the private tmux socket, await the task PID instead of matching READY in the initial prompt, allow the pasted prompt to settle before Enter, and recognize that a CLI started directly as tmux's session command closes its session on exit.
All final scenario checks used the corrected evaluator and retained product output.

Research context: the project research-book entry `claude-exit-backgrounds.md` records why background work can prevent a clean Claude exit. Official Claude [interactive-mode documentation](https://code.claude.com/docs/en/interactive-mode) and [tools reference](https://code.claude.com/docs/en/tools-reference), fetched through Exa during this run, document background task lifecycle and `run_in_background`. Observed live process state and terminal output determine the scenario verdicts.
