# Targeted test failure investigation

The target exactly restores the pre-PR-247 tree. No permanent source or test fix was applied.

## Results

- Full targeted autolaunch run: exit 1 after 844646 ms at tests/fm-autolaunch.test.sh:1263, `the second retry must finish`.
- Original EGM1-R2 count-mismatch case: reproduced on the base snapshot, passed on the target.
- Failed controller case alone: exit 0, 55545 ms.
- Preceding controller case plus failed case: exit 0, 15839 ms. A temporary test copy added failure-state capture only; the capture hook did not fire.
- Live task readiness, hold/unhold, dependency completion, fleet snapshot, native candidate publication, and incomplete/malformed publication rejection passed in a marked disposable home.

## Diagnosis and limits

Trigger: failed-launch retries while the fixture advances a synthetic clock.
Symptom: the helper's five-real-second receipt observation timed out during the full run.
Possible masking conditions: asynchronous process and slot settlement, variable preparation runtime, or observing a later diagnosis attempt that intentionally waits for a fixture gate.
The preparation subprocess allows fifteen seconds, and receipt creation can precede process exit while retry admission requires settlement.
Independent read-only review confirmed these timing boundaries but could not establish which caused the original failure because its fixture had already been cleaned.

Hypothesis: full-run scheduling lets receipt publication exceed the observation window or changes which attempt the helper observes.
Disproof: retained failing state showing the correct retry had settled and its receipt was available within that window.
The paired check would have captured journal, unit output and attempt identity on failure, but passed.
The failed full run remains unresolved; passing narrow rechecks do not establish a green full targeted subject.
No unrelated fix was added because the authoritative intent permits only the exact historical revert.

## Research and retained guard

Research book: no entry available under this worktree's data/research-book; other checkouts were not read.
Kun: consulted the requirements, tests, and review opinion; it supplies no specific diagnosis of this race.
A partial disposable pull cache was stopped and removed after reading its root documents.

Primary sources checked 2026-11-06 UTC: [GNU Bash manual](https://www.gnu.org/software/bash/manual/bash.html) describes asynchronous commands returning without waiting for completion; [POSIX wait](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/wait.html) defines waiting for child termination.
These distinguish observing a receipt from waiting for process completion; they do not prove this failure's cause.
Initial GNU fetches failed; Exa fetching recovered against POSIX and web search recovered against GNU.

Existing guard: tests/fm-autolaunch.test.sh, test_controller_busy_pass_reconciles_receipt_siblings.
Repeatable live proof: live-revert-check.sh in this evidence directory.
All disposable homes and the temporary test copy were removed.
