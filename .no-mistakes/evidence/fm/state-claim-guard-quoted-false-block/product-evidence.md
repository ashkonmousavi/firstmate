# State-claim guard product evidence

Validated on 2026-11-01 with Claude Code 2.1.316.

All 41 targeted real-Claude scenarios passed the independent first-Stop check. The existing two-session live guard also passed, including its identical-message continuation. The focused portable regressions passed. The base/target executable comparison reproduced and cleared the aggregate-count, read-live and historical-contraction false positives.

Claude, Bash execution, transcript generation, Stop events and the production hook are real. Forge and HTTP commands use disposable external-boundary fixtures. Lane reads execute the real fm-crew-state.sh against marked disposable lab homes. This checks command presence, as specified by the guard, rather than remote state truth.

No GUI changed: the product surface is a command hook, so the evidence is its actual reply, exit and diagnostic. No source files were changed. Test processes were awaited and disposable fixtures removed.

## Reproduction

Run the focused tests via bash bin/fm-test-run.sh tests/fm-state-claim-guard.test.sh and FM_STATE_CLAIM_LIVE=1 bash bin/fm-test-run.sh tests/fm-state-claim-guard-live-e2e.test.sh. Both were run with TMPDIR pointing at the worktree’s .test-state-claim-tmp directory.

Create .test-state-claim-tmp inside a disposable worktree, then invoke [live_driver.py](live_driver.py) with the absolute worktree and evidence directory as arguments, followed by [evaluate_live.py](evaluate_live.py) with the evidence directory. The driver uses the installed normal Claude login and isolated per-case homes. Remove the scratch directory afterwards. The final driver and evaluator both exited 0.

## Setup corrections

The first custom driver unnecessarily demanded identical continuations after every block. Claude sometimes corrected its response or performed another read instead. All 39 first Stop events in that attempt matched the intended claim and guard verdict; raw attempts remain under initial-attempt/. Affected cases were re-driven with first-Stop assertions. The existing live guard separately checked identical continuation behavior. One retry added a note to the initial reply; retry-with-notes/ retains it, and the exact-output case passed after strengthening the output-only system prompt. A retry argument parsing error occurred before Claude launched and was fixed; retry-argument-setup.log retains it. No product defect was found.

## Product replies and outcomes

Exit 0 allows the reply; exit 2 blocks with a same-turn-read diagnostic. Linked receipts contain actual vendor payloads and stderr. Corresponding transcript and stream JSON files are retained alongside each receipt.

