Live lock takeover verification

Replay from the gate worktree:

    ROOT="$PWD" python3 ~/.no-mistakes/evidence/01M69PNP07GVT0C49316P6573T/live-lock-driver.py

The driver refuses an existing `l` directory, mints a marked disposable home through fm-lab-home, runs real installed Claude CLIs with the existing login in an isolated profile, and uses a private fm-lab tmux socket with a 160x44 grid. It copies the worktree scripts unchanged except a wrapper that ends the simulated idle clock before executing the real watcher. All fixture files remain inside the worktree and are removed after the owned processes exit.

Independent oracle: the author intent and recorded R11 decision require recent-turn refusal, acceptance of the retained prior session after A-to-empty-B clear, unrelated-fork refusal, exactly one holder through repeated switches, and one queued holder ask after 15 minutes of watcher silence. Assertions reject a stolen recent/unrelated lock, an unknown or mixed pid/session pair during handover, multiple ownership verdicts, missing handover records, failure to run the real watcher, or duplicate inbox notes.

Qualifications:

- The phone topology is a real local no-TTY `claude -p --fork-session --resume` process, followed by a real TTY-bearing return process. Actual phone/network transport is outside this lock-change proof.
- The native `/clear` transition and its A/B ids are real. The driver makes B's vendor-reported transcript path readable and empty if it does not exist yet; the accepted predicate requires readable holder histories.
- The quiet-period classifier clock advances 3600 seconds; original vendor user/assistant turn records are unmodified. The backstop is exercised with beacon mtimes aged to 600 and 901 seconds. This verifies threshold behavior without a 30-minute wall-clock wait.
- Both startup and real Stop refuse a recent predecessor. The accelerated Stop then takes ownership and runs the actual watcher, whose actionable output and exit-2 outcome are captured. The wrapper returns zero to Claude after capturing the result: unsolicited asyncRewake feedback delivery is outside this changed acquisition-path proof.
- Concurrent coherent ownership reads span both handovers. All five still-live Claude processes then execute their own ownership checks; only the final return process authorizes. Supplementary targeted regressions deliberately pause split publication and interrupt takeover phases, exercise lease restoration and new-turn revalidation, and hold a sweep for more than five seconds.
- There is no rendered UI change. Product evidence is CLI output, persisted handover records, coherent holder observations, ownership verdicts, and the actual queued inbox note.

Early driver attempts exposed two setup issues (wrong inbox extension and teardown before the terminal process completed its exit). They changed no product source. The final run waits for every launched CLI, the observation child, the lab watcher, and the private tmux server to stop before removing the lab.
