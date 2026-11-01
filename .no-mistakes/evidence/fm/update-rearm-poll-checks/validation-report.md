# Targeted product validation

Target: `132c5dba2961acf2c170d9d652753e94d8648350`; base: `4e174ee560a0226fcd5e0dd84707eb89c5c753d2`.

The real update CLI, PR record owner, retirement CLI, watcher, Git repositories, and lock implementation ran in disposable worktree-local homes.
No forge CLI, record owner, or lock implementation was replaced in the live replay.
GitHub CLI credentials and all home/configuration paths were isolated; no real fleet home, credential, pane, or remote machine was accessed.

| Disposable home | First update | Repeat update | Result |
| --- | --- | --- | --- |
| Primary home with separate code root | rearmed=1 left=3 | rearmed=0 left=3 | Current poll identity preserved |
| Registry-only local secondmate | rearmed=1 left=3 | rearmed=0 left=3 | Refresh does not need a live endpoint |
| Remote host code root, exercised locally | rearmed=1 left=3 | Not repeated | Root diagnostics survive nested update |
| Remote persistent home, exercised locally | rearmed=1 left=3 | Not repeated | Home diagnostics precede synced result |

These are synthetic fixture counts, not MAIN/server/x-ux/eel-web operational counts.
Each `left=3` comprises a missing worker copy, a latest worker head not pushed outside its copy, and a modified check whose registered bytes no longer match.
All are preserved and individually reported.
Custom check and trust-file hashes remain unchanged in every home.
The historical poll template contains an execution canary; re-arm and retirement never execute those stored bytes.

Before repair, the actual watcher prints `check: rejected unauthenticated state checks: .../ready.check.sh` and exits 0 after publishing that wake.
After repair, it accepts the registration and reaches the installed poll's GitHub query: `watcher: PR poll for ready failed (exit status 4)`.
That expected exit is the isolated GitHub CLI's absent login, not a successful forge read or merge notification.
No end-to-end merge observation or landed-work notice is claimed.

The retirement CLI removes only the selected old poll's check, sidecar, and registration, states its reason, and preserves metadata and work.
Repeated retirement is harmless.
Tampered checks, custom trust, and pending merge receipts refuse without removing the check.
The focused suite additionally exercises hardlink, symlink, and empty-state refusals.

For concurrency, the real refresh and record-owner processes were paused at a real held metadata lock while another real command retired or replaced the poll.
Different-URL and same-URL replacement generations both survive unchanged, as does retirement.
The resumed refresh prints `skipped=superseded-or-retired`, reports `rearmed=0 left=0`, and exits 0 in each case.
Before/after files record metadata and artifact hashes plus file identities.

## Commands and retained results

- `TMPDIR="$PWD/.test-phase-tmp" bash bin/fm-test-run.sh tests/fm-update.test.sh tests/fm-check-unregister.test.sh`: exit 0, neither subject skipped; retained in `targeted-suites.log`.
- `bash ~/.no-mistakes/evidence/01M6BND9PKB3P0JYRZA36Y781C/live-validation.sh`: corrected replay exit 0; `live-validation.log`, `update-first.log`, `update-repeat.log`, `update-remote.log`, and watcher logs.
- `bash ~/.no-mistakes/evidence/01M6BND9PKB3P0JYRZA36Y781C/race-validation.sh`: exit 0; `race-validation.log`, per-case logs, and before/after TSV files.

An initial replay exited 1 because its checksum file was an unignored file in the disposable mate checkout; the update correctly skipped that dirty home.
`setup-attempt.log` retains that failed setup attempt.
The hypothesis was that the test's own checksum evidence dirtied all code checkouts; an independent agent confirmed it and the warning-prefixed error assertions.
Checksum files moved under ignored `state/`, every disposable checkout was verified clean before retry, and all four homes then completed their expected refresh.
Git's official status contract includes untracked nonignored paths: https://git-scm.com/docs/git-status .
The operational research book was outside this run's project/data boundary, so this test-only diagnosis stays in the evidence record.

No linters, formatters, static analysis, full suite, push, PR, CI, remote lifecycle, or other pipeline phases ran.
All fixture scripts clean their homes on exit, all invoked checks have known exit statuses, and a final process check found no remaining fixture children.
No source or permanent test files changed.

## Remaining acceptance evidence

The supplied verification plan describes historical per-home receipts, but those private files are absent from the supplied worktree.
This phase expressly forbids reading operator homes or shared services, so it cannot independently confirm actual MAIN/server/x-ux/eel-web counts or the laptop's six historical retirements.
Supply sanitized per-home before/after snapshots and repair/retirement receipts inside the run worktree to make those facts independently checkable without violating the boundary.
