# Backstop CLI validation

Executed the real backstop CLI, fm-on, remote-file, remote-delta-read and timestamp parser in disposable worktree-local homes. A read-only local transport adapter replaced SSH; explicit external fault injection supplied stalls, failures and preemption. No product logic or clock was replaced. Sending stayed disabled: alarm text below comes from the product’s persisted deferred-alarm records; no Herdr or fleet session was accessed.

Oracle: the supplied intent and recorded R1 decision. The baseline commit must rebuild exact legacy cursors and count advancing over-budget scans as failed reads; the target must preserve those cursors and converge without those false failures. Both regressions were reproduced against the base; the stalled-read and transport guards passed there.

The 12 focused candidate behavioral tests passed. No full suite, lint, delivery or CI phase ran.

All fixture directories were removed and every subprocess was awaited.

## legacy-large-cursor

Kept 1699879-byte cursor and SHA256; one tail delta read, no whole-file get or alarms.

Pass 1: exit 0; cursor 1699879; pending []; read_fails {}; active incidents [].

```text
migrated q-server legacy reader cursor
checked watcher_age=1793195838s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1699879 56d4f5ec4d373ea81ff67a98372bc0c8db0884b9ce1313649f2ab4d465786990` → exit 75

## legacy-pending-lag-and-clear

Migrated pending stamp triggers durable lag; mirroring it clears pending and active lag episode.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
migrated q-server legacy reader cursor
BACKSTOP ALARM HELD: backstop-bb1cb867cb374de481d5493f4d0d368f
BACKSTOP ALARM HELD: backstop-a1dff71580da49ff889c8608971e5674
checked watcher_age=1793195838s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 36 389a5b7b9c7dd6bbf2324c3599d42608a63e8e1719d9789847a5fecaf9caf52f` → exit 75

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3600s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

Pass 2: exit 0; cursor 36; pending []; read_fails {}; active incidents [].

```text
checked watcher_age=1793195838s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 36 389a5b7b9c7dd6bbf2324c3599d42608a63e8e1719d9789847a5fecaf9caf52f` → exit 75

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3600s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## invalid-legacy-0

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-d315a92c749b4eabbdf4343e862e39cd
BACKSTOP ALARM HELD: backstop-70faa38042574171924f58f6cbebd529
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## invalid-legacy-1

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-70311680532d42a0bab8514331003cf4
BACKSTOP ALARM HELD: backstop-abfe42681e2f4664bf31d5f5a4998230
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## invalid-legacy-2

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-58702cb98ec14b76a96c44b27f4cde55
BACKSTOP ALARM HELD: backstop-108dc0a6d84e44939ebfffb0c6e1f2f7
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## invalid-legacy-3

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-e23696bc83a04e77959f970438c59d98
BACKSTOP ALARM HELD: backstop-ee804cf9e3db486897434970762fff78
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## invalid-legacy-4

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-cb7708b704944773af0a4f84fa9b4986
BACKSTOP ALARM HELD: backstop-26daa7be0fd34d7298f2910c9d8f07fc
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## invalid-legacy-5

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-bd11b87c027c4e7cb9c6d414d60930b5
BACKSTOP ALARM HELD: backstop-f974aea56efb42de9af9ddffc21f9a33
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## invalid-legacy-6

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-73c2f76d578443c48b95e89c06465bb8
BACKSTOP ALARM HELD: backstop-5b33440e4c644d5084e18b7315785da2
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## invalid-legacy-7

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-be942bb664d7405cae9dd86062ee9d27
BACKSTOP ALARM HELD: backstop-c0afddec359e46dc819c690390df77a6
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## invalid-legacy-8

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-c586652edc594bef90ee730c126b107a
BACKSTOP ALARM HELD: backstop-342c24c36da84ae1ba3451a94e3fe205
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## invalid-legacy-9

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-35bcee907ab94c4f8f60961d975b49b6
BACKSTOP ALARM HELD: backstop-cc7d3d90dfa7490a8feaa2602af06865
checked watcher_age=1793195839s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3601s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## invalid-legacy-10

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-2cc08adc522d4112b806db1257e12686
BACKSTOP ALARM HELD: backstop-9d2675d18d9147a395239fd5ed5ab1aa
checked watcher_age=1793195840s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3602s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## invalid-legacy-11

Invalid shape/stamp bypasses migration, rebuilds through real whole-file reader and reports oldest lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-3e73cb707e214c57b91253239d7156c5
BACKSTOP ALARM HELD: backstop-3b726996c20e437480dfa62c686f2a16
checked watcher_age=1793195840s alarms=2
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3602s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

## bogus-valid-hash-continuity

Validly shaped but false prefix produces continuity-broken, then rebuilds before reporting lag.

Pass 1: exit 0; cursor 36; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
migrated q-server legacy reader cursor
read q-server log moved; resyncing cursor
BACKSTOP ALARM HELD: backstop-a2af02fad6cb4555bed540ba8fe56004
BACKSTOP ALARM HELD: backstop-dd395a3e3e7e4053974cba0ca6f2202a
checked watcher_age=1793195840s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 36 0000000000000000000000000000000000000000000000000000000000000000` → exit 0; response continuity-broken at offset 36
- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 0

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3602s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## cold-large-backlog

