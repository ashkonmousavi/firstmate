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
