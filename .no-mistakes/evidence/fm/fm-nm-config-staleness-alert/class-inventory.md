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
