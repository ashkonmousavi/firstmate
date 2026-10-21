# Targeted routine-wake validation

Source: branch commit 8e1eff2643a65e25fcc1a1ed91dd172652ac884e; base 1d7284d0d615c6f291620e1725d0affbcc155cf1.

The oracle is the recorded acceptance contract: proven routine work must be acknowledged and the same Stop process must repark; uncertain work must remain unread and produce a handling turn. A cached routine decision that consumes a subsequent unsafe batch must fail.

`base-red.log` runs the branch's unchanged fixture definitions against a disposable `git archive` of the base. Each selected case runs independently. The base fails the routine-consumption/repark boundary, rather than a source-text assertion. `branch-green.log` runs those same cases against the branch. The selector consists of the existing test script through its function definitions, followed by `"${FM_GATE_CASE:?}"`; no assertions are changed.

Selected cases:
- test_all_routine_wakes_are_acknowledged_without_a_turn
- test_empty_rearm_and_routine_host_return_stay_quiet
- test_quiet_repark_rechecks_unsafe_batches (mixed, uncertain, malformed, ack-failed, captain)
- test_quiet_repark_delivers_the_next_real_event

`hook-state-transcript.log` captures the hook's actual exit, emitted handling banner, queue, unread status, generation marker, cursor existence, and park invocations from those branch fixtures. The harness and park boundary are simulated; this is deterministic integration evidence, not proof that a real Claude session remains silent. The first three captured records name a nonexistent `.branch-outcomes` instead of `branch-outcomes.jsonl`; their outcome assertions still run unchanged and their queue/cursor/ack evidence is intact.

`direct-cli.log` is a real product CLI run in a disposable home, with no simulated harness or park implementation invoked: append a routine outcome, append three wake rows, run the routine peek, and invoke the returned generation-bound `fm-wake-drain.sh --ack-through` command. `direct-cli-driver.sh` records the exact driver. It demonstrates acknowledgement and cursor preservation, not Claude turn behavior.

`focused-suites.log` records `bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-supervision-host.test.sh`.

The recorded decision assigns real-Claude proof separately to `fm-fork-routine-wake-live-proof`. These fixtures do not waive it. No real Claude session was launched in this remedial round, and the prior workspace-trust limitation is not claimed fixed.

The initial instrumented sequence in `branch-green.log` completed its assertions but then exited 2 with an unexpected EOF: the temporary capture script was edited while Bash was still interpreting it. This was an evidence-driver setup error. `branch-sequence-retry.log` records the complete successful retry with the script held fixed (exit 0), and the unchanged canonical suite independently passed the same sequence. No product or permanent test fix was made.

## Host-suite failure and focused test repair

The canonical Stop-hook suite passed (exit 0). The host-suite run passed the previously reported closed-successor and attended captain-outcome cases, then failed `test_quiet_record_without_its_daemon_is_a_present_captain` at its 250-poll delivery wait. Remaining host-suite cases were not executed.

The same isolated quiet-mode case failed on base and branch (`quiet-base-native.log`, `quiet-branch-native.log`). The retained state shows a durable signal queue row and announced handling marker, with no engine call when the wait expired. The fixture configures `FM_ARM_CONFIRM_TIMEOUT=30`, exceeding its 25-second nominal wait. Changing only the wait to the existing `HOOK_RETRY_POLLS` budget let both captain outcome and main-only decision assertions pass (`quiet-branch-extended.log`, exit 0).

The permanent test-only fix replaces the two 250-poll waits in that quiet-mode case with `HOOK_RETRY_POLLS`, matching adjacent captain-delivery coverage already changed on the branch. No production code or assertions changed. `quiet-fixed.log` records the focused recheck using the patched test definitions with no diagnostic wait override.
