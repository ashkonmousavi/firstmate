# push - real Claude read-only Gather evaluation

The agent ran in the gate worktree with a marked disposable FM_HOME and the normal existing Claude login.
Hooks and executable/write tools were disabled to confine evaluation to gathering and sequencing recommendations.
The branch case received the complete generated system prompt; other cases used the maintained worktree instructions.
This is instruction-consumption evidence, not deployed-home adoption or fleet dispatch evidence.

## Actual tool calls, in execution order

```jsonl
{"tool": "Glob", "input": {"pattern": "**/*", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd"}}
{"tool": "Grep", "input": {"pattern": "planner|wave|Q bug|bug-list|sequenc", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP", "glob": "*.md", "-i": true}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.agents/skills/push/SKILL.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/backlog.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/projects/Q/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/projects/Q/data/bugs.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/planner/data/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/planner/data/waves/2026-10-05.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/planner/data/waves/2026-10-06.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/config/backlog-backend"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/captain.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/projects.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/secondmates.md"}}
```

## Actual final agent response

I read everything and changed nothing: no scripts, no dispatch, no record edits, no access to any operator home. `/push` isn't an installed command in this session, so I followed the Gather section of the repo's push skill (`.agents/skills/push/SKILL.md`) and only read files.

**Next eligible task: LAB2 (Fix study save loss).**

**Order: LAB2, then LAB1, then LAB3.**

No input is missing. The backlog, the current planner wave and the Q bug list all agree.

**Why**
- **Backlog** (`data/backlog.md`, manual backend):
  - LAB1 is Priority 1 and blocked by LAB2.
  - LAB3 is Priority 2 with no blockers.
  - LAB2 is Priority 3 with no blockers.
  - LAB1 can't start yet, even though its priority is highest.
- **Q bug list** (found through `data/projects.md`, which points to `projects/Q/README.md`, which points to `data/bugs.md`): Q-BUG-91, "Study edits can be lost on save", is a release blocker. LAB2 is its fix. LAB1 has to wait for it, and LAB3 is put off until it's fixed. So LAB3 being unblocked in the backlog doesn't make it eligible.
- **Planner wave** (the registered navigation planner in `data/secondmates.md`, whose index in `planner/data/README.md` names `waves/2026-10-06.md` as current): "fix LAB2 first to unlock LAB1. Then LAB1, then LAB3." It states outright that LAB3 goes after the save-loss fix even though its backlog priority is higher.

**Things to watch**
- The older wave file, `waves/2026-10-05.md`, said "LAB3 first, then LAB1". That order is out of date. Following it would start LAB3 before the release-blocker fix, so it shouldn't be used.
- LAB3's "Blocked-by: none" in the backlog doesn't match the bug list. The record would need correcting (blocked by LAB2) or a note added, but that's an edit to a record, which this pass doesn't allow.
- I didn't check the live fleet (open lanes, PRs, crew state) or any home's lock or wake queue. This recommendation comes only from the records listed above.
