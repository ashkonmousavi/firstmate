# Review list 1 class inventory (run 01M4DT9WJSM59MB5VKZWYZCKXT, head fbb9e3ed)

## Cause A - claim-reaper timestamp rewrite (standards-remote-claim-reap-macos, standards-claim-reaper-python-dependency)

Reproduced cause: auto-fix round 2 (fbb9e3ed) replaced the merged claim sweep's POSIX `touch -d <ISO-8601>.999999999Z` beacon in `fm_remote_job_reap_stale` with a mandatory `python3` `os.utime` call, and rewrote the retention test's `touch_frac` to Python behind a fabricated shim that makes every `touch -d` fail.
The premise was the GNU-only `touch -d @<epoch>` form; this code uses the ISO date_time form that POSIX touch specifies (`-d YYYY-MM-DDThh:mm:SS[.frac][Z]`), and its epoch-to-ISO step already probes GNU `date -d @` then BSD `date -r`, the same probe order as `tests/lib.sh` `fm_touch_epoch`.
This is upstream Kun code (#6575 remote churn) adopted unchanged; the catch-up's intent is to use upstream fixes where Kun has them, so changing its portability approach is out of this PR's scope and belongs upstream.

Occurrences (complete):
- `bin/fm-remote-job-lib.sh` `fm_remote_job_reap_stale` beacon block (round-2 lines 849-861).
- `tests/fm-remote-job-claim-retention.test.sh` lines 11-14 (`touch` failure shim), 28-35 (`touch_frac` Python), and the added cases 7, 8, 9 that depend on it.

Search scope: `git grep -n 'touch -d\|python3'` over `bin/` and `tests/` at fbb9e3ed.
Negative evidence: no other `touch -d` user in `bin/`; `tests/lib.sh:673` is a comment on the different `@<epoch>` form; `bin/fm-remote-job-worker.sh` and `docs/remote-secondmates.md` add no Python requirement.

Fix: restore both files byte-for-byte to the pre-run merge head `a8ba9c2b` (which carries the upstream code plus the fork's existing lines); no new dependency.
Regression evidence: `bash tests/fm-remote-job-claim-retention.test.sh` passes on Linux after restore; `git diff a8ba9c2b -- <both files>` is empty.
Unverified: native macOS execution (no macOS host here); recorded as an upstream follow-up, not fixed in this PR.

## Cause B - fix-round inventory not retained in run evidence (standards-class-inventory-unavailable, review-1)

Reproduced cause: rounds 1 and 2 were internal auto-fix rounds started by the pipeline, not by a worker response, so no inventory was handed in; round 2 kept its own inventory only in the worktree scratchpad `scratchpad-review-3e13a34a/inventory.md` and `verification.log`, and `~/.no-mistakes/evidence/01M4DT9WJSM59MB5VKZWYZCKXT/` does not exist.

Fix: create `~/.no-mistakes/evidence/01M4DT9WJSM59MB5VKZWYZCKXT/`, copy round 2's `inventory.md` and `verification.log` there as `round-2-inventory.md` and `round-2-verification.log`, and write this file there as `review-list-1-inventory.md` before editing.
Round 1's inventory was never produced; that gap is recorded as unverified rather than reconstructed.

## Recorded restore decision at fbb9e3ed

The supplied inventory and exact worktree Round 2 artifacts were copied into this run evidence directory before source editing.
Round 1 produced no retained inventory; that remains an unverified gap and is not reconstructed here.
The scope of this fix is an exact restore of bin/fm-remote-job-lib.sh and tests/fm-remote-job-claim-retention.test.sh to a8ba9c2b, plus the evidence placement and receipts explicitly requested by the recorded decision.
Invariant A: both claim-reaper files retain the adopted merge revision's exact bytes and introduce no runtime Python dependency through this review fix.
Its affected sites are the reaper reference timestamp and marker block, the retention test's fractional timestamp helper, the review-added touch shim and review-added cases.
Invariant B: next Review can consume review-list-1-inventory.md, round-2-inventory.md and round-2-verification.log at this exact run path without assuming the missing Round 1 inventory exists.
Restore verification is pending in this turn; earlier artifacts are retained as historical evidence.
Native macOS execution is not claimed.

## Restore verification receipts

Starting head: fbb9e3edc5db328629eaa72e01f385c7c23146f1.
Post-edit retrace: adopted date conversion, fractional beacon, marker publication, batched claim removal and staging cleanup are restored; the original retention helper and cases are restored.
No review-created helper or parameter remains in either restored file.

```text
$ git diff a8ba9c2b -- bin/fm-remote-job-lib.sh tests/fm-remote-job-claim-retention.test.sh
PASS: empty diff against a8ba9c2b.
PASS: both restored files are byte-identical to a8ba9c2b.
$ bash tests/fm-remote-job-claim-retention.test.sh
ok - claim sweep preserves numeric-name eligibility and whole-second expiry
PASS: focused retention test exited 0 on Linux.
PASS: retained Round 2 inventory and log match the worktree originals exactly.
PASS: diff whitespace check.
$ git diff HEAD --name-only
bin/fm-remote-job-lib.sh
tests/fm-remote-job-claim-retention.test.sh
```

Only the two authorized claim-reaper files changed in this fix turn.
Other dialog escalation, spawn-generation marker, live-guard and test-family changes remain at the starting head.
Round 1 inventory remains an unverified gap and was not reconstructed.
Native macOS execution remains unverified; no new timestamp mechanism or runtime dependency was introduced.
