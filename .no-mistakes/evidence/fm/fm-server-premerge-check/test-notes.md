Validated target 67192a215d3f6309074afdfea26a98658218aacc against base 5e21b96150e4e834254a6a5c6f8ce1b3a7fb05fb.

The targeted public CLI suite ran via `bash bin/fm-test-run.sh tests/fm-q-premerge-plan-check.test.sh --json <evidence>/targeted-run.json` with a temporary output recorder selected through FM_PREMERGE_CHECK_CLI and TMPDIR inside the run worktree.
The recorder delegates to the unchanged real helper and retains its stdout, stderr, return status and merge identities in public-cli.jsonl.
Two recorder setup mistakes were corrected before the successful complete run: the recorder needed a Bash entry point, and its missing-Python fallback needed the absolute Bash interpreter.
Their setup logs are retained separately; these were driver failures, not helper failures.

The suite uses real Git graphs and the real Firstmate helper with synthetic BASE-owned Q checkers.
It establishes orchestration, refusal, closure handling, snapshot fidelity, private history, origin resolution, warnings and source-state protection; it is not proof of production Q receipt semantics or installation.
The suite's HTTPS transport seam separately executes generated ASKPASS callbacks for allowed, blocked and mismatched prompts.
Those stub-transport callback cases are supplemental behavioral checks, not real HTTPS transport proof.

`python3 -I .gate-live-tmp/live-https.py` separately drove the real helper and real Git through disposable loopback HTTP and TLS services backed by real git http-backend.
All HTTPS names were routed through a local CONNECT fixture that opens no upstream connection, using a throwaway certificate trusted only by the child Git process.
Fake gh supplied only fixture credentials and asserted explicit github.com token scope, including with GH_HOST=other.invalid.
The real Git tests covered username/password prompt forms, username-bearing origins, unavailable/rejected fake credentials, HTTP, other hosts, deceptive hostnames/userinfo, and a cross-host redirect refusal.
The redirected request was refused before any credential callback; this does not claim a real mismatched ASKPASS prompt was observed.
The TLS fixture initially needed Content-Length responses and acceptance of the explicitly supplied fixture username; correcting those setup errors produced the final passing run.
Final request observations, scoped-token retrieval counts, exact helper receipts and unchanged source state are in real-git-https.json.
No real token was read and no external host was contacted.

No baseline test execution was supplied by the outer executor; only the above targeted checks ran here.
No full suite, lint, formatter, static-analysis, push, PR, CI, fleet lifecycle, or other pipeline phase ran.
This change has a CLI surface; visual UI evidence is not applicable.
All fixture servers were stopped and temporary files in the worktree were removed.

The installed q-server helper/hash, server instruction and current real-Q BASE/PR_HEAD/TREE receipt remain untested here.
The bounded worktree contains no Q plan-tool closure or installed q-server environment, and this phase cannot read operator data, install into fleet homes, or perform production operations.
Main/fleet-ops owns post-merge distribution and must supply installed source/hash plus the current real-Q receipt; local fixtures cannot substitute for that receipt.
