### First aged label opens one notification
check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict


Notifications:
1792659664	1	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict

Drain:
1792659664	1	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict

WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 265235.1792659664.4AkN1k
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 11s ago).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  After draining queued wakes, repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds 180.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

Acknowledgement:


### Same label application stays quiet


Notifications:

Drain:

WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation 275120.1792659680.u622zH
WARNING: watcher still down (same stale episode; last beat: 8s ago, grace 300s) - full banner already printed this episode.

Acknowledgement:


### Clear removes episode without another notification


Notifications:

Drain:

WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation 283853.1792659690.i9i5ci
WARNING: watcher still down (same stale episode; last beat: 7s ago, grace 300s) - full banner already printed this episode.

Acknowledgement:


### Relabel after observed clear opens a second notification
check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict


Notifications:
1792659699	2	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict

Drain:
1792659699	2	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict

WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 292028.1792659699.nMi1Tg
WARNING: watcher still down (same stale episode; last beat: 7s ago, grace 300s) - full banner already printed this episode.
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

Acknowledgement:


### Relabel without observing clear opens a third notification
check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict


Notifications:
1792659711	3	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict

Drain:
1792659711	3	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/episode-home/state/lane.check.sh: conflict

WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 3 --recovery-generation 300154.1792659711.NJRzoO
WARNING: watcher still down (same stale episode; last beat: 8s ago, grace 300s) - full banner already printed this episode.
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

Acknowledgement:


### Repeated third episode stays quiet


Notifications:

Drain:

WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation 305962.1792659722.tObtRu
WARNING: watcher still down (same stale episode; last beat: 7s ago, grace 300s) - full banner already printed this episode.

Acknowledgement:

