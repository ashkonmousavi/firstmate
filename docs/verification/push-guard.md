# push-guard hook-loading verification

Active empirical record for **which sessions actually load the push-guard PreToolUse seatbelt**.
[`docs/push-guard.md`](../push-guard.md) is the authoritative contract for what the guard blocks; this file only records whether it runs at all, per adapter and per worker kind.

The question this file answers was opened by a 2026-09-08 review finding: a non-mutating run of `bin/fm-push-guard-command-policy.mjs` showed the classifier denying a direct push to `main` while allowing a forced feature-branch push and a remote branch deletion, and whether the hook was loaded in project workers had never been proved either way.
The classifier gap is closed (see `tests/fm-push-guard.test.sh`).
The loading answer, recorded below, is that a project worker does not load this guard at all.

## Result, 2026-09-09

| Adapter | Registered | Loads for a firstmate-repo worker | Loads for a project worker |
| --- | --- | --- | --- |
| claude | yes, `.claude/settings.json` | yes, live-verified below | no |
| codex | yes, `.codex/hooks.json` | yes by registration; not live-exercised in this run | no |
| cursor | no | no; also stands down on the Claude entry it loads | no |
| grok | no | no; explicitly stands down on the Claude entry it loads | no |
| opencode | no | no | no |
| pi | no | no | no |
| kimi | no | no | no |
| gemini | no | no | no |
| muse | no | no | no |

The split is by **worker kind**, not by harness.
Every registration this guard has lives in a tracked repository-root configuration file, so a session loads the guard only when its project root is a firstmate checkout or worktree.

## Evidence

### Registration inventory

```
$ for f in .claude/settings.json .codex/hooks.json .cursor/hooks.json; do
    printf '%s: %s\n' "$f" "$(grep -o 'fm-[a-z-]*-pretool-check\.sh' "$f" | sort -u | tr '\n' ' ')"
  done
.claude/settings.json: fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-push-guard-pretool-check.sh fm-subagent-pretool-check.sh
.codex/hooks.json: fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-push-guard-pretool-check.sh
.cursor/hooks.json: fm-arm-pretool-check.sh fm-cd-pretool-check.sh
```

`.claude/settings.json` and `.codex/hooks.json` are the only two registrations.
Cursor registers the sibling watcher-arm and cd seatbelts but not this one.
No tracked hook configuration exists for opencode, pi, grok, kimi, gemini, or muse.

Two adapters load the tracked Claude entry without being covered by it:

- **Grok** loads Claude project settings, and the entry opens with `[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0`, so it stands down under Grok's own markers.
- **Cursor** loads it alongside its own registration, and `fm_hook_payload_is_foreign_host` in `bin/fm-hook-host-lib.sh` makes the transport exit 0 on a foreign-host payload.

Neither stand-down is a defect - both prevent double evaluation - but neither leaves the adapter protected.

### A worker is never sent a PreToolUse hook

```
$ grep -c 'PreToolUse' bin/fm-spawn.sh
0

$ grep -o '"[A-Za-z]*":\[{"hooks"' bin/fm-spawn.sh | sort -u
"AfterAgent":[{"hooks"
"BeforeAgent":[{"hooks"
"SessionEnd":[{"hooks"
"Stop":[{"hooks"
"StopFailure":[{"hooks"
"UserPromptSubmit":[{"hooks"
```

`bin/fm-spawn.sh` installs no `PreToolUse` hook of any kind.
The `.claude/settings.local.json` it writes into a task worktree carries only busy-state and turn-end events, and the Gemini equivalent under `state/<id>.gemini-settings.json` carries only `BeforeAgent`, `AfterAgent`, and `SessionEnd`.

There is no user-scope registration to fall back on:

```
$ grep -c 'fm-push-guard' ~/.claude/settings.json
0
```

### Registered project clones carry no registration

```
$ for p in projects/*/; do ... done
XAUUSD        claude: no .claude/settings.json   codex: no .codex/hooks.json
no-mistakes   claude: no .claude/settings.json   codex: no .codex/hooks.json
```

A project worktree therefore carries neither file, on either adapter.
Under Codex the session additionally cannot locate the script: its registration re-resolves from `pwd -P` and requires that root to carry `AGENTS.md` and a `.codex/hooks.json` naming this script.

### Live block, claude, firstmate-repo worker

Run from a spawned claude crewmate in a firstmate task worktree, against a throwaway repository on `main` with no remote configured:

```
$ git init -q hooktest && cd hooktest && git commit -q --allow-empty -m init && git branch -M main
$ git push origin main
PreToolUse:Bash hook error: [[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0; exec "$CLAUDE_PROJECT_DIR"/bin/fm-push-guard-pretool-check.sh --claude]:
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[protected-branch-push] a direct git push to main or master is blocked; land it through a PR so CI proves it before main - use bin/fm-pr-merge.sh or bin/fm-merge-local.sh."}
```

The command never executed: the hook blocked the tool call itself.
The absent remote is deliberate, so a hypothetical guard failure could still not have reached a real repository.

## Limits of this record

- The Codex row is proved by registration and by the absence of the file in a project worktree, not by a live Codex block in this run.
  A live Codex exercise is the remaining gap for the positive half of that row; the negative half needs no harness, because there is no hook present to fire.
- This records loading only.
  What the guard blocks once loaded is pinned by `tests/fm-push-guard.test.sh`, which runs with no harness.
- For a project worker the crewmate brief's own prohibition is the only thing forbidding a direct, forced, or deleting push.
  Closing that gap means giving workers a `PreToolUse` registration across the supported adapters, which is a separate change this record does not make.

## Refreshing this record

```sh
for f in .claude/settings.json .codex/hooks.json .cursor/hooks.json; do
  printf '%s: %s\n' "$f" "$(grep -o 'fm-[a-z-]*-pretool-check\.sh' "$f" | sort -u | tr '\n' ' ')"
done
grep -c 'PreToolUse' bin/fm-spawn.sh
tests/fm-push-guard.test.sh
```

Re-run after any change to `bin/fm-spawn.sh`'s hook installation, to a tracked harness hook configuration, or when an adapter is added.
