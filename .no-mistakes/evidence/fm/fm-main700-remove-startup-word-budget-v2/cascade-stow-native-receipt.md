Captain, the stow is finished for the lab primary and its one registered secondmate. It is not reset-safe yet, because one exception is still open (details below).

**Lab primary**
- `data/captain.md`: **rewritten**. I added the missing one-line memory-tier header. The single preference ("never discard unlanded work without explicit authority") is kept as pinned.
- `data/captain-shared.md`: **unchanged**. This home has no such file, and I did not create one.
- `data/learnings.md`: **rewritten** and **pruned**. I added the tier header. The dispatch rule appeared twice, word for word, so I removed one copy and kept the other with its original 2026-10-06 date. I did not refresh that date, because nothing in this session exercised the rule.
- Nothing was archived and nothing was proposed for offload.

**Second mate "archive-secondary"**
I curated it directly from here. It is a local home with no live agent, so no message was sent and no worker was launched.
- `data/captain.md`: **unchanged**. This home has no such file.
- `data/captain-shared.md`: **routed**. The file is owned by the primary and is read-only from this home. I left it byte-identical, which a checksum confirmed. It lacks the memory-tier header, and that has to be fixed by the primary owner.
- `data/learnings.md`: **archived** and **rewritten**. I moved the old secondary-incident entry (last confirmed 2026-01-01, path `/disposable/old-secondary`) to that home's new cold archive, `data/memory-archive.md`, with the reason "unreinforced 278d". Nothing in this session confirmed it. The file now has its header and no entries.

**Other results**
- No findings were filed outside memory; there were none to capture.
- No open work records were filed, corrected, or left alone; none exist in this session.
- **Open exception:** the second mate's shared captain file needs its tier header added by the primary owner. The lab primary has no `data/captain-shared.md` to apply it to, so it stays open. I won't create that file without your say-so.
- **Reset-safe: no.** Every finding and work record is captured, so this exception is the only thing blocking it. Even once it's resolved, reset-safe would only mean nothing this session knew was lost. It would not mean these homes' records are confirmed correct.

No tracked source, outside home, pipeline, worker, or external service was touched.

lanes working: 0 (no workers are recorded in either lab home)