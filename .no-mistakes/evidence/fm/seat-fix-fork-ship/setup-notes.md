# Targeted test setup notes

The initial targeted run passed machine resources, capacity, capacity-reader and state-claim suites.
Request-acceptance had two setup failures: TMPDIR was inside the source checkout, so its two handoff fixtures were correctly refused as secondmate homes inside the source tree.
Hypothesis: changing only temporary-fixture placement would let those same tests reach their handoff assertions.
Disproof would have been the same failures with TMPDIR outside the source tree.
An independent read-only reviewer confirmed the causal path in RequestCustody.setUp and validate_secondmate_home.
The full request-acceptance suite then exited 0 with TMPDIR beneath this evidence directory; its fixtures were removed.
No product guard or permanent test was changed.

Research read: data/research-book/INDEX.md and capacity-review.md; no existing entry covered this setup condition.
The Python [tempfile contract](https://docs.python.org/3/library/tempfile.html#tempfile.gettempdir), checked 2026-11-03, makes TMPDIR the first temporary directory candidate.
The permanent prevention here is the existing secondmate path guard, whose refusal was retained in targeted-regressions.log; the evidence drivers also create private custody packets with mode 0600.

The first manual intake attempt used a non-private packet and was correctly refused; setting the disposable packet to 0600 made the accepted packet scenario pass.

All live Claude Stop cases ran on Claude Code 2.1.318 using the normal login, a marked lab home and its private fm-lab tmux socket (120 columns by 40 rows).
All lab sessions, processes and fixture homes were stopped and removed.
No Herdr or production fleet lifecycle was exercised.
Alarm installation and queue filling remain outside this change under the recorded decisions; no external alarm proof is claimed.
