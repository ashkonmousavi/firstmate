# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router's detection and safety sections for static crew and secondmate harness resolution and all explicit overrides.
`config/crew-dispatch.json` can override that static default for one crewmate or scout with concrete harness, model, and effort axes.
For a profile array, load `quota-array-dispatch` after establishing capability, harness/provider facts, required tools, and supported effective effort here; quota preference then ranks only suitable candidates.

`../secondmate-provisioning/SKILL.md` owns inherited local material.
Its harness consequence is that a secondmate's workers receive literal `config/crew-harness` and `config/crew-dispatch.json`, while the primary-only `config/secondmate-harness` is never inherited because secondmates do not spawn secondmates.
A concrete crew value such as `codex` carries that runtime into the secondmate home.
Unset or `default` carries no concrete value, so its workers use that home's own or detected harness rather than the primary's effective crew harness.
The inherited dispatch file applies the same best-fit profiles there.

## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate, while scripts receive concrete axes.

## Launch-attached tool services

`../../../bin/fm-spawn.sh` accepts `--mcp lean|full`. A ship defaults to
`lean`; a scout and a secondmate default to `full`. Use `--mcp full` when the
brief needs persistent code-graph, language-server, type-checker, or other MCP
services. Use `--mcp lean` for a deliberately lightweight scout.

The flag is launch-scoped and never authorizes editing a user-level or project
configuration. A running lean lane can still invoke a task-specific CLI such as
`gitnexus ... --repo fm-<project>` or `pyright <path>` on demand; persistent MCP
availability is selected on the next spawn or relaunch with `--mcp full`.

| Harness | Attachment point and lean disposition |
|---|---|
| Claude | Launch-scoped settings-source restriction plus strict empty MCP config; fixed. |
| Codex | Effective MCP inventory rendered as one launch `-c ...enabled=false` override per enabled server; fixed. |
| OpenCode | Inline config deep-merges and has no universal disable; operator-owned user/project config, documented only. |
| Pi / Pi-signed | Auto-discovered extensions suppressed with the version-probed `--no-extensions`; explicit Firstmate extensions remain; fixed. |
| Grok | MCP comes from user/project config and the verified adapter has no universal launch replacement; operator-owned, documented only. |
| Kimi | Firstmate-owned empty `--mcp-config-file` prevents the default global MCP file from loading; fixed. |
| Cursor | MCP comes from user/project `.cursor/mcp.json`; the CLI exposes persistent `mcp disable`, not a launch replacement; operator-owned, documented only. |
| Gemini | Firstmate-owned system settings set `mcp.allowed` to an empty list; fixed. |
| Muse | No launch-attached MCP/plugin mechanism in the verified build; unaffected. |

OpenCode, Grok, Cursor, and raw launch commands emit a warning when a lean lane
cannot be enforced without touching operator-owned state. Do not translate that
warning into a config write: select a preconfigured lean operator profile or a
harness with a verified launch boundary.

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered delivery signals, and the `empty` / `pending` / `pending-unproven` / `unknown` decision belong only to `../../../bin/fm-composer-lib.sh`.
Tool references record empirical knowledge for those executable owners.

## Adapter verification

For an approved new adapter check, use the spawn owner's raw-launch escape hatch only for a trivial supervised task.
Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, busy state in `../../../bin/fm-busy-lib.sh`, shared composer behavior in `../../../bin/fm-composer-lib.sh`, lifecycle in `../../../bin/fm-control-lib.sh`, and tmux liveness in `../../../bin/backends/tmux.sh` when secondmate use is supported.
Also verify primary integration through `references/common/primary-hooks.md`, model discovery through `references/common/model-and-effort.md`, and one tool record.
A value remains unreachable until its executable owner, portable regression, applicable credentialed live guard, and verification record land together.
`../firstmate-coding-guidelines/SKILL.md` owns harness-dependent proof.
