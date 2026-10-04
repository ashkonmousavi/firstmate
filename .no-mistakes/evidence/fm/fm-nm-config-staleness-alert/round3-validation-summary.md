# Current-head live validation
Target: 3745e8fea8d51a3e3b436817a18f5c8d996c8759.
Verdict: no-go.
No tracked files changed.

## Confirmed stale alert lost after natural host clock movement
Initial real-daemon observation:
```json
{"btime": 1791085743, "identity_and_config_fixed": true, "observation": {"config_mtime_ns": 1791130299000000001, "diagnostic": "", "machine": "pc", "pid": 77737, "process_start_ticks": 4455632, "sampled_at": "2026-10-04T16:11:40.054192+00:00", "schema": "fm-nm-config-age/1", "started_at": "2026-10-04T16:11:39Z", "status": "stale"}, "sample": 0, "status": "stale"}
```
Failing observation with unchanged PID-record bytes, kernel start ticks and config mtime:
```json
{"btime": 1791085739, "identity_and_config_fixed": true, "observation": {"diagnostic": "unverified_metadata", "machine": "pc", "sampled_at": "2026-10-04T16:12:27.360271+00:00", "schema": "fm-nm-config-age/1", "status": "unavailable"}, "sample": 50, "status": "unavailable"}
```
A fresh episode then emitted:
```text
server-idle-watch: no-mistakes observation unavailable on: pc
server-idle-watch: no-mistakes observation unavailable on: server
server-idle-watch: no-mistakes observation unavailable on: zenbook
```
The current owning suite also fails its retained forward/backward clock-step regression.
The source head explicitly leaves the independent identity-proof contract pending additional metadata authorization.
That decision remains with the outer executor; no test or sampler was weakened.

## Confirmed stale warnings stream while real remote SSH probes remain pending
```text
HANG server: stdout 0.260s; live pending phases=['health', 'metadata']; complete 15.072s; exit=0
HANG zenbook: stdout 0.252s; live pending phases=['health', 'metadata']; complete 15.072s; exit=0
```
Both pending phases were live health and metadata SSH commands.
Each check completed within the watcher deadline with the corresponding unavailable diagnostic.
Strict newer/equal/older, sorted episode output, unchanged deduplication, clear/rewarning, real daemon replacement, partial remote failure, metadata races and read-only sampling passed through executable interfaces.
Read-only sampling was observed with inotify on config and daemon control socket, immutable config bytes and authenticated SSH command transcripts.

## Independent remote process identities
Two disposable Linux PID namespaces each ran a real daemon with numeric PID 2.
Their authenticated loopback SSH samples correctly reported stale/equal/older against host-local procfs.
The same remote records sampled against PC procfs were unavailable.
An empty PID namespace reported not_running.
See round3-namespace-transcript.log.

## Existing check alerts and registration
The real registered-check snapshot emitted the D worker-storm warning for three real isolated serving remote-job workers, and did not repeat that warning.
Live A/B alert attempts were quiet because actual integer MemAvailable was 5 GiB; the existing threshold requires greater than 6 GiB.
A disposable home or PID namespace cannot create physical available memory.
Freeing the real fleet or changing VM memory is outside this gate's authority.
Provide an isolated host with at least 7 GiB available memory to complete those live alert scenarios.
The unchanged historical owning suite from 68ac1b56 was additionally executed against the current helper and fixture, covering A/B/D, registration byte binding, malformed transport and sampling races.
It passed; this supplemental fixture run does not replace the failing current owning suite and is not installed host acceptance.

## Boundary and cleanup
SSH tooling was downloaded and extracted only inside this worktree; no system install or tool configuration changed.
All daemons, SSH servers and worker processes were stopped by their disposable drivers.
The downloaded packages, extracted tooling, lab homes and historical test copy were removed.
Actual PC/server/Zenbook installation and private registration were not touched; main owns those observations and host integration.
CLI transcripts are the user-facing artifacts; this change has no rendered UI requiring screenshots.
