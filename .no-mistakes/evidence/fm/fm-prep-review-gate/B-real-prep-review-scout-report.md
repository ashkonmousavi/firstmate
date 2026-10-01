# Prep review: lab-ship

## Verdict: APPROVE (with one wording correction)

reviewed-prep.md DIFFERS from the original prep.md in one place (section 1). prep.md was not edited.

## What I did
Read prep.md, brief.md and the worktree. Worktree state: README.md is 6 bytes (`xxd`: `6865 6c6c 6f0a`, i.e. `hello\n`), single commit `8f53127 init`, clean. `.claude/` holds only `settings.local.json` (fleet hooks), no project CLAUDE.md or README/record conventions.

## Findings
1. Tier answers are honest. Q1=yes (a user reading the README sees a new line) gives tier 2 per the record's own header, and all 12 sections are present.
   Q2=no is right (one file). UI wiring=no is right (no control).
   Q1=yes is conservative; Q1=no would make a tier 0 record with no sections 2 and 11, which the spec presupposes.
2. Section 2 is concrete and testable: the line `Welcome to the lab project.` directly under `hello`. Check: `sed -n 2p README.md`.
3. Section 11 is concrete and consistent with section 2: README.md second line is the copy, no other file changes. Check: `git diff --stat` shows only README.md.
4. Nothing promised is out of scope. Section 8 excludes other README edits; section 12 says one file. The n/a answers (3, 4, 5, 6, 7, 9, 10) each carry a valid one-line reason for a one-line docs change.
5. Wording fix (the only change): section 1 says "the captain's words" but paraphrased them ("greeting line"). I replaced it with the quoted words "Add a welcome line to the README." and noted that the exact copy is the preparer's wording within that ask.
6. Non-gating note: the new line directly follows `hello` with no blank line, so Markdown renders both as one paragraph. This matches the spec as written and is not a defect. If a separate paragraph was intended, a blank line is needed, which would break "second line" in section 11.

## Evidence
`diff prep.md reviewed-prep.md`:
```
15c15,16
< Add a greeting line to README.md as the captain asked.
---
> Captain's words: "Add a welcome line to the README."
> The copy `Welcome to the lab project.` is the preparer's wording, within that ask.
```

## Completion gate
No unresolved captain call. Ran `FM_HOME=/tmp/fm-lab.msxl6U bin/fm-captain-hold.sh complete lab-prep-review --none`, output: `complete: lab-prep-review captain-call inventory reviewed`.

## Recommendation
Dispatch the worker with /tmp/fm-lab.msxl6U/data/lab-prep-review/reviewed-prep.md.
