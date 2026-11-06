# Fixture placement diagnosis

The first full subject invocation exited 1 at `ship scaffold for derivation` after 54 seconds. Its disposable fixture project was an uninitialized directory nested inside this gate worktree, so Git discovered this repository. The production publication guard correctly rejected consent for `github.com/o/r` against the enclosing Firstmate repository.

Hypothesis: limiting upward Git discovery at the temporary root preserves the fixture's intended unrelated-project status. Falsifier: Git still discovers this worktree from a fixture descendant with that ceiling.

The paired executable Git probes in git-fixture-isolation.json establish the cause: ordinary discovery returns this worktree, while the identical probe with GIT_CEILING_DIRECTORIES at the temporary root returns 128, not a repository. An independent read-only agent reviewed the test setup, fm-role-lib.sh and helper environment handling and confirmed the repair. It also checked that discovery at the actual source root still works.

The second full subject invocation adds only process-local `GIT_CEILING_DIRECTORIES=$PWD/.validation-tmp`; no source, grants, protected tests, global config or production state changed. It retains TMPDIR inside the workspace and unsets all five selector variables. This invocation supersedes the contaminated first attempt when it completes successfully.

Primary reference, retrieved 2026-11-05: https://git-scm.com/docs/git#Documentation/git.txt-codeGITCEILINGDIRECTORIEScode. Git documents this variable as an absolute-directory ceiling for repository discovery.

Research book: no entry available in this gate worktree (no data directory). Other project clones are outside this phase's read boundary. Kun: no relevant opinion consulted for this direct Git behavior counterfactual; the real executable and official contract settle the setup question. This private evidence record is the reproducible guard for the placement issue; no unrelated tracked research book was created.
