# Fix handoff

Inventory: /home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M/class-inventory.md
Read this exact inventory before the next fix re-check.
Verify every listed occurrence and the regression results below, then search for missed siblings within the listed scope.
Re-check these fixes only; do not start another whole-branch review.

The supplied inventory was written and read back before source edits.
The original fixture mapping and six bounded parallel probes were retained.
The current defect was deferred stdout at both the collector wait and episode final publication.
All three metadata calls now use the same observe boundary, which bounds execution, discards failed transport output, and immediately streams a completed observation or unavailable result.
The episode loop flushes diagnostics and sorted confirmed stale sets as they arrive.
The reporter compares confirmed identities to prevent an unchanged server warning repeating while a restarted PC clears retained evidence.
The marker still commits the final metadata-only digest map by private atomic replacement after collection.
No sampler metadata-read logic, authenticated host paths, watcher cadence, lifecycle commands, or A/B/D behavior changed.
No new CLI, scheduler, watcher, fallback transport, or installed private hook was introduced.
The only --episode collector caller found is tests/fixtures/server-idle-watch.check.sh; docs/scripts.md points to it and now describes streaming.
The header owns publication mechanics; docs/scripts.md remains an operator-current reference with the same ownership pointer and no removed safety fact.

# Verification

Command: bash bin/fm-test-run.sh tests/fm-nm-config-staleness.test.sh
The suite also executes fixture-only fm-test-run.sh --list --changed --base HEAD in its disposable repository and requires exactly its owning test.
Red log: /home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M/prompt-emission-red.log
The red-first fixture failed with original production code for both remote hosts: stale PC output was absent within five seconds while both health and metadata probe PIDs were live; final output arrived after approximately fifteen seconds.
Intermediate failed log: /home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M/prompt-emission-postfix-1.log
The existing restart assertion caught a repeated server warning; comparing confirmed stale identities corrected this regression.
Green log: /home/tegris/.no-mistakes/evidence/01M43P3QK7WHEXNJJNX0D6ME6M/prompt-emission-green.log
Final result: one suite, zero failures, zero skipped gates, 43446 ms suite duration.
Hanging server: confirmed PC and Zenbook stdout at 0.036 seconds with server health and metadata probes live; check completed at 15.028 seconds with the server unavailable diagnostic.
Hanging Zenbook: confirmed PC and server stdout at 0.037 seconds with Zenbook health and metadata probes live; check completed at 15.026 seconds with the Zenbook unavailable diagnostic.
Each warning line is sorted and contains only confirmed stale machines; the final line contains the entire independently verified stale set.
Unchanged three-host and single-host episodes remain quiet; daemon identity replacement clears only the old mismatch, and a fully cleared episode warns again on fresh stale evidence.
Distinct unknown cases, malformed and failed probes, A/B/D alerts, exact-byte private registration, command-log lifecycle exclusion, and immutable fixture config contents passed.
This is public executable fixture evidence, not installed or signed-in host integration.
The dedicated outer pipeline still owns the broader test, lint, publication, PR, and CI phases.
No external network calls or live private fleet operations were performed.
9b15c32621f8eee38efa93a9bfeeccb350da6432a406c310fc69b99d60497906  bin/fm-nm-config-staleness-check.sh
d296cef0b4e6f5599088f39743b1e9d752b00ae4d7a5983effd45d1d84013fea  tests/fixtures/server-idle-watch.check.sh
b98ed81264170d73b4a8ee2214330682cc3903aa31d7e25601dbffe7fbe59ce9  tests/fm-nm-config-staleness.test.sh
\nVerified fix commit: 68ac1b56cd6bb3979d2b141cb3a771289bcede4c
Subject: fix(bin): emit confirmed config staleness promptly
