# Native Treehouse root correction

Date: 2026-11-03.
Base tested head: c9b4d824ce90f7e2f73a6c9b8e1b6d143ba847d0, plus the two-file working-tree fix.
Installed native Treehouse: v3.1.8.
Research book consulted: ~/Firstmate/firstmate/data/research-book/INDEX.md; no entry covers native root resolution.
This phase cannot write the live research book under its workspace boundary; this evidence records the result for the outer executor.

## Primary-source contract

- https://raw.githubusercontent.com/kunchenguid/treehouse/v3.1.8/internal/config/config.go : ResolvePoolRoot joins every explicit root with `.treehouse`; the implicit root is HOME/.treehouse.
- https://raw.githubusercontent.com/kunchenguid/treehouse/v3.1.8/cmd/lease.go : lease resolves the same pool through ResolveRoot and ResolvePoolDir and upgrades an existing slot without checkout mutation.

Read both tagged sources on 2026-11-03 using Exa.

## Reproduction and causal check

`bash native-spawn-reproduce.sh` (existing evidence script, invoked from the assigned worktree) failed with exit 1 before the fix:

```
jq: error (at <stdin>:1): slot identity unavailable
error: cannot retain task alpha's copy .../.l/p/.treehouse/project-758d88/1/project until cleanup; refusing launch
```

`bash native-root-reproduce.sh` independently allocated a native slot, observed one slot with the configured root, zero slots with the helper-derived root, and one slot with the parent of `.treehouse` (exit 0).
The script's final message confirms that the original helper sees an empty different pool despite a registered lease.

Trigger: spawn upgrades its interactive allocation to a durable lease.
Masking condition: existing test adapters ignore `--root`.
Symptom: native spawning refuses before worker launch because status reads a nested, empty pool.
Hypothesis: passing the parent of `.treehouse` to both status and lease resolves the actual slot; a failure with that parent or native lease loss after shell exit would disprove it.

## Regression and fix

Added `test_spawn_resolves_native_pool_root` to tests/fm-shared-copy.test.sh.
It executes fm-spawn against a scratch Git worktree and a root-aware Treehouse boundary adapter.
The adapter follows the tagged native root contract, locates state by resolved root, and rejects nonexistent pools.
The fixture deliberately supplies a different ambient TREEHOUSE_ROOT, so simply dropping --root also fails.
Assertions require successful spawn, a durable lease in the actual pool, and the correct published task worktree.
The regression failed with the same slot-identity error before changing production code.
The shared helper now derives the parent of `.treehouse` for both status and lease calls.

## Native verification

Both of these existing end-to-end reproducers completed with exit 0 after the fix:

```
bash ~/.no-mistakes/evidence/01M6HHP6GWKMX7FZ0GRB6213RN/native-spawn-reproduce.sh
DEFAULT_POOL=1 bash ~/.no-mistakes/evidence/01M6HHP6GWKMX7FZ0GRB6213RN/native-spawn-reproduce.sh
```

Logs: native-root-fix-explicit.log and native-root-fix-default.log.
Both finish with:

```
PASS: native interactive reservation became durable, survived shell exit, later allocation used a distinct copy, and fresh same-ID retry preserved ownership.
```

These checks use the real public fm-spawn CLI, real Treehouse v3.1.8, a private tmux server, scratch lab homes and raw sleep workers.
They submit no model request.
Each script stops its private tmux server and removes its scratch lab in its EXIT trap.
No live home or shared pool was mutated.

A first post-fix regression run with TMPDIR inside this worktree passed the new regression but encountered an existing secondmate-home teardown placement guard.
This is test setup, not the root bug: teardown intentionally refuses a secondmate home inside the Firstmate repository.
The targeted suite is therefore rerun with `env -u TMPDIR bash bin/fm-test-run.sh tests/fm-shared-copy.test.sh`; its actual result is recorded in native-root-fix-regression.log.
No linter, formatter, static analyzer, broad suite, delivery or other pipeline phase was run.

Final targeted regression result: exit 0, 13 cases passed, zero failures or skips (22.145 seconds).
All eight process IDs observed in the two native logs were confirmed exited using kill(pid, 0), and native lab scratch was absent.
The empty .test-scratch directory was removed.
Only bin/fm-treehouse-lib.sh and tests/fm-shared-copy.test.sh remain modified.
