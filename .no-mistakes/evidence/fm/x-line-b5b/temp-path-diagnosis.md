The first focused suite run used TMPDIR=$PWD/.test-b5b-tmp and exited 1 at the existing test_branch_prefix_command_is_shell_safe case. All new Slice cases had passed before that failure.

Hypothesis: that test embeds its absolute marker path in a branch prefix. A dot-prefixed path component makes the resulting ref invalid, independently of Slice extraction. Disproof would be Git accepting the worktree-based ref or rejecting the equivalent /tmp-based ref.

Counterfactual using the real git check-ref-format --branch interface:
- $(touch${IFS}~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/marker)brief-branch-safe-g3: exit 128, invalid branch name.
- $(touch${IFS}/tmp/fm-brief-fixture/marker)brief-branch-safe-g3: exit 0.

Independent primary source, retrieved 2026-11-05 (undated documentation): https://git-scm.com/docs/git-check-ref-format.html. Git disallows slash-separated ref components beginning with a dot. Current primary documentation was searched first. No research-book entry: this worktree has no data/ directory; reading another Firstmate checkout is outside this phase's path contract.

The rerun uses TMPDIR=/tmp, the suite's standard ephemeral location, permitted by the workspace instruction's test-toolchain temporary-write exception. Manual native-backlog fixtures remained within the worktree and were deleted by their driver. No source change is required. Existing Slice executable-output regressions are the durable guard for the change under test.
