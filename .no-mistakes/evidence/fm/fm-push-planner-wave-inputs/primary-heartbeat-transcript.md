# primary-heartbeat - real Claude read-only Gather evaluation

The agent ran in the gate worktree with a marked disposable FM_HOME and the normal existing Claude login.
Hooks and executable/write tools were disabled to confine evaluation to gathering and sequencing recommendations.
The branch case received the complete generated system prompt; other cases used the maintained worktree instructions.
This is instruction-consumption evidence, not deployed-home adoption or fleet dispatch evidence.

## Actual tool calls, in execution order

```jsonl
{"tool": "Glob", "input": {"pattern": "**/*", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd"}}
{"tool": "Grep", "input": {"pattern": "heartbeat|planner|wave|bug-list|bug list", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP", "glob": "*.md", "-i": true}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/backlog.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/planner/data/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/planner/data/waves/2026-10-06.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/planner/data/waves/2026-10-05.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/projects/Q/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/projects/Q/data/bugs.md"}}
{"tool": "Grep", "input": {"pattern": "(?i)planner|bug list|bugs\\.md", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP", "glob": "!.test-phase/**", "output_mode": "content", "head_limit": 40}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/projects.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/captain.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.j9vqurmd/data/secondmates.md"}}
```

## Actual final agent response

**Run LAB2 next. Order: LAB2 → LAB1 → LAB3.** I found every input the sequencing step needs, so nothing is missing.

**What the records say**

| Source | What it says |
|---|---|
| `data/backlog.md` | LAB1 is priority 1 and blocked by LAB2. LAB2 is priority 3, not blocked. LAB3 is priority 2, not blocked. |
| Planner wave (`planner/data/README.md` points to `waves/2026-10-06.md`) | "Fix LAB2 first to unlock LAB1. Then LAB1, then LAB3." It says LAB3 waits for the study save-loss fix even though its backlog priority is higher. |
| Q bug list (`projects/Q/README.md` points to `data/bugs.md`) | Q-BUG-91, "study edits can be lost on save," blocks release and is being fixed in LAB2. LAB1 must wait for that fix, and LAB3 (the chart expansion) is put off until it's done. |

**Why this order**
1. **LAB2** is the only task with nothing blocking it that the current plan allows to start. It fixes Q-BUG-91, which blocks the release.
2. **LAB1** comes next because it is blocked by LAB2 and has the top priority.
3. **LAB3** goes last. The backlog alone would put LAB3 ahead of LAB2, since it has a higher priority and nothing blocking it. But the current planner wave and Q-BUG-91 both say it waits until the save-loss bug is fixed.

**Older plan I didn't follow:** `waves/2026-10-05.md` said "dispatch LAB3 first, then LAB1." The planner's index marks that wave as replaced, so I ignored it.

I only read files under the given FM_HOME and the tracked instructions in this worktree (`AGENTS.md:297`, `.agents/skills/push/SKILL.md:26-29`). I didn't run any scripts, dispatch anything, change any records, or open any operator home.
