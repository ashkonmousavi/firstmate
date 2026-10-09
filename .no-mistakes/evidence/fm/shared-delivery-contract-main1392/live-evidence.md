# Live watcher evidence

The real fm-watch.sh, fm-crew-state.sh and fm-tasks-axi.sh ran from the target worktree against disposable marked homes.
All homes were removed after the drives.
No replacement state reader, tasks CLI or tmux binary was used.

The attributed run was 01M4F2NZEMTNTG7A1KQNEJ55Y7 at 37e8a9a361cbec9d557bbbeaae699c6e72ab6cb9.
Its observed state was working/run-step during Test.
Parked, done and failed run transitions were not observed and remain fixture-only.

Exact reproducible commands and setup are retained in live-driver.py.
Raw observations and persisted queues are in live-transcript.log and live-results.json.
Quiet checks assert unchanged wake queues as well as empty stdout.
Recent notice markers were prospectively aged by 60 seconds to avoid host clock correction affecting repeat suppression; no historical evidence was reconstructed.

## Empty backlog produces no fill-lanes notice

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
(empty)
```

## Ready work below writing maximum is named

Result: pass.

```text
check: idle writing lanes: 0/3 occupied, 0 working, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508463	1	check	idle-writing-lanes	check: idle writing lanes: 0/3 occupied, 0 working, 1 ready: repair-one
```

## Unchanged ready work does not repeat

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
1791508463	1	check	idle-writing-lanes	check: idle writing lanes: 0/3 occupied, 0 working, 1 ready: repair-one
```

## Changed ready set is named

Result: pass.

```text
check: idle writing lanes: 0/3 occupied, 0 working, 2 ready: repair-one,independent-two
```

Persisted wake queue:

```text
1791508463	1	check	idle-writing-lanes	check: idle writing lanes: 0/3 occupied, 0 working, 1 ready: repair-one
1791508467	2	check	idle-writing-lanes	check: idle writing lanes: 0/3 occupied, 0 working, 2 ready: repair-one,independent-two
```

## Full writing maximum suppresses fill notice

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
1791508463	1	check	idle-writing-lanes	check: idle writing lanes: 0/3 occupied, 0 working, 1 ready: repair-one
1791508467	2	check	idle-writing-lanes	check: idle writing lanes: 0/3 occupied, 0 working, 2 ready: repair-one,independent-two
```

## One published lane below release bound keeps ordinary notice

Result: pass.

```text
check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508471	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

## Published lanes saturate release bound and keep repair visible

Result: pass.

```text
check: lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508471	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
1791508472	2	check	lane-backpressure	check: lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one
```

## Unchanged release pressure does not repeat

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
1791508471	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
1791508472	2	check	lane-backpressure	check: lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one
```

## Retiring a published lane releases pressure

Result: pass.

```text
check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508471	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
1791508472	2	check	lane-backpressure	check: lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one
1791508477	3	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

## Unconfigured release capacity reports ordinary availability

Result: pass.

```text
check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508478	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

## Adding PR without release capacity stays quiet

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
1791508478	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

## Removing PR without release capacity stays quiet

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
1791508478	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

## Capacity '00' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:45-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '0000' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:46-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '0' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:47-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '-1' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:49-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:48-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity 'zero' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:50-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '9223372036854775808' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:51-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '18446744073709551616' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:52-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity '9999999999999999999999999999999999999999' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:53-0700] invalid config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity 'directory' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:54-0700] unreadable config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Capacity 'dangling' refuses with diagnostic

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:55-0700] unreadable config/release-capacity
```

Persisted wake queue:

```text
(empty)
```

## Supported positive bound 0001 remains usable

Result: pass.

```text
check: lane backpressure: 1/0001 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508496	1	check	lane-backpressure	check: lane backpressure: 1/0001 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

## Supported positive bound 9223372036854775807 remains usable

Result: pass.

```text
check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508497	1	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 0 working, 1 ready: repair-one
```

## Unavailable real crew state refuses a capacity notice

Result: pass.

```text
(no actionable stdout)
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:58-0700] idle-lane release state unavailable: one
```

Persisted wake queue:

```text
(empty)
```

## Recorded PR establishes pressure despite unavailable crew state

Result: pass.

```text
check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

Diagnostic from the watcher:

```text
[2026-10-08T18:14:58-0700] idle-lane release state unavailable: one
```

Persisted wake queue:

```text
1791508499	1	check	lane-backpressure	check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

## Current real validation saturates capacity without a PR

Result: pass.

```text
check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508503	1	check	lane-backpressure	check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

## Adding PR to already counted real validation does not repeat

Result: pass.

```text
(no actionable stdout)
```

Persisted wake queue:

```text
1791508503	1	check	lane-backpressure	check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
```

## Real validation plus PR on one lane counts once below bound two

Result: pass.

```text
check: idle writing lanes: 1/3 occupied, 1 working, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508503	1	check	lane-backpressure	check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
1791508510	2	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 1 working, 1 ready: repair-one
```

## Second published lane plus real validation saturates bound two

Result: pass.

```text
check: lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one
```

Persisted wake queue:

```text
1791508503	1	check	lane-backpressure	check: lane backpressure: 1/1 lanes awaiting validation or release; land or repair them before new starts, 1/3 occupied, 1 ready: repair-one
1791508510	2	check	idle-writing-lanes	check: idle writing lanes: 1/3 occupied, 1 working, 1 ready: repair-one
1791508513	3	check	lane-backpressure	check: lane backpressure: 2/2 lanes awaiting validation or release; land or repair them before new starts, 2/3 occupied, 1 ready: repair-one
```

