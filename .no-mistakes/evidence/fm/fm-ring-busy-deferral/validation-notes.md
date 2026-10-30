# Busy-deferral live validation

Both focused suites completed with exit status 0:

- `bash tests/fm-task-inbox.test.sh`
- `bash tests/fm-send-remote-delivery.test.sh`

The independent oracle is the supplied author intent: no ring budget while a non-queue worker is busy; a single stuck-busy wake at the busy bound; a permanent escalation marker; exactly one owed idle follow-up without another wake; queue harnesses and old-parent requests keep ringing; new parents retry legacy due on an old remote. The local triage line must appear only following successful below-bound bookkeeping.

The lab used the actual Herdr 0.9.5 server and actual Pi 1.0.0 and Claude Code 2.1.314 terminal applications in the non-default `fm-lab-ring-gate` session. Every Herdr call was forwarded through `bin/fm-herdr-lab.sh`; a namespace-only adapter redirected the remote control protocol's mandatory `fm-remote` session into that private session. The remote and parent homes were disposable marked lab homes inside the gate worktree. The `FM_SSH_BIN` adapter executed the real remote control executable locally; it did not simulate remote-control, backend, composer, delivery, or wake results. Actual network SSH transport was outside this change's tested scope.

Busy/idle semantic records were supplied through the public `fm-busy-event.sh` interface. The strongest lifecycle proof additionally observed a real Pi turn working before deferral and settled (`done`) before delivery. It acknowledged the original wake using the public drain/ack protocol before the idle follow-up; the wake queue then remained empty. The terminal showed RECEIVED after the follow-up. The Claude queue proof observed native `working`, rang through the real backend, and captured its eventual RECEIVED response. A conflicting idle record under parent-route confirmed that the remote busy check uses its own home state directory.

The original Pi Anthropic provider reported an expired refresh token. No login or credential store was edited. A read-only `pi auth check --provider openai-codex --no-refresh --json` returned ready for Pi's existing OpenAI Codex login, and final Pi proofs used that provider with real model responses. The initial Claude startup suggestion was protected as a foreign pending composer; after a normal initial message cleared that startup surface, the working-turn queue proof returned `rang 0 reason=ok` and its terminal receipt was captured.

The compatibility proof executed the base commit's remote control command with current unchanged dependency interfaces and a new parent watcher; remote-calls.log shows due with the optional busy maximum, retry without it, then legacy ring. The opposite direction omitted the optional argument against the new remote while its semantic state was busy.

The retained drivers document exact commands. `nonqueue-live-proof.log` records the working/deferred half; `nonqueue-finish-proof.log` records completion after acknowledging the public wake receipt. An initial driver assumption that drain alone removed a wake was corrected to follow its printed ack command; Herdr's completed `done` state was accepted as settled, consistent with its public contract. These were setup corrections, not product changes.

No browser or renderer source changed; product evidence consists of watcher/wake logs, durable inbox state, and actual terminal captures. No screenshot was required for this CLI bookkeeping change.

Primary reference for native lifecycle semantics: https://herdr.dev/docs/agents/ (working is active; a done state remains visible until viewed). Native reporting API: https://herdr.dev/docs/add-herdr-support/ and https://herdr.dev/docs/socket-api/ .

Cleanup completed: the owning lab process returned exit status 0 after `fm-herdr-lab.sh teardown fm-lab-ring-gate`, which verified its default-session tripwire. All lab panes/server and disposable worktree fixtures were removed. No tracked source or test files were changed.
