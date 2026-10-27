Targeted validation: codex-cli 0.163.0, 2026-10-27.

bash tests/fm-codex-harness.test.sh completed with exit 0. An initial TMPDIR inside the repository hit the secondmate-home location restriction; normal ephemeral test storage resolved it.

The retained live-check.sh adapts tests/fm-codex-brief-typed-live-e2e.test.sh with a marked lab home, workspace-local TREEHOUSE_ROOT and CODEX_HOME, an existing login copied into disposable storage, private tmux server sized 200x50, gpt-6.1-sol/low, and retained pane captures. Exit 0. New folder: 9 seconds; trusted folder: 6 seconds, with distinct response challenges. No global Codex configuration or trust store changed.

The retained unready-check.sh ran real Codex with an intentionally empty disposable CODEX_HOME and FM_CODEX_READY_POLLS=16. Real fm-spawn returned 1 within 15 seconds and reported codex did not take the brief. The negative-check driver exited 0. This does not claim the normal login is unavailable.

FM_HERDR_LAB_STATE_DIR=$PWD/.test-tmp/herdr-state bash bin/fm-herdr-lab.sh provision fm-lab-codex-gate-proof returned 1 with the retained tripwire refusal. No default session changed. The owner decision defers Herdr proof to MAIN.

Both live drivers completed their cleanup and exited 0. Disposable credentials, scratch repositories, pool, and scripts were then removed.
