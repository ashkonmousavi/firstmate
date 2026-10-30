# Timeout reference and existing diagnosis

Read the project research-book entries `watcher-check-timeout-silent.md` and `github-ubuntu-2604-uutils.md` before validation. The former records the exact silent-timeout and ignored-nonzero failures covered here; the latter distinguishes GNU and uutils timeout behavior.

Exa search located timeout exit-status documentation. The web fetch of the official GNU page timed out; curl fetched that same page successfully, retained as `timeout-reference.html`.

Primary reference: https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html

Installed executable: GNU coreutils timeout 9.4. The independent acceptance oracle is the supplied intent; live observations in `check-wakes-results.json` confirm timeout notifications, preserved failure statuses including signals, actual elapsed seconds, repeat wakes without suppression, quiet success, and unchanged printed success for the native and Perl paths.

No shared research-book mutation was made because this gate permits intentional writes only within the worktree and its evidence directory. This evidence note is available for the outer record owner.
