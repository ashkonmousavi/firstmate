# Lane-release shim live validation

Acceptance oracle: the author's requirement that the shim runs its home's own code root. Additional CLI contracts come from `docs/configuration.md` (Lane release) and the `bin/fm-lane-release.sh` header: arm registers a check, the check runs sweep, and disarm removes it.

Reproduce from the run worktree:

```sh
python3 ~/.no-mistakes/evidence/01M6AHBHMAYT1GXYZJABSB69CS/drive-lane-shim.py
```

The driver copies the actual product bin directory into disposable roots within the worktree, creates marked lab homes with `fm-lab-home.sh create`, arms the real CLI, and runs the generated check through the real `fm_custom_check_snapshot_prepare` consumer used by the watcher. Bash execution tracing records the selected executable and its `sweep` argument; actual sweep output and persisted invalid-setting state independently prove execution in the intended home. The invalid setting prevents any worker-release action. There are no fake product implementations or backend probes. All disposable roots are removed.

The transcript `lane-shim-live.log` records each command, stdout, stderr, and exit status. `lane-shim-results.json` lists the nine live scenarios. Shell-sensitive paths contain spaces, an apostrophe, a dollar sign, a semicolon, and parentheses. The relative-home scenario also invokes the check with an unrelated caller FM_HOME.

The original pre-fix executable from base commit ee1fcd6f14c2df2be31bc119171bc3f7c6014f3f reproduced exit 127 when its arming root was deleted despite executable home code. The target passed that same removed-root case, including a byte-bound snapshot of the original unmodified generated check.

The focused existing regression command is `TMPDIR=<disposable-worktree-dir> bash tests/fm-lane-release.test.sh`. Its endpoint/control substitutes make it supporting regression evidence, not live fleet evidence. No fleet session, real operator data/configuration, publication, pipeline control, lint, static analysis, or complete repository suite is involved. The altered surface is a shell CLI/check shim; there is no rendered UI requiring screenshot evidence.

External shell-reference lookup: Exa returned the GNU Bash manual mirror at https://gnu.cs.utah.edu/Manuals/bash-2.05a/html_node/bashref_54.html describing exec and executable tests. Direct fetches of current www.gnu.org manual pages timed out in web and returned SOURCE_NOT_AVAILABLE through Exa. This auxiliary lookup failure did not prevent execution of the installed real Bash and real product interfaces; no external dependency was installed. The retained executable driver is the regression guard for this evidence turn.

Final result: the live driver exited 0 and every scenario passed; the focused existing regression suite exited 0. Exact completion statuses are retained in `lane-shim-driver-status.json` and `lane-release-targeted-status.json`. All testing children completed, disposable worktree directories were removed, and the final worktree status was clean. No source changes were necessary.
