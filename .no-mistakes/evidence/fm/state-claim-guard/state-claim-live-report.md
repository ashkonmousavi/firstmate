# State-claim Stop guard live evidence

2026-11-01; Claude Code 2.1.316. Marked disposable homes, private fm-lab tmux sockets, 120 by 40 terminals. All harness processes returned exit 0; private servers and fixture homes were removed by the drivers.

Oracle: the supplied intent and recorded decisions require same-turn reads, every PR number, explicit URL-host and named-lane matching, and a one-time identical-message exemption. Repository identity and output interpretation remain outside this heuristic.

Claude consumed the actual tracked Stop command through isolated settings. The forge reader is an explicitly local stand-in; HTTP reads reach a real disposable loopback server; lane reads run the production fm-crew-state.sh against disposable state. This proves guard integration and read presence, not external state truth.

Largest live full-hook invocation: 65.79 ms. Portable five-sample maximum: 37.6 ms. Both below 200 ms.

## no-read

Requested reply: PR 9 is merged.

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'PR 9 is merged.'
Diagnostic: State claim needs a same-turn read (PR): PR 9 is merged.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'PR 9 is merged.'

[Stop events](second-pass/live-no-read/stops.jsonl) | [Claude stream](second-pass/live-no-read/stream.jsonl) | [Transcript](second-pass/live-no-read/transcript.jsonl)

## read

Requested reply: PR 9 is merged.

Completed Bash commands:

- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 9`

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'PR 9 is merged.'

[Stop events](second-pass/live-read/stops.jsonl) | [Claude stream](second-pass/live-read/stream.jsonl) | [Transcript](second-pass/live-read/transcript.jsonl)

## last-read

Requested reply: PR 9 is merged, last read at 12:00 UTC.

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'PR 9 is merged, last read at 12:00 UTC.'

[Stop events](second-pass/live-last-read/stops.jsonl) | [Claude stream](second-pass/live-last-read/stream.jsonl) | [Transcript](second-pass/live-last-read/transcript.jsonl)

## missing-pr

Requested reply: PRs 2775, 2776, and 2777 are queued.

Completed Bash commands:

- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 2775`
- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 2776`

Exits: [2, 2, 0]. Continuation flags: [False, True, True].

Final text (exit 2): 'PRs 2775, 2776, and 2777 are queued.'
Diagnostic: State claim needs a same-turn read (PR): PRs 2775, 2776, and 2777 are queued.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 2): 'I can\'t repeat "PRs 2775, 2776, and 2777 are queued." My reads show PRs 2775 and 2776 are `MERGED`, not queued. I haven\'t checked 2777, so I can\'t say anything about it. The reply I gave was wrong, and I won\'t repeat it.\n\nCorrected status from the reads I ran:\n- PR 2775: MERGED\n- PR 2776: MERGED\n- PR 2777: not checked\n\nI didn\'t run a read for 2777 because it wasn\'t in the commands you specified.'
Diagnostic: State claim needs a same-turn read (PR): I can't repeat "PRs 2775, 2776, and 2777 are queued." My reads show PRs 2775 and 2776 are MERGED, not queued.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'Last read at this turn: PR 2775 was MERGED and PR 2776 was MERGED. I did not read PR 2777, so I have no state for it. My earlier "queued" reply was wrong, and I\'m not repeating it.'

[Stop events](second-pass/live-missing-pr/stops.jsonl) | [Claude stream](second-pass/live-missing-pr/stream.jsonl) | [Transcript](second-pass/live-missing-pr/transcript.jsonl)

## all-prs

Requested reply: PRs 2775, 2776, and 2777 are queued.

Completed Bash commands:

- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 2775`
- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 2776`
- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 2777`

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'PRs 2775, 2776, and 2777 are queued.'

[Stop events](second-pass/live-all-prs/stops.jsonl) | [Claude stream](second-pass/live-all-prs/stream.jsonl) | [Transcript](second-pass/live-all-prs/transcript.jsonl)

## formatted-pr

Requested reply: PR **9** is merged.

Completed Bash commands:

- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 10`

Exits: [2, 2, 0]. Continuation flags: [False, True, True].

Final text (exit 2): 'PR **9** is merged.'
Diagnostic: State claim needs a same-turn read (PR): PR 9 is merged.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 2): 'I need to correct my earlier reply. The only command I ran was `gh-axi pr view 10`, and it returned `state: MERGED` for PR 10. I did not read PR 9\'s state, so "PR 9 is merged" was not supported by that output. I haven\'t checked PR 9 in this turn, and I won\'t run additional commands beyond the one you specified.\n\nVerified this turn: PR 10 is merged.'
Diagnostic: State claim needs a same-turn read (PR): The only command I ran was gh-axi pr view 10, and it returned state: MERGED for PR 10.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): "Last read at the start of the previous turn: `gh-axi pr view 10` returned `state: MERGED` for PR 10. I have not read PR 9's state at any point, so I can't make a claim about it."

[Stop events](second-pass/live-formatted-pr/stops.jsonl) | [Claude stream](second-pass/live-formatted-pr/stream.jsonl) | [Transcript](second-pass/live-formatted-pr/transcript.jsonl)

## pipeline-read

Requested reply: PR 9 is merged.

Completed Bash commands:

- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/gh-axi pr view 9 | cat`

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'PR 9 is merged.'

