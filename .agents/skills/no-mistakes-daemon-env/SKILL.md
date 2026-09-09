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

## Two different subprocess shapes inside one run

A pipeline run can execute commands through two different mechanisms, and they do **not** end up
with the same environment even though both ultimately descend from the daemon process:

- A configured `commands.*` step (`sctx.Config.Commands.Test` etc., `internal/pipeline/steps/test.go:102`)
  runs via `runStepShellCommand` -> `runShellCommandWithProcessEnv`, which execs a **non-login**
  `sh -c '<cmd>'` (`internal/pipeline/steps/common_exec.go:316`) with `stepEnvironment(sctx)` as its
  env - nil in production, so it inherits the daemon's own cached, one-time-merged `os.Environ()`
  described above (minimal: no `uv`, no project python, on this host).
- A coding-agent subprocess (Claude/Codex/etc.) is spawned with the same kind of minimal daemon-derived
  environment (`gitSafeEnvWithOverlay`, `base := overlay.Apply(nil)` at `internal/agent/env.go:57`, again
  `nil` base -> the daemon's `os.Environ()`). But when that agent's own tool-use loop decides to run a
  shell command, the agent CLI itself (not no-mistakes code) wraps it as `bash -lc '<cmd>'` (see the
  `bash -lc` wrapper literals in `internal/agent/codex_metrics_test.go` and the unwrap comment at
  `internal/agent/invocationmetrics.go:140`). That `-l` makes it a **fresh, live** login shell at the
  moment the agent runs it - it re-sources `~/.profile`/`~/.bashrc` right then, independent of and richer
  than the daemon's own cached startup snapshot (this is the "worker-shell shape": everything currently
  in the interactive login environment, `uv` included).

Consequence: a variable placed only in `~/.profile` reaches the agent-tool-call path immediately (every
fresh `bash -lc` re-reads it) but reaches the `commands.*` path only after the **daemon itself** is
restarted (its login-shell probe is cached once per process lifetime, `internal/shellenv/shellenv.go:54-76`).
A variable placed on the daemon's own process environment (systemd unit `Environment=`, or a drop-in)
reaches both paths as soon as the daemon (re)starts with it, because both paths' subprocess trees inherit
from that one process's environment - the agent's `bash -lc` re-sourcing adds to what it inherited, it
does not clear it first.

## Drop-in survives the managed-unit refresh

`daemon start`'s managed-unit refresh (`installSystemdUserService`, `internal/daemon/service_systemd.go:13`)
only ever writes the main unit file (`writeServiceFile` at `:28`) and reloads it (`:31`); nothing in that
function or elsewhere in `internal/daemon/service_systemd.go` reads, writes, or removes a `<unit>.d/`
drop-in directory. A drop-in placed there is untouched by any no-mistakes install/refresh path and is
picked up by systemd's own `daemon-reload` like any other drop-in.

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

Prefer a systemd drop-in (`Environment=` line under the unit's `.d/` directory, see above) over a
`~/.profile` export: the drop-in reaches every pipeline execution path (`commands.*` and agent tool
calls) as soon as the daemon restarts with it, while a `~/.profile`-only export reaches agent tool
calls immediately but leaves `commands.*` steps unfixed until the daemon itself is separately
restarted. Never edit `~/.bashrc` - it is off-limits to automated edits; if a profile-level export is
chosen anyway, `~/.profile` already carries a precedent one-liner for exactly this at `~/.profile:37`.

Never assume the client (`axi run`) can inject a step-scoped environment variable in production - the
`StepContext.Env` field (`internal/pipeline/pipeline.go:53`) it would need is documented in source as
"used in tests" only, and nothing in the IPC layer carries a client environment to the daemon.
