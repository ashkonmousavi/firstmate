# Reproducing the live checks

The retained drivers are test evidence, not permanent project changes.
Run from the target gate worktree with the machine's existing Herdr and Claude login.
The driver deliberately uses real Claude and real backend/inbox functions; transport instrumentation pauses only the disposable Claude process or holds an inbox-lock reclamation boundary.

Create `.doorbell-lab/bin`, `.doorbell-lab/tmp`, and `.x/herdr` inside the worktree.
Copy `herdr-instrumentation.sh` to `.doorbell-lab/bin/herdr` and `reclamation-instrumentation.sh` to `.doorbell-lab/bin/rm`, making both executable.
Set the isolated Herdr config to a non-login /bin/bash shell with version and manifest checks disabled.
The stock lab helper requires a live default-session liveness tripwire: the run used a worktree-local `.x/herdr/herdr.sock` symlink to `~/.config/herdr/herdr.sock`, with all named-session state kept under `.x/herdr/sessions/`.
The symlink is used only by stock helper session-list liveness checks; no control calls target default.
Named sessions are always `fm-lab-dg`; all lifecycle calls go through `bin/fm-herdr-lab.sh`.
Provision calls prepare internally.
Do not provision in one completed tool command and then test in another: keep provision, driving, and teardown in the same foreground driver.

Execute the retained `live-driver.sh`, then remove only its disposable lab home and execute `prefix-driver.sh`; the latter independently creates a fresh marked lab home.
Execute `cli-overlap-driver.sh` for the public CLI notice contract.
Each driver has a teardown trap and reports the teardown exit status.
The successful live calls were `bash .doorbell-lab/run.sh`, `bash .doorbell-lab/prefix.sh`, and `bash .doorbell-lab/cli-check.sh`.
See `research-notes.md` for the corrected initial prefix-driver error: `--literal` is text in Herdr's CLI, not an option, so the initial remainder carried an unintended suffix and was correctly refused.
