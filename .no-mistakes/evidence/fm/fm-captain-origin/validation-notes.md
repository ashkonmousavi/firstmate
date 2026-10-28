# Hold provenance live validation

Oracle: the supplied author intent says an inherited worker status must not become an owner decision. The changed CLI contract in docs/captain-hold-lifecycle.md specifies three attribution classes, preservation on omitted flags, restoration after backend refusal, and metadata that does not gate lifecycle commands.

## CLI observations

The real fm-captain-hold.sh and fm-tasks-axi.sh commands used the installed tasks-axi backend against a marked lab home below the gate worktree. No backend output was mocked. All five scenarios in origin-cli-results.json completed successfully; origin-cli-transcript.txt contains the public commands and complete full-body readbacks.

- Creation recorded owner-request, finding, and pipeline-outcome. An older caller without --origin-kind still created a held task.
- Re-holds preserved timestamp, unrelated task context, origin association, and omitted classification. Reclassification replaced the old class without duplicate metadata.
- Invalid new and existing classifications failed before backlog bytes changed.
- For the refusal case, a temporary PATH interposer delegated every operation to the installed real tasks-axi. During hold only, it made the lab backlog and its directory read-only, retained the actual backend result, and restored permissions. backend-denial.txt shows EACCES and backend exit 1. The wrapper refused and the full task readback exactly matched its state before the call, including the previous origin and finding attribution.
- Complete and verify accepted a finding-class hold. Answer recorded the supplied exact words, closed the task, and retained provenance. A subsequent re-hold of the closed task failed without changing it.

## Agent observations

A real Claude primary ran from the target worktree on a private fm-lab tmux socket in a marked disposable home, using its existing login. The terminal was explicitly 120 columns by 40 rows. Tools, hooks, MCP servers, and session persistence were disabled for this read-only text probe; native project instruction loading remained enabled. No login or credential state was changed.

The input was synthetic and is retained in agent-provenance-prompt.txt. The complete authenticated harness response is agent-provenance-result.json; the user-facing text is agent-provenance-response.md.

Manual behavioral review against the author intent:

- A worker status claiming “Owner parked the lane,” with no owner message, was described as an earlier agent call. The agent proposed advisor resolution of the technical question and did not ask the owner to approve it.
- A prior firstmate note from a pipeline review claiming the owner required another review was also described as an earlier agent call, with advisor review as the next step.
- A genuine owner message msg-104 retained its attribution, deferral, and color constraint.
- The response explicitly said no advisor had yet been consulted and no state had been changed.

This is a single development-time live model observation, not a deterministic guarantee of all future model interpretations or a live-LLM CI regression test. No UI layout or copy-placement surface changed; the actual public surfaces here are CLI output and an agent reply, retained as text rather than screenshots.

## Setup correction and cleanup

The first attempted backend-refusal input, 2099-02-31, was accepted by the installed backend. This was an incorrect test-setup assumption, not a failure of the changed provenance behavior. tasks-axi hold --help and the upstream README (https://github.com/kunchenguid/tasks-axi) specify a YYYY-MM-DD date gate without promising calendar validation. The first fault-injection attempt then exposed only the wrapper diagnostic because the wrapper captures backend output; retaining the raw real backend output resolved that evidence gap. The corrected run completed every scenario. Initial transcripts are retained separately for audit.

Both Python drivers awaited their children and exited 0. Claude's retained result reports success and exit 0. The private tmux server had already exited when cleanup checked it; fm-lab-home teardown confirmed and removed its private socket directory. All disposable homes were deleted. Final git status --short was empty. No source, test, or agent-memory files were edited. No suite, linter, formatter, static-analysis, delivery, or pipeline-control command ran.
