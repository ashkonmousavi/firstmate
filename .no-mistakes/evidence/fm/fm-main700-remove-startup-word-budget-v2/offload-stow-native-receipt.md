Captain, the stow is finished for the lab primary and its one registered second mate. The session is **not** safe to reset yet, because one ownership issue is still open (explained below).

lanes working: 0. This lab home has no task workers recorded, and none were launched.

**Lab primary**
- `data/captain.md`: **rewritten**. I added the one-line tier pointer. Its single rule ("never discard unlanded work") is unmarked, so it stays pinned and unchanged.
- `data/captain-shared.md`: **unchanged**. This home doesn't have one.
- `data/learnings.md`: **rewritten** and **pruned**.
  - I added the tier pointer.
  - The dispatch rule ("resolve the registered home before selecting its transport") stays as it is. It is already dated today and applies fleet-wide.
  - I moved the LAB-CALIBRATION batch-trace entry into `data/lab-calibration.md`, which already owns that trigger. That note is private and git-ignored. Before removing the entry from memory, I checked that the note holds all three checks: preserve the batch id, compare the sampling interval with the trace header, and inspect the recorded sequence. I dropped the entry's sentences about where it should be stored, since the move itself carries them out.
- The primary archive was not needed. No pinned entry was a candidate for a move, so nothing needs your approval.

**Second mate (archive-secondary)**
- No agent was running there, so I curated this local home directly.
- `data/captain.md`: **unchanged**. It doesn't exist there.
- `data/learnings.md`: **rewritten** and **archived**.
  - I added the tier pointer.
  - The "finished secondary incident / old-secondary path" entry was last confirmed on 2026-01-01. Nothing in this session confirms it, so it went to that home's new `data/memory-archive.md` with the reason "unreinforced 278d".
- `data/captain-shared.md`: **routed**. This file belongs to the primary, so I left it byte-identical (I checked its checksum before and after).

**Open issue (why the session isn't reset-safe)**
- The second mate's shared captain-preference file has no tier pointer.
- Only the primary owner can add it. This lab primary has no `data/captain-shared.md` to curate it from, so the issue is still open.

**Other results**
- No findings were filed outside memory. The session had no uncaptured findings.
- No open work records were filed or corrected, because none exist.

I didn't touch tracked source or any home outside the two lab homes. I didn't launch any workers or pipelines, and I didn't contact any external service. Reset-safe would mean nothing this session knew has been lost; it would not mean the home's records are correct.