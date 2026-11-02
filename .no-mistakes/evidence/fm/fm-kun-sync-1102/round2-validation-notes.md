# Integration test revalidation

Target: e1d1ff2d7e301f247c5225051358d07ee03172f3. Source changes were not needed. No publication, merge, CI, or pipeline-control command was performed.

## Setup and reproducibility

An unchanged `git archive HEAD` was extracted into `.no-mistakes/retest/runtime` inside the supplied worktree. All fixture directories, scratch repositories, Treehouse pools, and the downloaded Rex executable were confined to `.no-mistakes/retest`. The Codex live guard's disposable test copy was adapted only to create its empty home through `fm-lab-home.sh` and print actual pane captures before cleanup. Production code was not altered. The existing guard gives its private tmux session a 200x50 terminal.

Commands: `TMPDIR="$PWD/.no-mistakes/retest/tmp" TREEHOUSE_ROOT="$PWD/.no-mistakes/retest/treehouse" FM_CODEX_LIVE_E2E=1 FM_CODEX_TYPED_LAUNCH=1 bash .no-mistakes/retest/runtime/tests/fm-codex-brief-typed-live-e2e.test.sh`; repeat with FM_CODEX_TYPED_LAUNCH=0 and a separate Treehouse pool. The requested replies `codex-brief-ok` and `codex-relaunch-ok` are independent expected outputs from the scenario instructions, not values derived from the implementation. A dropped brief or premature success without a reply fails the guard.

The targeted Codex harness and worker-account guards ran from that source archive with workspace-local TMPDIR. These boundary-fixture suites support the live observations; they are not claimed as live model or T3 proofs. In particular they exercise pending/unknown/empty startup without processing, stale previous-turn evidence, completed turns, no duplicate delivery, backend carrier selection, and T3 account preflight.

## Rex

Official source: https://www.superlogical.com/rex/docs/linux/installation . Downloaded archive: https://blob.superlogical.com/download/rex/preview/e6592f74969959db77f1f84261901ef599a025cf/rex-linux-amd64.tar.gz . SHA-256: 01044e9e21c0e664d47dd5c52ff715f79ae767859eaaa351c5b273ad5e11e82f . Native version: 0.1.0-preview.12, API revision 8. No installer was run.

The workspace's absolute socket path exceeds the platform limit. The runner held a directory descriptor open on `.no-mistakes/retest` and passed `unix:///proc/<runner-pid>/fd/<descriptor>/rex-<scenario>.sock`; the sockets therefore remained inside the workspace. Its test-only copy of rex-test-safety.sh accepts that endpoint rather than constructing an overlong absolute path. Each real server used private state and empty config and was awaited and stopped. No operator Rex server was contacted.

The guard exercised native tab creation, input, capture, 200x50 resize, foreground process tracking, busy state, reclaim, stopped-server refusal, and explicit session loss. Additional actual-server checks proved: present terminals cannot be declared absent; deleting one permits the matching recorded server to prove absence; target-only, wrong-server, and missing-server claims refuse. A retained native session survived a restart (actual block-size JSON retained); a stopped server or that retained block never proved absence. Explicit deletion did.

The real fm-spawn command launched real Codex on Rex with FM_CODEX_TYPED_LAUNCH=1. The requested `rex-carrier-ok` reply arrived, proving the positional instructions were preserved. The test driver answered only the observed scratch-folder trust dialog. It killed its spawned terminal, confirmed absence against the recorded private server, and returned its scratch worktree.

## Remote fixture isolation

The remote lifecycle guard uses deterministic SSH and terminal boundary fixtures. Its first attempt inherited the enclosing gate repository through its temporary working directory and was correctly refused. A standalone fixture Git repository at `.no-mistakes/retest/remote-tmp` isolates this directory from the enclosing repository; the rerun uses that directory as TMPDIR. Neither production guard code nor gate environment was edited to remove the restriction.

## T3 live coverage limit

Real fm-spawn attempts for ship, scout, and secondmate with isolated disposable homes and deferred Codex account selection all stopped at the earlier missing `config/t3code-token` capability boundary. `t3` is absent from PATH, and the repository is a T3 client rather than a disposable T3 server implementation. Downloading a CLI would not supply an authorized server or credential. No operator credential or real runtime configuration was read. The product requires a full-access OAuth mcp-client credential; signing into or modifying production credentials is prohibited in this phase. To exercise the account-specific capability boundary live, supply an isolated T3 server with an authorized disposable token in the lab config. The account fixture suite tests the intended refusal for all three roles but is not live T3 evidence.

## Evidence rendering

round2-terminal-transcripts.html renders the actual retained terminal text and native API output. It is a transcript view, not a screenshot of a browser product. This change alters launch orchestration, not browser UI layout.

## Notification cap

`TMPDIR="$PWD/.no-mistakes/retest/tmp" FM_WATCH_WEDGE_CAP_LIVE=1 bash .no-mistakes/retest/runtime/tests/fm-watch-wedge-cap-live.test.sh` completed with exit 0. The real watcher observed a real process in its private tmux lab, emitted repeated default notifications, emitted the configured terminal cap notification, and resumed notifications after the full 300-second expiry with no intervention. The product notification transcript is retained. The previously declined readiness concern was not changed or re-reported.

## Completion

The isolated remote lifecycle rerun exited 0 and printed ALL TESTS PASSED, including dead Rex secondmate recovery, stopped-server probe safety, and retirement/archive boundaries. This remains supporting fixture evidence, not live SSH or Herdr evidence. The initial gate-isolation setup refusal is retained separately; it was resolved without modifying product code.

Both live Codex modes completed with exit 0: typed fresh-folder launch 24 seconds and trusted relaunch 22 seconds; positional fresh-folder launch 25 seconds and trusted relaunch 19 seconds. Both returned the independently requested replies. The Codex-harness and worker-account regression suites exited 0, as did all four real-Rex runs and the notification-cap live guard. The T3 attempt exited 0 only because the driver explicitly expected the missing-credential refusal; it does not assert T3 account capability success. Actual command exits are retained in round2-command-exits.json and round2-rex-exits.json.

## Cleanup

All started test commands completed and their real exit statuses were collected. The process-table check found no process naming this run's disposable test root or private Codex tmux sessions. The entire .no-mistakes/retest directory, including the downloaded release, copied sources, fixture Git repositories, caches, and Treehouse pools, was removed after completion. git status --porcelain is empty. Evidence remains in this dedicated evidence directory. No owned test server or browser child remains.
