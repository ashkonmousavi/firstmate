
## Lint fix inventory
Cause: tests/fm-composer-dialog-live-e2e.test.sh uses A && B || C chains reported as SC2015 by ShellCheck 0.11.0, causing bin/fm-lint.sh to exit 1.
Occurrences: tests/fm-composer-dialog-live-e2e.test.sh lines 94 and 113, exactly the two occurrences in the supplied lint summary.
Search scope: bin/fm-lint.sh changed-file output for this run; the supplied summary reports no other file.
Fix: rewrite both chains as explicit if/then/else with identical pass/fail outcomes.
Scope: only this test file; no ShellCheck suppression, bin changes, other test changes, or behavioral test execution.
Verification: rerun bin/fm-lint.sh and bash -n tests/fm-composer-dialog-live-e2e.test.sh; append receipts below.

## Reproduction receipt
Command: bin/fm-lint.sh
Exit status: 1
ShellCheck 0.11.0: SC2015 at tests/fm-composer-dialog-live-e2e.test.sh:94 and :113; no other ShellCheck findings.
actionlint 1.7.12: 3 workflow files valid.

## Verification receipts
Command: bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: local changed-file mode; ShellCheck source following disabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
Exit status: 0
Command: bash -n tests/fm-composer-dialog-live-e2e.test.sh
Exit status: 0
