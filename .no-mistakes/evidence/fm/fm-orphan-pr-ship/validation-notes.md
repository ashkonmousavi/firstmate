# Orphan sweep test evidence

Target d03fc1e3835a5221eed114ea1fa9db3ffadf89bb; base baae6e980da1cc4a9ab7d49dcf9d4837f6c92cd2.

The focused suite tests/fm-pr-orphan-sweep.test.sh exited 0. It replaces gh and tmux with recording stubs; its forge and watcher assertions are regression evidence, not live proof. Retained output: orphan-focused-tests.log.

local-product-transcript.json contains commands, actual exit statuses, stdout, stderr and persisted-state observations from the genuine executable without replacement tools. Reproducer: drive-local.py. From this worktree, create .test-phase/tmp, run that retained Python driver, then remove .test-phase. It creates disposable marked lab homes and removes them in its finally block.

Live checks passed: local-only, forge-bound, non-GitHub, malformed and missing publication targets are quiet without a wake or marker; --report and unknown arguments return usage and exit 2; a real unauthenticated forge listing reports a diagnostic without false wakes.

No GH_TOKEN or GITHUB_TOKEN was supplied in the execution environment. With an isolated empty GH_CONFIG_DIR, actual gh 2.102.0 refuses both listing and polling pending authentication. This does not claim that the operator login is unavailable: operator login/configuration was intentionally not consulted. No sign-in, credential mutation or shared-service mutation was attempted. A fake gh or API response cannot satisfy the live-evidence requirement; localhost cannot supply a genuine github.com GraphQL label episode. Live completion requires a disposable GitHub read credential and a repository seeded with aged, young, relabeled and poll-covered conflict-labeled fm/ PRs. Fixture preparation must be supplied through an authorized channel outside this phase's worktree-only authority.

Core live-untested scenarios: forge-to-watcher wake delivery and owner routing; age threshold; episode identity across relabeling, listing omissions and coverage changes; case-insensitive authenticated coverage and teardown; publication target selection and literal fm/ filtering. All passed only in the stubbed focused suite.

Research: consulted the project research-book index and research skill. Official CLI listing contract: https://cli.github.com/manual/gh_pr_list . Credential/config isolation: https://cli.github.com/manual/gh_help_environment . GraphQL authentication: https://docs.github.com/en/graphql/guides/forming-calls-with-graphql . Central research-book writes are outside this phase's boundary; findings are retained here.

No source changes, linters, formatters, broad suite, pipeline controls or delivery phases were run. Required local commands were awaited to exit 0. The CLI/watcher surface requires no screenshot. Overall verdict: inconclusive because central GitHub-backed behavior lacks live proof.
