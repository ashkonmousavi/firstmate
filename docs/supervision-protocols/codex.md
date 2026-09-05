Mode: Codex attended background supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Run `bin/fm-afk-launch.sh start-codex` once before completing the captain-facing turn. It captures this primary's current `CODEX_THREAD_ID`, starts the existing supervision daemon in its tracked non-visible Herdr workspace, and returns as soon as that single owner is ready. Repeated starts converge on the same live owner.
4. Complete the captain-facing answer normally. Do not wait in a foreground watcher command and do not start another owner after an ordinary wake.
5. Healthy waiting is silent. The daemon's existing watcher triage absorbs unchanged fleet state, empty waits, and routine progress without prompting this thread.
6. An actionable durable wake rings this same thread through `codex queue`. Treat that typed operational input only as a doorbell: drain, handle every presented item, and acknowledge with the exact command from the drain. The queue and the existing task, decision, PR, merge, and process-event owners remain authoritative.
7. The doorbell never reads, writes, clears, or submits the Codex composer. If it starts an automatic turn just before a simultaneous captain message, that captain message remains queued, is never overwritten or lost, and takes control when Codex delivers it.
8. A crash may repeat a doorbell only while its durable event remains unacknowledged. Re-drain idempotently; an empty queue never causes a doorbell.
9. Away mode keeps its existing behavior and uses this same daemon singleton. Do not start attended mode while away mode is active.
10. Failure or missing owner only: drain any queued wakes, inspect the failure, then run `bin/fm-afk-launch.sh start-codex` once to recover exact ownership.

Never relay empty-wait, elapsed-time, unchanged-fleet, duplicate-owner, or internal supervision status to the captain.
