# Current-head local validation
Target: 3745e8fea8d51a3e3b436817a18f5c8d996c8759.
Result: no-go.

## Confirmed clock failure
Initial observation: {"sample": 0, "btime": 1791085790, "status": "stale", "identity_and_config_fixed": true, "observation": {"schema": "fm-nm-config-age/1", "machine": "pc", "status": "stale", "diagnostic": "", "sampled_at": "2026-10-04T16:00:29.971670+00:00", "pid": 26190, "started_at": "2026-10-04T16:00:28Z", "process_start_ticks": 4383899, "config_mtime_ns": 1791129628000000001}}
Failing observation: {"sample": 32, "btime": 1791085787, "status": "unavailable", "identity_and_config_fixed": true, "observation": {"schema": "fm-nm-config-age/1", "machine": "pc", "status": "unavailable", "diagnostic": "unverified_metadata", "sampled_at": "2026-10-04T16:00:59.888694+00:00"}}
PID record bytes, kernel start ticks and config mtime were asserted unchanged throughout.
Fresh episode after the failure emitted only unavailable diagnostics and no stale warning.
The current owning suite independently fails its clock-step regression.

## Prompt emission
Hanging server: confirmed pc and zenbook warnings at 0.271 seconds while both SSH health and metadata commands were still alive; completion at 15.071 seconds included unavailable server.
Hanging zenbook: confirmed pc and server warnings at 0.247 seconds while both SSH health and metadata commands were still alive; completion at 15.071 seconds included unavailable zenbook.
All warnings named only confirmed stale machines in sorted order.

## Evidence boundaries
Three real foreground no-mistakes daemons and two real authenticated loopback SSH servers were disposable and worktree-local.
Collector installation substitutions changed fixture host paths, SSH client configuration, and fixture user names only.
No test seams or synthetic procfs were enabled in live drivers.
The actual PC/server/Zenbook installation was not accessed: private host installation and registration remain with main.
Existing A/B/D, malformed-probe and registration regressions were executed separately from the retained pre-clock test revision 68ac1b56 against the current helper and collector; those are fixture evidence, not live host proof.
No source or retained test file changed; all disposable daemons, SSH servers, package extractions, keys, homes and the temporary historical regression copy were torn down.

## Source identities
9b15c32621f8eee38efa93a9bfeeccb350da6432a406c310fc69b99d60497906  bin/fm-nm-config-staleness-check.sh
d296cef0b4e6f5599088f39743b1e9d752b00ae4d7a5983effd45d1d84013fea  tests/fixtures/server-idle-watch.check.sh
b1ca16fe9877e7386470f83a3449990796830f7f974090e04582bc73ccd8bf21  tests/fm-nm-config-staleness.test.sh
