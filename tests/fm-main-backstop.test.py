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
(remote/'state/parent-replies.status').write_text('working [at=%d]: remote reply\\n' % c['remote'])
os.environ['FM_HOME']=str(remote)
reader=os.environ['BACKSTOP_READER']
os.execv(reader,[reader]+sys.argv[3:])
''')
        self.env = dict(os.environ, FM_HOME=str(self.home),
                        PATH=str(self.fake) + ':' + os.environ['PATH'],
                        BACKSTOP_FIXTURE=str(self.fixture), BACKSTOP_CALLS=str(self.calls),
                        BACKSTOP_REMOTE=str(self.base / 'remote'),
                        BACKSTOP_READER=str(ROOT / 'bin/fm-remote-file.sh'))
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

    def test_dead_runner_is_alarmed(self):
        (self.state / '.last-watcher-beat').touch()
        pe = self.state / 'procevent'
        pe.mkdir()
        (pe / 'remote-reply-q-server.source').touch()
        (pe / 'remote-reply-q-server.runner').write_text('999999999\n')
        self.run_guard()
        self.assertIn('REPLY RUNNER DOWN q-server', self.notes())

    def test_ambiguous_live_primary_is_not_guessed(self):
        self.config['panes'] = 2
        self.run_guard()
        self.assertFalse(any(c[:2] == ['pane','send-text'] for c in self.commands()))
        self.assertIn('BACKSTOP FAILURE', self.notes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
