# Live custom-check wake evidence

Oracle: the supplied user intent and recorded removal decision. Each failure or timeout produces exactly one durable check wake; quiet successful checks produce none; printed successful output is preserved. The driver runs the production registration, watcher, drain, acknowledgement, and unregistration commands in a marked disposable home. It uses no mock product commands.

GNU timeout 9.4 and the production Perl fallback were exercised. Every watcher and acknowledgement exited successfully; the disposable lab was removed.

## GNU timeout first timeout

Wall time: 1.722s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

## GNU timeout consecutive timeout

Wall time: 1.875s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

## GNU timeout re-registered timeout

Wall time: 1.822s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

## GNU timeout exit-one

Wall time: 2.806s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/exit-one.check.sh: exited 1 after 2s
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/exit-one.check.sh: exited 1 after 2s
```

## GNU timeout output-failure

Wall time: 0.817s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/output-failure.check.sh: exited 7 after 0s: diagnostic detail
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/output-failure.check.sh: exited 7 after 0s: diagnostic detail
```

## GNU timeout term

Wall time: 0.804s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/term.check.sh: exited 143 after 0s
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/term.check.sh: exited 143 after 0s
```

## GNU timeout kill

Wall time: 0.767s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/kill.check.sh: exited 137 after 0s
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/kill.check.sh: exited 137 after 0s
```

## GNU timeout quiet-success and printed-success

Wall time: 0.876s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/z-success.check.sh: first line
second line
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/z-success.check.sh: first line second line
```

## Perl fallback first timeout

Wall time: 1.944s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

## Perl fallback consecutive timeout

Wall time: 1.857s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

## Perl fallback re-registered timeout

Wall time: 1.85s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/slow.check.sh: timed out after 1s (FM_CHECK_TIMEOUT)
```

## Perl fallback exit-one

Wall time: 2.658s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/exit-one.check.sh: exited 1 after 2s
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/exit-one.check.sh: exited 1 after 2s
```

## Perl fallback output-failure

Wall time: 0.648s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/output-failure.check.sh: exited 7 after 0s: diagnostic detail
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/output-failure.check.sh: exited 7 after 0s: diagnostic detail
```

## Perl fallback term

Wall time: 0.673s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/term.check.sh: exited 143 after 0s
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/term.check.sh: exited 143 after 0s
```

## Perl fallback kill

Wall time: 0.648s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/kill.check.sh: exited 137 after 1s
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/kill.check.sh: exited 137 after 1s
```

## Perl fallback quiet-success and printed-success

Wall time: 0.745s

```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/z-success.check.sh: first line
second line
```

Durable queue payload:
```text
check: ~/.no-mistakes/worktrees/049a88734b0e/01M66CXP9Z4FN8GKTTG9PHYD2V/.live-check-lab-cded1vqj/state/z-success.check.sh: first line second line
```

Quiet-check execution was proved by its disposable execution marker, while its id was absent from the queue. Successful multiline output stayed multiline on stdout and used the existing single-row queue serialization.

See check-wakes-transcript.txt for the full registration, delivery log, drain, and acknowledgement transcript. See drive-check-wakes.py to reproduce.
