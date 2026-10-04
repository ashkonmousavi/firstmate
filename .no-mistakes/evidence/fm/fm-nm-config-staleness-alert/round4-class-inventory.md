Run: 01M43P3QK7WHEXNJJNX0D6ME6M
Observed pipeline head: 4e476e7ce9634f930113360be4384dbc312395eb
Authority: inbox 004, Main decision, fix both in one round; run probes in parallel within watcher 30s deadline; print each confirmed stale machine as soon as known; add hanging-remote fixture.

standards-1 cause class: new executable fixture paths lack owning-test selection.
At this head bin/fm-test-run.sh:1692-1693 explicitly maps tests/fixtures/server-idle-watch.check.sh to fm-nm-config-staleness.test.sh.
The original cause is gone at this head. The pipeline Fix retained log reports fixture-only changed selection test passed.
Search scope: bin/fm-test-run.sh owning maps, all newly added paths, tests/fm-nm-config-staleness.test.sh fixture copy and test-selection assertions.
No other new fixture file in this branch.

spec-1 original cause class: sequential local/remote health and metadata sampling exceeds watcher deadline, losing confirmed independent stale evidence.
At this head every health and metadata probe is bounded by timeout -k 1 15, all six start before the shared wait.
All affected occurrences: fixture health server, zenbook, pc and metadata pc, server, zenbook.
The pipeline Fix retained log reports both hanging-remote scenarios finish within the public watcher deadline and preserve pc stale plus unavailable host diagnostic.

Remaining part of Main decision: confirmed stale output is still deferred until every probe exits. The shared wait precedes all aggregation in tests/fixtures/server-idle-watch.check.sh; helper episode collects every stdin line before printing its warning. Neither current timeout fixture checks emission while a remote is pending; they capture final command output.
Affected occurrences: check shared wait and pc/server/zenbook metadata result aggregation; helper episode stdin loop and final warning publication; owning suite hanging server and zenbook cases.
Search scope: all --episode callers and new helper, fixture, owning suite and docs/scripts.md. Only this fixture is the new collector caller; docs points to it. No live private hook was changed.
Source proof establishes deferred publication; prompt emission under a hanging remote remains unproven by the current public fixture assertions.

Next authorized Fix handoff must retain this inventory in existing run evidence before editing, fix/test every listed occurrence, and require next Review to consume that exact retained inventory, verify all listed fixes and regression evidence, and search for sibling paths. Preserve unknown status, sorted warning, unchanged-episode deduplication, private atomic metadata-only markers and existing A/B/D behavior. No daemon lifecycle or config-value reads.


Round 4 Test fix inventory, retained before editing
Run: 01M43P3QK7WHEXNJJNX0D6ME6M
Observed pipeline head: 3745e8fea8d51a3e3b436817a18f5c8d996c8759
Authority: Main decision in steering inbox 007; both current Test findings selected.

Exact Main words:
Main decision, contract settled: process identity = (PID, kernel start ticks, field 22 of /proc/<pid>/stat) and nothing else; never use btime or any wall-clock value for identity, so clock steps cannot reject the same process, while a reused PID still fails because its start ticks differ. Staleness only: daemon start wall time = current btime + ticks/CLK_TCK, compared to config mtime with a 10-second tolerance. Make the retained clock-step regression pass, keep the PID-reuse regression. Commit early.

Cause: reconstructed UTC birth from current btime was used to reject otherwise unchanged PID/tick identity; wall-clock movement changes btime while PID, kernel start ticks, record and config mtime remain fixed.
Owning source: bin/fm-nm-config-staleness-check.sh sample() reconstructs birth and rejects abs(record UTC - birth)>2 seconds. identity() reads field 22 (tail index19 after pid/comm). The before/after checks, record validation and output must use the settled separation between process identity and staleness.
Sibling occurrence: episode() evidence currently includes started_at; remove wall-clock fields from identity/dedup evidence so clock changes alone are not new daemon identities.
Affected public evidence: tests/fm-nm-config-staleness.test.sh retained clock-step regression and PID-reuse/changed-start-tick fixture, strict/equal/older comparison cases, streaming hanging-remote warnings, restart/clear/dedup and malformed/unavailable cases; adjust comparison fixtures for the explicit 10-second tolerance and test its boundary. Keep a genuine failing PID/tick-reuse case rather than conflating an old UTC record with a changed kernel identity.
Affected prose/interface: helper header and docs/scripts.md must state the 10-second comparison tolerance and clock-independent identity accurately, without AGENTS additions.
Retained independent evidence: staleness-clock-probe.py/log and disposable authenticated PID-namespace/live-driver scenarios in the run EvidenceDir. Re-run the failing clock-step case with the settled contract, keeping timestamps sufficiently beyond the 10-second tolerance when asserting stale; check the same PID/ticks remain verified when btime changes. Re-run kernel tick reuse rejection and both hanging-remote scenarios. Update live validation assertions to this explicitly superseding contract, while retaining the old no-go evidence.
Search scope/negative evidence: all btime/started_at/start-tick references in the helper, owning suite, sanitized collector and docs/scripts.md, plus retained clock/namespace driver. Only one tracked helper and one new collector exist in the branch. No actual installed PC/server/Zenbook hook has been changed.
No config values, process environment, credentials, sockets, pipeline DB, daemon lifecycle, /proc/locks or daemon.lock reads are authorized for the helper. Lab test-owned setup/cleanup stays isolated. Preserve bounded parallel probes, prompt flushed output, partial failure diagnostics, atomic private metadata markers and A/B/D behavior.

Required handoff: next Test/re-check and Review must consume this exact inventory, verify each listed occurrence and regression result and search for missed siblings. Do not track private evidence.
Before-fix reproduction: round4-before-fix.log; focused owning suite fails unchanged-identity clock-step assertion.