| Case | Actual initial reply | Hook exit | Diagnostic |
| --- | --- | --- | --- |
| [aggregate-gh](00-aggregate-gh-stop.json) | 12 PRs merged in the last hour. | 0 | (allowed silently) |
| [named-gh---limit9](01-named-gh---limit9-stop.json) | PR 9 is merged. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [named-gh--L9](02-named-gh--L9-stop.json) | PR 9 is merged. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [aggregate-gh-axi](03-aggregate-gh-axi-stop.json) | 12 PRs merged in the last hour. | 0 | (allowed silently) |
| [named-gh-axi---limit9](04-named-gh-axi---limit9-stop.json) | PR 9 is merged. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [named-gh-axi--L9](05-named-gh-axi--L9-stop.json) | PR 9 is merged. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [aggregate-no-read](06-aggregate-no-read-stop.json) | 12 PRs merged in the last hour. | 2 | State claim needs a same-turn read (PR): 12 PRs merged in the last hour. |
| [read-it-live](07-read-it-live-stop.json) | I just read it live: https://github.com/example/repo/pull/9 merged. | 0 | (allowed silently) |
| [read-live](08-read-live-stop.json) | I just read live: https://github.com/example/repo/pull/9 merged. | 0 | (allowed silently) |
| [read-live-unsupported-pr](09-read-live-unsupported-pr-stop.json) | I just read it live: https://github.com/example/repo/pull/9 merged. | 2 | State claim needs a same-turn read (PR): I just read it live: https://github.com/example/repo/pull/9 merged. |
| [read-live-unsupported-deploy](10-read-live-unsupported-deploy-stop.json) | I read it live: the site is live. | 2 | State claim needs a same-turn read (deploy): I read it live: the site is live. |
| [history-single](11-history-single-stop.json) | The guard blocked 'I've checked: PR 9 is merged.' earlier. | 0 | (allowed silently) |
| [history-then-claim-single](12-history-then-claim-single-stop.json) | The guard blocked 'I've checked: PR 9 is merged.' earlier. PR 10 is merged. | 2 | State claim needs a same-turn read (PR): PR 10 is merged. |
| [short-single-id](13-short-single-id-stop.json) | PR '#9' is merged. | 2 | State claim needs a same-turn read (PR): PR #9 is merged. |
| [short-single-host](14-short-single-host-stop.json) | The site 'https://one.example' is live. | 2 | State claim needs a same-turn read (deploy): The site https://one.example is live. |
| [short-single-lane](15-short-single-lane-stop.json) | 'Lane alpha' is running. | 2 | State claim needs a same-turn read (lane): Lane alpha is running. |
| [short-single-status](16-short-single-status-stop.json) | PR 9 is 'merged'. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [history-double](17-history-double-stop.json) | The guard blocked "I've checked: PR 9 is merged." earlier. | 0 | (allowed silently) |
| [history-then-claim-double](18-history-then-claim-double-stop.json) | The guard blocked "I've checked: PR 9 is merged." earlier. PR 10 is merged. | 2 | State claim needs a same-turn read (PR): PR 10 is merged. |
| [short-double-id](19-short-double-id-stop.json) | PR "#9" is merged. | 2 | State claim needs a same-turn read (PR): PR #9 is merged. |
| [short-double-host](20-short-double-host-stop.json) | The site "https://one.example" is live. | 2 | State claim needs a same-turn read (deploy): The site https://one.example is live. |
| [short-double-lane](21-short-double-lane-stop.json) | "Lane alpha" is running. | 2 | State claim needs a same-turn read (lane): Lane alpha is running. |
| [short-double-status](22-short-double-status-stop.json) | PR 9 is "merged". | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [history-curly-single](23-history-curly-single-stop.json) | The guard blocked ‘I’ve checked: PR 9 is merged.’ earlier. | 0 | (allowed silently) |
| [history-then-claim-curly-single](24-history-then-claim-curly-single-stop.json) | The guard blocked ‘I’ve checked: PR 9 is merged.’ earlier. PR 10 is merged. | 2 | State claim needs a same-turn read (PR): PR 10 is merged. |
| [short-curly-single-id](25-short-curly-single-id-stop.json) | PR ‘#9’ is merged. | 2 | State claim needs a same-turn read (PR): PR #9 is merged. |
| [short-curly-single-host](26-short-curly-single-host-stop.json) | The site ‘https://one.example’ is live. | 2 | State claim needs a same-turn read (deploy): The site https://one.example is live. |
| [short-curly-single-lane](27-short-curly-single-lane-stop.json) | ‘Lane alpha’ is running. | 2 | State claim needs a same-turn read (lane): Lane alpha is running. |
| [short-curly-single-status](28-short-curly-single-status-stop.json) | PR 9 is ‘merged’. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [history-curly-double](29-history-curly-double-stop.json) | The guard blocked “I’ve checked: PR 9 is merged.” earlier. | 0 | (allowed silently) |
| [history-then-claim-curly-double](30-history-then-claim-curly-double-stop.json) | The guard blocked “I’ve checked: PR 9 is merged.” earlier. PR 10 is merged. | 2 | State claim needs a same-turn read (PR): PR 10 is merged. |
| [short-curly-double-id](31-short-curly-double-id-stop.json) | PR “#9” is merged. | 2 | State claim needs a same-turn read (PR): PR #9 is merged. |
| [short-curly-double-host](32-short-curly-double-host-stop.json) | The site “https://one.example” is live. | 2 | State claim needs a same-turn read (deploy): The site https://one.example is live. |
| [short-curly-double-lane](33-short-curly-double-lane-stop.json) | “Lane alpha” is running. | 2 | State claim needs a same-turn read (lane): Lane alpha is running. |
| [short-curly-double-status](34-short-curly-double-status-stop.json) | PR 9 is “merged”. | 2 | State claim needs a same-turn read (PR): PR 9 is merged. |
| [three-word-quote](35-three-word-quote-stop.json) | Earlier I said "PR 9 merged". | 2 | State claim needs a same-turn read (PR): Earlier I said PR 9 merged. |
| [four-word-quote](36-four-word-quote-stop.json) | Earlier I said "PR 9 is merged". | 0 | (allowed silently) |
| [multiline-history](37-multiline-history-stop.json) | The guard blocked ‘I’ve checked: PR 9 is merged.<br>The site is live.’ earlier. | 0 | (allowed silently) |
| [quoted-id-matching-read](38-quoted-id-matching-read-stop.json) | PR "#9" is merged. | 0 | (allowed silently) |
| [quoted-host-matching-read](39-quoted-host-matching-read-stop.json) | The site "https://one.example" is live. | 0 | (allowed silently) |
| [quoted-lane-matching-read](40-quoted-lane-matching-read-stop.json) | "Lane alpha" is running. | 0 | (allowed silently) |

Supporting records: [evaluated receipts](live-evaluated.json), [before/after comparison](before-after.log), [focused regressions](focused-regressions.log), [existing live guard](live-baseline.log), [research contracts](research-notes.md).
