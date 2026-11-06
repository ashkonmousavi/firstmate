Run from this change in a disposable gate worktree with Codex, tmux, Treehouse, Python and jq on PATH. No real logins are used.

1. Run the canonical targeted command from the test result.
2. Create `.nm-live`, copy `drive-driver.py` to `.nm-live/drive.py`, and the other `*-driver.py` files to `.nm-live/{released,alias,batch,refusals}.py`.
3. Mint `.nm-live/home` with `bin/fm-lab-home.sh create "$PWD/.nm-live/home"`; create `.nm-live/user` and `.nm-live/project`.
4. Run `python3 .nm-live/drive.py`, then `released.py`, `alias.py`, `batch.py`, and `refusals.py` from that folder path, in order. Each uses the private `fm-lab` tmux socket below `.l/tmux`, gives the terminal a 160x45 grid, and stops its server/API children. The executable paths stay real; external fixtures are listed in environment.json.
5. Inspect the retained JSON observations and CLI transcripts, then remove the disposable `.l` and `.nm-live` trees.

Early lab setup retries corrected the empty activity inventory protocol, the private socket identity, use of a nonexistent control status verb, the required relaunch note, the selected account rules directory, and the independent Treehouse identity for the released test repository. Final retained driver runs all exited zero. These were lab setup errors, not product failures.

Native backend limits: isolated Herdr prepare refused because its mandatory tripwire requires exactly one running default session; no session was provisioned. T3 admission stopped at the missing disposable credential. No production session or credential was changed. The targeted T3 suite passed its modeled admission checks; that is not native T3 proof.

This is CLI/startup behavior, with no renderer or visual layout change; evidence is native runtime inventory, PID readback, task metadata, and actual CLI/TUI transcripts.
