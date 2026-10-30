# Timeout wake validation oracle

The owner's supplied intent and accepted R1 decision define the contract: every custom check run killed at its configured bound must surface `check: <original path>: timed out after <N>s (FM_CHECK_TIMEOUT)`. Consecutive timeouts must each wake. The fallback timeout marker is temporary evidence of its alarm, not an episode-suppression marker.

Prior project evidence read: the research-book index and its `watcher-check-timeout-silent.md` entry describe the 31/32/51-second silent failures and the temporary 90-second operator workaround. No operator home was changed during validation.

Primary outside sources checked via Exa:

- [GNU coreutils timeout source](https://github.com/coreutils/coreutils/blob/master/src/timeout.c): documents exit status 124 for expiration, and 137 when SIGKILL also kills the monitor. This independently supports testing the installed timeout and alternate executable-name route with the real GNU coreutils 9.4 binary.
- [Perl alarm documentation](https://perldoc.perl.org/functions/alarm): specifies delivery of SIGALRM after the configured wall-clock seconds. The real Perl fallback was exercised with the product's `FM_CHECK_FORCE_FALLBACK=1` selection.

Live evidence uses the actual registration, watcher, and wake-drain executables against disposable marked lab homes. No harness CLI or backend is replaced. The gtimeout route is tested by exposing the installed GNU binary under that alternate name in a private PATH without a timeout executable; this tests command selection on this Linux host, without claiming a macOS run.

The two Python drivers are retained beside their transcripts and can be run from the gate worktree to repeat the checks. Both remove their disposable data and code copies. Research findings are retained here because the task confines intentional writes to the worktree and this evidence directory.
