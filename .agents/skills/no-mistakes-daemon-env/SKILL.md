---
name: no-mistakes-daemon-env
description: >-
  Agent-only reference for how the no-mistakes daemon's process environment is composed.
  Use before debugging why a pipeline step command sees (or is missing) a PATH entry, a tool, or a
  custom environment variable, and before proposing a systemd-unit or dotfile change to fix it.
user-invocable: false
metadata:
  internal: true
---

# no-mistakes-daemon-env

## The mechanism

A pipeline step's subprocess environment is the no-mistakes daemon's own live process
environment (`os.Environ()` at the moment the daemon forks the step), not the client
process that ran `no-mistakes axi run` - no environment is transported over the daemon's
IPC connection (`internal/ipc/*.go` has no `Env` field on any request).

The daemon's live environment is composed in two layers, applied at daemon startup only,
inside the daemon process itself:

1. The systemd user unit's `Environment=` lines (`~/.config/systemd/user/no-mistakes-daemon-*.service`)
   set the process's environment at `execve`. This baseline is minimal (`HOME`, a short `PATH`)
   and is what a static `/proc/<daemon-pid>/environ` read shows - forever, because `/proc/<pid>/environ`
   is a snapshot taken at `execve` and is never updated by a later in-process `setenv()` call.
2. `prepareDaemonEnvironment` (`internal/daemon/daemon.go:109`, called at `internal/daemon/daemon.go:81`)
   calls `applyShellEnvToProcess` (`internal/daemon/daemon.go:42,122`), which resolves a one-time login-shell
   probe (`internal/shellenv/shellenv.go:54` `Resolve`, `:79` `ApplyToProcess`, `:103` `resolveUncached`,
   running `$SHELL -l -i -c "env -0"` at `:109-111`) and calls `os.Setenv` for every key it returns
   (`internal/shellenv/shellenv.go:79-96`). This **overwrites** the unit's value for any key the login
   shell also sets (PATH included) and **adds** any key the unit never set; it never removes a unit-only
   key. The result is cached for the daemon process's lifetime.

So: for any key already exported by the login shell's startup files, the login shell's value wins over
the unit. For a key the login shell never sets, whatever the unit provided (or nothing) survives untouched.

On this host `$SHELL` is bash with no `~/.bash_profile`, so the `-l` login-shell probe reads `~/.profile`,
which unconditionally sources `~/.bashrc` (`~/.profile:13-15`) - that's where PATH entries like
`/home/linuxbrew/.linuxbrew/bin` (`~/.bashrc:70`) and `~/.local/share/whisper-venv/bin` (`~/.bashrc:351`)
come from, and why they show up in every step subprocess even though the unit's own `Environment=` never
mentions them.

## Diagnosing what a step actually saw

Do **not** trust `/proc/<daemon-pid>/environ` for anything set after startup - it is frozen at `execve`.
Instead read the daemon's own post-merge snapshot, logged once per startup by `logDaemonPathSummary`
(`internal/daemon/daemon.go:139`, called right after the merge):

```
grep '"daemon environment ready"' ~/.no-mistakes/logs/daemon.log | tail -1
```

Cross-check the `pid=` on the neighboring `"daemon process launched"` line against the live daemon pid
(`pgrep -af 'no-mistakes daemon run'`) to confirm which startup the entry belongs to.

## Adding a durable variable

A new key (one the login shell does not already export) can be set durably at either layer without
conflict, because the merge only overwrites keys the login shell defines:
- a systemd drop-in / `Environment=` line on the unit, verified to survive the `daemon start`
  managed-unit refresh, or
- an export in `~/.profile` (not `~/.bashrc` - that file is off-limits to automated edits; `~/.profile`
  already carries a precedent one-liner for exactly this, `~/.profile:37`), which becomes part of the
  login-shell probe's resolved set and gets merged in the same way.

Never assume the client (`axi run`) can inject a step-scoped environment variable in production - the
`StepContext.Env` field (`internal/pipeline/pipeline.go:53`) it would need is documented in source as
"used in tests" only, and nothing in the IPC layer carries a client environment to the daemon.
