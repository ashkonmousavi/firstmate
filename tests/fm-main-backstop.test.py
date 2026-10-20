"""End-to-end backstop cases: fake transports, real durable inbox and processes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(os.environ['ROOT'])


class Backstop(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fm-main-backstop-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / 'home'
        self.state = self.home / 'state'
        self.code = self.base / 'code'
        self.fake = self.base / 'fake'
        for path in [self.state, self.home / 'data', self.code / 'bin', self.fake]:
            path.mkdir(parents=True)
        self.executable(self.code / 'bin/fm-inbox.sh', '#!/bin/bash\nexec \"' + str(ROOT / 'bin/fm-inbox.sh') + '\" \"$@\"\n')
        (self.state / 'example.meta').touch()
        (self.state / '.last-watcher-beat').touch()
        os.utime(self.state / '.last-watcher-beat', (time.time() - 600,) * 2)
        (self.home / 'data/main-pane').write_text('dead:old\n')
        self.fixture = self.base / 'fixture.json'
        self.calls = self.base / 'calls.jsonl'
        self.config = {'agent': 'claude', 'process': 'claude', 'remote': 1000,
                       'local': 1000, 'fail_send': False, 'panes': 1}
        (self.state / 'q-server.status').write_text('working [at=1000]: caught up\n')
        self.executable(self.fake / 'herdr', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
c=json.loads(Path(os.environ['BACKSTOP_FIXTURE']).read_text())
a=sys.argv[1:]
with open(os.environ['BACKSTOP_CALLS'],'a') as f:f.write(json.dumps(a)+'\\n')
if a==['pane','list']:
 p={'pane_id':'live:p1','agent':c['agent'],'cwd':os.environ['FM_HOME']}
 print(json.dumps({'result':{'panes':[p]*c['panes']}}))
elif a[:2]==['pane','process-info']:
 print(json.dumps({'result':{'process_info':{'foreground_processes':[{'name':c['process'],'pid':os.getppid(),'cwd':os.environ['FM_HOME']}]}}}))
elif a[:2] in (['pane','send-text'],['pane','send-keys']):
 sys.exit(1 if c['fail_send'] else 0)
else:sys.exit(2)
''')
        self.executable(self.code / 'bin/fm-on.sh', '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
c=json.loads(Path(os.environ['BACKSTOP_FIXTURE']).read_text())
remote=Path(os.environ['BACKSTOP_REMOTE'])
(remote/'state').mkdir(parents=True,exist_ok=True)
status=remote/'state/parent-replies.status'
if c.get('remote_missing'):
    status.unlink(missing_ok=True)
elif 'remote_file' in c:
    status.write_text(c['remote_file'])
else:
    status.write_text('working [at=%d]: remote reply\\n' % c['remote'])
if c.get('fail_reads',0)>0:
    counter=Path(os.environ['BACKSTOP_REMOTE_FAILS'])
    n=int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n+1))
    if n<c['fail_reads']:
        sys.exit(1)
command=sys.argv[2]
with open(os.environ['BACKSTOP_CALLS'],'a') as f:f.write(json.dumps(['reader',command]+sys.argv[3:])+'\\n')
os.environ['FM_HOME']=str(remote)
real=str(Path(os.environ['BACKSTOP_ROOT'])/'bin'/command)
os.execv(real,[command]+sys.argv[3:])
''')
        self.env = dict(os.environ, FM_HOME=str(self.home),
                        PATH=str(self.fake) + ':' + os.environ['PATH'],
                        BACKSTOP_FIXTURE=str(self.fixture), BACKSTOP_CALLS=str(self.calls),
                        BACKSTOP_REMOTE=str(self.base / 'remote'),
                        BACKSTOP_ROOT=str(ROOT),
                        BACKSTOP_REMOTE_FAILS=str(self.base / 'remote-fails.txt'))
        # No test inherits a real operational state override.
        for key in ['FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE']:
            self.env.pop(key, None)

    def executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_guard(self):
        self.fixture.write_text(json.dumps(self.config))
        result = subprocess.run(['python3', str(ROOT / 'bin/fm-main-backstop.py'),
                                 '--home', str(self.home), '--code-root', str(self.code),
                                 '--mate', 'q-server'], env=self.env,
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def commands(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def reader_calls(self):
        return [c for c in self.commands() if c[0] == 'reader']

    def memory(self):
        return json.loads((self.state / '.main-backstop.json').read_text())

    def notes(self):
        return '\n'.join(p.read_text() for p in (self.state / 'inbox').glob('*.note'))

    def test_stale_saved_pane_is_ignored_and_live_agent_nudged(self):
        self.run_guard()
        sends = [c for c in self.commands() if c[:2] == ['pane', 'send-text']]
        self.assertEqual(len(sends), 1)
        self.assertEqual(sends[0][2], 'live:p1')
        self.assertEqual((self.home / 'data/main-pane').read_text().strip(), 'live:p1')
        self.run_guard()
        self.assertEqual(len([c for c in self.commands() if c[:2] == ['pane','send-text']]), 1)

    def test_shell_pane_is_never_typed_into_and_alarm_reaches_drain(self):
        self.config['process'] = 'bash'
        self.run_guard()
        self.assertFalse(any(c[:2] == ['pane','send-text'] for c in self.commands()))
        self.assertIn('BACKSTOP FAILURE', self.notes())
        self.assertIn('no verified live primary', self.notes())
        queue = (self.state / '.wake-queue').read_text()
        self.assertIn('BACKSTOP FAILURE', queue)
        (self.state / 'example.meta').unlink()
        drain = subprocess.run([str(ROOT / 'bin/fm-wake-drain.sh')], env=self.env,
                               capture_output=True, text=True, timeout=20)
        self.assertIn('BACKSTOP FAILURE', drain.stdout)
        before = len(list((self.state / 'inbox').glob('*.note')))
        self.run_guard()
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before)

    def test_failed_nudge_is_durable(self):
        self.config['fail_send'] = True
        self.run_guard()
        self.assertIn('primary nudge failed', self.notes())

    def test_reply_lag_above_fifteen_minutes_alarms_even_with_fresh_beat(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1901
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 901s', self.notes())
        self.assertIn('REPLY DELIVERY LAG', (self.state / '.wake-queue').read_text())

    def test_exact_fifteen_minute_lag_does_not_alarm(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1900
        self.run_guard()
        self.assertEqual(self.notes(), '')

    def test_healthy_beat_and_caught_up_reply_are_quiet(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertFalse(any(c[:2] == ['pane','send-text'] for c in self.commands()))

    def register_runner(self, content):
        pe = self.state / 'procevent'
        pe.mkdir(exist_ok=True)
        (pe / 'remote-reply-q-server.source').touch()
        (pe / 'remote-reply-q-server.runner').write_text(content)

    def live_runner(self):
        # Python keeps its argv in /proc/<pid>/cmdline, matching a real
        # `fm-procevent.sh _start remote-reply-<mate>` runner's identity.
        runner = subprocess.Popen(['python3', '-c', 'import time; time.sleep(300)',
                                   '_start', 'remote-reply-q-server'])
        self.addCleanup(runner.wait)
        self.addCleanup(runner.kill)
        return runner.pid

    def sends(self):
        return [c for c in self.commands() if c[:2] == ['pane', 'send-text']]

    def test_single_not_alive_runner_pass_is_tolerated_without_alarm(self):
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('999999999\n')
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertEqual(self.sends(), [])
        self.assertIn('runner not alive once, tolerating one pass: q-server',
                      (self.state / '.main-backstop.log').read_text())

    def test_empty_runner_record_counts_as_one_not_alive_pass(self):
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('')
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.run_guard()
        self.assertIn('REPLY RUNNER DOWN q-server', self.notes())

    def test_two_consecutive_not_alive_runner_passes_alarm_then_dedup(self):
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('999999999\n')
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.run_guard()
        self.assertIn('REPLY RUNNER DOWN q-server', self.notes())
        self.assertIn('REPLY RUNNER DOWN', (self.state / '.wake-queue').read_text())
        self.assertEqual(len(self.sends()), 1)
        before = len(list((self.state / 'inbox').glob('*.note')))
        self.run_guard()
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before)

    def test_live_runner_pass_clears_the_not_alive_streak(self):
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('999999999\n')
        self.run_guard()
        self.register_runner('%d\n' % self.live_runner())
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertNotIn('q-server', self.memory().get('runner_fails', {}))
        self.register_runner('999999999\n')
        self.run_guard()
        self.assertEqual(self.notes(), '')

    def test_remote_source_larger_than_transfer_bound_still_verifies(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = ''.join(
            'working [at=%d]: reply %d\n' % (5000 + i * 60, i) for i in range(40000))
        self.assertGreater(len(self.config['remote_file']), 1048576)
        newest = 5000 + 39999 * 60
        (self.state / 'q-server.status').write_text('done [at=%d]: caught up\n' % newest)
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertEqual(self.memory()['readers']['q-server']['stamp'], newest)
        cold_calls = len(self.reader_calls())
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertEqual(len(self.reader_calls()), cold_calls + 1)

    def test_lag_alarm_carries_exact_stamp_from_over_bound_source(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = ''.join(
            'working [at=%d]: reply %d\n' % (5000 + i * 60, i) for i in range(40000))
        newest = 5000 + 39999 * 60
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: %ds (remote_at=%d ingested_at=1000)'
                      % (newest - 1000, newest), self.notes())

    def test_steady_state_reads_only_appended_lines(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.assertEqual(self.notes(), '')
        cold_calls = len(self.reader_calls())
        self.config['remote_file'] = ('working [at=1000]: remote reply\n'
                                      'done [at=1901]: newer reply\n')
        self.run_guard()
        self.assertEqual(len(self.reader_calls()), cold_calls + 2)
        self.assertIn('REPLY DELIVERY LAG q-server: 901s (remote_at=1901 ingested_at=1000)',
                      self.notes())

    def test_unicode_and_crlf_preserve_transport_cursor(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = 'working [at=1000]: café\r\n'
        self.run_guard()
        self.config['remote_file'] += 'done [at=1901]: café\r\n'
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 901s', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_unicode_oversized_bootstrap_reaches_tail(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = 'working [at=1000]: café\n' * 50000
        self.config['remote_file'] += 'done [at=1901]: café\n'
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 901s', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))

    def test_replaced_log_resyncs_byte_cursor(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = 'done [at=1901]: café\r\n'
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 901s', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_multi_chunk_backlog_reports_tail_lag(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = ('working [at=1000]: remote reply\n' +
                                      'working [at=1200]: backlog\n' * 5000 +
                                      'done [at=3000]: latest\n')
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 2000s', self.notes())
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_over_budget_backlog_stays_unverified_until_tail(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = ('working [at=1000]: remote reply\n' +
                                      'working [at=1200]: backlog\n' * 22000 +
                                      'done [at=3000]: latest\n')
        self.run_guard()
        self.assertIn('q-server', self.memory()['read_fails'])
        self.assertEqual(self.notes(), '')
        self.run_guard()
        self.assertIn('REPLY DELIVERY UNVERIFIED q-server', self.notes())
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 2000s', self.notes())
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_single_transient_read_failure_is_tolerated_without_alarm(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['fail_reads'] = 1
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertIn('tolerating one pass', (self.state / '.main-backstop.log').read_text())
        self.config['fail_reads'] = 0
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertNotIn('q-server', self.memory().get('read_fails', {}))

    def test_two_consecutive_read_failures_alarm_then_dedup_and_clear(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['fail_reads'] = 99
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.run_guard()
        self.assertIn('REPLY DELIVERY UNVERIFIED q-server', self.notes())
        self.assertIn('REPLY DELIVERY UNVERIFIED',
                      (self.state / '.wake-queue').read_text())
        before = len(list((self.state / 'inbox').glob('*.note')))
        self.run_guard()
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before)
        self.config['fail_reads'] = 0
        self.run_guard()
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before)
        self.assertNotIn('q-server', self.memory().get('read_fails', {}))

    def test_lag_incident_survives_inconclusive_reads_until_caught_up(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1901
        self.run_guard()
        incident = self.memory()['episodes']['lag-q-server']
        self.config['fail_reads'] = 99
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertIn('read-q-server', self.memory()['episodes'])
        before = len(list((self.state / 'inbox').glob('*.note')))
        self.config['fail_reads'] = 0
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertNotIn('read-q-server', self.memory()['episodes'])
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before)
        (self.state / 'q-server.status').write_text('done [at=1901]: caught up\n')
        self.run_guard()
        self.assertNotIn('lag-q-server', self.memory()['episodes'])
        self.config['remote'] = 3000
        self.run_guard()
        self.assertNotEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before + 1)

    def test_runner_incident_clears_only_on_a_live_or_unregistered_runner(self):
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('999999999\n')
        self.run_guard()
        self.run_guard()
        incident = self.memory()['episodes']['runner-q-server']
        self.config['fail_reads'] = 99
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['runner-q-server'], incident)
        self.config['fail_reads'] = 0
        self.register_runner('%d\n' % self.live_runner())
        self.run_guard()
        self.assertNotIn('runner-q-server', self.memory()['episodes'])
        self.register_runner('999999999\n')
        self.run_guard()
        self.run_guard()
        self.assertNotEqual(self.memory()['episodes']['runner-q-server'], incident)
        (self.state / 'procevent/remote-reply-q-server.source').unlink()
        self.run_guard()
        self.assertNotIn('runner-q-server', self.memory()['episodes'])

    def test_recovery_incident_survives_inconclusive_pass_and_nudge_cooldown(self):
        self.config['fail_send'] = True
        self.run_guard()
        incident = self.memory()['episodes']['recovery']
        (self.state / '.last-watcher-beat').touch()
        self.config['fail_reads'] = 99
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['recovery'], incident)
        self.config['fail_reads'] = 0
        self.config['remote'] = 1901
        self.config['fail_send'] = False
        memory = self.memory()
        memory['last_nudge'] = int(time.time())
        (self.state / '.main-backstop.json').write_text(json.dumps(memory))
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['recovery'], incident)
        memory = self.memory()
        memory['last_nudge'] = 0
        (self.state / '.main-backstop.json').write_text(json.dumps(memory))
        self.run_guard()
        self.assertNotIn('recovery', self.memory()['episodes'])

    def test_recovery_incident_clears_when_all_checks_are_healthy(self):
        self.config['fail_send'] = True
        self.run_guard()
        self.assertIn('recovery', self.memory()['episodes'])
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.assertNotIn('recovery', self.memory()['episodes'])

    def test_ambiguous_live_primary_is_not_guessed(self):
        self.config['panes'] = 2
        self.run_guard()
        self.assertFalse(any(c[:2] == ['pane','send-text'] for c in self.commands()))
        self.assertIn('BACKSTOP FAILURE', self.notes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
