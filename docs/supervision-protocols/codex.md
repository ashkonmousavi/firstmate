Mode: Codex foreground checkpoint with persistent turn-end handoff.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
A quiet checkpoint expiry is not completed supervision.
When Codex reaches Stop while supervision is still required, the tracked Stop hook binds the existing persistent supervision daemon to this exact Codex session, home lock, backend, and captain-facing target.
The Stop remains blocked until that daemon owns one healthy watcher child; `stop_hook_active` does not bypass this proof.
The daemon stays silent while waiting, uses the existing one-shot watcher and durable drain/acknowledgement path, and injects only an actionable wake into the same session.
The captain may start another turn while that owner remains active.
The owner retires when supervision is no longer required or the Codex session loses the home lock; away mode keeps precedence if it is active.
If the current backend cannot provide the verified persistent terminal and same-session injection route, the Stop hook fails closed with its Codex-successor diagnostic.
