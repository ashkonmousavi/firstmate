# Quota gate live validation

Oracle: the accepted intent and later minimal-scope decisions. Explicit launches
refuse exhausted quota and projected exhaustion less than three hours away;
recommendations use the greatest configured eligible spendPriority. Only an
explicit override may proceed and persist the reason and refusal evidence.
Implicit/recovery launches remain exempt. No native alias/default resolution is
required by the accepted reduced scope.

The real `fm-spawn.sh` and `fm-control.sh`, tmux, Treehouse, and Grok binaries ran
against disposable marked homes under `.q/`, with a private 120-column by 40-row
tmux server (`TMUX_TMPDIR=$PWD/.q/t tmux -L fm-lab`). Every lifecycle command used
the stock lab marker and no gate bypass. Quota snapshots are disposable external
input data; no Firstmate, terminal, or harness implementation was replaced in
these live checks. Grok reached its real startup authentication screen. No
sign-in was approved and no model inference is claimed or needed by the quota
startup/metadata contract. The live checks never used production quota or fleet
configuration.

`live-quota-driver.py` and `live-quota-transcript.log` retain the public commands
and observations for 16 adapters at spawn, 15 at control relaunch, caller and
configured-model inputs, exhausted and short early-confidence projections,
legacy positional dispatch, eligible alternatives, refusal before stopping a
real Grok process, and two-child batch refusal. The old task metadata remained
byte-identical after refusals.

`live-lifecycle-driver.py`, `live-lifecycle-transcript.log`, and
`live-override-meta.txt` demonstrate real launch with an explicit override,
healthy control relaunch removing the override fields, a four-hour projection
launching, one missing-reading notice surviving control delegation, implicit
exhausted recovery launching, and a two-child batch carrying the exact override
reason and authoritative evidence to both real launches. The driver's continuation
flag was used after correcting its shutdown timing to wait for Grok's visible
quit footer before sending Ctrl-Q; the retained log includes the completed
healthy relaunch from the first invocation and all subsequent successful steps.

`live-edges-driver.py` and `live-edges-transcript.log` demonstrate that named
accounts cannot borrow healthy default quota, the sole configured literal model
selects the model-specific exhausted row, equal top spendPriority alternatives
are both disclosed, and released-copy refusal preserves its record and never
creates its missing worktree.

Polytoken was absent from PATH. Its official 0.9.4 Linux binary was installed
only into `.poly/bin` using the vendor's installer and verified checksum. A
throwaway offline provider configuration pointed to loopback port 9; no real
credential, login, or model request was involved. Its real `print models`
catalog accepted `zai/glm-5.3-flash(low)`, then the real control entrypoint
refused the exhausted quota and preserved metadata. See
`live-polytoken-driver.py`, `live-polytoken-transcript.log`, and
`polytoken-catalog.log`. This closes native preflight coverage for the sixteenth
relaunch adapter. The downloaded binary and local configuration were removed.

## Remote live boundary

The attempted real `fm-remote-secondmate-control.sh launch` stopped at the stock
containment guard, as retained in `live-edges-transcript.log`. Its nested spawn
sets FM_HOME to the code root and redirects state/data to parent-route. A gate
permits only a marked stock lab home, so this is not an authorized live route.
In addition the remote entrypoint fixes its Herdr session to `fm-remote`, while
this run's contract permits only helper-owned named `fm-lab-*` sessions. No Herdr
session was started, no guard was bypassed, and no real remote/fleet home was
used. Completing this live scenario requires a supported lab mapping for the
remote home/state and a named lab session, or a separately authorized disposable
remote integration environment. Regression coverage below uses fake SSH/Herdr
boundaries and is explicitly supplemental, not live evidence.

## Targeted regression commands

- `TMPDIR=/tmp bash tests/fm-quota-gate.test.sh`
- `TMPDIR=/tmp bash tests/fm-remote-secondmate-relaunch.test.sh`
- `TMPDIR=/tmp bash tests/fm-remote-secondmate-trace-context.test.sh`

Logs are retained alongside this note. The initial quota-suite attempt used a
worktree-local TMPDIR; the product correctly refused a fixture secondmate nested
inside its source repository. The suite was then rerun using its normal ephemeral
temporary directory. Initial live fixtures were corrected to remove a duplicate
schema-5 provider, add a capacity declaration and complete brief, and use the
vendor's UTC `Z` timestamp format. These were fixture defects, not product
failures. No source files, linters, formatters, full suite, or pipeline-control
commands were changed or run.

## Primary research used for fixture setup

- [quota-axi README](https://github.com/kunchenguid/quota-axi/blob/main/README.md):
  schema 5/6 and the runway JSON contract, with UTC `Z` timestamps.
- [Polytoken installation](https://docs.polytoken.dev/installation/): supported
  Linux architecture and explicit PT_INSTALL_DIR local installation.
- [Polytoken CLI reference](https://docs.polytoken.dev/reference/cli/):
  `print models` reads effective configuration and emits the selectable catalog.
- The downloaded CLI's `print schema app-config` and its actual config-validation
  diagnostics supplied the typed offline fixture schema, provider auth format,
  base URL rule, and explicit default-model group.

The research notes remain in the permitted evidence directory; the operator's
external research book was read but not modified across the workspace boundary.

## Final check results

All three targeted regression commands exited 0. The remote-chain suite also
proved the exhausted remote Grok recovery exemption, explicit remote refusal,
remote-route alternative filtering, override forwarding and host-confirmed
metadata, and preservation of exactly one uncertainty notice on stderr. These
remain non-live tests because SSH and Herdr are fixture boundaries. Both live
private tmux servers were stopped, the remote regression worker exited during
its trap cleanup, all temporary worktree directories and downloaded binaries
were removed, and no tracked source or test files changed.

`live-control-override-driver.py` and `live-control-override-transcript.log`
subsequently closed the remaining live control-delegation case: an exhausted
Grok relaunch with `--quota-override 'replacement reason with spaces'` emitted
one control notice, launched the real replacement, replaced the old reason,
and persisted the refusal plus best-alternative evidence. This driver exited 0
and stopped its private tmux server and removed its marked lab in its finally
cleanup.
