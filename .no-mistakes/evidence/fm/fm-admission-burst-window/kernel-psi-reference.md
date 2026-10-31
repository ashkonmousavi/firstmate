# Admission validation reference

The Linux kernel PSI interface reports memory stall percentages over 10, 60, and 300 seconds.
These are stall-time trends, not percentages of allocated or available bytes.
Source: https://docs.kernel.org/accounting/psi.html (queried through Exa during this validation).
The independent live oracles were real proc/cgroup readings, configured numeric policy limits, the CLI exit-status contract, and the nine-column admission TSV contract.
No kernel resource interface, resource-reader executable, runtime backend, or harness was replaced in the live checks.
The focused repository regressions use synthetic inputs and are reported separately from live checks.
The maintainer-supplied three-host historical comparison is recorded in docs/verification/machine-admission-psi-window.md; this run did not independently reproduce its historical totals.
