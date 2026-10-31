# Ruff pre-push live validation

The installed hook was driven using real Git, real Ruff, disposable repositories, bare file:// remotes, and the actual generated Git environment. Every refusal checked the remote ref did not advance; recovery checked the exact pushed commit reached the remote. No source changes were needed.

The direct scenarios cover executable fix commands through PATH, .venv, venv, real uvx and uv tool run with committed ruff==0.12.7; committed and per-ref settings despite dirty local configuration; stubs and notebooks; large excluded files; unavailable tools and unpinned uv; real invalid TOML and Python parser errors; changed-file selection and no-base fallback; independent guard diagnostics; project hook input and refusal; source symlinks and their transition back to regular files; automatic declarations and undeclared repositories.

before-after-regression.log shows the base revision accepts unformatted Python, the target refuses it without advancing the remote, and the displayed fix followed by commit/push succeeds.

The focused tests/fm-git-push-guard.test.sh completed successfully. Its fake-runner cases are supplemental regression coverage, not evidence of live Ruff. Direct live scenario logs contain the real product terminal output.

Two selected fm-spawn-dispatch-profile cases passed: test_keep_ai_trailers_preserves_attribution_and_format_checks and test_keep_ai_trailers_reaches_secondmate_crew_launches. They use fixture session/harness tools and are not claimed as live agent launches. The initial selector accidentally included unrelated allowlist checks and hit the existing prohibition against a secondmate home beneath the code root. Removing the unintended invocations and extracting the same committed runtime to a disposable sibling of the fixture homes resolved that setup issue; spawn-selected.log records the successful rerun. No product workaround or change was applied.

The change is a CLI Git-hook surface. Reviewer-visible evidence consists of terminal transcripts. Live remote worker sessions and vendor agent launches were not exercised; both use the common hook environment and supplementary fixture coverage checks installation and inheritance. No live fleet sessions, operator configuration, or credentials were touched. The declined R9 configuration-containment decision was not reopened.

Independent oracle: accepted user decisions; Git remote ref identity; Ruff's official format exit-code and exclusion contracts: https://docs.astral.sh/ruff/formatter/ and https://docs.astral.sh/ruff/configuration/ (looked up with Exa in this run). No private research book was available in this gate snapshot; outside-checkout project reads and research-book writes were excluded by the current workspace boundary.

Reproduce direct scenarios from this gate worktree by copying live-push-driver.py under .test-live-ruff, creating .test-live-ruff/tmp, then running python3 .test-live-ruff/drive.py. It needs real Git, Ruff, uvx and uv on PATH. Remove the disposable .test-live-ruff tree afterward. Evidence destinations in the driver name this run explicitly.

Tool versions:

```
git --version
git version 2.43.0
ruff --version
ruff 0.14.11
uv --version
uv 0.9.18
uvx --version
uvx 0.9.18
```