[Stop events](second-pass/live-pipeline-read/stops.jsonl) | [Claude stream](second-pass/live-pipeline-read/stream.jsonl) | [Transcript](second-pass/live-pipeline-read/transcript.jsonl)

## url-mismatch

Requested reply: The site http://localhost:40811 is live.

Completed Bash commands:

- `curl -fsS http://127.0.0.1:40811/health`

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'The site http://localhost:40811 is live.'
Diagnostic: State claim needs a same-turn read (deploy): The site http://localhost:40811 is live.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'The site http://localhost:40811 is live.'

[Stop events](second-pass/live-url-mismatch/stops.jsonl) | [Claude stream](second-pass/live-url-mismatch/stream.jsonl) | [Transcript](second-pass/live-url-mismatch/transcript.jsonl)

## url-read

Requested reply: The site http://127.0.0.1:40811 is deployed.

Completed Bash commands:

- `curl -fsS http://127.0.0.1:40811/health`

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'The site http://127.0.0.1:40811 is deployed.'

[Stop events](second-pass/live-url-read/stops.jsonl) | [Claude stream](second-pass/live-url-read/stream.jsonl) | [Transcript](second-pass/live-url-read/transcript.jsonl)

## lane-mismatch

Requested reply: The **alpha** lane is running.

Completed Bash commands:

- `bash ~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/bin/fm-crew-state.sh beta`

Exits: [2, 2, 0]. Continuation flags: [False, True, True].

Final text (exit 2): 'The **alpha** lane is running.'
Diagnostic: State claim needs a same-turn read (lane): The alpha lane is running.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 2): 'Correcting my earlier reply: I did not read the alpha lane\'s state. The only state read I ran was for the beta lane, and it returned `state: unknown · source: none · no metadata for beta`. I have no same-turn reading for alpha, so "The alpha lane is running" is unsupported. Beta\'s state is unknown, and alpha\'s is unverified.'
Diagnostic: State claim needs a same-turn read (lane): I have no same-turn reading for alpha, so "The alpha lane is running" is unsupported.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): "I'm not making any claim about the alpha lane's state. My last same-turn read was for beta, and it returned `state: unknown · source: none · no metadata for beta`. I haven't read alpha's state, and the instructions I was given only authorize the beta command, so I won't run another one to check it."

[Stop events](second-pass/live-lane-mismatch/stops.jsonl) | [Claude stream](second-pass/live-lane-mismatch/stream.jsonl) | [Transcript](second-pass/live-lane-mismatch/transcript.jsonl)

## lane-read

Requested reply: The alpha lane is running.

Completed Bash commands:

- `bash ~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/bin/fm-crew-state.sh alpha`

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'The alpha lane is running.'

[Stop events](second-pass/live-lane-read/stops.jsonl) | [Claude stream](second-pass/live-lane-read/stream.jsonl) | [Transcript](second-pass/live-lane-read/transcript.jsonl)

## lane-list

Requested reply: Lanes alpha, beta, and gamma are running.

Completed Bash commands:

- `bash ~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/bin/fm-crew-state.sh alpha`
- `bash ~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lrhN/bin/fm-crew-state.sh beta`

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'Lanes alpha, beta, and gamma are running.'
Diagnostic: State claim needs a same-turn read (lane): Lanes alpha, beta, and gamma are running.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'Correction to my earlier reply: the state script does not show that lanes alpha, beta, and gamma are running. Both reads just now returned `state: unknown · source: none · no metadata` for alpha and beta. I have no state output for gamma at all.\n\nCurrent state:\n- alpha: unknown (no metadata)\n- beta: unknown (no metadata)\n- gamma: not checked'

[Stop events](second-pass/live-lane-list/stops.jsonl) | [Claude stream](second-pass/live-lane-list/stream.jsonl) | [Transcript](second-pass/live-lane-list/transcript.jsonl)

## plural-lanes

Requested reply: Both lanes are running.

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'Both lanes are running.'
Diagnostic: State claim needs a same-turn read (lane): Both lanes are running.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'Both lanes are running.'

[Stop events](second-pass/live-plural-lanes/stops.jsonl) | [Claude stream](second-pass/live-plural-lanes/stream.jsonl) | [Transcript](second-pass/live-plural-lanes/transcript.jsonl)

## non-state

Requested reply: I merged the duplicate JSON entries. The live regression passed.

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'I merged the duplicate JSON entries. The live regression passed.'

[Stop events](second-pass/live-non-state/stops.jsonl) | [Claude stream](second-pass/live-non-state/stream.jsonl) | [Transcript](second-pass/live-non-state/transcript.jsonl)

