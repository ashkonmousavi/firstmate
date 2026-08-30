Mode: Codex persistent Stop successor with one bounded bootstrap checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Bootstrap only: before the first persistent Stop handoff, run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. When that checkpoint returns for any reason, drain queued wakes, handle any emitted wake, process any queued user message now visible to Codex, then reach Stop so the tracked hook establishes the persistent successor. Do not start another checkpoint.
5. After handoff, the persistent owner runs the existing one-shot watcher. An actionable wake returns through the same captain-facing session; drain and handle it without starting another foreground checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Successor-unavailable diagnostic only: drain queued wakes and inspect the Stop diagnostic. The turn stays closed until the adapter is available; a checkpoint expiry is never a completed handoff.

Codex cannot reason while a foreground tool call is running.
The one bootstrap checkpoint returns control for user messages before the first handoff.
At Stop, the hook binds the existing daemon and one-shot watcher lifecycle to this session's live home lock and Herdr or tmux target, and allows the turn only after that daemon owns the watcher.
Healthy waiting is silent, the captain can start another turn while the owner remains active, and away mode keeps presentation precedence.
