# Targeted validation

The acceptance oracle is the recorded owner decision: skip duplicate local lint with an explicit successful command, retain hosted lint and Pi typechecking, and leave commands.test absent.
The [official command contract](https://kunchenguid.github.io/no-mistakes/reference/repo-config/#commandslint) executes nonempty commands through sh -c and checks their exit status; default-branch trust means this branch cannot change the current run's trusted configuration.

config-command.json records normalized YAML semantics, actual /bin/sh -xc execution of the configured colon command, and the real fm-test-run.sh lane selection. No linter or compiler was executed. An initial probe expected a shorter CI command and failed its own assertion; inspection showed the actual partition-total and telemetry arguments, so the corrected probe parses shell argv after matrix expansion. This was a probe expectation error.

The runtime lock oracle is mutual exclusion and eventual handoff: four real Bash contenders use the unmodified production library, real filesystem symlinks, process identity and sleeps. An independent mkdir sentinel rejects overlapping holders. All 24 acquisitions/releases completed. A fifth process exited while holding the mutex; the next process reclaimed it and released it without leaving owner records.

The existing publication-race regression injects one readlink failure at the external filesystem boundary. It fails against the base library with “repair mutex rejected a symlink published after a failed readlink” and passes against the target. This is targeted fault injection, not a live Darwin LaunchAgent check.

The two changed watcher tests execute the real OpenCode plugins against fake watcher/guard executables and a fake client. They pass and are supplemental behavioral tests, not a live authenticated OpenCode primary.

Reproduce the targeted existing tests from the repository root with:

```sh
python3 /path/to/this/evidence/targeted-reproduce.py
```

Reproduce the real lock scenario from the repository root after creating .gate-test with:

```sh
timeout 45 bash /path/to/this/evidence/live-lock-driver.sh
```

The drivers create isolated state below the worktree. Remove .gate-test after the lock driver finishes. Neither driver runs lint, a broad suite, or a no-mistakes pipeline. Real no-mistakes lint-phase and hosted CI execution are reserved to the outer executor; they were not driven here. No UI surface changed, so visual evidence is not applicable.
