# Live-driver lifecycle correction

No repository-local research-book directory is present in this gate worktree; the attached author report likewise names no pending-reply classifier entry. No other project checkout was read.

2026-11-04: the first real watcher invocation printed `signal: .../labmate.status` and exited 0. Its documented interface exits when an actionable wake occurs. Hypothesis: the driver incorrectly assumed a perpetual watcher; a nonzero watcher exit or a missing signal would disprove that explanation. The retained first-attempt logs establish a successful wake, rather than a product failure.

The [official Python subprocess reference](https://docs.python.org/3/library/subprocess.html), consulted 2026-11-04, documents `poll` and `wait` for observing and reaping child exits, including zero for success and negative signal exit values. The corrected driver records each invocation, restarts only after expected zero exits with a fixed restart bound, and uses nested cleanup so an already-exited watcher cannot prevent isolated terminal teardown. An independent reviewer confirmed this interpretation and the evidence scope.

Live scope: real `fm-send.sh`, real `fm-watch.sh`, and real persisted records, with `cat` as an isolated external terminal endpoint. Durable enqueue is the sender's documented delivery contract. This proves parent-side classification and reconciliation, without claiming receipt or interpretation by a model.
