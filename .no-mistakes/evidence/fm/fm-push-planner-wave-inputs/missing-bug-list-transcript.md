# missing-bug-list - real Claude read-only Gather evaluation

The agent ran in the gate worktree with a marked disposable FM_HOME and the normal existing Claude login.
Hooks and executable/write tools were disabled to confine evaluation to gathering and sequencing recommendations.
The branch case received the complete generated system prompt; other cases used the maintained worktree instructions.
This is instruction-consumption evidence, not deployed-home adoption or fleet dispatch evidence.

## Actual tool calls, in execution order

```jsonl
{"tool": "Glob", "input": {"pattern": "**/*", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs"}}
{"tool": "Grep", "input": {"pattern": "planner|wave|bug-list|bug list", "-i": true, "glob": "*.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.agents/skills/push/SKILL.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/data/backlog.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/projects/Q/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/planner/data/README.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/planner/data/waves/2026-10-05.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/planner/data/waves/2026-10-06.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/data/captain.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/data/projects.md"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/config/backlog-backend"}}
{"tool": "Glob", "input": {"pattern": "**/bugs*", "path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase"}}
{"tool": "Read", "input": {"file_path": "/home/tegris/.no-mistakes/worktrees/f0c41e9b5fa0/01M49VVNMKYRSJTX7CEVNAZ8PP/.test-phase/fm-lab.0t3uochs/data/secondmates.md"}}
```

## Actual final agent response

Captain, I can't make a final sequencing decision yet because one required input is missing: the Q bug list.

**What's missing:** Q's project notes (`projects/Q/README.md`) say its current bug list is at `projects/Q/data/bugs.md`. That file doesn't exist, and there's no bug-list file anywhere in this home. The push instructions say I must read the backlog, the latest roadmap wave and the Q bug list before sequencing, so I'm stopping here. Q's owner needs to publish that file.

**Provisional order, pending the bug list:**
1. **LAB2, Fix study save loss.** This is the next eligible task. Nothing blocks it, and LAB1 is waiting on it.
2. **LAB1, Release Q study feature.** It's priority 1, but it's blocked until LAB2 is done.
3. **LAB3, Extend Q chart history.** It's priority 2, but the current wave puts it behind the save-loss fix.

**Where this order comes from:**
- **Backlog** (`data/backlog.md`): LAB1 is priority 1 and blocked by LAB2. LAB2 is priority 3 with no blockers. LAB3 is priority 2 with no blockers.
- **Current roadmap wave** (`planner/data/waves/2026-10-06.md`, the current wave according to `planner/data/README.md`): "fix LAB2 first to unlock LAB1. Then LAB1, then LAB3." It keeps LAB3 behind the save-loss repair even though LAB3 has the higher backlog priority.
- **Old wave** (`waves/2026-10-05.md`, "LAB3 first, then LAB1"): it has been replaced, so I ignored it.
- **Your standing note** (`data/captain.md`): this home is disposable and may only be read. I followed that.

The bug list could still change this order. For example, it might rank the save-loss bug differently or list other Q bugs that should come before LAB3.

This pass was read-only. I didn't run any scripts, dispatch anything, change any records or open any other home. `/push` isn't installed as a command in this session, so I followed the push instructions in the repo (`.agents/skills/push/SKILL.md`) up to the point where sequencing starts.
