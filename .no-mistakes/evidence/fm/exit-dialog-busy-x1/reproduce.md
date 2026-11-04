# Reproduce the isolated live checks

Run from the validated worktree. Copy `live-control-driver.py` to `.test-validation/live-control.py` and `remote-live-driver.py` to `.test-validation/remote-live.py`, create `.test-validation`, then run `python3 .test-validation/live-control.py`.

The driver provisions generated fm-lab-* sessions only through bin/fm-herdr-lab.sh, starts the real Claude CLI with its existing login and automatic updates disabled, and invokes the actual fm-control.sh against a marked disposable home. Its transparent Herdr wrapper validates the session and forwards every operation through the lab helper. All fixture and server configuration remains below .test-validation; the helper and Claude maintain incidental runtime files as documented. The driver requires a fresh .test-validation/run directory and tears down its Herdr session and SSH server itself. Remove .test-validation afterward.

The loopback SSH probe uses disposable host/client keys and a narrow encoded-bootstrap adapter that executes the actual fm-remote-secondmate-control.sh, not a canned result. The host controller refuses any Herdr session except fm-remote, before it reaches fm-control; the mandatory helper permits only fm-lab-* names. Consequently full remote busy propagation is untested live. The existing remote wrapper regression separately proves retryable 75 propagation and unchanged parent metadata using an SSH fixture.

Baseline red proof: extract bin/fm-control.sh at 06cd6721cad90ed00ef393fff101602c9e9bdcf9 into a temporary executable adjacent to the current bin libraries, import tests/fm-control.test.sh with FM_TEST_FIXTURE_IMPORT=control, override CONTROL to that executable, and invoke test_exit_busy_background_shell_is_retryable. The old caller returns 1 for the captured shell dialog instead of required 75. The focused tests against the submitted executable pass. This baseline isolates the changed caller, using current shared libraries rather than claiming a complete historical checkout test.

Retained terminal-evidence.html renders exact product captures. It is a terminal transcript rendering, not a bitmap screenshot. No UI renderer or CSS was changed by the patch.
