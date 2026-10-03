# Remote job identity validation

The tested head is cf1d3d1d3db9eebe7e1d6a58f32243fade197453.
The comparison base is 97fbdb847bec742b72eeb2cde3d896e64d673d02.
The live platform is Linux 6.6.114.1-microsoft-standard-WSL2.

`live-identity.log` records an actual running worker and job, persisted kernel cookies, nonvacuous UTC/HST ps rendering differences, retained serving PID and supervisor group, delivered job output, rejected tick/PID/command mismatches, unchanged ps fallback, staging custody and successful crash recovery.
`baseline-date-divergence.log` reproduces rejection of a still-live process using the base helper, while `fixed-date-divergence.log` records acceptance using the target helper.
`live-comm.log` records the same process start cookie before and after a real kernel comm change to a name containing spaces and parentheses.
`legacy-cookie.log` records rejection of an actual ps date cookie despite a matching live PID and command, with a current-format acceptance control.

Five focused suites passed: remote-job, remote-transport-lanes, remote-job-orphan-reap, remote-entrypoint and remote-doctor.
The transport fixture drives real fm-on, entrypoint and worker scripts over a deterministic SSH seam; it does not establish acceptance against a real remote SSH host.
The doctor suite uses deterministic platform/tool fixtures; its simulated Darwin checks do not establish native macOS acceptance.
The procfs parser's malformed-record and read-failure checks are supplemental fixture tests, not live kernel-corruption evidence.

The first remote-job namespace run failed because the evidence supervisor initially did not reap exited children while waiting for the suite.
After adding continuous PID1 reaping, the unchanged suite passed.
The first transport run failed before caller staging because its real entrypoint clears HOME and resolves the passwd account; mapping the namespace user to root left that account's /root inaccessible.
An empty disposable /root bind mount inside only the private mount namespace corrected that setup, and the unchanged transport suite passed.
No production or permanent test source was changed.
Every invocation records LAB_WORKERS_AFTER=0 and removal of its disposable TMPDIR.

Native macOS remains unavailable in this Linux workspace; the actual Linux ps fallback was exercised with procfs disabled through the supported override.
The recurring Zenbook cut-offs remain unproven because this phase cannot install into the operator's real home, sample real fleet traffic, or change the shared system wall clock.
A coordinated quiet installation and two clean hours of owner-authorized Zenbook measurements are still required before claiming that recurring incident solved.
Lint, documentation checks, delivery, upstream posting and hosted CI belong to other phases and were not executed here.