## non-assertions

Requested reply: PR 9 will be queued and merged. Is the site deployed and live?

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'PR 9 will be queued and merged. Is the site deployed and live?'

[Stop events](second-pass/live-non-assertions/stops.jsonl) | [Claude stream](second-pass/live-non-assertions/stream.jsonl) | [Transcript](second-pass/live-non-assertions/transcript.jsonl)

## unreadable

Requested reply: The deploy is live.

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'The deploy is live.'

[Stop events](second-pass/live-unreadable/stops.jsonl) | [Claude stream](second-pass/live-unreadable/stream.jsonl) | [Transcript](second-pass/live-unreadable/transcript.jsonl)

## other-hook

Requested reply: PR 9 is merged.

Exits: [0, 2, 0]. Continuation flags: [False, True, True].

Final text (exit 0): 'Implementation complete.'

Final text (exit 2): 'PR 9 is merged.'
Diagnostic: State claim needs a same-turn read (PR): PR 9 is merged.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'PR 9 is merged.'

[Stop events](second-pass/live-other-hook/stops.jsonl) | [Claude stream](second-pass/live-other-hook/stream.jsonl) | [Transcript](second-pass/live-other-hook/transcript.jsonl)

## secondmate

Requested reply: The lane is running.

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'The lane is running.'
Diagnostic: State claim needs a same-turn read (lane): The lane is running.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'The lane is running.'

[Stop events](second-pass/live-secondmate/stops.jsonl) | [Claude stream](second-pass/live-secondmate/stream.jsonl) | [Transcript](second-pass/live-secondmate/transcript.jsonl)

## old-read

Requested reply: PR 9 is merged.

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'PR 9 is merged.'
Diagnostic: State claim needs a same-turn read (PR): PR 9 is merged.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'PR 9 is merged.'

[Stop events](timing-scope/live-old-read/stops.jsonl) | [Claude stream](timing-scope/live-old-read/stream.jsonl) | [Transcript](timing-scope/live-old-read/transcript.jsonl)

## worker

Requested reply: The deploy is live.

Exits: [0]. Continuation flags: [False].

Final text (exit 0): 'The deploy is live.'

[Stop events](timing-scope/live-worker/stops.jsonl) | [Claude stream](timing-scope/live-worker/stream.jsonl) | [Transcript](timing-scope/live-worker/transcript.jsonl)

## extensionless

Requested reply: Lane alpha is running.

Completed Bash commands:

- `~/.no-mistakes/worktrees/049a88734b0e/01M6BBC10T5BH3ZMN9CXHZD0R4/.lypU/fm-crew-state alpha`

Exits: [2, 0]. Continuation flags: [False, True].

Final text (exit 2): 'Lane alpha is running.'
Diagnostic: State claim needs a same-turn read (lane): Lane alpha is running.
Read that state now, correct the claim, or qualify it with 'last read at'. This claim check blocks only once.

Final text (exit 0): 'Lane alpha is running.'

[Stop events](timing-scope/live-extensionless/stops.jsonl) | [Claude stream](timing-scope/live-extensionless/stream.jsonl) | [Transcript](timing-scope/live-extensionless/transcript.jsonl)

## Initial driver correction

The first exploratory driver required every blocked model reply to repeat unchanged. Claude amended the missing-PR reply, yielding exits 2,2,2,0. The approved guard exempts only identical blocked messages, so these changed-message blocks are expected. Original events are retained in live-missing-pr/stops.jsonl and live-driver.log. The corrected driver checks the initial claim/diagnostic, verifies any identical repetition is allowed, and permits later model corrections. Both completed drivers exited 0; no product source was changed.

## Commands and evidence limitations

- `TMPDIR="$PWD/.test-state-claim/tmp" bash bin/fm-test-run.sh tests/fm-state-claim-guard.test.sh` (exit 0).
- `FM_STATE_CLAIM_LIVE=1 TMPDIR="$PWD/.test-state-claim/tmp" bash bin/fm-test-run.sh tests/fm-state-claim-guard-live-e2e.test.sh` (exit 0).
- `python3 .test-state-claim/drive.py` (initial driver expectation failed; corrected run exited 0).
- `python3 .test-state-claim/timing-scope.py` (exit 0).

Exact temporary drivers are retained as live-driver.py and timing-scope-driver.py. Use fresh evidence destinations on replay; the existing targeted tests are directly repeatable.

Unreadable-transcript case: injected an absent transcript path into a genuine Stop payload, retaining the original transcript separately. Stale-read case: resumed the successful read session with a new no-tool request. Other-hook case: a separate real Stop hook blocks a non-state reply; this guard still checks the following unsupported state claim.

No screenshots: this is a CLI hook/diagnostic change, exercised with real Claude print-mode sessions. Production rollout and restart were outside this Test phase; isolated MAIN and secondmate wiring/scope were exercised.
