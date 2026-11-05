# Native task lookup and generated brief output

Driven with installed tasks-axi and the target bin/fm-brief.sh, using an isolated markdown backlog. All 76 cases exited successfully and satisfied the author intent oracle.

## b5b-stamped-no-mistakes

Native task show output:

```text
task:
  id: b5b-stamped-no-mistakes
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: ship
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: "```text\nSLICE: ignored/example | Example | role=owner\n```\nSLICE: main/main-model | First chat | role=owner\nRULES: owner\nSCOPE: First chat\nORACLE: brief-slice\nSLICE: ignored/later | Later | role=owner"

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-stamped-no-mistakes/brief.md (ship, mode=no-mistakes; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
```

Generated section before Home brief additions:

```markdown
# Slice
SLICE: main/main-model | First chat | role=owner

# Home brief additions
```

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## b5b-stamped-scout

Native task show output:

```text
task:
  id: b5b-stamped-scout
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: scout
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: "```text\nSLICE: ignored/example | Example | role=owner\n```\nSLICE: main/main-model | First chat | role=owner\nRULES: owner\nSCOPE: First chat\nORACLE: brief-slice\nSLICE: ignored/later | Later | role=owner"

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-stamped-scout/brief.md (scout; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
```

Generated section before Home brief additions:

```markdown
# Slice
SLICE: main/main-model | First chat | role=owner

# Home brief additions
```

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## b5b-missing-no-mistakes

Native task show output:

```text
task:
  id: b5b-missing-no-mistakes
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: ship
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: Firstmate keeps its own intent words here.

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-missing-no-mistakes/brief.md (ship, mode=no-mistakes; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
note: no SLICE line in b5b-missing-no-mistakes's task body
```

Generated brief has no Slice section.

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## b5b-fenced-only-scout

Native task show output:

```text
task:
  id: b5b-fenced-only-scout
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: scout
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: "```text\nSLICE: main/main-model | First chat | role=owner\n```\n~~~markdown\nSLICE: main/main-model | First chat | role=owner\n~~~"

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-fenced-only-scout/brief.md (scout; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
note: no SLICE line in b5b-fenced-only-scout's task body
```

Generated brief has no Slice section.

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## b5b-unclosed-scout

Native task show output:

```text
task:
  id: b5b-unclosed-scout
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: scout
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: "````markdown\n```\nSLICE: main/main-model | First chat | role=owner"

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-unclosed-scout/brief.md (scout; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
note: no SLICE line in b5b-unclosed-scout's task body
```

Generated brief has no Slice section.

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## b5b-wrong-marker-scout

Native task show output:

```text
task:
  id: b5b-wrong-marker-scout
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: scout
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: "~~~markdown\n```\nSLICE: ignored/example | Example | role=owner\n~~~\nSLICE: main/main-model | First chat | role=owner"

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-wrong-marker-scout/brief.md (scout; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
```

Generated section before Home brief additions:

```markdown
# Slice
SLICE: main/main-model | First chat | role=owner

# Home brief additions
```

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## b5b-form-12-scout

Native task show output:

```text
task:
  id: b5b-form-12-scout
  title: Disposable B5b task
  state: queued
  blocked: no
  blocked_by: none
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: scout
  repo: sample
  priority: "-"
  created: 2026-11-04
  closed: "-"
  deps: none
  links: none
  body: "~~~markdown\n```text\nSLICE: ignored/example | Example | role=owner\n~~~\n###### * **SLICE**: main/main-model | First chat | role=owner\nSLICE: ignored/later | Later | role=owner"

```

CLI stdout:

```text
scaffolded: ~/.no-mistakes/worktrees/049a88734b0e/01M6N37SCY6ZV4A7184ZE4DQW8/.test-b5b-tmp/native-backlog/home/data/b5b-form-12-scout/brief.md (scout; replace {TASK} and {FIRSTMATE_SPEC})
```

CLI stderr:

```text
```

Generated section before Home brief additions:

```markdown
# Slice
###### * **SLICE**: main/main-model | First chat | role=owner

# Home brief additions
```

Generated intent remains:

```markdown
## Captain's intent
{TASK}

## Firstmate spec
```

## Before-change reproduction

The baseline CLI at 214912ce94d9e057a6a0b7341535501464afd606, driven against the same native backlog with a literal SLICE declaration, exited 0 and omitted the Slice section. The target emits the section as shown above.
