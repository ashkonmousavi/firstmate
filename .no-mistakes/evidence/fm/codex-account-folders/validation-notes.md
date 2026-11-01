# Account-folder validation

Target: d6e608d3f8a51858ea0c2a8ddf42d4437f415ed1, plus the retained test-only synthetic credential fixture repair.

## Product evidence

- account-cli.log: real installed Codex and quota-axi, independent synthetic file-backed folders, shared configuration preparation, lexical unmeasured selection, two folder-labelled unavailable quota rows, registered healthy checks, stale/missing-auth alarms, and metadata-copy/link/invalid-list refusals. No real credential was used.
- spawn-refusal.log: real fm-spawn against a marked disposable lab. Empty lists, signed-out folders and raw CODEX_HOME overrides refused without publishing metadata or an endpoint. No default backend session was contacted.
- live-guard-final.log: real Codex 0.166.0 refused duplicate synthetic ChatGPT identities and accepted distinct identities silently using a disposable localhost routing service. Codex itself decoded credentials and emitted identities. Retained Claude 2.1.316 and Pi 1.0.0 checks also passed; optional pi-signed was absent. Actual suite exit: 0.
- real-cancellation.log: a real native Codex process waited on a disposable localhost service. The internal app-server deadline completed in about ten seconds. External SIGTERM finished in milliseconds at both subprocess ownership sites. Every owned native process was reaped and an unrelated process survived. Actual driver exit: 0.
- treehouse-installer.log and treehouse-compatibility.log: installed Treehouse v3.1.4 correctly refused; the tracked installer downloaded and verified v3.1.8 only into the disposable workspace, whose real capability check passed. No installed-tool upgrade or pool operation occurred.

## Baseline and targeted regressions

The original targeted-tests.log retains two failures. An in-repository TMPDIR placed secondmate fixtures inside the source root, correctly refused by product policy. Exporting tracked source through git archive HEAD into .validation-tmp/product and keeping fixture TMPDIR as its sibling inside .validation-tmp solved placement without weakening the guard or leaving the workspace. The entire worker-account subject then passed, including measured/exhausted quota ranking, model precedence, spawn environment propagation, endpoint/ownership cleanup and wrapper/native cancellation. Actual exit: 0, retained in disposable-regressions.log.

The old live identity fixture used an empty JWT signature and non-JWT access tokens. Real Codex rejected them, then required workspace discovery after format correction. Independent vendor protocol probes isolated the cause. The test-only repair provides valid-format future-expiry synthetic JWTs and a local routing HTTP fixture, with finally cleanup, while retaining the real runner and all duplicate/distinct identity assertions. It passed after the final edit. No production code changed.

The imported ship/scout/secondmate relaunch preflight cases also passed: old worker, metadata and ownership remained unchanged under refusal. These external-tool fixtures are not claimed as authenticated live worker proof. The initial errexit invocation stopped on a fixture-library source status; the successful invocation retained the test subject's ordinary shell posture.

The cancellation evidence driver initially expected a retained launcher wrapper, while this installation execs its native binary directly. It now records actual owned executable identities. Its deadline extension also needed a valid local model-catalog response. The retained final three-case driver passed and stopped its server and children.

## Limits

No authorized independent signed-in live accounts were available under this run's explicit prohibition on live-account operations. Synthetic local credentials cannot prove fresh service quota ranking, successful authenticated ship/scout startup, universal quota exhaustion while an actual authenticated worker remains alive, or successful vendor refresh persistence. Those scenarios remain untested live. Completing them needs separately authorized independent disposable signed-in accounts and lab lifecycle checks. No login, credential copy, refresh claim, remote machine operation or fleet rollout was fabricated.

## Reproduction

Create .validation-tmp/tmp from the worktree before rerunning evidence drivers. Run the permanent live guard with TMPDIR pointing there via bash bin/fm-test-run.sh tests/fm-worker-account-live-e2e.test.sh. For the secondmate-inclusive worker-account subject, first export git archive HEAD into .validation-tmp/product, then run its bin/fm-test-run.sh tests/fm-worker-account.test.sh from that copy with absolute TMPDIR pointing to sibling .validation-tmp/tmp.

The retained drive-account-cli.py, drive-spawn-refusal.py and drive-real-cancellation.py each run from the worktree and remove their own fixtures and services. They contain only synthetic credentials. All temporary source copies, account homes, downloads and caches were removed after validation; only the intended test-file repair remains.

## Primary sources

- [Treehouse v3.1.8 allocation](https://raw.githubusercontent.com/kunchenguid/treehouse/v3.1.8/cmd/get.go)
- [Treehouse v3.1.8 conditional return](https://raw.githubusercontent.com/kunchenguid/treehouse/v3.1.8/cmd/return_cmd.go)
- [Official Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [Official Codex account fixture](https://github.com/openai/codex/blob/main/codex-rs/app-server/tests/suite/v2/account.rs)

This file is gate evidence; operational research-book filing remains with its record owner.