Cold 1720430-byte resync refused whole-file get and converged in 7 passes at offsets [260132, 520265, 782409, 1044553, 1306697, 1568841, 1720430]; real oldest lag retained with zero read failures/unverified alarms.

Pass 1: exit 0; cursor 260132; pending []; read_fails {}; active incidents [].

```text
read q-server log catching up: cursor at 260132
checked watcher_age=1793195840s alarms=0
```

- Remote invocation: `fm-remote-file.sh get state/parent-replies.status 1048576` → exit 1
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` → exit 0; response delta at offset 63524
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 63524 76b2c7b9393aa5a03a2890e0d453bb388c29591bfe5409d36a52f19823238e9f` → exit 0; response delta at offset 129060
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 129060 a7815ca66e34b5a9a05df9e60d0a22515122e971af99b84e32c1b388b2853585` → exit 0; response delta at offset 194596
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 194596 f7a6be595cd42eb83faf88ba670b3f6815c4b0df40b3f8436ab1a9ccf74e2049` → exit 0; response delta at offset 260132

Pass 2: exit 0; cursor 520265; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
read q-server log catching up: cursor at 520265
BACKSTOP ALARM HELD: backstop-69151188e1604bc999b056fb0afea3fe
BACKSTOP ALARM HELD: backstop-7330e894060c44be8afd7ae12259aee4
checked watcher_age=1793195841s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 260132 f3a43de36c98a3186b78f672c0eed5bfe4e7675599926728285f3fb13f73db85` → exit 0; response delta at offset 323657
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 323657 456b2a8c0f347bc65aa6369664869c4ad002893a9d40fcf9d3bd3d90b4d911c2` → exit 0; response delta at offset 389193
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 389193 68ae36ae2e79adfa80cd93f39e520d295df3d2050f3e439ae4c217911f64bc56` → exit 0; response delta at offset 454729
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 454729 06c58fd9907f016c5b418a70fcf1e04592db7d291f2ff99cca7c5537ddb10e1f` → exit 0; response delta at offset 520265

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3603s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

Pass 3: exit 0; cursor 782409; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
read q-server log catching up: cursor at 782409
BACKSTOP ALARM HELD: backstop-69151188e1604bc999b056fb0afea3fe
BACKSTOP ALARM HELD: backstop-7330e894060c44be8afd7ae12259aee4
checked watcher_age=1793195841s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 520265 6d3b8f1496849f845cfa937e53d0b6fb304f5c47fc6effac8431e79f68dda4f3` → exit 0; response delta at offset 585801
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 585801 b54ecc629f31954a1dcf44b765baa7933e3a118848a89ce60ccad442bed0cc64` → exit 0; response delta at offset 651337
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 651337 57ddf705d64c576e04c11905a21923121bfda187d195854ca762723c23858124` → exit 0; response delta at offset 716873
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 716873 7dbe06dc020b83ffea7215e54b12a089dae66a58a1e06ff9c1a5a585e0f4647b` → exit 0; response delta at offset 782409

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3603s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

