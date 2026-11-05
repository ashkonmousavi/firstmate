# Treehouse status cost: independent gate evidence

Validated 2026-11-05 against the installed Treehouse v3.1.8, using only disposable repositories and pool roots.

The cwd comparison does not hold the pool constant. `--root` supplies the parent of `.treehouse`, but Treehouse still resolves the current repository, then selects a repository-specific directory underneath that root. Its name combines the repository basename and a hash of the remote URL (or repository path without a remote). Running from a different repository therefore lists a different pool. Running outside every repository fails before listing.

The native proof in live-transcript.log returned five slots from the project in 0.145 seconds, zero from another repository in 0.027 seconds, and the same five from a project worktree in 0.157 seconds. The enclosing gate repository selected an empty pool in 0.028 seconds. A true non-repository, enforced with Git's discovery ceiling on the disposable home, failed with exit 1. These are small disposable-pool measurements, not a reproduction of the original laptop's exact 9.8/0.23-second figures or a fleet spawn-latency claim.

A populated status performs work for every slot: pool state healing, process inspection, branch and lock inspection, and (for eligible unleased slots) Git dirty checks. Repeating that full list once for every retained record multiplies its cost. With five retained records over two real roots, the baseline made five status calls and the target made two. With three retained records on one root, the target made one. Preserved lease identities and unlanded files establish protection correctness separately from invocation counts.

Primary sources, retrieved 2026-11-05, pinned to the installed version (publication dates not independently established):

- [status command: repository discovery and pool resolution](https://github.com/kunchenguid/treehouse/blob/v3.1.8/cmd/status.go#L44)
- [pool directory: repository basename and remote/path hash](https://github.com/kunchenguid/treehouse/blob/v3.1.8/internal/config/config.go#L230)
- [pool listing: per-slot process and Git inspection](https://github.com/kunchenguid/treehouse/blob/v3.1.8/internal/pool/pool.go#L1197)

Source copies are retained beside this report. Sources were checked through GitHub/raw GitHub and Exa; a web-fetch cache miss for status.go was worked around with direct curl and Exa, which returned the actual source. Subsequent web access to the config source succeeded.

Research-book context: no data/research-book/INDEX.md exists in this isolated worktree. The phase prohibits reading another clone or operator data, so the live proof and this report provide the independent record here. No fleet research book was modified.
Kun: refreshed ENTRY.md, TOOLS.md, OPINIONS.md and VOICE.md into a worktree-local cache; consulted OPINIONS.md, “Requirements, tests, and review are the new bottlenecks.” This informed the choice to use the authoritative one-read-per-root requirement and actual native leases as independent oracles. The full content-cache pull also finished successfully (2003 new files, exit 0); it is research preparation, not a product check.

Guard: the changed tests/fm-shared-copy.test.sh regression asserts one read per root, preserved leases, fresh invocation snapshots, read-only check mode and no mutations on status failure. The existing selected suite passed in this run through bin/fm-test-run.sh. The native baseline comparison also reproduces the old repeated work on identical records without editing tracked source.
