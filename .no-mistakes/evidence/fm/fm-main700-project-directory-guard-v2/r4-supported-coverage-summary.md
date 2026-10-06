# MAIN732 supported Codex coverage Test fix

Scope is T-codex-workdir and test-2 only, under corr=8e7fb2fba273a8c2.
The starting and unchanged pipeline HEAD is 7db498716d77d0032384bb658f473bec48b28561; this phase leaves its source fixes uncommitted for the outer executor.
No Review findings, Cursor missing-cwd fixture, original authored commit, verified bundle, or pipeline controls were changed.

## Root cause and RED

Retained Codex 0.160.0 payloads contain the session cwd and command, omitting the requested exec_command.workdir.
The previous transport substituted session cwd for that omitted execution directory.
Replay returned allow for the protected relative command and deny for the unrelated relative command; correcting only the supplied cwd reversed both verdicts.
The independent control write stayed allowed.
These RED results are retained in r4-captured-red-replay.json; the original r3 native witnesses remain untouched.

## Change

The Codex registration explicitly selects --codex.
That transport mode removes the session-cwd fallback while retaining any supplied tool execution directory.
Without initial execution cwd, the policy limits checks to anchored targets across the whole command.
Claude continues to use its real top-level execution cwd; other adapters and output shapes remain unchanged.
The authoritative supported-coverage owner is docs/cd-guard.md, with native readback in docs/verification/runtime-backends.md.
The portable Codex matrix now supplies explicit tool workdir for its fully resolved cases and separately executes the actual registered hook for omitted-workdir coverage.

## GREEN

TMPDIR="$PWD/.gate-cd-validation/tmp" bash tests/.gate-cd-behavior.test.sh exited 0.
That disposable runner was an identical copy of tests/fm-cd-pretool-check.test.sh with only its final prohibited lint invocation omitted.
The 143 cases across eight entry forms, registered hooks, OpenCode/Pi/omp callbacks, branch-state comparisons, leak regression, and new Codex supported-coverage regression passed.
Output is retained in r4-focused-cd-behavior.log.
Retained Codex payload replay now allows both relative commands and the control, while retained Claude payload replay still denies the protected destination and allows the unrelated destination.
Those results are retained in r4-captured-supported-replay.json.

python3 .gate-cd-validation/native-codex.py exited 0 with Codex 0.160.0 and seven real tool calls.
Absolute and home-anchored protected sentinels were absent after persistent-cd denials.
Unrelated absolute/home targets, both unchecked relative targets, and the independent control produced their sentinels.
All seven real captured payloads omitted tool workdir and carried the same session cwd.
This proves the accepted partial coverage, including the intentional allowance of the protected relative target; it does not prove universal Codex protection.
The actual invocation and sentinel state are retained in r4-codex-supported-state.json; transcript and payloads are in r4-codex-supported-result.log and r4-codex-supported-payloads.jsonl.
The reusable private native driver is retained as r4-native-codex-supported.py.
Earlier probe setup receipts are retained separately and are not product verdicts: an interrupted startup, recorder-discovery mismatch, and untrusted fixture setup were corrected before the successful run.

No lint, formatter, static analysis, full repository suite, new Review, delivery, or pipeline control was executed.
The declined Cursor missing-cwd assertion and other earlier native availability gaps remain on their existing follow-ups.
Remote CI and delivery remain owned by the outer executor.
All disposable worktree test scripts, fixture repositories, caches, native logs, and sentinels were removed after evidence retention.
