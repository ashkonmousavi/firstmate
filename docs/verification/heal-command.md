# `/heal` command verification

Audience: maintainer verification.

This record supports the active guarantee that `/heal` is a manually invoked, argument-aware Claude Code skill whose private ledger mutations require verified Firstmate session-lock ownership.
The internal [`heal` skill](../../.agents/skills/heal/SKILL.md) owns the invocation route, and its [workflow](../../.agents/skills/heal/workflow.md) owns diagnosis, repair follow-through, lifecycle, checkpoint, and curation behavior.
[`bin/fm-heal.sh`](../../bin/fm-heal.sh) owns the mechanical record and safety contracts.

## Claude Code frontmatter receipt

The check ran on 2026-09-09 with Claude Code 2.1.266 and Context7 MCP server 4.0.5.
The mandatory Context7 `resolve-library-id` request asked for the official Claude Code behavior of `user-invocable`, `disable-model-invocation`, and slash-command arguments.
Context7 returned `Monthly quota exceeded` before it supplied a library ID, so exact-version Context7 documentation was unavailable.
The Context7 library ID is therefore recorded as unavailable rather than inferred.
The Context7 request was made directly through its connected MCP HTTP endpoint, and ordinary web search then located Anthropic's current official [Claude Code skills documentation](https://code.claude.com/docs/en/slash-commands) as the fallback authority on 2026-09-09.
Anthropic's page has no per-patch documentation selector, so the installed 2.1.266 patch could not be matched to a separately archived page.

The official reference says that `disable-model-invocation: true` prevents automatic model loading, `user-invocable` defaults to true and may be stated explicitly, direct `/name` invocation is supported, and `$ARGUMENTS` receives text following the command name.
The implementation therefore sets both requested booleans explicitly, uses `$ARGUMENTS` for an optional window such as `4h`, and omits `context: fork`, model overrides, and subagent routing so the primary session remains the executor.

## Claude Code command discovery and argument passing

The discovery check used a disposable nested Git repository, never the live Firstmate home.
Its `.claude/skills/heal/SKILL.md` copied the installed command's name and invocation-control frontmatter and returned a unique sentinel containing `$ARGUMENTS`.
The repository's real `.claude/skills` path was separately resolved as the existing symlink to `../.agents/skills`, so the shipped directory uses the same Claude Code discovery surface.

The exact commands were:

```bash
claude --version
readlink .claude/skills
cd scratchpad-heal-discovery
git init -q -b main .
claude --model haiku --allowedTools Skill -p '/heal 4h'
```

The exact output was:

```text
2.1.266 (Claude Code)
../.agents/skills
HEAL-DISCOVERY-4h
```

The sentinel proves that a fresh Claude Code process discovered `/heal`, invoked it only by explicit command, loaded its body, and substituted the optional window argument.

## Isolated behavior suites

Both suites use `tests/lib.sh` to allocate temporary homes and never point `FM_HOME` at the live operational home.
The verified-owner cases construct an isolated harness ancestry and lock record, while advisor cases intentionally provide no owned lock.

The exact commands were:

```bash
./tests/fm-heal.test.sh
./tests/fm-heal-lifecycle.test.sh
```

The first suite reported seven passing cases covering verified-owner mutation, read-only advisor refusal, occurrence and notification accounting, existing-owner deduplication, historical refresh, hold classification, consuming-workflow proof, and startup-memory and digest exclusion.
The second suite reported seven passing cases covering every permitted and forbidden lifecycle edge, reasoned dismissal, evidence-bound reopening, interrupted and repeated scans, index and checkpoint recovery, overflow, archive recurrence, and a completed scan with no actionable finding.
Before `bin/fm-heal.sh` existed, each suite was run once and failed at its first helper-dependent behavior, which established the tests' failure capability before implementation.
