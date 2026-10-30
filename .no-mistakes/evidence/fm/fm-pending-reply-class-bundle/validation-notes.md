# Pending-reply live validation

All six acceptance scenarios passed. No source changes were needed.

## Product evidence

- `live-notices-and-probes.log`: the real standalone `bin/fm-watch.sh` closed full-body notices, including a waiver beyond the summary length and `data/report.md`, as `one-way-notice`; reporting questions and comma-introduced directives remained awaiting reports. Unknown-delivery notices resolved without an escalation. Real OpenSSH calls through `bin/fm-on.sh` and `bin/fm-remote-secondmate-control.sh probe` found unread and handled inbox messages, returned absent for a different correlation, and the running watcher marked only the found correlation delivered while escalating the missing one.
- `live-local-recovery-final.log`: `fm_pending_reply_send_recovery` called the real `bin/fm-send.sh` against a private tmux lab running the installed Claude CLI. Old default/keyed decisions allowed durable recovery enqueues; newer, equal, and unreadable timestamps held the recovery unattempted. A later working event mentioning the key did not change the opening decision's age. Persisted recovery messages carry their original correlations. Delivery means durable enqueue; a skipped/unconfirmed composer doorbell is not model acknowledgement. The same CLI persisted and resolved a notice mentioning `data/report.md`.
- `live-dedup-interruption.log`: a real idempotent enqueue scanning 12,000 retained inbox records was stopped after both scratch files appeared, terminated with SIGTERM, and resumed to receive that signal. Both files disappeared, no new message was committed, and a normal retry reused the existing handled message. No command was mocked.
- `live-slow-probe-final.log`: the actual standalone watcher maintained advancing beacon timestamps with 16 unresolved remote records while the first probe's SSH channel was delayed. The whole transport has the fixed 20-second timeout; the observed remaining interval after the SSH server received the request was 18 seconds because authentication/startup had already consumed part of that budget. The record then escalated. The watcher's actual exit status was read.
- `persisted-pending-replies.json`: generated pending-reply state retained before disposable labs were deleted.

## Isolation and scope

Every lab home, inbox, metadata record, generated key, SSH configuration, and locally installed Python dependency was inside the gate worktree. Every lifecycle call used a home minted by `bin/fm-lab-home.sh`. Claude ran on a private tmux socket at a nonzero 120 by 40 grid. No Herdr session was started or contacted, and no fleet pane was driven.

The disposable localhost SSH server used real public-key SSH authentication and executed the real host-local control executable. It decoded the `fm-on.sh` wire arguments and acted as a forced-command SSH endpoint. It did not emulate probe answers or pending-reply logic. The unrelated account-level remote-job bootstrap was excluded because its account-home discovery would address the operator's home. This run therefore proves the changed probe/control/watcher path, not deployment/bootstrap to a production remote account.

Initial fixture failures were corrected: the generated SSH key needed mode 0600 (OpenSSH explicitly rejected its initial mode), watcher restarts needed normal wake drain/acknowledgement, remote endpoint metadata needed its complete schema, and tmux's configured base index required resolving the actual window name. A preliminary slow-check run exited on legitimate prior status wakes, so the final beacon check used a fresh parent home and a first-in-scan slow record. Initial transcripts are retained separately; the scenario evidence above names the final successful checks. See the [OpenSSH private-key permission contract](https://man.openbsd.org/ssh.1).

## Checks run

- `bash tests/fm-pending-reply.test.sh` — exit 0.
- `bash tests/fm-send-remote-delivery.test.sh` — exit 0.
- `bash tests/fm-task-inbox.test.sh` — exit 0.
- `PYTHONPATH="$PWD/.live-validation/python" python3 .lv/ssh-server.py` — disposable real SSH endpoint; explicitly stopped, exit 143 as requested.
- `bash .lv/run-live.sh` — full-body classification and real SSH delivery reconciliation. The combined preliminary runner later failed in its slow-check setup; the successful classification/probe portion is retained in `live-notices-and-probes.log` and the slow check was independently re-driven successfully.
- `bash .lv/local-live.sh` — final run exit 0, live local recovery and CLI notice checks.
- `python3 .lv/dedup-live.py` — exit 0, actual interrupted enqueue and successful retry.
- `bash .lv/slow-live.sh` — final run exit 0, live watcher beacon and fixed transport deadline check.

No linter, formatter, static analyzer, broad repository suite, pipeline control, push, PR, or CI phase was run. The real SSH server and private tmux/Claude server were stopped; all disposable worktree artifacts were removed. Evidence scripts describe the manual drivers; `ssh-server.py` generates fresh disposable keys, and no key is published here. Shell/state changes have CLI transcripts rather than visual screenshots.
