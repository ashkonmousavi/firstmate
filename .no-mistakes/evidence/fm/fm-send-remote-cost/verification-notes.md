Target: e997a061bbbbe6b53d145707a3d2eb867055253b; base: 914dff6ffc374ba053bf00a329b462add27250fa.

Live local proof used the real fm-send CLI and real private tmux shell pane, 120 columns by 40 rows. Ten sequential sends took 1.016–1.289 seconds each, with byte-exact Unicode/multiline/trailing-newline bodies and sequences 2049–2058 after 2048 retained records. Manual fixture moves into handled/ exercised sequence retirement; these moves are NOT worker acknowledgements. Eight concurrent real CLI sends produced sequences 2059–2066 and all eight distinct bodies. A shell endpoint deliberately exercises durable delivery without pretending that an agent consumed a doorbell. The down-monitor warning is expected in this disposable home; no monitor was started or repaired.

Public writer benchmark on three identical 2048-record histories: base 1.118–1.150 seconds; target 0.087–0.128 seconds. Both versions preserved sequence 2049 and exact body. Focused retained-history guard observed 20 shell processes, below its budget of 64.

Supplementary checks: the unchanged definitions of twelve selected inbox cases were extracted from tests/fm-task-inbox.test.sh before its top-level invocation list. Both this selection and the full fm-send-remote-delivery.test.sh passed through bin/fm-test-run.sh --jobs 1. The latter replaces SSH and endpoint boundaries and is NOT live remote evidence. The known pre-existing watcher-escalation case was not rerun or modified. No lint, static analysis, full repository suite, deployment, or pipeline control was run.

Commands:
- tmux -S .validation/tmux.sock new-session -d -s lab -x 120 -y 40 'bash --noprofile --norc'
- TMPDIR="$PWD/.validation/tmp" bin/fm-test-run.sh --jobs 1 tests/.validation-inbox.test.sh tests/fm-send-remote-delivery.test.sh
- python3 .validation/live-check.py
- python3 .validation/concurrent-cli.py
- tmux -S .validation/tmux.sock kill-server

For reproduction, retained scripts live here; place selected-inbox.test.sh under tests/ as .validation-inbox.test.sh so relative shared-helper imports resolve. Both Python drivers expect the repository current directory and a fresh .validation directory, with the named tmux pane above. The first driver creates the disposable marked home and benchmark states. Remove transient files afterward.

Remote limit: ten confirmed normal-transport q-server sends under server load remain deferred by the recorded review decisions. No shared host, fleet home, pending notice, or credentials were accessed. A local Herdr workaround cannot run unchanged: bin/fm-remote-secondmate-control.sh pins the remote session to fm-remote; the trusted runbook only permits lifecycle through fm-herdr-lab.sh with fm-lab-* sessions. Rex was not on PATH. Changing production session routing or installing/updating the shared q-server is outside this test phase and workspace boundary. The supervisor can resume the parked server proof after a compatible authorized rollout. Local sends, benchmarks, and stubbed transport tests do not establish that proof or reproduce the reported 14-second local CPU measurement.