Pass 4: exit 0; cursor 1044553; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
read q-server log catching up: cursor at 1044553
BACKSTOP ALARM HELD: backstop-69151188e1604bc999b056fb0afea3fe
BACKSTOP ALARM HELD: backstop-7330e894060c44be8afd7ae12259aee4
checked watcher_age=1793195842s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 782409 405c8669fb57def203cf66a4217a887ff8d49259eb4e6f8eed97a20429b032bc` → exit 0; response delta at offset 847945
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 847945 dd73753ac99cf28a14d4c0cb3f284e8ef457d08d77735c21299b8c750eaf25bb` → exit 0; response delta at offset 913481
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 913481 cb7095bd86a257d73074f0b3c5bfbd39b7f5334afc4f8c6d65bdf69c8e970af8` → exit 0; response delta at offset 979017
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 979017 99fca521fb040eb14073cf5a0ab9e5c5ac315583d56f28369416095bdb35028a` → exit 0; response delta at offset 1044553

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3604s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

Pass 5: exit 0; cursor 1306697; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
read q-server log catching up: cursor at 1306697
BACKSTOP ALARM HELD: backstop-69151188e1604bc999b056fb0afea3fe
BACKSTOP ALARM HELD: backstop-7330e894060c44be8afd7ae12259aee4
checked watcher_age=1793195840s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1044553 279608f478e73eb4b60425e8365c5e44746ae439681a3424b055e1ec3ff46f34` → exit 0; response delta at offset 1110089
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1110089 9bd4f461460d28b27b89c96207b8f1936f55178297dd59e6e046b432d7d39217` → exit 0; response delta at offset 1175625
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1175625 ee9849e8899d27559e9df41afc1c02ac8840c9e98f01ee74317eceddd9a911b0` → exit 0; response delta at offset 1241161
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1241161 2f4969989ce356e4e4f2f7311af4f2da4542f0bea03417318dc0429b3092303f` → exit 0; response delta at offset 1306697

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3602s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

Pass 6: exit 0; cursor 1568841; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
read q-server log catching up: cursor at 1568841
BACKSTOP ALARM HELD: backstop-69151188e1604bc999b056fb0afea3fe
BACKSTOP ALARM HELD: backstop-7330e894060c44be8afd7ae12259aee4
checked watcher_age=1793195840s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1306697 8e037061181f8226934b7fba917db61d334d0b96b88b5ee5ac912efef0c5d53d` → exit 0; response delta at offset 1372233
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1372233 c7c6e6a2fb4dcca00ab12c07c15e0dd061af63830b1b88104c26873a95b7f862` → exit 0; response delta at offset 1437769
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1437769 c1c9d23bd2a476bd3368af6ba508068f605f1e6a59d8f85cb2d2e4cb0d8dc556` → exit 0; response delta at offset 1503305
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1503305 3e660d64cca299855438e70bf1afe541eaa84b839d000308621a306512a6f457` → exit 0; response delta at offset 1568841

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3602s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

Pass 7: exit 0; cursor 1720430; pending [1793192238, 1793194338]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-69151188e1604bc999b056fb0afea3fe
BACKSTOP ALARM HELD: backstop-7330e894060c44be8afd7ae12259aee4
checked watcher_age=1793195841s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1568841 4971311eb30983bf66ef55a05fcc13e0419a16c89abfc0e974aca838bbad3e6e` → exit 0; response delta at offset 1634377
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1634377 0b334476276e9b1e0cfaea9275ad5c86185a5207a32a80cb85c96c9ce0c2fb0e` → exit 0; response delta at offset 1699913
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1699913 215631a082dabb8864125c9cb658ae679e4a60a0c4127d5e91c3947ec89b140d` → exit 0; response delta at offset 1720430
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 1720430 a37cc54c8e6665561eb56343aa492ebe6e0c57c11dd460721000ac506fa5da5d` → exit 75

Persisted product alarm text:

```text
REPLY DELIVERY LAG q-server: 3603s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
BACKSTOP HELD: reply lag: q-server
```

## stalled-budget

First failure tolerated; second pass records durable UNVERIFIED; real healthy tail read clears active read failure. Four calls per stalled/preempted pass, one per transport failure.

