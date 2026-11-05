# Duplicate-builder live validation

Target: 3a3a6690e611effdcf4fd87d2c29aa39c966d35a.

Core real-product checks passed using a workspace-local Forgejo 17.0.1, tea 0.16.0, real Git/Treehouse, and a private 120x40 tmux server. Successful spawn checks used Firstmate's supported raw launch command `codex --version`; the real installed codex-cli rendered in the worker terminal. This proves admission, allocation, PR-head checkout and metadata, without claiming model-generation validation. Standard worker checkouts begin detached; the emitted brief instructs the worker to create the recorded task branch.

The API returned pages [[8,7],[6,5],[4,3],[2,1],[]] despite requesting limit 50: the real server cap was 2 and the matching branch PR #4 was found on page 3. Transparent wrappers around the real Git and tea binaries were positively verified before checking that local-only refusals fetch nothing and ordinary local-only skips tea. Capacity admission returned 75 before any forge call; a manual retry with the same arguments returned 1 after an actual matching PR declaration was added. Automatic queue consumption was not exercised.

Real positive/negative cases include branch/body refusal and replay with no task state or pool, declarations inside R3/R9/R10 fence/container bodies and with strong decoration, prose/other-slice exclusion, actual PR merge and closure, a genuinely empty API list, strict continuation selection, continuation at the real PR SHA with a PR-only file, local-only split/equals rejection before fetch, ordinary local-only success, recorded bypass, blank-reason refusal, relaunch without tea, explicit UNKNOWN continuation with a real branch fetch, unavailable forge, and a stalled TCP response that times out as UNKNOWN. A disposable branch-matching mutant omitted existing PR #4 and failed the independent expected-PR oracle. Source was unchanged.

Both targeted baseline scripts completed with exit 0:
- `TMPDIR=/tmp bash tests/fm-spawn-duplicate-builder.test.sh`
- `TMPDIR=/tmp bash tests/fm-task-delivery.test.sh`

Successful authenticated GitHub/GitLab reads remain untested live. Their schema/provider/host cases passed the fixture-driven regression script. The real gh client under isolated configuration refused because no service token was present. glab 1.128.0 was downloaded into the workspace; its API traffic was explicitly blocked with a loopback-only proxy to avoid using shared services, and the lookup refused UNKNOWN. No operator service credentials or repository were used. Disposable authorized GitHub/GitLab endpoints and tokens are needed to close this gap. The read-only Docker info probe did not respond and was terminated (exit 143); this does not establish Docker availability, and no daemon changes were made.

Resolved setup issues were a read-only /dev/null Git configuration, a missing isolated-home activity reader, an unjustified named-checkout-branch assertion, relaunch argument placement, and using a Forgejo-bound registry/brief for an ordinary local-only case. Ordinary local-only was then driven with its valid local-only registry and real scaffold. Full attempt logs are retained; `live-validation.log` selects the complete successful sessions, and task-record-evidence.json retains the relevant public metadata fields. None of these setup corrections changed production code.

Reproduction: retained Python drivers run from the target worktree with downloaded `.test-live/bin/forgejo` and `.test-live/bin/tea`, the existing Git/Treehouse/tmux/codex tools, and installed activity.sh at the path named in forge-live.py. `forge-live.py` creates the disposable forge/home/project; `positive-live.py` runs attachment and lifecycle/escape checks; `contracts-live.py` completes body/merge/empty/mutation/timeout checks. `remaining-live.py` is the resume driver used after correcting the local-only fixture. Binaries came from the official release endpoints:
- https://code.forgejo.org/forgejo/forgejo/releases/download/v17.0.1/forgejo-17.0.1-linux-amd64
- https://gitea.com/gitea/tea/releases/download/v0.16.0/tea-0.16.0-linux-amd64
- https://gitlab.com/gitlab-org/cli/-/releases/v1.128.0/downloads/glab_1.128.0_linux_amd64.tar.gz

All disposable server, tmux, and TCP-listener children were stopped and awaited before cleanup. No GUI change was made; CLI transcripts are the rendered product surface.
