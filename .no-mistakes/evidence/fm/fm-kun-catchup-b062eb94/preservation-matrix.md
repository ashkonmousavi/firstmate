# Catch-up acceptance evidence

The exact upstream b062eb94 and the supplied fork base are both ancestors of HEAD.
The merge fbc43df6 has the upstream revision as its second parent; a8ba9c2b also retains the supplied fork base.
The topology and exact claim-reaper restore receipts are in lineage-and-restore.log.

| Fork addition | Evidence and boundary |
| --- | --- |
| Lane caps and memory admission | AGENTS.md section 7 retains the ceiling, per-lane admission, available-memory threshold and fail-closed missing-reading rule. The project-capacity regression exercises shared occupancy and concurrent last-place refusal through controlled transports. |
| Surgical preps and nav-prep install | The surgical scaffold and explicit install owner remain. The prep-install regression exercises valid installation, malformed/missing preparation refusal, byte preservation and spawn admission. |
| Dispatch router and Grok bot dispatch | Both owners are unchanged against the supplied base. live-dispatch-cli.log shows ordered selection and quota boundaries through the real CLI. Grok regression uses a controlled bridge; no external Bot conversation is claimed. |
| Navigation-mate consult | The advisory consult contract remains in AGENTS.md section 7. This is preserved guidance, not proof of model interpretation. |
| Heartbeat deploy-health and served-version check | AGENTS.md section 8 retains health and served-target checks. No operator service was contacted or deployed acceptance claimed. |
| CI map in learnings | AGENTS.md retains the requirement to map forge/CI/deploy machinery before relying on it. No private learnings file was read or modified. |
| Lanes line | The compact lanes line remains in AGENTS.md. No live fleet report was requested. |
| Push skill | The tracked push skill is unchanged against the supplied base and its trigger remains. No fleet takeover was executed. |

These are source-preservation and focused behavior receipts.
Installed adoption, PR readiness, CI, guarded merge and task landing remain with the outer executor and Main.

Both actual dialog surfaces were driven in a private 120x40 tmux lab.
Claude native shell mode made its exit picker reproducible with temporary configuration and without model authentication.
The normal-login trust and isolated no-login screens are setup evidence, not remaining blockers.
The Codex working prompt needed a subsequent Enter before the real turn started.
The earlier controls-driver failure describes that repaired setup sequence, not a product regression.

The Herdr E2E uses real Firstmate spawn/teardown, Treehouse and named-session Herdr with sleeping shell workloads.
It proves backend placement, focus, lock serialization, identity recovery and teardown, not vendor model behavior.
No Herdr GUI screenshot was retained because the test operates detached through its real CLI/API and guarded lab helper.
Actual Codex and Claude terminal surfaces are rendered in live-terminal-captures.html.

The only tracked Test-phase edit adds owner directory permission restoration to the Herdr test cleanup.
The original cleanup left mode-0500 Git-hook directories behind.
Focused RED/GREEN execution of cleanup_all reproduced the failure, verified removal, and proved an outside symlink target kept its permissions.
The full Herdr runtime assertions and default-session tripwire passed before that cleanup-only repair.
The two claim-reaper files remain byte-identical to a8ba9c2b.
