# Reply-runner recovery validation

Acceptance oracle: supplied owner intent requires that a dead remote-reply
runner restart without a hand restart. Recorded review decisions additionally
require fixed 30-second state/route bounds and exact `live` ownership.

Read the project's research-book index and its fleet-test-runs entry before
diagnosis. Relevant prior evidence: temporary homes must not overlap the remote
code root, tests can take minutes, and Herdr's default session must remain
untouched. No Herdr session or real fleet endpoint is used by these checks.

External primary references consulted through Exa:

- [GNU timeout manual](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html): the deadline must be positive; 124 indicates timeout and a zero duration disables the deadline.
- [AsyncSSH API](https://asyncssh.readthedocs.io/en/stable/api.html): authorized client keys authenticate real SSH clients; process_factory handles requested commands.

The live driver materializes an exact disposable copy of `bin/` for the remote
root, with separate marked lab homes under the run worktree. OpenSSH connects to
a loopback AsyncSSH server using disposable Ed25519 keys, strict host checking,
and a workspace-local SSH config. The service invokes the real remote
entrypoint, real remote job worker, and real reader executables. Fault injection
stops the TCP listener, signals the actual runner process group, or stalls an
authenticated remote command; it never synthesizes a Firstmate response.

The real watcher must restore source ownership and mirror independently supplied
reply bytes exactly once. The actual backstop CLI must distinguish live claims
from pid hints, preserve the owner lease, debounce death for one pass, deduplicate
its incident, and clear it after recovery. External backstop sends are disabled
inside the lab, so alarms are retained in the lab journal without discovering
or sending to a real primary.

The stalled-probe scenario explicitly makes the liveness tick due. It must show
the reply being mirrored before the 20-second observation deadline, followed by
the 30-second state deadline with the original metadata and pending expectation
preserved. The baseline driver substitutes only the pre-fix watcher from the
supplied base commit, to isolate ordering from timeout behavior.

The liveness and remote-reply shell suites are supplemental transport-fixture
checks, and the selected backstop tests use fake external transports. They are
not labeled live. No linter, static analyzer, full repository suite, pipeline
control, publication, PR, or CI phase is run here.

Setup corrections: workspace-nested temporary homes violated the intentional
remote-root overlap guard; stock test temporary directories resolved it. The
manual lab needed private state permissions, 0600 SSH key permissions, the
actual `.watch-triage.log` filename, and a due liveness tick. Those fixture
corrections did not change product source. All live fixture descendants are
subreaped and the lab is removed by the driver.

Final results: the target live driver and pre-fix comparison both exited zero.
The target recovered in 1.01 seconds before the stalled observation finished;
the observation and state requests began 20.215 seconds apart, and the state
timeout preserved the route after approximately 30 seconds. The baseline
watcher was inside the stalled observation with no source owner. All owned
children were reaped and both fixture trees removed. The supplemental liveness
suite and nine selected backstop tests exited zero. The remote-reply suite first
timed out waiting for generation 6; a diagnostic `bash -x` rerun completed with
exit zero, including all new revival tests. That intermittent capture failure's
cause remains unisolated and is reported as a test-reliability warning.

The evidence drivers can be rerun after installing AsyncSSH into a disposable
workspace-local dependency target and setting PYTHONPATH to it. Neither driver
requires the operator's SSH keys or a model login. No product source was edited.
