Validated head: 4cf7eda699f11ae6df0abc0cd8be3291cf8a7b21.
Consumed retained inventory: round4-class-inventory.md, with Main inbox 007 settled identity/tolerance contract, and round4-fix-handoff.txt.
The owning suite passed freshly, including fixture-only changed selection, deterministic before/after changed-tick rejection, clock steps, comparison boundaries, streaming timeouts, A/B/D, registration and read-only contracts.
Independent live CLI scenarios used real disposable no-mistakes daemons, real procfs, two authenticated loopback SSH endpoints, separate user/PID namespaces, and the registered custom-check snapshot consumer.
Live server timeout warnings appeared at 0.253 seconds with both remote probes alive; completion was 15.072 seconds.
Live Zenbook timeout warnings appeared at 0.271 seconds with both remote probes alive; completion was 15.072 seconds.
Natural btime changes 1791085597/1791085599/1791085601 did not invalidate the unchanged real daemon or repeat its episode; a fresh episode still warned.
Six real-daemon comparison cases passed, including 10-second equality and one nanosecond beyond it.
Initial live restart driver had a setup error: server offset remained 3 nanoseconds, within the settled 10-second tolerance.
Corrected round4-restart-driver.py used config offsets 100 seconds beyond start and demonstrated that replacing PC clears only PC while server remains stale.
Initial record-race home exceeded the Unix socket path limit; the shorter worktree-local home in round4-test-record-race-short.py succeeded.
These initial setup attempts are retained without changing their output; round4-final-results.json incorporates the successful re-drives.
Authenticated isolated namespaces reused numeric PID 2 with different real kernel start ticks; remote helpers correctly sampled their own procfs, while the PC procfs refused those records.
The daemon record has no saved ticks, so PID reuse completed before the first sample is not provable under the settled interface.
During-sampling tick reuse was exercised through the deterministic public proc fixture, not a real kernel PID-reuse race.
Live A/B room-dependent alerts could not be reached: loopback endpoints shared a host with 6 integer GiB MemAvailable; the consumer requires greater than 6.
Provide an authorized disposable SSH VM with at least 7 GiB MemAvailable to re-drive live A/B; changing VM memory or accessing real fleet machines is outside this phase.
The owning suite's synthetic A/B fixtures passed, and the live D alert plus deduplication passed with three actual isolated remote-job workers.
Actual installed PC/server/Zenbook registration and observations remain Main-owned and were not accessed.
No source changes, lint/static analysis, broad suite, pipeline control, push, PR or CI operations were performed.
Downloaded SSH packages were extracted solely inside the worktree, never installed; all test-created dependencies, keys, homes and daemons were removed after verification.
The changed surface is a CLI/custom-check alert; its product evidence consists of CLI transcripts, not GUI screenshots.
