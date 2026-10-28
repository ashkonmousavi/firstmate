# Backstop live validation

The target passed every exercised acceptance scenario. The real cron CLI ran with disposable homes and mate logs. Its real fm-on route used OpenSSH to a loopback AsyncSSH endpoint; that endpoint decoded the read request and executed the repository's actual fm-remote-file.sh or fm-remote-delta-read.sh against the disposable mate home. It supplied no fabricated log data, reader protocol records, or backstop decisions. SSH queue installation and Herdr lifecycle were outside the changed surface and were not exercised.

Send permission was deliberately absent, so lag and corruption alarms were retained in the product's persisted deferred-alarm journal. No operator home, fleet pane, real mate, or credentials were used.

## Results

- PASS: Whole-file multiline replies and mirror accept plain and grammar-rejected continuation lines.
- PASS: Nonzero delta cursor accepts leading continuations, tracks UTF-8 byte length, and clears mirrored replies.
- PASS: Offset-zero delta accepts a parsed head followed by multiline content.
- PASS: Corrupt leading lines fail whole-file, offset-zero delta, and local mirror reads without committing cursor progress or clearing lag.
- PASS: Legacy list state runs cleanly, preserves last_nudge, and reboots obsolete reader records.
- PASS: Non-dict legacy bookkeeping resets while a valid byte cursor and last_nudge survive.
- PASS: Multiline reads retain the oldest unmirrored reply and report delivery lag instead of claiming caught up.
- PASS: Regression reproduction on base commit.

## Evidence

`live-backstop.json` retains each CLI command, exit status, stdout, stderr, final persisted journal, and actual remote reader invocation. `live-backstop.log` is the CLI transcript. `drive-backstop.py` reproduces the disposable setup and assertions. Expected timestamps come from explicit input epochs; expected offsets come from the input bytes, independently of backstop internals. The corrupt-head checks reject lost cursor progress and falsely cleared lag incidents.

The base commit b1d56ea04800102e9718ff266d57992bcd5ac70a failed the whole-file and nonzero-delta multiline reads and crashed with `TypeError: pop expected at most 1 argument, got 2` on list-shaped state. The first evidence-driver run incorrectly expected AttributeError for that crash; its actual retained stderr identified TypeError. The driver assertion was corrected, and the complete live run then exited 0. Target product code required no fixes.

## Targeted existing tests

The following command exited 0 (9 tests, 66.472 seconds). These tests use fake transport boundaries and supplement the separate live CLI run.

```sh
env ROOT="$PWD" TMPDIR="$PWD/.test-backstop-tmp" python3 tests/fm-main-backstop.test.py \
 Backstop.test_legacy_list_shaped_state_migrates_and_runs_one_pass \
 Backstop.test_multiline_reply_entries_read_as_continuations_from_the_head \
 Backstop.test_delta_window_beginning_mid_entry_reads_continuations \
 Backstop.test_invalid_leading_remote_line_does_not_commit_delta_progress \
 Backstop.test_invalid_mirror_timestamp_is_unverified_without_clearing_incident \
 Backstop.test_unicode_and_crlf_preserve_transport_cursor \
 Backstop.test_unicode_oversized_bootstrap_reaches_tail \
 Backstop.test_replaced_log_resyncs_byte_cursor \
 Backstop.test_remote_source_larger_than_transfer_bound_still_verifies
```

## Reproduce the live check

From the run worktree, materialize an isolated dependency then run:

```sh
mkdir -p .test-backstop-tmp
python3 -m pip install --target .test-backstop-tmp/deps asyncssh==2.24.1
PYTHONPATH="$PWD/.test-backstop-tmp/deps" python3 ~/.no-mistakes/evidence/01M60T561RQMM90GG5HE30QFGQ/drive-backstop.py
rm -rf .test-backstop-tmp
```

All required children completed. The loopback SSH listener was closed and disposable homes removed in the driver finally block. The locally materialized dependencies were removed after validation. This is a CLI/state change, so no screenshot is applicable.
