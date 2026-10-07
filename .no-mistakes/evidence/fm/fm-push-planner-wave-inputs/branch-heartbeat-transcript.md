# branch-heartbeat - real Claude read-only Gather evaluation

The agent ran in the gate worktree with a marked disposable FM_HOME and the normal existing Claude login.
Hooks and executable/write tools were disabled to confine evaluation to gathering and sequencing recommendations.
The branch case received the complete generated system prompt; other cases used the maintained worktree instructions.
This is instruction-consumption evidence, not deployed-home adoption or fleet dispatch evidence.

## Actual tool calls, in execution order

```jsonl
{"tool": "Grep", "input": {"pattern": "Gather|planner|wave|Q bug", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.agents/skills/push/SKILL.md", "output_mode": "content", "-C": 2}}
{"tool": "Glob", "input": {"pattern": "**/*", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/data/backlog.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/planner/data/waves/2026-10-06.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/projects/Q/data/bugs.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/planner/data/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/projects/Q/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/data/captain.md"}}
```

## Actual final agent response

**Next task: LAB2 (fix study save loss). Order: LAB2 → LAB1 → LAB3.** Nothing is missing that would block this decision.

Here's what each record says and how it decides the order:

- **Backlog (`data/backlog.md`)**:
  - LAB1, releasing the Q study feature, is priority 1 and is blocked by LAB2.
  - LAB3, extending Q chart history, is priority 2 with no blockers.
  - LAB2, fixing study save loss, is priority 3 with no blockers.
- **Planner wave**: the planner's index (`planner/data/README.md`) names `waves/2026-10-06.md` as current and the 10-05 file as superseded. The current wave says: "fix LAB2 first to unlock LAB1. Then LAB1, then LAB3," and states that LAB3 waits behind the save-loss repair even though its backlog priority is higher.
- **Q bug list**: Q's README points to `projects/Q/data/bugs.md`. Q-BUG-91 says study edits can be lost on save, marks it as a release blocker tracked by LAB2, says LAB1 must wait for the fix, and defers LAB3 until it lands.

So LAB2 goes first even though its priority number is the lowest. It's the only thing blocking LAB1, and both the planner and the bug list put it first. LAB1 follows as soon as LAB2 lands. LAB3 goes last because the planner and the bug list both defer it, which overrides its priority-2 ranking.

Following your read-only limit, I only read files: I ran no scripts, dispatched nothing, filed no supervision report, and changed no records.
