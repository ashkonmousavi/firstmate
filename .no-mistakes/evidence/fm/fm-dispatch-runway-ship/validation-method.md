# Resolver runtime validation

Acceptance scope follows the recorded operator decision: resolver only; spawn enforcement is deferred.

The real `bin/fm-dispatch-resolve.sh` ran as a CLI subprocess from this gate worktree with a disposable `FM_HOME`, HOME, XDG directories, and TMPDIR inside the worktree.
The driver used real curl over TLS to a disposable loopback classifier endpoint, keeping its predetermined rule response outside the product under test.
No TYPESAFE_API_KEY was available in the environment; the synthetic classifier credential was used only on that loopback endpoint.
This proves the changed deterministic resolver behavior after classification; it makes no claim about live Jev classification accuracy or vendor forecast accuracy.
No worker, primary, Herdr session, or fleet lifecycle was launched.

For the reported regression, ranking, all-tight, default/floor routing, ambiguous/approval evidence, tie, exhaustion, and unrelated-model checks, the installed real quota-axi 0.1.66 derived quota semantics from disposable raw cache snapshots through its supported QUOTA_AXI_SNAPSHOT interface.
Additional cases supplied controlled external quota JSON for weak/missing confidence, an unranked alternative, mixed-confidence scope/date evidence, and schema-6 account binding.
These inputs replace external telemetry, never the resolver executable or its candidate evaluator.
All protocol cases still drove the real resolver CLI through its public argv, FM_HOME, and PATH interface.

## Independent oracle

- The supplied intent requires a through-reset candidate to displace short Claude/Codex even when Claude has the larger spendPriority.
The raw snapshot deliberately combined Claude's nearly unused five-hour window with its overdrawn weekly window, producing a high scalar alongside established short runway using the real quota producer.
The base revision selected Claude; the target selected Grok and explained both Claude/Codex refusals.
- At equal cycle position, Grok's 60% remaining allowance versus Z.ai's 55% produces the larger scalar; reversing their declared order must still select and print Grok first.
- The recorded all-tight decision requires continued selection without the removed summary, including when unrelated healthy providers exist outside the candidate array.
- Weak/unknown/missing-confidence projections cannot justify refusal or activate the gate.
The mixed-confidence worked example places weak evidence at 01:00Z and established evidence at 02:00Z; the refusal must cite the established scope and 02:00Z, irrespective of input order.
- Existing safety contracts require genuine ties to escalate, exhausted quota to stay blocked, unrelated model scopes to stay unrelated, and native Codex to bind to codex-home rather than a healthy unrelated account.

The targeted existing behavior suite also passed with exit 0.
Its fake curl/quota fixtures are offline evidence and are not themselves claimed as live scenarios.

## Research and setup correction

The official [quota-axi README](https://github.com/kunchenguid/quota-axi#readme) and installed `quota-axi --help` document QUOTA_AXI_SNAPSHOT as cache-format input that avoids credential/vendor reads and cache writes.
The official [cache parser](https://github.com/kunchenguid/quota-axi/blob/main/src/cache.ts) owns schema 3 and Codex window identity; [interpretation.ts](https://github.com/kunchenguid/quota-axi/blob/main/src/interpretation.ts) owns recognized provider/window scopes.
The first hand-built fixture was rejected because Codex's five_hour window used label five_hour instead of session.
Independent review identified that identity mismatch; correcting only its label made the real producer accept the fixture.
Grok credits and Z.ai five_hour window IDs were then selected from their documented semantics before the scenario driver was run.
Exa search worked; its initial raw-source fetch failed, and a later repository fetch succeeded.
No product fix was necessary.
This evidence report records the research locally because the assigned workspace boundary prohibits modifying the operational research book.

## Reproduction and cleanup

From this worktree, run `python3 ~/.no-mistakes/evidence/01M68W3DQX4GW58YYY5BKH6ZD6/drive-resolver.py ~/.no-mistakes/evidence/01M68W3DQX4GW58YYY5BKH6ZD6`.
The driver captures product stdout, exit codes, quota inputs, and a baseline comparison.
It waits for every CLI child, shuts down and joins its TLS server, and removes its disposable home in a finally block.
The baseline is extracted using normal git archive into that disposable directory; no other checkout or gate repository files are directly accessed.
The full repository suite, static analysis, delivery, PR, and CI phases were not run.
This is a CLI-only surface; its reviewer-visible evidence is the actual command transcript, without a browser or rendered visual surface.
