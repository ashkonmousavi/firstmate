# Capacity live validation

The independent oracle is the owner's supplied Seats rule: an exited agent with no non-shell process in its worktree frees its seat; unknown evidence retains it. This is distinct from checking that two product counters agree.

The focused regression scripts execute the real admission and reporting commands, but their backend fixtures are mocked, so those scripts alone are not claimed as live proof. `live-capacity.py` instead uses real tmux, lsof, ps, Git clones, and OS processes, and compares product results to explicit expected occupants. Its public spawn check launches a real Python workload through Firstmate's supported raw-command interface; it does not impersonate an authenticated AI CLI. Its separate live-agent check uses the installed Codex CLI without a model request.

Outside research consulted lsof's upstream [FAQ](https://github.com/lsof-org/lsof/blob/master/00FAQ) and [project documentation](https://github.com/lsof-org/lsof). The documented cwd records and machine-readable field output support a bounded process scan; there is no need for a recursive worktree filesystem scan. Search did not establish any upstream incident as the cause of this project-capacity bug. Local counterfactual evidence is stronger: the same idle exited record consumes one project seat under the base implementation and zero under the target.

All project fixtures live in the run worktree. The lab's own Treehouse pool hardens its copied Git hooks directory; cleanup restores owner directory permissions only inside that disposable tree before removing it. The private tmux server has no user tmux config and starts its PTYs at 100 by 30 cells. Codex's updater is skipped for the current invocation, and its hooks are disabled with the production launcher's `--disable hooks` flag; no tool upgrade or stored hook-trust change is performed.

Research evidence is retained here for the outer executor; this test phase does not edit the operator's private research book, fleet records, configuration, or another delivery phase.
