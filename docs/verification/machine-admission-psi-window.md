# Machine-admission PSI-window verification

Audience: maintainer verification.

The [machine-capacity policy](../configuration.md#machine-capacity-configlane-capacity) owns configuration guidance, and the [resource reader](../../bin/fm-machine-resources.py) owns policy validation and refusal decisions.
This record distinguishes real-machine replay evidence from the synthetic behavioral cases in `tests/fm-machine-resources.test.sh`.

## Date, versions, and measurement boundary

- Captured on 2026-10-31, approximately 21:45-22:35 UTC, on three Linux hosts identified here as PC, server, and laptop.
- Replayed with `bin/fm-machine-resources.py` at commit `20562e154c4a429a1d8382aada6ca599940e4a19`, using policy schema `fm-machine-admission.v1`.
- Exact kernel and Python versions were not included in the supplied capture; do not infer them from the replay version.
- Samples read `/proc/pressure/memory` full avg10, avg60, and avg300, taking each window's maximum over the host and the reading process's cgroup ancestors, plus `/proc/meminfo` MemAvailable.
- Collection requested 540 samples per host at five-second intervals; the retained counts and elapsed spans are reported below.
- Each sample was replayed through the branch's real `refusal_reasons(facts, rules)` using the old avg60 ceiling of 5 and the new avg300 ceiling of 5 with an avg60 ceiling of 25.
- The actual memory floors were 3 GiB on PC and laptop and 1.5 GiB on server.
- This comparison isolates PSI and host MemAvailable; it is a replay of sampled resource readings, not counts of actual worker launch attempts or a live rollout comparison of all lane, reserve, disk, and cgroup-limit gates.
- The aggregate capture and diagnostic readings below were supplied by the maintainer; raw samples are not committed here, so reproducing the historical totals requires those samples.

## Repeatable collection and replay

The following commands reproduce the described collection and replay method from the repository root.
They are a reusable recipe, not a claim that these exact script bytes or new measurements were used to produce the historical capture.
Run the sampler on each host, setting `host` to `pc`, `server`, or `laptop`, and retain the three JSONL outputs together for replay.
New runs measure their own workload window and need not produce the historical totals.

```bash
host=pc
python3 -B - "$host" <<'PY'
import json, sys, time
from pathlib import Path

host = sys.argv[1]
root = Path('/sys/fs/cgroup')
windows = ('avg10', 'avg60', 'avg300')
with Path(f'{host}-psi.jsonl').open('w') as output:
    for _ in range(540):
        membership = Path('/proc/self/cgroup').read_text()
        relative, = [line[3:] for line in membership.splitlines() if line.startswith('0::')]
        assert relative.startswith('/') and '..' not in Path(relative).parts
        group = root / relative.lstrip('/')
        paths = [Path('/proc/pressure/memory')]
        while True:
            pressure = group / 'memory.pressure'
            if pressure.exists():
                paths.append(pressure)
            if group == root:
                break
            group = group.parent
        readings = []
        for path in paths:
            full, = [line for line in path.read_text().splitlines() if line.startswith('full ')]
            fields = dict(field.split('=') for field in full.split()[1:])
            readings.append({window: float(fields[window]) for window in windows})
        available, = [line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines()
                      if line.startswith('MemAvailable:')]
        assert Path('/proc/self/cgroup').read_text() == membership
        sample = {'epoch': time.time(), 'mem_available_bytes': int(available) * 1024}
        sample.update({f'memory_full_{window}': max(row[window] for row in readings)
                       for window in windows})
        output.write(json.dumps(sample) + '\n')
        output.flush()
        time.sleep(5)
PY
```

Replay uses host MemAvailable as the memory input and a nonbinding disk input to isolate the measured memory/PSI decision.
It does not claim to reconstruct unrecorded cgroup limits or disk readings.

```bash
python3 -B - <<'PY'
import importlib.util, json
from pathlib import Path

spec = importlib.util.spec_from_file_location('resources', 'bin/fm-machine-resources.py')
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)
print('host samples span_min min_avail_GiB max_full60 max_full300 old_refused new_refused')
for host, floor in [('pc', 3), ('server', 1.5), ('laptop', 3)]:
    samples = [json.loads(line) for line in Path(f'{host}-psi.jsonl').read_text().splitlines()]
    old = {'memory_floor_gib': floor, 'memory_full_avg60_max': 5, 'disk_floor_gib': 0}
    new = {**old, 'memory_full_avg60_max': 25, 'memory_full_avg300_max': 5}
    facts = [{**sample, 'effective_available_bytes': sample['mem_available_bytes'],
              'disk_available_bytes': {'/': 1}} for sample in samples]
    refused = [sum(bool(resources.refusal_reasons(sample, rules)) for sample in facts)
               for rules in (old, new)]
    span = int((samples[-1]['epoch'] - samples[0]['epoch']) / 60)
    minimum = min(sample['mem_available_bytes'] for sample in samples) / resources.GIB
    full60 = max(sample['memory_full_avg60'] for sample in samples)
    full300 = max(sample['memory_full_avg300'] for sample in samples)
    print(f'{host} {len(samples)} {span} {minimum:.1f} {full60:.2f} {full300:.2f} '
          f'{refused[0]} {refused[1]}')
PY
```

The exact supplied replay output was:

```text
host samples span_min min_avail_GiB max_full60 max_full300 old_refused new_refused
pc 540 44 4.8 4.68 1.56 0 0
server 530 45 7.7 9.23 4.45 45 0
laptop 530 45 14.4 12.37 6.30 174 73
```

Every refused server reading had at least 7.7 GiB available, and every refused laptop reading had at least 14.4 GiB available.
The new policy removed all 45 server refusals and reduced laptop refusals from 174 to 73 over the same readings while retaining the actual host memory floors.
PC had no refusals under either policy.

## Threshold sensitivity and measured cause

- On these same readings, the avg60 ceiling never binds between 15 and 30 because the maximum observed avg60 is 12.37.
- Laptop refusals are 73/530 at an avg300 ceiling of 5 and 0/530 at 7.5 or 10; server refusals are zero at all three avg300 ceilings with the higher avg60 ceiling.
- The replay supports fewer refusals with ample available memory; it does not establish that a five-minute limit of 5 eliminates all compaction-related refusals or that a higher threshold is suitable for every workload.
- A 30-second laptop `/proc/vmstat` delta showed `compact_stall +8567`, `allocstall_movable +3349`, `pswpin +1`, `pgscan_direct 0`, and `pgscan_kswapd 0`.
- Lifetime `compact_fail/compact_stall` was 99.2% on laptop and 98.5% on server, and `/proc/buddyinfo` showed no free order-9 or order-10 blocks.
- Transparent huge pages had `enabled=madvise` and `defrag=madvise`.
- Laptop host-level pressure came from CI runner services in `system.slice`, while the worker user slice read about 0.2-0.5.
- These observations point to direct compaction and memory fragmentation despite ample free bytes, rather than host memory exhaustion.
- The [direct-compaction allocation path](https://github.com/torvalds/linux/blob/v6.12/mm/page_alloc.c) brackets compaction with PSI memory-stall accounting; the [kernel PSI documentation](https://docs.kernel.org/accounting/psi.html) describes its stall-time windows and per-cgroup pressure interface.

## Live follow-up

The change takes effect only once a host's `config/machine-admission.json` adds `memory_full_avg300_max`, with `memory_full_avg60_max` raised to the intended burst ceiling.
After merge, the per-verdict `state/machine-admission.log` is the source for a live day's before/after table of policy hashes, refusal counts, PSI windows, and available memory.
The [capacity library](../../bin/fm-capacity-lib.sh) owns the log columns and rotation limit; retain both the current file and `.1` when collecting a day's evidence before rotation discards older samples.

## Class inventory for validation

Inspected on 2026-10-31 against the call boundaries below, starting from commit `4fb6db3ffb53eed0c288e906145ccc8d107b74e3`.
This is the handoff required by `bin/fm-dod-lib.sh`, not a claim of live launch coverage.
Regression pointers identify executable coverage for the designated validation phase; the focused review command is `bash tests/fm-machine-resources.test.sh`.
The recorder's nine-column TSV contract is the independent oracle for its failure-output regression: a missing, whitespace-only, or truncated reader response must produce one unknown record with six empty reading fields while admission fails closed.

| Axis | Inspected paths and coverage or exemption |
| --- | --- |
| Reader and policy consumers | `measure()` calls `refusal_reasons()` for the CLI consumed by `fm_capacity_read()`; the replay above calls the same decision function directly, and `fm-remote-home-provision.sh` invokes `--validate-policy` without measuring or recording a verdict; `tests/fm-machine-resources.test.sh` covers legacy and windowed policies, host and enclosing-cgroup pressure, memory floors, malformed fields, and unreadable PSI. |
| Report and advice callers | `fm-capacity.sh` default text, `--json`, `--publish`, and `--admit` all call `fm_capacity_read()` and its shared recorder; `fm-fleet-view.sh --capacity` and `fm-fleet-ledger.sh capacity` delegate to that command, `fm-home-summary-refresh.sh` uses `--publish`, `fm-spawn-deferred.sh` reads its text output, and `fm-place.sh` consumes published facts; the focused regression exercises every report mode with empty, whitespace-only, and truncated output; `tests/fm-capacity.test.sh` covers normal reporting and publication. |
| Task kinds | `fm-spawn.sh` applies machine admission to ships and scouts through the same non-secondmate branch; persistent secondmate startup is explicitly exempt; `tests/fm-capacity.test.sh` covers secondmate exclusion from occupied lanes and machine-wide counting across local homes; task-kind selection does not enter the recorder or PSI reader. |
| Harnesses | The shared admission branch has no harness-specific condition for claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, gemini, muse, rovo, omp, agy, devin, commandcode, or polytoken; inspection of `fm-harness.sh` and the `fm-spawn.sh` admission call establishes the exemption from per-harness output and keybinding tests: this change reads kernel facts and serializes JSON/TSV, without interpreting vendor output. |
| Runtime backends | `fm-backend.sh` lists tmux, herdr, zellij, orca, cmux, and paseo as spawn-capable; the `fm-spawn.sh` non-secondmate machine gate precedes backend launch for all six, including Orca; no backend argument enters `fm_capacity_sample()` or `refusal_reasons()`; backend-specific launch mechanics are unchanged and are exempt from new backend smoke coverage for this recorder fix. |
| Platforms | Linux host PSI and cgroup-v2 ancestor reads are exercised with synthetic proc/cgroup files, including differing host and ancestor pressure; `fm-capacity.sh` has Darwin informational probes, but the resource reader still requires Linux proc/PSI evidence and fails closed when it is absent; this change adds no macOS capacity support; native Windows is outside the Bash/proc reader interface, and neither native Windows nor macOS execution is claimed by this inspection. |
| Account selections | `fm-spawn.sh` resolves dispatch profiles and account pins through `fm-worker-account-lib.sh`; neither the selected account, provider, model, nor profile is an input to the resource reader or recorder; pinned Claude/Pi accounts, ambient accounts, and profile-selected launches therefore share the same gate; no credential or account-selection behavior changes. |
| Lifecycle transitions | Fresh ship/scout launch, ordinary relaunch, and relaunch from a released copy all traverse the shared machine gate; relaunch passes its own task id for seat replacement; deferred retry reads capacity before invoking spawn again, so it also reaches the gate; secondmate startup/relaunch remains exempt; these inspected branches are unchanged; `tests/fm-capacity.test.sh` covers admission and seat rules, and `tests/fm-control-relaunch.test.sh` is the existing relaunch regression entry point for the designated validation phase. |
| Verdict and log transitions | Readable admission, readable refusal, malformed PSI, and an empty or interrupted reader result all reach `fm_capacity_sample()` before the caller acts on the reader status; `tests/fm-machine-resources.test.sh` covers yes/no/unknown records, empty output with success and killed-reader statuses, malformed output, byte-cap rotation, and unwritable logging without changing admission; policy opt-in and the unmodified legacy policy are separate tested states. |

### Live guards and remaining gaps

No real-harness guard is required for a changed vendor signal because this change introduces none.
The existing `tests/fm-harness-liveness-drift-live-e2e.test.sh` and `tests/fm-harness-adapter-instructions-live-e2e.test.sh` guard vendor-dependent liveness and launch instructions; those surfaces are unaffected by the inspected recorder and PSI decision boundaries.
If the designated validation phase expands into live harness launch behavior, it owns those guards and must record actual installed versions and output before claiming live proof.
No live per-harness or per-backend spawn, relaunch, account switch, or macOS execution is established by this review handoff.
The supplied historical replay has the raw-sample and software-version gaps stated above, and a live day's before/after verdict table remains follow-up work after host policy opt-in.
