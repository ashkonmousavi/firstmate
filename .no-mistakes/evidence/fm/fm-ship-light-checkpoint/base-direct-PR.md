# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/ordinary
class fix: test fails without the fix; symptom seen twice.
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
Perform exactly one code review round against the preparation outcomes and project standards using the existing review mechanism.
Record the reviewed head, findings and their resolution in the task report; fix the findings without another review round, then validate the final head through the selected delivery path's checks.
That round's finding list is the only one: never request a second review list, and record any finding you leave unfixed under the review follow-up rule as a follow-up item, never as fixed.
Do not commission a separate preparation review or add a second implementation review.
This task is complete only with an existing non-draft PR and every required check green for its current head.
When it is implemented and committed, push your branch and open a PR with `gh-axi` that is ready for review, not a draft.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Wait for every required check on the current PR head to be green, reading the forge with `gh-axi pr checks <number>` (consult its `--help` for current usage).
Pending checks use `paused [at=<epoch>]: {checks awaited and completion condition}`; resume when they finish, fixing failed checks and pushing the repair through this direct-PR path before checking again.
Then append `done [at=<epoch>]: PR {full https URL from the forge} checks green` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
