# Codex maintenance stamp validation

The public oracle is the author intent: a stale account check becomes silent and exits 0 immediately after successful maintenance, even when Codex leaves auth.json unchanged; failed maintenance must not reset the maintenance age.
The guard remains the executable regression case `test_codex_spawn_and_checks` in `tests/fm-worker-account.test.sh`.

## Research

The existing research-book index points to `tool-gap-research-2026-11-02.md`, which recommends independent vendor homes and ordinary Codex execution for credential maintenance.
The official guide states that normal execution refreshes ChatGPT auth only when the session is stale, and a weekly lightweight exec is the supported maintenance pattern: https://learn.chatgpt.com/docs/auth/ci-cd-auth .
The custom provider and isolated CODEX_HOME configuration are documented at https://developers.openai.com/codex/config-advanced and https://developers.openai.com/codex/config-reference .

## Reproduction and results

Hypothesis: auth file age alone keeps a check red when normal exec succeeds without rewriting auth.json.
Disproof would be a successful base-version maintenance followed by a green check with the same old credential file.
The base version instead returned check=1, maintain=0, check=1 with unchanged synthetic credential bytes and metadata.
The target returned check=1, maintain=0, check=0, check=0 for both independent folders.

`drive-codex-stamp.py` drives the actual Firstmate executable and installed codex-cli 0.166.0 against a deterministic loopback Responses API provider.
Only the external model API is substituted; no fake Codex executable or Firstmate implementation is used.
Synthetic file-backed API-key records avoid reading, copying, refreshing or mutating any operator credentials.
This validates the maintenance success/failure and filesystem contract; production OAuth refresh and remote machine deployments are outside this change and were not exercised.

The retained CLI transcript also proves failed exec creates no stamp and does not renew an old stamp, successful recurring maintenance renews an existing expired stamp, the check is green 60 seconds before the six-day deadline and red at six days, expired/future/linked/non-file stamps remain red, a recent credential write remains green, missing auth/config remains red, moving a folder preserves its marker, and both generated watcher commands exit 0 silently.
Successful maintenance preserves each auth file's bytes, mtime, size, inode and permissions.
The marker is mode 0600 and contains only a UTC timestamp.

The existing `test_codex_spawn_and_checks` case was run by retaining the original shell definitions and invoking only that case in a temporary sibling test script, which was removed afterward.
It passed; its fake-runner result is supplemental regression evidence, not live-product evidence.

## Reproduce

From the same gate worktree with codex and python3 on PATH:

```sh
python3 ~/.no-mistakes/evidence/01M6F73V2MFRH20X4XJX9AVPBG/drive-codex-stamp.py
```

The driver bounds subprocess lifetimes, stops and joins its local provider, and removes its worktree-local lab automatically.
The completed driver and focused regression command both exited 0.
No source changes, persistent test fixtures, or child servers remain.
