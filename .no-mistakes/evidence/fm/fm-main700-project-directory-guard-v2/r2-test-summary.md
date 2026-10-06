# Project-directory guard: fresh Test-phase evidence

Target: 7db498716d77d0032384bb658f473bec48b28561.
Verdict: no-go.

The base public guard blocked `cd bin` and `cd ..`; the target public guard allowed both while retaining project-directory denial.
Real public transport probes exercised protected and unrelated literal destinations, preceding literal cd/pushd commands, scoped/data carve-outs, tilde prefix quoting, Cursor output shape, and the persisted backlog leak.
The unguarded clone-backlog leak was reproduced, then its exact command was denied before execution; the home backlog received a separate permitted update.
The focused guard behavior suite passed with only its final lint invocation omitted because this Test phase prohibits lint and static analysis.
The required Cursor portable suite failed on its payload without cwd, the exact previously declined R-cursor-o5 mismatch; it was preserved without a new finding or source edit.
The real Cursor transport returned a deny object when given cwd and preserved fail-open behavior without cwd.

Native Codex 0.160.0 omitted exec_command workdir from its actual PreToolUse payload.
Its session cwd was the lab home, but the protected command executed from lab/bin and created DENIED_SENTINEL.
An unrelated relative destination executed from lab/outside was blocked and ALLOWED_SENTINEL was absent.
CONTROL_SENTINEL was created by a separate successful call.
Replaying the captured payloads reproduced both verdicts; supplying only the actual execution cwd reversed both to the intended verdicts.
This is the previously unselected T-codex-workdir API gap, distinct from the declined literal-policy findings.
A supported effective-cwd API or an explicit supported-coverage decision is required; the transport cannot safely infer an omitted workdir.

Native Claude Code 2.1.292 delivered actual persistent cwd changes in hook payloads and correctly denied the protected write, allowed the unrelated write, and created the control sentinel.
Native Pi 1.0.0 loaded the real primary extension, emitted its actual callback ctx.cwd, denied the protected write, and created the unrelated and control sentinels.

Cursor Agent 2026.10.01-e373342 and Grok 1.0.46 were launched in workspace-contained user-data homes; they returned Authentication required and Not signed in respectively, with no tool attempts.
These results do not claim the operator's normal logins are unavailable.
Omp 18.2.7 loaded the real extension but emitted no tool events during a 150-second run; a separate run with per-session auto-approval and a 60-second CLI limit also emitted no events before its 75-second bound.
Omp's model/tool startup remains unavailable for proof; no credential stores or provider configuration were changed.
OpenCode was absent from PATH, and offline workspace materialization failed with ENOTCACHED.
Workspace-only online materialization of OpenCode 1.18.35 succeeded; both its headless CLI and 120x35 TUI reached a provider 403 stating the free tier can only be used from within OpenCode.
The real plugin initialized, but no bash tool reached the callback.
The signed Pi launcher was absent from PATH and no repository-local signed launcher was supplied; ordinary Pi evidence does not prove signed-wrapper adoption.

Read-only Windows command discovery now succeeded and found claude.exe, node.exe, git.exe, and the system Bash WSL launcher, but no jq or tmux.
Attempting the exact supplied Linux worktree path in native PowerShell failed at Set-Location before invoking Claude.
Native proof needs a permitted Windows-accessible workspace route and the guard's native shell/dependency and authenticated-harness setup; the gate path contract does not permit guessing an alternative project path.

The changed cd-guard documentation was read as its own public text contract.
Its current block list and absolute-path paragraphs describe project-only denial and permit unrelated directory changes.
The doc-audience checker was not run because this phase prohibits static analysis; documentation has no independent live product surface.
Publication, current-head CI, merge under MAIN700, every-home placement/adoption, and FINALIZE-AFTER custody remain outside this Test phase's authority.

Every native lab used a marked workspace-contained home, a private named fm-lab tmux socket, and a non-zero 120x35 grid.
Every lab server was stopped and its home removed in its evidence turn.
No default Herdr session or default tmux server was used.
Transient copied checkouts, downloaded dependencies, and the temporary test runner were removed.
No source, test, documentation, memory file, pipeline, publication, or installed-home change is retained.
