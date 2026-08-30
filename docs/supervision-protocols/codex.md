Mode: Codex persistent turn-end supervision with one bounded bootstrap checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Bootstrap only: before this session's first persistent Stop handoff, run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. When that bootstrap checkpoint returns for any reason, drain queued wakes, handle any emitted wake, process any queued user message now visible to Codex, then let the turn reach Stop so the tracked hook establishes the persistent successor; do not start a second checkpoint.
5. After handoff, the identity-matched persistent successor owns every healthy wait and the next one-shot watcher. On an ordinary wake, drain and handle it without starting another foreground checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Successor-unavailable diagnostic only: drain queued wakes and inspect the exact Stop diagnostic, then use at most one foreground checkpoint as bounded legacy coverage while repairing the persistent handoff; never retry it as the healthy wait loop.

Codex cannot reason while a foreground tool call is running.
The one bounded bootstrap checkpoint returns control so user messages and queued wakes can be handled before the first persistent handoff without relying on background-task wake semantics.
A quiet checkpoint expiry is not completed supervision.
When Codex reaches Stop while supervision is still required, the tracked Stop hook binds the existing persistent supervision daemon to this exact Codex session, home lock, backend, and captain-facing target.
The Stop remains blocked until that daemon owns one healthy watcher child; `stop_hook_active` does not bypass this proof.
The daemon stays silent while waiting, uses the existing one-shot watcher and durable drain/acknowledgement path, and injects only an actionable wake into the same session.
The captain may start another turn while that owner remains active.
The owner retires when supervision is no longer required or the Codex session loses the home lock; away mode keeps precedence if it is active.
If the current backend cannot provide the verified persistent terminal and same-session injection route, the Stop hook fails closed with its Codex-successor diagnostic.
