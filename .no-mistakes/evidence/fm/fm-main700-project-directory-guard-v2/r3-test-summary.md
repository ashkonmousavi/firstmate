# Project-directory guard: Test-phase result

Target: 7db498716d77d0032384bb658f473bec48b28561.
Verdict: no-go.
No source or test changes remain.

## Confirmed native failure

Codex 0.160.0 received three exact exec_command calls on a disposable primary with a private fm-lab tmux socket and a 120x35 grid.
The call from lab/bin executed `cd ../projects/foo` and created DENIED_SENTINEL inside the protected test home.
The call from lab/outside attempted `cd projects/foo` into an unrelated folder, but the hook blocked it and ALLOWED_SENTINEL was absent.
The independent control call succeeded and created CONTROL_SENTINEL.
The captured PreToolUse payloads carry the session cwd and command, but omit the requested exec_command workdir.
Replaying each original payload reproduces the wrong verdict; changing only the supplied execution cwd produces the intended deny and allow.
This is the unresolved T-codex-workdir vendor-emitter gap, distinct from the declined literal-policy findings.
The transport cannot safely infer the missing field.
A supported effective-cwd API or an explicit supported-coverage decision is required.

Evidence: r3-codex-workdir-result.log, r3-codex-workdir-state.json, r3-codex-workdir-payloads.jsonl, r3-codex-cwd-boundary-replay.json.

## Successful product checks

The base public transport denied `cd bin` and `cd ..`; the target public transport permits them while retaining project denial.
Direct real transport probes exercised protected relative and absolute targets, pushd, unrelated directories, preceding literal directory changes, child-process and quoted-data carve-outs, initial tilde quoting and escaping, cwd overrides, and Cursor output shape.
The unguarded backlog leak was reproduced in an actual Bash shell, then the real guard denied the exact move before execution; the clone backlog remained absent and the home backlog received its permitted update.
Native Claude Code 2.1.292 forwarded persistent execution cwd correctly, denied the protected write, and permitted the unrelated and control writes.
Native Pi 1.0.0 loaded the actual extension, delivered callback ctx.cwd, denied the protected write, and permitted the unrelated and control writes.

Evidence: r3-public-hook-transcript.json, r3-base-hook-transcript.json, r3-claude-cwd-result.log, r3-claude-cwd-state.json, r3-claude-cwd-payloads.jsonl, pi-r3-native-result.log, pi-r3-native-state.json, pi-r3-native-events.jsonl.

## Focused automated checks

The behavior portion of tests/fm-cd-pretool-check.test.sh passed, including registered adapter callbacks, supplied workdir overrides, command-list branch execution, checkout scoping, and fail-open behavior.
A disposable identical runner omitted only the final lint invocation because this Test phase prohibits lint and static analysis.
The runner was removed after the check.
`bash tests/fm-cursor-primary.test.sh` failed at the known missing-cwd payload assertion, exactly the declined R-cursor-o5 concern.
That decision was preserved without edits or a new finding.
The public Cursor transport separately returned the deny object with execution cwd and retained fail-open behavior without cwd.

Evidence: r3-cd-behavior.log, r3-cursor-behavior.log, r3-public-hook-transcript.json.

## Remaining native gaps

Cursor Agent 2026.10.01-e373342 and Grok 1.0.46 launched with disposable workspace-contained user data, but returned Authentication required and Not signed in before any tool call.
These results do not establish that the operator normal login is unavailable.
Their native proof needs a lab-authenticated account or an authorized route that reuses an existing login while keeping all state inside the worktree.
No credential store was copied or modified and no login was attempted.

Omp 18.2.7 loaded the actual extension, but both a session-only auto-approval run and an explicit cursor/claude-4.5-sonnet run with the tracked worker overlay emitted no tool calls within their 75-second bounds.
The available-model catalog lists Cursor chat models and only Ollama embedding models; the openai-codex catalog is empty.
No local generative model route was present in that catalog.
The native check needs responsive Omp provider/model startup that can issue the requested bash calls.

OpenCode was absent from PATH.
Offline workspace installation returned ENOTCACHED; online workspace-only installation of opencode-ai@1.18.35 succeeded.
The real plugin initialized in both headless and 120x35 TUI runs, but the free model endpoint returned HTTP 403 before any bash callback.
Native proof needs an allowed OpenCode provider/model account or endpoint; no credential or global configuration changes were made.

Pi-signed is absent from PATH and no repository-local signed executable is supplied.
The ordinary Pi check cannot prove signed-wrapper adoption; provide the genuine signed launcher to close this gap.

The first native Windows bridge attempt hit WSL UtilAcceptVsock accept4 failure 110.
A bounded retry reached PowerShell, but Set-Location could not resolve the required exact Linux worktree path.
Native PATH discovery found Claude, Node, and the system WSL Bash launcher, but no jq, tmux, Codex, or Cursor launcher.
Native proof needs an authorized Windows-accessible worktree path and supported native guard dependencies and harness setup.
The gate path contract forbids inventing an alternative source path.

## Documentation and phase boundary

The changed public docs/cd-guard.md contract was read directly.
Its block list and absolute-path prose describe project-only denial and permit nonproject changes; its known precision limits remain documented and subject to the recorded declined decisions.
Documentation has no independent live product surface.
The doc-audience checker was not run because static analysis is prohibited in this phase.
Publication, hosted CI, merge under MAIN700, every-home placement and adoption, and FINALIZE-AFTER custody belong to the outer executor and were not executed or claimed here.
No renderer or UI layout is changed; evidence uses actual CLI transcripts, payloads, API errors, and persisted sentinel/backlog state rather than screenshots.

## Cleanup

Every marked lab used its own fm-lab socket and a non-zero 120x35 grid.
Every private server was stopped and its lab removed in its evidence turn.
No Herdr session or default tmux server was touched.
Downloaded dependencies, disposable checkouts, caches, and the temporary runner were removed.
No marked lab or lab-owned process remains; git status is empty.
The dedicated evidence directory retains the transcripts and test drivers.

Evidence: r3-cleanup.json.
