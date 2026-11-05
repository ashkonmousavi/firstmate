# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, which have no side effects, so they can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

The [endpoint-absence proof](#reclaiming-a-task-whose-endpoint-is-gone) below is the only function here that runs backend reads; sourcing the file is still free.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. An endpoint reading `missing` (or, on Rex, `unreadable`) goes through the shared [absence proof](#reclaiming-a-task-whose-endpoint-is-gone); T3 Code refuses `exit` before reading anything. Proven gone reports `endpoint-gone` (the agent went with it, and the endpoint this verb normally preserves did not survive), a pane that turns out to be there and idle is the ordinary `already-stopped`, one whose agent is back takes the ordinary interrupt-then-exit path. Tmux requires the prior-boot evidence described below; unproven absence refuses. |
| `relaunch` | Replace the agent on the exact recorded adapter or an explicitly chosen harness, model, and effort, reusing its local copy and surviving endpoint or [recreating a released copy](#relaunching-a-released-copy). | The new agent is alive on the endpoint the task's record now names, and that record names the harness that is actually running. |

Automatic callers such as [lane release](../bin/fm-lane-release.sh) use unattended exit to avoid interrupting a running turn; the [`bin/fm-control.sh` header](../bin/fm-control.sh) owns its flags and refusal statuses.
An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
For Claude, both `exit` and the stopping stage of `relaunch` also clean up background sessions for the exact task worktree under the recorded launch account, even when the foreground agent is already stopped or its endpoint is proven gone.
Cleanup verifies that session-owned carried work stops across respawns; a removal failure, surviving process, or surviving session listing fails the verb.
An unreadable session listing instead leaves cleanup explicitly unverified and emits a diagnostic; foreground exit success alone therefore does not prove background work stopped.
[`bin/fm-control.sh`](../bin/fm-control.sh) owns the output fields and account fallback for older records, and [`bin/fm-claude-bg-stop.py`](../bin/fm-claude-bg-stop.py) owns process ownership and termination checks.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
On T3 Code the backend's native interrupt is the acknowledgement: T3's own run wait decides `cancel=confirmed`, `not-running`, or `unconfirmed` for every harness.
Devin emits no lifecycle hook for cancellation either, so after an armed interrupt the control plane invalidates the interrupted turn's busy record to `unknown` with `cancel=unconfirmed`; that invalidation is a conservative loss of knowledge, never a fabricated idle.
Cortex Code is the exception to both: its `Stop` hook fires on an Escape interrupt, so one Escape cancels the turn and the hook closes the busy record itself, with no invalidation and no arming gate; an Escape on an idle Cortex composer does nothing.
Devin's double Escape also opens its `/revert` picker on an idle agent, where Enter reverts file changes, so its second press is sent only after the first renders a running turn's armed hint and never sooner than the adapter's press gap.
An interrupt whose first press shows no running turn stops there and reports `cancel=not-running`, leaving busy state untouched; a picker a mistimed press opened is closed with one Escape and reported as `revert-picker=dismissed`, and `exit` refuses to type into an open picker.
Command Code cancels a running turn on one Escape and its own busy mod records the cancelled run idle, while two quick Escapes on an idle agent open its Rewind checkpoint picker, where Enter restores a checkpoint; it therefore gets exactly one press, and the same picker dismissal and `exit` refusal apply.
[`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh) owns the arm signal, press gap, and picker signal.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

On pane backends, interrupt also applies any adapter-required composer clear.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

Before delivering an interrupt or typing an exit command, the control plane attempts to clear this task's own unsubmitted steering-inbox doorbell where the backend supports Ctrl+E and Ctrl+U.
Ownership requires a whitespace-normalized match to the doorbell built by `fm_task_inbox_doorbell_line`, or a visible wrapped prefix reaching through the task's quoted inbox name and the following `steering inbox,` text; [`fm_task_inbox_composer_holds_own`](../bin/fm-task-inbox-lib.sh) owns that check.
Another task's doorbell, an arbitrary draft, or additional nonmatching typed text does not qualify for this clear.
Clearing never submits the doorbell or acknowledges its unread inbox records, and a clear that does not read back empty refuses the lifecycle action before further input.
An unrecognized or unreadable draft skips this ownership-based clear; interrupt retains its adapter sequence, while exit retains the composer gate below.

A visible Claude background shell makes `exit` and `relaunch` return status 75 with `busy: background shell running`; retry after the shell finishes.
[`fm_control_background_shell_running`](../bin/fm-control-lib.sh) accepts either a positive shell status count or the background-shell exit dialog, including versions that render another composer below it.
The check runs before lifecycle input and before picker confirmation, so unfinished background delivery is preserved even for landed work.
For a typed exit, `exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict, including after clearing an own doorbell; any other `pending` draft refuses by naming the pending text, and any other verdict (`unknown`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.
`exit` also refuses, naming the dialog as `blocked on a prompt`, when the screen shows a recognised dialog that a further Enter would answer, whether the dialog was open before the exit command was typed or the submitting Enter opened it; it sends no Escape and chooses no option, so closing the dialog is left to the operator.
The one exception is Claude's background-task exit picker without a visible shell, authorized by backlog Done, an unattended lane release after its validated [release classification](../bin/fm-lane-release.sh), or an explicit `exit --landed-work` after the caller verifies landing.
It sends one confirming Enter to choose the selected `Exit and stop tasks` row and reports the stop only once the agent is dead; the task's local copy and pull request are kept.
Before confirmation, including a compatible Herdr client retry, the backend re-reads the live picker; unattended lane release also rechecks the spawn generation and idle busy-state sequence.
Herdr returns its viewport to the bottom before that read so scrolled history cannot authorize confirmation.
A secondmate, a task without any of those authorizations, and a picker already open when an unattended lane-release exit starts still refuse.
A stopped agent whose pane still shows the dialog text is not refused.
[`fm_composer_blocking_dialog`](../bin/fm-composer-lib.sh) owns the recognised set, which today is only Claude's background-task exit picker; [its verification record](verification/runtime-backends.md#claude-background-task-exit-picker) lists the dialogs that are not covered.
T3 Code has no composer and its `/mcp` tools offer no session stop, so `exit` refuses there before sending anything ([`t3code-backend.md`](t3code-backend.md#current-lifecycle-and-safety)).

**Teardown and discard are not verbs and will not become verbs.**
`exit` preserves the endpoint, worktree, uncommitted changes, and conversation transcripts while stopping the agent and cleaning up its retained Claude background sessions.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex, grok, gemini, devin, commandcode, cortex, and kiro resume only from a session id printed at exit (kiro also has a cwd-scoped `--resume`, and its sessions live under the per-task `KIRO_HOME`), polytoken resumes only from a session id held in its own sessions registry, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, omp, kimi, and agy have no verified general pane-resume contract.
`relaunch` uses the brief on disk - not a harness-private session - as the durable instruction when the backend can prove the old agent stopped and the composer is empty; Devin on Herdr currently fails that composer check and refuses.
T3 Code cannot host a fresh replacement agent in a thread, so `relaunch` refuses before stopping anything.
A relaunch does take one session reference when the endpoint's own runtime recorded it - see [the relaunch transaction](#transactional-relaunch) - but that is a relaunch input, not a caller-facing verb.

For release while deployment or acceptance proof remains pending, follow [ship-landing](../.agents/skills/ship-landing/SKILL.md#resource-release-and-accepted-completion).

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.
The following sequence applies to an existing copy; a [released copy](#relaunching-a-released-copy) follows its own checkpoint, allocation, note and rollback ordering.
For a secondmate, relaunch first honors the [owner-park contract](configuration.md#owner-park).

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Without an explicit harness, a `kind=secondmate` task re-resolves its [configured runtime pin for that mate](configuration.md#choose-the-secondmate-harness) before the checkpoint.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
   A Claude or Pi replacement must also pass the home's [worker account pin](configuration.md#worker-account-pin-configclaude-account-configpi-account), or a secondmate's own [per-secondmate account pin](configuration.md#per-secondmate-account-pins) when one is set, so a pin that no longer resolves or is signed out refuses before the old agent stops.
   An omp secondmate replacement likewise passes its [per-secondmate omp profile](configuration.md#per-secondmate-omp-profile) file check before the old agent stops.
   Ship and scout replacements also pass the [worker tool exclusion checks](configuration.md#worker-tool-exclusions-configcrew-exclude-tools) at this step.
   An explicit `--harness` also passes the [explicit-harness quota gate](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) here; that contract owns home-level admission policy and per-launch overrides.
   A Codex replacement, a secondmate's included, resolves its [account folder and model](configuration.md#codex-account-folders-configcodex-accounts) in the recorded worktree here, so no usable folder refuses before the old agent stops.
2. **Safe checkpoint and launch admission.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
   Then the replacement's deterministic launch admission runs through the functions `bin/fm-spawn.sh` itself uses (`bin/fm-spawn-admission-lib.sh` and the watcher-continuity admission), in this order:
   - watcher continuity, the backend, the launch environment, and launch configuration such as permission and approval modes;
   - a ship task's recorded branch name;
   - adapter and executable checks, including the Kimi turn-end hook configuration;
   - for a secondmate, its home's shape and its registry binding;
   - the per-task launch files, each through its owner's check mode: Claude workspace trust (in the store of the selected [worker account](configuration.md#worker-account-pin-configclaude-account-configpi-account)), the Claude operational-inbox path, the Devin config and the Polytoken config mirror;
   - the backlog row, one capacity read, and a pending authoritative backlog close;
   - for a ship or scout, the instructions, then the instructions with the pending progress note appended to a scratch copy, including the Herdr lifecycle guard.
   A refusal caused only by the pending note names the real instructions file and says the note caused it.
   Any refusal here leaves the old agent running and the task unchanged.
   Runtime failures after the stop are not part of this check; a secondmate's home synchronization and configuration inheritance run after it, at launch.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which reuses the recorded worktree instead of creating one, adopts the recorded endpoint when it still exists, clears the previous harness's per-task wiring, and arms a fresh busy generation.
   When the recorded endpoint is proven gone rather than merely idle or unreachable, the launch owner creates one fresh endpoint in that same worktree and the republished record rebinds the task to it - see [Reclaiming a task whose endpoint is gone](#reclaiming-a-task-whose-endpoint-is-gone).
6. **Preserve runtime-bound status authority where supported.**
   The endpoint's runtime may bind pane status to one session identity; the launch owner preserves it only when that runtime records a reference the replacement adapter can consume, and otherwise launches the ordinary fresh session.
   This reference is a launch input, never authority to send, close, or act on the pane.
   [`docs/herdr-backend.md`](herdr-backend.md#agent-status-authority-and-relaunch) owns the mechanism and measured behavior.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Reclaiming a task whose endpoint is gone

A reboot can destroy tmux endpoints; Herdr panes or workspaces, or a Rex block, can also disappear during churn, a session restart, or a stopped Rex server.
The task's worktree, branch, commits, and uncommitted changes all survive that; only its terminal does not.

Reclaim uses the shared absence proof in `bin/fm-control-lib.sh` for Herdr, Rex, and tmux.
A missing endpoint without that proof still refuses.

Two endpoint verdicts are agent-free, and both license a relaunch:

- `dead` - the endpoint exists and confidently holds no agent. It is **adopted**, so the task keeps its exact recorded address.
- gone, **proven** - there is no endpoint and therefore no agent, and it cannot be adopted, so the launch owner **creates one fresh endpoint in the recorded worktree** and the republished record rebinds the task to it.

That proof is its own step for pane backends because their classifier's `missing` can conflate *the endpoint was destroyed* with *the endpoint is unreachable from here right now*.
An unreachable endpoint can still hold the live agent a rebind would duplicate, so absence is proven and never inferred from a failed read - and whether it is provable at all is a property of the backend:

- **Herdr can prove it.** Every read goes through the adapter's `--session <session>` CLI, so the recheck starts and reads the session the *record* names, through that session's own socket.
  It starts that server (only the server: no workspace and no tab are created) and **re-reads the recorded pane**.
  `dead` means the pane survived the restart and is adopted after all, with no second tab; `alive` means the agent came back and refuses; only a second `missing` proves the pane itself did not survive ([`docs/herdr-backend.md`](herdr-backend.md) "Restart and liveness behavior").
  That server start is a real side effect, and the parenthetical above does not cover it: when the recorded session's server no longer exists at all, the probe stands a fresh empty one up in order to ask, and nothing afterwards uses it.
  So in that state `exit` - which otherwise reads as a read-only inspection - leaves an idle herdr server behind.
- **Rex can prove it.** Rex never reuses a session, window, or block id, so a structured not-found for the recorded block from the server the task was created on proves the block is gone.
  The record carries that server's endpoint (`rex_server=`), and the recheck refuses unless the server this process reaches reports the same endpoint; it normally lets the CLI start a stopped personal server before checking the block.
  [Remote second-mate readiness](remote-secondmates.md#repair-with---fix) owns the exception that prevents this autostart for remote control.
  [Rex's server-stop limits](rex-backend.md#active-limits) distinguish a restored shell from a missing block.
  A block that is still there is classified from its process view, so `dead` is adopted and `alive` refuses ([`docs/rex-backend.md`](rex-backend.md) "Cleanup and the absence proof").
  Rex's passive reads never start a server, so a stopped Rex server reads `unreadable` rather than `missing`; a Rex `unreadable` therefore goes through this recheck too, and still refuses unless the recheck settles it.
- **Tmux requires reboot evidence.** The existing `spawn_gen` timestamp must predate the current OS boot, and the endpoint is rechecked before declaring it gone.
  The old process cannot survive that reboot even on another socket.
  Missing, malformed, or current-boot generations remain unproven; a server inventory alone cannot distinguish destruction from a different socket.
  Reclaim creates the replacement in the recorded tmux session and existing worktree.
- **T3 Code refuses `exit` before this proof.** Its [native status table](t3code-backend.md#restart-and-liveness-behavior) owns absence and unreadability, including an archived thread whose active run is still draining.
  T3 Code still cannot reclaim the task because a thread keeps its conversation, so no fresh agent can replace it and `relaunch` refuses before this proof can authorize a replacement.

Every transient or self-contradicting read stays `unreadable` or `ambiguous` and still refuses, so a momentary backend failure can never be mistaken for absence.

That proof has one owner for the whole control plane (`fm_control_endpoint_absence_verdict` in `bin/fm-control-lib.sh`), so `exit` and `relaunch` cannot reach two different answers about one endpoint.
`exit` reports what the proof established and nothing more - see its row in the verb table above.

What a reclaim is not:

- It is **not a teardown**. The worktree is reused exactly as the previous agent left it; nothing unlanded is ever discarded, and the ordinary `--note` requirement still applies.
- It does **not** change the task's identity. The task id, its armed poll and registration, and its status log are untouched; only the endpoint binding in the record moves.
  Its instructions are the one exception, and only in the way an ordinary relaunch already changes them: a ship or scout reclaim appends the required `--note` under a `## Progress note (<timestamp>)` heading in `data/<id>/brief.md`, so re-read that brief rather than assuming it is byte-identical - a reclaim that failed and was retried leaves one block per attempt.
  A secondmate's standing charter is never rewritten.
- It is **not** a peer seat's operation. `fm-control` resolves an exact task id against **this** home's `state/`, so only the home that owns the task can reclaim it.
- It does **not** cover a secondmate. A secondmate whose endpoint is gone already has one recovery path - `bin/fm-spawn.sh <id> --secondmate`, driven by the session-start sweep or the watcher's liveness tick - so control-plane reclaim refuses and names it rather than becoming a second path to the same outcome.

A Rex reclaim opens the new tab in the exact Rex session the record names, focus-safe, and falls back to the ordinary placement only when that session is itself gone.
A bare-shell tab left behind by an earlier reclaim that refused before the record was republished carries the same block label, and the next Rex reclaim closes it before opening the new tab, whether that tab lands in the recorded session or the fallback placement; a non-shell program in such a tab refuses the reclaim instead.

The re-created tab is opened in the herdr session the record names, never in whichever session the recovering seat happens to sit in - relocating a task onto another herdr server would be an identity change published as a self-consistent but wrong record.
A seat that *claims* a herdr launcher pane belonging to a different session is refused rather than allowed to place the endpoint somewhere else, so reclaim such a task from a seat in the recorded session.
A seat with no herdr launcher pane at all - a plain ssh or cron shell, which is the ordinary way an operator reclaims - is not refused: placement falls back to the recorded session's labeled container, so the tab still lands in the session the record names.
The reclaim pins the recorded **session** but not the **workspace**: the container follows the reclaiming seat, so a reclaim run from a seat inside the recorded session places the new tab in *that seat's* workspace rather than the recorded `herdr_workspace_id`, even when the recorded workspace still exists and only the pane was destroyed.
The record is republished consistently and no work is lost, but the task's `herdr_workspace_id` moves with it.
The pane id necessarily changes (the pane did not survive), and the record follows it.
A Herdr reclaim deliberately uses the flat container shape rather than presentation projection: projection is a presentation-only layout that is never endpoint or ownership authority, and flat is already the documented fallback for every recovery it cannot bind exactly ([`docs/herdr-backend.md`](herdr-backend.md)).

**Known Herdr limitation - a refusal before the record is republished leaves a stray husk pane** (follow-up bead `fm-herdr-rebind-leak-20260913`).
The rebind registers no abort cleanup, so a refusal in the window between the new tab being created and the record being republished leaves that pane behind while the record still names the old, gone one.
The stray pane holds a bare shell - the harness is not delivered until after publication - so the next reclaim cleans up after it: the re-created tab carries the same `fm-<id>` label, `tab create` finds it, classifies it a husk, and closes and replaces it.
That self-heals only when the retry resolves the *same* workspace, which the placement rule above does not guarantee.
The worktree and the task's records are unaffected either way.

### Relaunching a released copy

`bin/fm-teardown.sh` can free the local copy of a ship whose pull request is still open under the release rule in its header.
Release requires a configured non-gate remote whose URL matches the PR head repository and a readable head-branch identity; `no-mistakes` and `publicsrc` never qualify.
A fork published with only no-mistakes `--fork-url`, while `origin` points to the parent, needs a configured fork remote before release.
Unreadable head identity, including the state-only `gh-axi` fallback, refuses release and keeps the copy.
A reported forge-head mismatch always refuses, even when a freshly fetched tracking ref matches local HEAD; tracking proof is used only when the head identity is readable but the forge reports no head commit.
The `released_head=`, `released_branch=` and `released_pr=` proof is persisted before returning the copy and survives failed endpoint closure and retries.
Only after endpoint closure is confirmed does the kept record name `worktree=<state>/<id>.released-copy`.
A relaunch of such a record recreates the copy instead of reusing one.

- **Checkpoint.** `fm-control` runs a released checkpoint in place of the worktree checkpoint, with no git read of the sentinel: the task is a ship with its project and released head, branch and pull request recorded, its endpoint is missing, and the pull request reads OPEN through `bin/fm-pr-lib.sh`.
  A merged pull request refuses because the task needs cleanup, a closed one because relaunching it needs a captain decision, and an unreadable one asks for a later retry.
- **Endpoint.** Teardown writes the sentinel only after it closed and confirmed the endpoint, so for this record alone a tmux endpoint that reads `missing` is gone without the reboot evidence above; Herdr keeps its ordinary absence proof.
  A window or pane that still exists refuses with "close that window first", and an alive, unreadable or ambiguous endpoint refuses as always.
  Only tmux and herdr recreate a released copy; Orca, cmux and zellij refuse by name.
- **Admission and allocation.** `fm-spawn --relaunch` opens the new endpoint in the project and allocates the copy through the fresh path's `treehouse get`, isolation check and slot claim, under the same machine-lane admission, project capacity admission and Treehouse project lock a fresh worker takes.
  No free machine lane, a full project, a held project lock or an exhausted copy pool defers with exit 75 and preserves the brief, journal and task record.
  The backlog item teardown held "awaiting merge <pull request>" (kind external) is accepted, and that exact hold is lifted at the launch commit point so the item goes back In flight only once the worker is launched; any other hold, including a captain hold, refuses as before.
- **Branch.** The branch is fetched from the configured non-gate remote matching the PR head repository and must contain the released head; a tip that moved on is accepted only as a descendant of that head and, when the forge reports a head, only when it is that head.
  The copy is checked out on the branch itself, tracking that remote, and must be clean.
- **Note and record.** Only after that does `fm-spawn` append the progress note, which says the copy was recreated from the branch at the commit actually checked out and that uncommitted files, ignored files and a no-mistakes run's local state were not carried over.
  A path-keyed session resume is not attempted, so the worker continues from its brief and that note.
  `fm-spawn` alone republishes the record, naming the new copy and dropping the released fields.
- **Failure.** Rollback remains active through launch delivery and dispatch commit, including HUP and TERM.
  It confirms closure of the endpoint it opened before restoring the released record.
  It returns a copy only when it is clean, including ignored files, and has no commits beyond the recreated head once launch delivery was attempted.
  A complete rollback restores the brief and released record and leaves the journal and prior-record copy untouched, so a retry adds no second note.
  A failed brief or record restoration retains that snapshot and reports its path for recovery.
  If endpoint absence or safe return cannot be proven, it keeps the copy, branch, claim and current record and reports their location; it does not force-return the copy or hide it behind the sentinel.

### Failure and rollback

The following applies to relaunches that reuse an existing copy; released-copy rollback is owned by the section above.

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped is reported as a `commit-phase failure`, restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch`, drive the host through [`bin/fm-remote-secondmate-relaunch.sh`](../bin/fm-remote-secondmate-relaunch.sh), which runs `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...` and then republishes this home's route record from the identity the host confirmed; the host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` and `exit` have no such route.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
  T3 Code has no composer, so Escape and Ctrl+C are both a turn interrupt and Ctrl+U is refused.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux, herdr, rex, and t3code - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, cmux, and paseo are refused rather than reported as successful blind.
- On t3code, `exit` refuses before anything is sent: a T3 thread has no composer for a typed exit command, and T3's `/mcp` tools offer no session stop.
- `relaunch` additionally requires a backend that can host a replacement agent - tmux, herdr, and rex.
  t3code is refused before anything is stopped: a T3 thread keeps its conversation, so a new turn or a provider change on it continues the same agent rather than launching a fresh one.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts; a Rex `unreadable` acts only once the absence proof above settles it.
- `exit`'s composer-empty check, above, is itself a fail-closed boundary that `relaunch` inherits by stopping the old agent through `exit`.
- `fm-spawn --relaunch` independently requires an agent-free endpoint under the applicable [existing-copy](#reclaiming-a-task-whose-endpoint-is-gone) or [released-copy](#relaunching-a-released-copy) proof, so a replacement can never join a live agent.
  An `alive`, `ambiguous`, or `unreadable` verdict all refuse (a Rex `unreadable` after the absence proof cannot settle it), and so does any endpoint whose absence is not provable; absence is claimed only from positive evidence of it.
  It also requires the shell to be in the selected worktree, whether reused or recreated: every backend but Orca (which owns its own task worktree with no current-path probe) gets one explicit `cd` to that path, then a pre-launch path read that refuses before any harness starts unless it confirms the endpoint is sitting in that copy.

## Capability matrix

Backend key support and recovery-grade agent-state capabilities come from each adapter's real surface and are defined by `fm_control_backend_supports_key` and `fm_control_backend_state_verified` in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh).
Replacing the agent through `relaunch` is supported on tmux, Herdr, and Rex; T3 Code keeps its thread, so it never takes a replacement agent.

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`, with adapters outside its lane pinning their control mechanics in their own harness suites.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for its verified-harness lane (adapters outside the lane pin their control mechanics in their own harness suites), the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and the endpoint-absence proof both verbs share - Herdr reclaim, tmux reboot recovery, and refusal when absence remains unproven - plus the recreation of a released copy and its refusals.
  Startup cases also exercise eligibility rechecks under the lifecycle lock, attributed run ownership, the prevalidation handoff, and capacity through the real control and spawn paths with a stubbed backend.
- `tests/fm-crew-recovery.test.sh` - the startup sweep's home scoping, worktree evidence, serial failure and deferral handling, and deferred-bootstrap composition.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-backend-rex.test.sh` and `tests/fm-backend-rex-smoke.test.sh` - the Rex classifier and absence proof against a stateful fake CLI and a private test server; [`docs/verification/runtime-backends.md`](verification/runtime-backends.md#rex) records the live `interrupt`, `exit`, endpoint-gone, and reclaim runs.
- `tests/fm-backend-t3code.test.sh` - the t3code exit and relaunch refusals and the native interrupt against a fake T3 server.

[Lifecycle clearing verification](verification/runtime-backends.md#lifecycle-clearing) records the own-doorbell regressions, live guards, dated harness results, and coverage limits.
