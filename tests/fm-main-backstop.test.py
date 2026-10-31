"""End-to-end backstop cases: fake transports, real durable inbox and processes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(os.environ['ROOT'])
HAS_PROC_RUNNER = all(os.access('/proc/self/' + name, os.R_OK)
                      for name in ('stat', 'cmdline'))


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
        self.executable(self.code / 'bin/fm-backend.sh',
                        'export PATH=' + shlex.quote(str(self.fake)) + ':$PATH\n'
                        '. ' + repr(str(ROOT / 'bin/fm-backend.sh')) + '\n')
        (self.state / 'example.meta').touch()
        (self.state / '.last-watcher-beat').touch()
        os.utime(self.state / '.last-watcher-beat', (time.time() - 600,) * 2)
        (self.home / 'data/main-pane').write_text('dead:old\n')
        self.now = 5000
        os.utime(self.state / '.last-watcher-beat', (4400, 4400))
        self.fixture = self.base / 'fixture.json'
        self.calls = self.base / 'calls.jsonl'
        self.config = {'agent': 'claude', 'process': 'claude', 'remote': 1000,
                       'local': 1000, 'fail_send': False, 'panes': 1, 'draft': ''}
        (self.state / 'q-server.status').write_text('working [at=1000]: caught up\n')
        (self.state / '.remote-reply-mirrored-q-server').write_text('working [at=1000]: caught up\n')
        self.executable(self.fake / 'herdr', '''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
c=json.loads(Path(os.environ['BACKSTOP_FIXTURE']).read_text())
a=sys.argv[1:]
if a[-2:-1]==['--session']:a=a[:-2]
with open(os.environ['BACKSTOP_CALLS'],'a') as f:f.write(json.dumps(a)+'\\n')
if a==['pane','list']:
 if c.get('revoke_on_discovery'):Path(os.environ['BACKSTOP_SEND_FILE']).unlink(missing_ok=True)
 p={'pane_id':'live:p1','agent':c['agent'],'cwd':os.environ['FM_HOME']}
 print(json.dumps({'result':{'panes':[p]*c['panes']}}))
elif a[:2]==['pane','process-info']:
 p={'name':c['process'],'pid':os.getppid(),'cwd':os.environ['FM_HOME']}
 if 'process_pid' in c:
  name=subprocess.check_output(['ps','-p',str(c['process_pid']),'-o','comm='],text=True).strip()
  p={'name':Path(name).name,'pid':c['process_pid'],'cwd':c['process_cwd']}
 print(json.dumps({'result':{'process_info':{'foreground_processes':[p]}}}))
elif a[:2]==['status','--json']:
 print(json.dumps({'server':{'running':True}}))
elif a[:2]==['agent','get']:
 print(json.dumps({'result':{'agent':{'agent':c['agent'],'agent_status':c.get('status','idle')}}}))
elif a[:2]==['pane','get']:
 print(json.dumps({'result':{'pane':{'pane_id':a[2],'scroll':{'offset_from_bottom':0}}}}))
elif a[:2]==['pane','read']:
 if c.get('unreadable'):sys.exit(1)
 glyph='❯' if c['agent']=='claude' else '›'
 print('────────────────────────')
 print(glyph+' '+c['draft'])
 print('────────────────────────')
elif a[:2]==['pane','send-text']:
 if c['fail_send']:sys.exit(1)
 c['draft']+=a[3]
 Path(os.environ['BACKSTOP_FIXTURE']).write_text(json.dumps(c))
elif a[:2]==['pane','send-keys']:
 if c['fail_send']:sys.exit(1)
 if a[3]=='enter' and not c.get('hold_enter'):
  c.setdefault('submitted',[]).append(c['draft'])
  c['draft']=''
  c['status']='working'
 elif a[3]=='ctrl+u':c['draft']=''
 Path(os.environ['BACKSTOP_FIXTURE']).write_text(json.dumps(c))
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
if command=='fm-remote-delta-read.sh' and c.get('preempt_delta',0)>0:
    counter=Path(os.environ['BACKSTOP_PREEMPTS'])
    n=int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n+1))
    if n<c['preempt_delta']:
        sys.exit(76)
if command=='fm-remote-delta-read.sh' and c.get('stuck_delta',0)>0:
    sys.stdout.write('schema=fm-remote-delta.v1\\nstatus=delta\\nto_offset=%s\\npayload_bytes=0\\nto_prefix_sha256=%s\\n\\n' % (sys.argv[4],sys.argv[5]))
    sys.exit(0)
os.environ['FM_HOME']=str(remote)
real=str(Path(os.environ['BACKSTOP_ROOT'])/'bin'/command)
os.execv(real,[command]+sys.argv[3:])
''')
        self.env = dict(os.environ, FM_HOME=str(self.home),
                        PATH=str(self.fake) + ':' + os.environ['PATH'],
                        BACKSTOP_FIXTURE=str(self.fixture), BACKSTOP_CALLS=str(self.calls),
                        BACKSTOP_REMOTE=str(self.base / 'remote'),
                        BACKSTOP_ROOT=str(ROOT),
                        BACKSTOP_REMOTE_FAILS=str(self.base / 'remote-fails.txt'),
                        BACKSTOP_PREEMPTS=str(self.base / 'preempts.txt'))
        self.send_enabled_file = None
        # No test inherits a real operational state override.
        for key in ['FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE']:
            self.env.pop(key, None)

    def executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_guard(self):
        self.fixture.write_text(json.dumps(self.config))
        argv = ['python3', '-c',
                                 'import runpy,sys,time; clock=float(sys.argv.pop(1)); time.time=lambda:clock; '
                                 'sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__")',
                                 str(self.now), str(ROOT / 'bin/fm-main-backstop.py'),
                                 '--home', str(self.home), '--code-root', str(self.code),
                                 '--mate', 'q-server']
        if self.send_enabled_file is not None:
            argv += ['--send-enabled-file', str(self.send_enabled_file)]
        result = subprocess.run(argv, env=self.env,
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def select_send_file(self, content=b'enabled\n'):
        config = self.home / 'config'
        config.mkdir(exist_ok=True)
        config.chmod(0o700)
        self.send_enabled_file = config / 'main-backstop-send-enabled'
        self.send_enabled_file.write_bytes(content)
        self.send_enabled_file.chmod(0o600)
        self.env['BACKSTOP_SEND_FILE'] = str(self.send_enabled_file)
        return self.send_enabled_file

    def assert_observe_only(self):
        self.assertEqual(self.notes(), '')
        self.assertFalse((self.state / '.wake-queue').exists())
        self.assertFalse(any(c[0] in ('pane', 'agent') for c in self.commands()))
        self.assertEqual(self.sends(), [])
        self.assertNotIn('last_nudge', self.memory())
        self.assertEqual((self.home / 'data/main-pane').read_text(), 'dead:old\n')

    def test_nested_backend_shell_uses_recording_transport(self):
        selected = self.select_send_file()
        self.assertTrue(selected.exists())
        probe = subprocess.run(['bash', '-c', '. "$1"; command -v herdr', 'fixture',
                                str(self.code / 'bin/fm-backend.sh')], env=self.env,
                               capture_output=True, text=True, timeout=5)
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertEqual(probe.stdout.strip(), str(self.fake / 'herdr'))

    def test_selected_missing_or_malformed_capability_keeps_watcher_observe_only(self):
        selected = self.select_send_file()
        selected.unlink()
        self.run_guard()
        self.assert_observe_only()
        self.assertIn(self.memory()['episodes']['recovery'], self.memory()['deferred_alarms'])

    def test_held_incident_keeps_identity_until_enabled_note(self):
        selected = self.select_send_file()
        selected.unlink()
        self.run_guard()
        incident = self.memory()['episodes']['recovery']
        self.assertIn(self.memory()['episodes']['recovery'], self.memory()['deferred_alarms'])
        selected.write_bytes(b'enabled\n')
        selected.chmod(0o600)
        self.run_guard()
        self.assertIn('BACKSTOP HELD', self.notes())
        self.assertIn(incident, self.notes())
        self.assertNotIn(incident, self.memory()['deferred_alarms'])

    def check_distinct_incidents_across_stop(self, kind):
        selected = self.select_send_file()
        self.config['process'] = 'bash'
        (self.state / '.last-watcher-beat').touch()
        key = kind + '-q-server' if kind != 'recovery' else kind

        def trigger():
            if kind == 'runner':
                self.register_runner('999999999\n')
            elif kind == 'lag':
                self.config['remote'] += 60
            elif kind == 'read':
                self.config['fail_reads'] = 100
            else:
                os.utime(self.state / '.last-watcher-beat', (4400, 4400))
            self.run_guard()
            self.run_guard()

        def resolve():
            if kind == 'runner':
                (self.state / 'procevent/remote-reply-q-server.source').unlink()
            elif kind == 'lag':
                (self.state / '.remote-reply-mirrored-q-server').write_text(
                    'done [at=%d]: mirrored\n' % self.config['remote'])
            elif kind == 'read':
                self.config['fail_reads'] = 0
            else:
                (self.state / '.last-watcher-beat').touch()
            self.run_guard()

        trigger()
        first = self.memory()['episodes'][key]
        self.assertIn(first, self.notes())
        selected.unlink()
        self.run_guard()
        resolve()
        self.assertNotIn(key, self.memory()['episodes'])
        self.assertIn(first, self.memory()['deferred_alarms'])
        trigger()
        second = self.memory()['episodes'][key]
        self.assertNotEqual(first, second)
        self.assertNotIn(second, self.notes())
        self.select_send_file()
        self.run_guard()
        self.assertIn(second, self.notes())
        self.assertEqual(self.notes().count('request_id=' + first), 1)
        self.assertEqual(self.notes().count('request_id=' + second), 1)
        self.assertEqual(self.memory()['deferred_alarms'], {})

    def test_runner_resolution_releases_identity_during_stop(self):
        self.check_distinct_incidents_across_stop('runner')

    def test_lag_resolution_releases_identity_during_stop(self):
        self.check_distinct_incidents_across_stop('lag')

    def test_read_resolution_releases_identity_during_stop(self):
        self.check_distinct_incidents_across_stop('read')

    def test_recovery_resolution_releases_identity_during_stop(self):
        self.check_distinct_incidents_across_stop('recovery')

    def test_resolved_held_incidents_both_deliver_after_resume(self):
        selected = self.select_send_file()
        selected.unlink()
        self.run_guard()
        first = self.memory()['episodes']['recovery']
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        os.utime(self.state / '.last-watcher-beat', (4000, 4000))
        self.run_guard()
        second = self.memory()['episodes']['recovery']
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.assertNotEqual(first, second)
        self.assertEqual(self.notes(), '')
        self.select_send_file()
        self.run_guard()
        self.assertIn(first, self.notes())
        self.assertIn(second, self.notes())
        self.assertIn('watcher silent for 600s', self.notes())
        self.assertIn('watcher silent for 1000s', self.notes())
        self.assertEqual(self.memory()['deferred_alarms'], {})

    def test_legacy_deferred_alarm_keeps_original_delivery_identity(self):
        selected = self.select_send_file()
        selected.unlink()
        journal = self.state / '.main-backstop.json'
        journal.write_text(json.dumps({
            'episodes': {'recovery': 'backstop-original'},
            'deferred_alarms': {'recovery': 'original held incident'}}))
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.assertNotIn('recovery', self.memory()['episodes'])
        self.select_send_file()
        self.run_guard()
        self.assertIn('backstop-original', self.notes())
        self.assertIn('original held incident', self.notes())
        self.assertEqual(self.memory()['deferred_alarms'], {})

    def test_legacy_list_shaped_state_migrates_and_runs_one_pass(self):
        (self.state / '.last-watcher-beat').touch()
        (self.state / '.main-backstop.json').write_text(json.dumps({
            'episodes': [], 'last_nudge': 4700, 'read_fails': [],
            'runner_fails': [],
            'readers': {'q-server': {'offset': 12, 'prefix': 'a' * 64,
                                     'stamp': 1000}}}))
        self.run_guard()
        memory = self.memory()
        self.assertEqual(memory['episodes'], {})
        self.assertEqual(memory['read_fails'], {})
        self.assertEqual(memory['runner_fails'], {})
        self.assertEqual(memory['last_nudge'], 4700)
        self.assertEqual(memory['readers']['q-server']['offset'],
                         len('working [at=1000]: remote reply\n'))
        self.assertEqual(memory['readers']['q-server']['pending_at'], [])
        self.assertEqual(self.notes(), '')

    def test_selected_valid_capability_is_recognized(self):
        selected = self.select_send_file()
        spec = importlib.util.spec_from_file_location('backstop_candidate', ROOT / 'bin/fm-main-backstop.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.send_capability_enabled(self.home, selected))

    def test_selected_valid_capability_allows_confirmed_nudge(self):
        self.select_send_file()
        self.run_guard()
        self.assertTrue(any(c[:2] == ['pane', 'read'] for c in self.commands()))
        self.assertEqual(len(self.sends()), 1)
        self.assertIn('last_nudge', self.memory())

    def test_malformed_large_and_symlink_capabilities_refuse_send(self):
        for contents in (b'enabled', b'enabled\nextra', b'x' * 1024):
            with self.subTest(contents=contents[:12]):
                self.select_send_file(contents)
                self.run_guard()
                self.assert_observe_only()
        selected = self.send_enabled_file
        selected.unlink()
        target = self.base / 'enabled-target'
        target.write_bytes(b'enabled\n')
        selected.symlink_to(target)
        self.run_guard()
        self.assert_observe_only()
        selected.unlink()
        selected.write_bytes(b'enabled\n')
        (self.home / 'config').chmod(0o777)
        self.run_guard()
        self.assert_observe_only()

    def test_fifo_capability_is_rejected_without_blocking(self):
        selected = self.select_send_file()
        selected.unlink()
        os.mkfifo(selected, 0o600)
        program = (
            'import importlib.util,sys; from pathlib import Path; '
            'spec=importlib.util.spec_from_file_location("backstop_fifo",sys.argv[1]); '
            'module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); '
            'print(module.send_capability_enabled(Path(sys.argv[2]),Path(sys.argv[3])))'
        )
        child = subprocess.run(
            ['python3', '-c', program, str(ROOT / 'bin/fm-main-backstop.py'),
             str(self.home), str(selected)], env=self.env,
            capture_output=True, text=True, timeout=2)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(child.stdout.strip(), 'False')

    def test_disabled_runner_and_lag_incidents_keep_cursors_without_notes(self):
        self.send_enabled_file = self.home / 'config/main-backstop-send-enabled'
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('999999999\n')
        self.config['remote'] = 1001
        self.run_guard()
        self.run_guard()
        self.assert_observe_only()
        memory = self.memory()
        self.assertIn('q-server', memory['runner_fails'])
        self.assertEqual(memory['lag_oldest']['q-server'], 1001)
        self.assertEqual(memory['readers']['q-server']['pending_at'], [1001])

    def test_disabled_read_failure_does_not_write_alarm_or_drop_incident(self):
        self.send_enabled_file = self.home / 'config/main-backstop-send-enabled'
        (self.state / '.last-watcher-beat').touch()
        self.config['fail_reads'] = 2
        self.run_guard()
        self.run_guard()
        self.assert_observe_only()
        self.assertIn('q-server', self.memory()['read_fails'])

    def test_revocation_during_discovery_refuses_submission_and_note(self):
        self.select_send_file()
        self.config['revoke_on_discovery'] = True
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertNotIn('last_nudge', self.memory())
        self.assertEqual(self.notes(), '')

    def test_wrong_owner_capability_is_refused_by_reader(self):
        selected = self.select_send_file()
        spec = importlib.util.spec_from_file_location('backstop_candidate', ROOT / 'bin/fm-main-backstop.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = os.stat(selected)
        values = list(original)
        values[4] = original.st_uid + 1
        with patch.object(module.os, 'fstat', return_value=os.stat_result(values)):
            self.assertFalse(module.send_capability_enabled(self.home, selected))

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
        observed = json.loads(self.fixture.read_text())
        self.assertEqual(observed.get('submitted'), [sends[0][3]])
        self.assertEqual(observed['draft'], '')
        self.assertEqual((self.home / 'data/main-pane').read_text().strip(), 'live:p1')
        self.run_guard()
        self.assertEqual(len([c for c in self.commands() if c[:2] == ['pane','send-text']]), 1)

    def test_pending_primary_draft_is_preserved_and_recovery_alarms(self):
        for harness in ('claude', 'codex'):
            with self.subTest(harness=harness):
                self.config.update(agent=harness, process=harness, draft='unfinished owner draft')
                self.run_guard()
                observed = json.loads(self.fixture.read_text())
                self.assertEqual(observed['draft'], 'unfinished owner draft')
                self.assertEqual(observed.get('submitted', []), [])
                self.assertEqual(self.sends(), [])
                self.assertFalse(any(c[:2] == ['pane', 'send-keys'] for c in self.commands()))
                self.assertIn('BACKSTOP FAILURE', self.notes())
                self.assertIn('BACKSTOP FAILURE', (self.state / '.wake-queue').read_text())
                self.assertNotIn('last_nudge', self.memory())

    def test_empty_codex_primary_uses_confirmed_submission(self):
        self.config.update(agent='codex', process='codex')
        self.run_guard()
        observed = json.loads(self.fixture.read_text())
        self.assertEqual(len(observed.get('submitted', [])), 1)
        self.assertTrue(observed['submitted'][0].startswith('[backstop] watcher silent'))
        self.assertEqual(observed['draft'], '')
        self.assertIn('last_nudge', self.memory())

    def test_unconfirmed_submission_does_not_advance_nudge_time(self):
        self.config['hold_enter'] = True
        self.run_guard()
        observed = json.loads(self.fixture.read_text())
        self.assertEqual(observed.get('submitted', []), [])
        self.assertNotIn('last_nudge', self.memory())
        self.assertIn('BACKSTOP FAILURE', self.notes())

    def test_unreadable_composer_refuses_nudge(self):
        self.config['unreadable'] = True
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertNotIn('last_nudge', self.memory())
        self.assertIn('BACKSTOP FAILURE', self.notes())

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

    def test_stale_harness_labels_over_a_real_shell_refuse_nudges(self):
        with subprocess.Popen(['bash', '--noprofile', '--norc', '-c',
                               'pwd -P; read -r pending'], cwd=self.home,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              text=True) as shell:
            observed_cwd = shell.stdout.readline().strip()
            self.assertEqual(Path(observed_cwd), self.home.resolve())
            observed_name = subprocess.check_output(
                ['ps', '-p', str(shell.pid), '-o', 'comm='], text=True).strip()
            self.assertEqual(Path(observed_name).name, 'bash')
            self.config.update(process_pid=shell.pid, process_cwd=observed_cwd)
            for harness in ('claude', 'codex'):
                with self.subTest(harness=harness):
                    self.config['agent'] = harness
                    self.run_guard()
                    self.assertIsNone(shell.poll())
                    self.assertEqual(self.sends(), [])
                    self.assertFalse(any(c[:2] == ['pane', 'send-keys']
                                         for c in self.commands()))
                    self.assertIn('no verified live primary', self.notes())
                    self.assertIn('BACKSTOP FAILURE', (self.state / '.wake-queue').read_text())

    def test_failed_nudge_is_durable(self):
        self.config['fail_send'] = True
        self.run_guard()
        self.assertIn('primary nudge failed', self.notes())

    def test_reply_lag_above_fifteen_minutes_alarms_even_with_fresh_beat(self):
        self.now = 2802
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1901
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 901s', self.notes())
        self.assertIn('REPLY DELIVERY LAG', (self.state / '.wake-queue').read_text())

    def test_exact_fifteen_minute_lag_does_not_alarm(self):
        self.now = 2800
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1900
        self.run_guard()
        self.assertEqual(self.notes(), '')

    def test_close_emissions_alarm_as_undelivered_reply_ages(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1060
        self.now = 1100
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.now = 1961
        self.run_guard()
        self.assertIn('901s (oldest_at=1060 ingested_at=1000)', self.notes())

    def test_newest_only_cursor_is_rebuilt_before_reporting_delay(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1060
        (self.state / '.main-backstop.json').write_text(json.dumps({
            'readers': {'q-server': {'offset': 9999, 'prefix': '0' * 64, 'stamp': 99999}}}))
        self.run_guard()
        self.assertIn('3940s (oldest_at=1060 ingested_at=1000)', self.notes())
        # The migrated legacy cursor is tried first; its bogus prefix breaks
        # continuity and the pass rebuilds from the whole file.
        self.assertEqual(self.reader_calls()[0][1], 'fm-remote-delta-read.sh')
        self.assertEqual(self.reader_calls()[1][1], 'fm-remote-file.sh')

    def test_report_body_cannot_advance_mirror_or_clear_incident(self):
        (self.state / '.last-watcher-beat').touch()
        mirrored = self.state / '.remote-reply-mirrored-q-server'
        mirrored.write_text('done [at=1000]: reproduced case at=9000;\n')
        self.config['remote_file'] = 'done [at=1060]: pending, example [at=9999]\n'
        self.run_guard()
        self.assertIn('3940s (oldest_at=1060 ingested_at=1000)', self.notes())
        incident = self.memory()['episodes']['lag-q-server']
        mirrored.write_text('done [at=1000]: body [at=999999999999]\n')
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        mirrored.write_text('done [at=1060]: mirrored; body at=9999;\n')
        self.run_guard()
        self.assertNotIn('lag-q-server', self.memory()['episodes'])

    def test_permissive_timestamp_cursor_is_rebuilt(self):
        (self.state / '.last-watcher-beat').touch()
        body = 'done [at=1060]: reply\n'
        self.config['remote_file'] = body
        (self.state / '.main-backstop.json').write_text(json.dumps({
            'readers': {'q-server': {'offset': len(body),
                                    'prefix': hashlib.sha256(body.encode()).hexdigest(),
                                    'pending': []}}}))
        self.run_guard()
        self.assertIn('3940s (oldest_at=1060 ingested_at=1000)', self.notes())
        self.assertEqual(self.reader_calls()[0][1], 'fm-remote-file.sh')

    def test_invalid_mirror_timestamp_is_unverified_without_clearing_incident(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1060
        self.run_guard()
        incident = self.memory()['episodes']['lag-q-server']
        for line in ('done: at=9000;', 'done [at=1000] [at=9000]: duplicate',
                     'done [at=01000]: leading zero', 'done [at=-1]: negative',
                     'done [at=1000.0]: fraction', 'done [at=1000000000000]: overflow'):
            with self.subTest(line=line):
                (self.state / '.remote-reply-mirrored-q-server').write_text(line+'\n')
                self.run_guard()
                self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
                self.assertIn('q-server', self.memory()['read_fails'])
        self.assertIn('REPLY DELIVERY UNVERIFIED', self.notes())

    def test_remote_header_contract_across_whole_delta_and_replacement(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = 'done [at=1060]: body at=1; [at=9999]\n'
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [1060])
        self.config['remote_file'] += 'done [corr=example] [at=1200]: body at=2;\n'
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [1060, 1200])
        self.config['remote_file'] = 'done [at=1300] [key=example]: replacement at=3;\n'
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [1060, 1200, 1300])
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_invalid_leading_remote_line_does_not_commit_delta_progress(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        offset = self.memory()['readers']['q-server']['offset']
        for line in ('done: at=1060;', 'done [at=1060] [at=9000]: duplicate',
                     'done [at=01060]: leading zero', 'done [at=1000000000000]: overflow'):
            with self.subTest(line=line):
                self.config['remote_file'] = line + '\nworking [at=1000]: remote reply\n'
                self.run_guard()
                self.assertEqual(self.memory()['readers']['q-server']['offset'], offset)
                self.assertIn('q-server', self.memory()['read_fails'])
        self.assertIn('REPLY DELIVERY UNVERIFIED', self.notes())

    def test_multiline_reply_entries_read_as_continuations_from_the_head(self):
        (self.state / '.last-watcher-beat').touch()
        entry = ('done [corr=sample] [at=1060]: landed the first item\n'
                 'Desk page: nothing of mine owns the desk screen.\n'
                 'Step 1, wiring: two follow-up swaps stay open.\n')
        self.config['remote_file'] = entry + 'done [at=4990]: second entry\n'
        (self.state / '.remote-reply-mirrored-q-server').write_text(entry)
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [4990])
        self.assertNotIn('q-server', self.memory()['read_fails'])
        self.assertEqual(self.notes(), '')

    def test_delta_window_beginning_mid_entry_reads_continuations(self):
        (self.state / '.last-watcher-beat').touch()
        head = 'done [corr=sample] [at=1060]: landed the first item\n'
        self.config['remote_file'] = head
        (self.state / '.remote-reply-mirrored-q-server').write_text(head)
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [])
        cold_calls = len(self.reader_calls())
        self.config['remote_file'] += ('Desk page: nothing of mine owns the desk screen.\n'
                                       'Step 1, wiring: two follow-up swaps stay open.\n')
        self.run_guard()
        delta_calls = self.reader_calls()[cold_calls:]
        self.assertTrue(delta_calls)
        self.assertTrue(all(call[1] == 'fm-remote-delta-read.sh' for call in delta_calls))
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [])
        self.assertNotIn('q-server', self.memory()['read_fails'])
        self.assertEqual(self.notes(), '')
        self.config['remote_file'] += 'done [at=4990]: second entry\n'
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [4990])

    def test_preempted_delta_read_reissues_same_cursor_and_progresses(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        offset = self.memory()['readers']['q-server']['offset']
        calls = len(self.reader_calls())
        self.config['remote_file'] = ('working [at=1000]: remote reply\n'
                                      'done [at=1901]: newer reply\n')
        self.config['preempt_delta'] = 1
        self.run_guard()
        attempts = self.reader_calls()[calls:]
        self.assertEqual(attempts[0][1], 'fm-remote-delta-read.sh')
        self.assertEqual(attempts[1][3], attempts[0][3])
        self.assertEqual(attempts[1][4], attempts[0][4])
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertNotIn('q-server', self.memory()['read_fails'])
        self.assertIn('REPLY DELIVERY LAG q-server: 3099s (oldest_at=1901 ingested_at=1000)',
                      self.notes())

    def test_permanently_preempted_delta_read_fails_boundedly(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        offset = self.memory()['readers']['q-server']['offset']
        calls = len(self.reader_calls())
        self.config['remote_file'] = ('working [at=1000]: remote reply\n'
                                      'done [at=1901]: newer reply\n')
        self.config['preempt_delta'] = 100
        self.run_guard()
        attempts = self.reader_calls()[calls:]
        self.assertEqual(len(attempts), 4)
        self.assertTrue(all(call[1] == 'fm-remote-delta-read.sh' for call in attempts))
        self.assertTrue(all(call[3] == str(offset) for call in attempts))
        self.assertEqual(self.memory()['readers']['q-server']['offset'], offset)
        self.assertIn('q-server', self.memory()['read_fails'])
        self.assertEqual(self.notes(), '')
        self.run_guard()
        self.assertIn('REPLY DELIVERY UNVERIFIED q-server', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'], offset)

    def test_canonical_timestamp_upper_bound_is_accepted(self):
        (self.state / '.last-watcher-beat').touch()
        self.now = 999999999999
        self.config['remote_file'] = 'done [at=999999999999]: maximum timestamp\n'
        self.run_guard()
        self.assertEqual(self.notes(), '')
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [999999999999])

    def test_first_fresh_reply_after_long_silence_is_not_late(self):
        (self.state / '.last-watcher-beat').touch()
        self.now = 100000
        self.config['remote'] = 99990
        self.run_guard()
        self.assertEqual(self.notes(), '')

    def test_partial_mirroring_advances_oldest_and_clears_its_incident(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = 'done [at=1060]: first\ndone [at=4990]: second\n'
        self.run_guard()
        self.assertIn('3940s (oldest_at=1060 ingested_at=1000)', self.notes())
        mirrored = self.state / '.remote-reply-mirrored-q-server'
        mirrored.write_text('done [at=1060]: first\n')
        self.run_guard()
        self.assertNotIn('lag-q-server', self.memory()['episodes'])
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [4990])
        self.now = 6000
        self.run_guard()
        self.assertIn('1010s (oldest_at=4990 ingested_at=1060)', self.notes())

    def test_replacement_cannot_discard_an_unmirrored_incident(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote'] = 1060
        self.run_guard()
        incident = self.memory()['episodes']['lag-q-server']
        self.config['remote_file'] = 'done [at=4990]: fresh replacement\n'
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [1060, 4990])

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

    @unittest.skipUnless(HAS_PROC_RUNNER, 'requires Linux /proc runner identity')
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
            'working [at=%d]: reply %d; at=1; [at=999999999999]\n' % (5000 + i * 60, i) for i in range(40000))
        self.assertGreater(len(self.config['remote_file']), 1048576)
        newest = 5000 + 39999 * 60
        (self.state / 'q-server.status').write_text('done [at=%d]: caught up\n' % newest)
        (self.state / '.remote-reply-mirrored-q-server').write_text('done [at=%d]: caught up\n' % newest)
        for _ in range(16):
            self.run_guard()
            if self.memory()['readers']['q-server']['offset'] == len(self.config['remote_file'].encode()):
                self.run_guard()
                break
        self.assertNotIn('q-server', self.memory()['read_fails'])
        self.assertFalse(any('REPLY DELIVERY LAG' in p.read_text()
                             for p in (self.state / 'inbox').glob('*.note')))
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [])
        cold_calls = len(self.reader_calls())
        self.run_guard()
        self.assertNotIn('lag-q-server', self.memory()['episodes'])
        self.assertEqual(len(self.reader_calls()), cold_calls + 1)

    def test_lag_alarm_carries_oldest_stamp_from_over_bound_source(self):
        (self.state / '.last-watcher-beat').touch()
        self.now = 10000
        self.config['remote_file'] = ''.join(
            'working [at=%d]: reply %d; at=1; [at=999999999999]\n' % (5000 + i * 60, i) for i in range(40000))
        for _ in range(16):
            self.run_guard()
            if 'lag-q-server' in self.memory()['episodes']:
                break
        self.assertIn('REPLY DELIVERY LAG q-server: 5000s (oldest_at=5000 ingested_at=1000)',
                      self.notes())

    def test_steady_state_reads_only_appended_lines(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.assertEqual(self.notes(), '')
        cold_calls = len(self.reader_calls())
        self.config['remote_file'] = ('working [at=1000]: remote reply\n'
                                      'done [at=1901]: newer reply\n')
        self.run_guard()
        self.assertEqual(len(self.reader_calls()), cold_calls + 2)
        self.assertIn('REPLY DELIVERY LAG q-server: 3099s (oldest_at=1901 ingested_at=1000)',
                      self.notes())

    def test_unicode_and_crlf_preserve_transport_cursor(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = 'working [at=1000]: café\r\n'
        self.run_guard()
        self.config['remote_file'] += 'done [at=1901]: café\r\n'
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 3099s', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_unicode_oversized_bootstrap_reaches_tail(self):
        (self.state / '.last-watcher-beat').touch()
        self.config['remote_file'] = 'working [at=1000]: café\n' * 50000
        self.config['remote_file'] += 'done [at=1901]: café\n'
        for _ in range(8):
            self.run_guard()
            if 'lag-q-server' in self.memory()['episodes']:
                break
        self.assertIn('REPLY DELIVERY LAG q-server: 3099s', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))

    def test_replaced_log_resyncs_byte_cursor(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = 'done [at=1901]: café\r\n'
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 3099s', self.notes())
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_adapter_notices_cannot_advance_ingestion_or_clear_lag(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = 'done [at=3000]: undelivered reply\n'
        status = self.state / 'q-server.status'
        with status.open('a') as out:
            out.write('note [at=4000]: remote reply continuity broken\n')
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 2000s (oldest_at=3000 ingested_at=1000)',
                      self.notes())
        incident = self.memory()['episodes']['lag-q-server']
        before = len(list((self.state / 'inbox').glob('*.note')))
        with status.open('a') as out:
            out.write('note [at=5000]: remote document did not transfer\n')
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before)
        with status.open('a') as out:
            out.write(self.config['remote_file'])
        (self.state / '.remote-reply-mirrored-q-server').write_text(
            self.config['remote_file'])
        self.run_guard()
        self.assertNotIn('lag-q-server', self.memory()['episodes'])
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_no_ingestion_evidence_does_not_use_local_notices(self):
        (self.state / '.last-watcher-beat').touch()
        (self.state / 'q-server.status').write_text('note [at=4000]: adapter notice\n')
        mirrored = self.state / '.remote-reply-mirrored-q-server'
        mirrored.unlink()
        self.config['remote'] = 1901
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 3099s (oldest_at=1901 ingested_at=0)',
                      self.notes())
        incident = self.memory()['episodes']['lag-q-server']
        mirrored.touch()
        self.run_guard()
        self.assertEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_multi_chunk_backlog_reports_tail_lag(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = ('working [at=1000]: remote reply\n' +
                                      'working [at=1200]: backlog\n' * 5000 +
                                      'done [at=3000]: latest\n')
        self.run_guard()
        self.assertIn('REPLY DELIVERY LAG q-server: 3800s', self.notes())
        self.assertNotIn('q-server', self.memory()['read_fails'])

    def test_over_budget_backlog_catches_up_without_unverified_alarm(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        self.config['remote_file'] = ('working [at=1000]: remote reply\n' +
                                      'working [at=1200]: backlog\n' * 22000 +
                                      'done [at=3000]: latest\n')
        for _ in range(6):
            self.run_guard()
            self.assertNotIn('q-server', self.memory()['read_fails'])
            self.assertNotIn('REPLY DELIVERY UNVERIFIED', self.notes())
            if self.memory()['readers']['q-server']['offset'] == len(self.config['remote_file'].encode()):
                break
        self.assertEqual(self.memory()['readers']['q-server']['offset'],
                         len(self.config['remote_file'].encode()))
        self.assertNotIn('q-server', self.memory()['read_fails'])
        self.assertIn('REPLY DELIVERY LAG q-server: 3800s', self.notes())
        self.assertNotIn('REPLY DELIVERY UNVERIFIED', self.notes())

    def test_tail_never_reached_without_progress_still_alarms(self):
        (self.state / '.last-watcher-beat').touch()
        self.run_guard()
        offset = self.memory()['readers']['q-server']['offset']
        calls = len(self.reader_calls())
        self.config['remote_file'] = ('working [at=1000]: remote reply\n'
                                      'done [at=1901]: newer reply\n')
        self.config['stuck_delta'] = 1
        self.run_guard()
        attempts = self.reader_calls()[calls:]
        self.assertEqual(len(attempts), 4)
        self.assertTrue(all(call[1] == 'fm-remote-delta-read.sh' for call in attempts))
        self.assertEqual(self.memory()['readers']['q-server']['offset'], offset)
        self.assertIn('q-server', self.memory()['read_fails'])
        self.assertEqual(self.notes(), '')
        self.run_guard()
        self.assertIn('REPLY DELIVERY UNVERIFIED q-server', self.notes())

    def test_legacy_reader_record_migrates_and_keeps_cursor(self):
        (self.state / '.last-watcher-beat').touch()
        body = 'working [at=1000]: remote reply\n'
        self.config['remote_file'] = body
        prefix = hashlib.sha256(body.encode()).hexdigest()
        for stamp in (0, 1000):
            with self.subTest(stamp=stamp):
                (self.state / '.main-backstop.json').write_text(json.dumps({
                    'readers': {'q-server': {'offset': len(body), 'prefix': prefix,
                                             'stamp': stamp}}}))
                calls = len(self.reader_calls())
                self.run_guard()
                reads = self.reader_calls()[calls:]
                self.assertEqual(len(reads), 1)
                self.assertEqual(reads[0][1], 'fm-remote-delta-read.sh')
                self.assertEqual(reads[0][3:5], [str(len(body)), prefix])
                self.assertEqual(self.memory()['readers']['q-server'],
                                 {'offset': len(body), 'prefix': prefix, 'pending_at': []})
                self.assertNotIn('q-server', self.memory()['read_fails'])
                self.assertEqual(self.notes(), '')

    def test_legacy_reader_preserves_unmirrored_stamp_until_mirrored(self):
        (self.state / '.last-watcher-beat').touch()
        self.now = 2802
        body = 'done [at=1901]: remote reply\n'
        self.config['remote_file'] = body
        prefix = hashlib.sha256(body.encode()).hexdigest()
        (self.state / '.main-backstop.json').write_text(json.dumps({
            'readers': {'q-server': {'offset': len(body), 'prefix': prefix,
                                     'stamp': 1901}}}))
        self.run_guard()
        self.assertEqual(len(self.reader_calls()), 1)
        self.assertEqual(self.reader_calls()[0][1], 'fm-remote-delta-read.sh')
        self.assertEqual(self.reader_calls()[0][3:5], [str(len(body)), prefix])
        self.assertEqual(self.memory()['readers']['q-server'],
                         {'offset': len(body), 'prefix': prefix, 'pending_at': [1901]})
        self.assertIn('901s (oldest_at=1901 ingested_at=1000)', self.notes())
        self.assertNotIn('q-server', self.memory()['read_fails'])
        (self.state / '.remote-reply-mirrored-q-server').write_text(
            'done [at=1901]: mirrored\n')
        self.run_guard()
        self.assertEqual(self.memory()['readers']['q-server']['pending_at'], [])
        self.assertNotIn('lag-q-server', self.memory()['episodes'])

    def test_invalid_legacy_reader_rebootstraps_before_reporting_lag(self):
        (self.state / '.last-watcher-beat').touch()
        self.now = 2802
        body = 'done [at=1901]: remote reply\n'
        self.config['remote_file'] = body
        prefix = hashlib.sha256(body.encode()).hexdigest()
        legacy = {'offset': len(body), 'prefix': prefix, 'stamp': 1901}
        records = [dict(legacy, version=2),
                   {key: value for key, value in legacy.items() if key != 'stamp'},
                   dict(legacy, offset=-1), dict(legacy, prefix='bogus')]
        records += [dict(legacy, stamp=stamp)
                    for stamp in (-1, True, False, 1901.0, '1901', None, [], {})]
        for record in records:
            with self.subTest(record=record):
                (self.state / '.main-backstop.json').write_text(json.dumps({
                    'readers': {'q-server': record}}))
                calls = len(self.reader_calls())
                self.run_guard()
                self.assertEqual(self.reader_calls()[calls][1], 'fm-remote-file.sh')
                self.assertEqual(self.memory()['readers']['q-server'],
                                 {'offset': len(body), 'prefix': prefix, 'pending_at': [1901]})
                self.assertIn('901s (oldest_at=1901 ingested_at=1000)', self.notes())
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
        (self.state / '.remote-reply-mirrored-q-server').write_text('done [at=1901]: caught up\n')
        self.run_guard()
        self.assertNotIn('lag-q-server', self.memory()['episodes'])
        self.config['remote'] = 3000
        self.run_guard()
        self.assertNotEqual(self.memory()['episodes']['lag-q-server'], incident)
        self.assertEqual(len(list((self.state / 'inbox').glob('*.note'))), before + 1)

    @unittest.skipUnless(HAS_PROC_RUNNER, 'requires Linux /proc runner identity')
    def test_runner_incident_clears_only_on_a_live_runner(self):
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

    def test_runner_incident_clears_when_unregistered(self):
        (self.state / '.last-watcher-beat').touch()
        self.register_runner('999999999\n')
        self.run_guard()
        self.run_guard()
        self.assertIn('runner-q-server', self.memory()['episodes'])
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

    def start_named_claude(self):
        path = self.base / 'holder-bin' / 'claude'
        path.parent.mkdir(exist_ok=True)
        if not path.exists():
            path.symlink_to('/bin/sleep')
        proc = subprocess.Popen([str(path), '30'])
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        return proc.pid

    def test_reused_nonharness_pid_keeps_stale_lock_recovery(self):
        holder = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % holder)
        os.utime(self.state / '.last-watcher-beat', (4000, 4000))
        self.run_guard()
        self.assertIn('holder-%s' % holder, self.memory()['episodes'])
        sleeper = subprocess.Popen(['/bin/sleep', '30'])
        self.addCleanup(sleeper.wait)
        self.addCleanup(sleeper.kill)
        (self.state / '.lock').write_text('%s\n' % sleeper.pid)
        self.run_guard()
        self.assertEqual(len(self.sends()), 1)
        self.assertNotIn('holder-%s' % holder, self.memory()['episodes'])
        self.assertNotIn('holder-%s' % sleeper.pid, self.memory()['episodes'])

    def test_unknown_holder_report_preserves_deduplicated_episode(self):
        holder = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % holder)
        os.utime(self.state / '.last-watcher-beat', (4000, 4000))
        self.run_guard()
        incident = self.memory()['episodes']['holder-%s' % holder]
        self.executable(self.fake / 'ps', '#!/bin/sh\nexit 1\n')
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.memory()['episodes']['holder-%s' % holder], incident)
        (self.state / '.lock').write_text('2147483647\n')
        self.executable(self.fake / 'ps', '#!/bin/sh\nexit 127\n')
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.memory()['episodes']['holder-%s' % holder], incident)
        (self.state / '.lock').write_text('%s\n' % holder)
        (self.fake / 'ps').unlink()
        self.run_guard()
        self.assertEqual(self.notes().count('Idle lock holder'), 1)
        self.assertEqual(self.memory()['episodes']['holder-%s' % holder], incident)

    def test_handover_before_report_uses_reported_pid_for_deduplication(self):
        predecessor = self.start_named_claude()
        successor = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % predecessor)
        os.utime(self.state / '.last-watcher-beat', (4000, 4000))
        self.env['BACKSTOP_NEXT_HOLDER'] = str(successor)
        self.executable(self.fake / 'bash', '''#!/bin/bash
if [ "${3:-}" = holder-report ]; then
  tmp=$(mktemp "$5/.lock-transition.XXXXXX") || exit 1
  printf '%s\\n' "$BACKSTOP_NEXT_HOLDER" > "$tmp"
  mv -f "$tmp" "$5/.lock"
fi
exec /bin/bash "$@"
''')
        self.run_guard()
        self.run_guard()
        self.assertEqual(self.notes().count('Idle lock holder'), 1)
        self.assertIn('pid=%s' % successor, self.notes())
        self.assertIn('holder-%s' % successor, self.memory()['episodes'])
        self.assertNotIn('holder-%s' % predecessor, self.memory()['episodes'])

    def test_disabled_capability_with_live_lock_defers_without_discovery(self):
        pid = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % pid)
        selected = self.select_send_file()
        for content in (None, b'invalid\n'):
            with self.subTest(content=content):
                if content is None:
                    selected.unlink()
                else:
                    selected.write_bytes(content)
                self.run_guard()
                self.assert_observe_only()
                incident = self.memory()['episodes']['recovery']
                self.assertIn(incident, self.memory()['deferred_alarms'])
        selected.write_bytes(b'enabled\n')
        selected.chmod(0o600)
        self.run_guard()
        self.assertIn(incident, self.notes())
        self.assertNotIn(incident, self.memory()['deferred_alarms'])

    def test_foreign_holder_under_fifteen_minutes_is_not_nudged_or_asked(self):
        pid = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % pid)
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertNotIn('Idle lock holder', self.notes())
        self.assertNotIn('BACKSTOP FAILURE', self.notes())
        self.assertIn('idle lock holder pid=%s' % pid, (self.state / '.main-backstop.log').read_text())

    def test_holder_ask_is_queued_once_for_working_main_after_fifteen_minutes(self):
        pid = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % pid)
        os.utime(self.state / '.last-watcher-beat', (4000, 4000))
        self.run_guard()
        self.run_guard()
        notes = self.notes()
        self.assertEqual(notes.count('Idle lock holder'), 1)
        self.assertIn('pid=%s' % pid, notes)
        self.assertIn('tty=', notes)
        self.assertIn('idle=', notes)
        self.assertNotIn('BACKSTOP FAILURE', notes)
        self.assertEqual(self.sends(), [])
        self.assertIn('holder-%s' % pid, self.memory()['episodes'])
        self.assertTrue((self.state / '.wake-queue').exists())

    def test_foreground_holder_is_also_queued_once_after_fifteen_minutes(self):
        pid = self.start_named_claude()
        (self.state / '.lock').write_text('%s\n' % pid)
        self.config['process_pid'] = pid
        self.config['process_cwd'] = str(self.home)
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertNotIn('Idle lock holder', self.notes())
        os.utime(self.state / '.last-watcher-beat', (4000, 4000))
        self.run_guard()
        self.run_guard()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.notes().count('Idle lock holder'), 1)
        self.assertIn('pid=%s' % pid, self.notes())
        self.assertIn('tty=', self.notes())
        self.assertIn('idle=', self.notes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