Pass 1: exit 0; cursor 31; pending []; read_fails {'q-server': 1793195842}; active incidents [].

```text
read failed once, tolerating one pass: q-server
checked watcher_age=1793195842s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31

Pass 2: exit 0; cursor 31; pending []; read_fails {'q-server': 1793195842}; active incidents ['read-q-server'].

```text
BACKSTOP ALARM HELD: backstop-d36004e6c61841dbb43a5f560571bcab
checked watcher_age=1793195842s alarms=1
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 31

Persisted product alarm text:

```text
REPLY DELIVERY UNVERIFIED q-server: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.
```

Pass 3: exit 0; cursor 31; pending []; read_fails {}; active incidents [].

```text
checked watcher_age=1793195842s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 75

Persisted product alarm text:

```text
REPLY DELIVERY UNVERIFIED q-server: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.
```

## transport-failure

First failure tolerated; second pass records durable UNVERIFIED; real healthy tail read clears active read failure. Four calls per stalled/preempted pass, one per transport failure.

Pass 1: exit 0; cursor 31; pending []; read_fails {'q-server': 1793195842}; active incidents [].

```text
read failed once, tolerating one pass: q-server
checked watcher_age=1793195842s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 1

Pass 2: exit 0; cursor 31; pending []; read_fails {'q-server': 1793195842}; active incidents ['read-q-server'].

```text
BACKSTOP ALARM HELD: backstop-27410bb2430e4b11b59773c0e89bc07f
checked watcher_age=1793195842s alarms=1
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 1

Persisted product alarm text:

```text
REPLY DELIVERY UNVERIFIED q-server: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.
```

Pass 3: exit 0; cursor 31; pending []; read_fails {}; active incidents [].

```text
checked watcher_age=1793195842s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 75

Persisted product alarm text:

```text
REPLY DELIVERY UNVERIFIED q-server: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.
```

## permanent-preemption

First failure tolerated; second pass records durable UNVERIFIED; real healthy tail read clears active read failure. Four calls per stalled/preempted pass, one per transport failure.

Pass 1: exit 0; cursor 31; pending []; read_fails {'q-server': 1793195842}; active incidents [].

```text
read failed once, tolerating one pass: q-server
checked watcher_age=1793195842s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76

Pass 2: exit 0; cursor 31; pending []; read_fails {'q-server': 1793195843}; active incidents ['read-q-server'].

```text
BACKSTOP ALARM HELD: backstop-dfc41eee0ef242bfb829fc30b1dd71ff
checked watcher_age=1793195843s alarms=1
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76

Persisted product alarm text:

```text
REPLY DELIVERY UNVERIFIED q-server: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.
```

Pass 3: exit 0; cursor 31; pending []; read_fails {}; active incidents [].

```text
checked watcher_age=1793195843s alarms=0
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 75

Persisted product alarm text:

```text
REPLY DELIVERY UNVERIFIED q-server: bounded remote/local timestamp read failed; inspect delivery before assuming caught up.
```

## bounded-preemption-retry

Three preemptions retry exactly the same cursor; fourth attempt executes real reader and reports lag without read failure.

Pass 1: exit 0; cursor 73; pending [1793192238]; read_fails {}; active incidents ['lag-q-server', 'recovery'].

```text
BACKSTOP ALARM HELD: backstop-c9870af5bb124b5595bfe2edc8f3d81a
BACKSTOP ALARM HELD: backstop-bea689da5b9e411fa3a9274d77d98483
checked watcher_age=1793195843s alarms=2
```

- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 76
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 31 b06bea00435b5b0385ca6ccc2811854539aff1b4766d1c6c33474c6b056ba104` → exit 0; response delta at offset 73
- Remote invocation: `fm-remote-delta-read.sh state/parent-replies.status 73 a62d3e0c4d4e0d19510866f91c808fe06d9e0548a3c600f4c55c634bad21e82b` → exit 75

Persisted product alarm text:

```text
BACKSTOP HELD: reply lag: q-server
REPLY DELIVERY LAG q-server: 3605s (oldest_at=1793192238 ingested_at=1793190838); primary wake path needs recovery.
```

