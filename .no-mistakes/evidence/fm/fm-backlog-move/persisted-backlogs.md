
### local-peer

```markdown
## In flight

## Queued
- [ ] parent - Parent title (repo: alpha)
  full first paragraph

  ## Intent
  full second paragraph
  prep: data/parent/prep.md
- [ ] child - Child title (repo: alpha) blocked-by: parent - needs evidence (since 2026-10-21)
  child body

## Done
```

### remote-a

```markdown
## In flight

## Queued
- [ ] parent - Parent title (repo: alpha)
  full first paragraph

  ## Intent
  full second paragraph
  prep: data/parent/prep.md
- [ ] child - Child title (repo: alpha) blocked-by: parent - needs evidence (since 2026-10-21)
  child body

- [ ] x - bound to A
  prep: data/x/prep.md
- [ ] stale - Original title
  original body
  prep: data/stale/prep.md
- [ ] origin2 - Independent source
- [ ] blocker - unresolved work
## Done
```

### remote-b

```markdown
## In flight

## Queued
- [ ] y - bound to B

## Done
```

### live-source

```markdown
## In flight

## Queued
- [ ] stale - Original title
  replacement body
## Done
```

### live-source2

```markdown
## In flight

## Queued
## Done
- [x] origin2 - Independent source (done 2026-10-22)
  moved to 127.0.0.1:~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5HC5M6NQ7YQRQ363RXP9QHE/.test-live-backlog/remote-a
```

### live-source3

```markdown
## In flight

## Queued
- [ ] blocker - unresolved work

- [ ] outside - outside dependent blocked-by: blocker (since 2026-10-22)
## Done
```

### legacy-source

```markdown
## Queued
- [ ] unrelated - stays here

## Done
```

### legacy-target

```markdown
## In flight

## Queued
- [ ] legacy-only - only remaining copy
  full body
  prep: data/legacy-only/prep.md

## Done
```
