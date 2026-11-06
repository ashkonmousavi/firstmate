#!/usr/bin/env bash
# Contract-derived stage transitions through the executable's public interface.
# No live worker, forge write, daemon, deployed app or machine install.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export FM_STAGE_TEST_ROOT="$ROOT"
python3 - <<'PY'
import base64
import copy
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(os.environ['FM_STAGE_TEST_ROOT'])
HEAD, MERGED, OTHER = 'a' * 40, 'b' * 40, 'c' * 40
URL = 'https://github.com/example/project/pull/42'


class Stages(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fm-stage-')
        self.base = Path(self.tmp.name)
        self.home = self.base / 'home'
        self.bin = self.base / 'bin'
        self.state = self.home / 'state'
        self.config = self.home / 'config'
        for path in [self.bin, self.state, self.config]:
            path.mkdir(parents=True)
        subject = Path(os.environ.get('FM_STAGE_TEST_SUBJECT', ROOT / 'bin/fm-stage-transition.sh'))
        shutil.copy2(subject, self.bin / 'fm-stage-real.sh')
        for name in ['fm-pr-lib.sh', 'fm-check-lib.sh', 'fm-check-register.sh', 'fm-lock-lib.sh', 'fm-timeout-lib.sh']:
            shutil.copy2(ROOT / 'bin' / name, self.bin / name)
        # Eligibility is an adapter here. Its real backend, hold and wait
        # behavior is additionally exercised in fm-control-relaunch.test.sh.
        self.script('fm-stage-transition.sh', '''#!/usr/bin/env bash
if [ "${1:-}" = _eligible ]; then
  sleep "${FM_STAGE_TEST_ELIGIBILITY_SLEEP:-0}"
  cat "$FM_HOME/eligible"
  exit
fi
exec "$(dirname "$0")/fm-stage-real.sh" "$@"
''')
        self.script('fm-control.sh', '''#!/usr/bin/env bash
[ "$2" = relaunch ] && [ "$3" = --if-stopped ] || exit 9
printf '%s\n' "$1" >> "$FM_HOME/calls"
sleep "${FM_STAGE_TEST_CONTROL_SLEEP:-0}"
printf '%s\n' "$1" >> "$FM_HOME/completed"
exit "$(cat "$FM_HOME/control-rc")"
''')
        self.script('gh-axi', '''#!/usr/bin/env python3
import base64,json,os,sys
from pathlib import Path
h=Path(os.environ['FM_HOME'])
if (h/'api-down').exists(): sys.exit(1)
path=sys.argv[3]
if path.endswith('/pulls/42'): name='pr'
elif '/check-runs?' in path: name='checks'
elif path.endswith('/status'): name='statuses'
elif path == 'graphql': name='queue'
else: sys.exit(9)
if '/repos/example/healthy/' in path or (path == 'graphql' and 'name:"healthy"' in sys.argv[-1]):
    name = 'healthy-' + name
print(base64.b64encode((h/(name+'.json')).read_bytes()).decode())
''')
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_STATE_OVERRIDE=str(self.state),
                        FM_CONFIG_OVERRIDE=str(self.config), PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.settings = {'schema': 1, 'tasks': {'lead': {'deploy_check': 'deploy', 'installed_check': 'installed'}}}
        self.configure()
        self.write('eligible', 'eligible\n')
        self.write('control-rc', '0\n')
        self.meta = 'kind=ship\nbranch=fm/lead\nworktree=/isolated/lead\npr=' + URL + '\n'
        (self.state / 'lead.meta').write_text(self.meta)
        self.pr()
        self.put('checks', {'check_runs': []})
        self.put('statuses', {'sha': HEAD, 'statuses': []})
        self.queue()
        self.check('deploy', 'pending')
        self.check('installed', 'pending')

    def tearDown(self):
        self.tmp.cleanup()

    def script(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o700)

    def write(self, name, text):
        (self.home / name).write_text(text)

    def put(self, name, data):
        self.write(name + '.json', json.dumps(data))

    def configure(self):
        (self.config / 'plan-leads.json').write_text(json.dumps(self.settings))

    def pr(self, merged=False, head=HEAD):
        self.put('pr', {'html_url': URL, 'number': 42, 'state': 'closed' if merged else 'open',
                        'merged': merged, 'merge_commit_sha': MERGED, 'head': {'sha': head}})

    def red(self, number=1, head=HEAD):
        self.put('checks', {'check_runs': [{'id': number, 'head_sha': head,
                  'conclusion': 'failure', 'completed_at': '2026-11-05T23:10:00Z'}]})

    def queue(self, event=None, head=HEAD):
        nodes = [] if event is None else [{'id': event, 'beforeCommit': {'oid': head}}]
        self.put('queue', {'data': {'repository': {'pullRequest': {'timelineItems': {'nodes': nodes}}}}})

    def check(self, name, verdict, head=MERGED, event='attempt-1'):
        self.put(name, {'head': head, 'status': verdict, 'event': event})
        path = self.state / (name + '.check.sh')
        path.write_text('#!/usr/bin/env bash\ncat "$FM_HOME/' + name + '.json"\n')
        path.chmod(0o700)
        result = subprocess.run([str(self.bin / 'fm-check-register.sh'), name], env=getattr(self, 'env', os.environ),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_stage(self, *args, good=True):
        out = subprocess.run([str(self.bin / 'fm-stage-transition.sh'), *args], env=self.env,
                             text=True, capture_output=True, timeout=45)
        if good:
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        else:
            self.assertNotEqual(out.returncode, 0, out.stdout)
        return out.stdout

    def record(self):
        return json.loads((self.state / '.stage-transitions.json').read_text())['tasks']['lead']

    def calls(self):
        path = self.home / 'calls'
        return path.read_text().splitlines() if path.exists() else []

    def test_budget_covers_serial_startup_and_confirmation(self):
        one = int(self.run_stage('budget'))
        self.assertGreater(one, 120 + 90)
        self.settings['tasks']['second'] = self.settings['tasks']['lead'].copy()
        self.configure()
        two = int(self.run_stage('budget'))
        self.assertGreater(two, 2 * (120 + 90))
        self.assertGreater(two, one)
        self.env['FM_STAGE_CONTROL_TIMEOUT'] = '600'
        self.assertGreater(int(self.run_stage('budget')), 2 * 600)

    def test_control_timeout_remains_bounded_and_deduplicated(self):
        self.red()
        self.env.update(FM_STAGE_CONTROL_TIMEOUT='1', FM_STAGE_TEST_CONTROL_SLEEP='3')
        self.run_stage('check')
        self.assertEqual({e['outcome'] for e in self.record()['events'].values()}, {'failed'})
        self.assertFalse((self.home / 'completed').exists())
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])

    def test_eligibility_can_finish_sequential_dependency_reads(self):
        self.red()
        self.env['FM_STAGE_TEST_ELIGIBILITY_SLEEP'] = '11'
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])
        self.assertEqual({e['outcome'] for e in self.record()['events'].values()}, {'relaunched'})

    def test_admission_deferral_retries_but_ambiguous_failure_does_not(self):
        self.red()
        self.write('control-rc', '3')
        self.run_stage('check')
        self.assertFalse(self.record()['events'])
        self.assertFalse(self.record()['launches'])
        self.write('control-rc', '0')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual({e['outcome'] for e in self.record()['events'].values()}, {'relaunched'})
        self.red(2)
        self.write('control-rc', '75')
        self.run_stage('check')
        self.write('control-rc', '0')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 3)
        self.assertIn('failed', {e['outcome'] for e in self.record()['events'].values()})

    def prepare_watcher(self):
        for source in (ROOT / 'bin').iterdir():
            target = self.bin / source.name
            if not target.exists():
                target.symlink_to(source)
        shutil.copy2(ROOT / 'bin/fm-watch.sh', self.bin / 'fm-watch-local.sh')
        self.script('tmux', '#!/usr/bin/env bash\nexit 1\n')

    def test_watcher_preserves_ordinary_check_deadline(self):
        self.prepare_watcher()
        (self.state / 'lead.meta').unlink()
        check = self.state / 'zz-slow.check.sh'
        check.write_text('#!/usr/bin/env bash\nsleep 3\ntouch "$FM_HOME/ordinary-completed"\n')
        check.chmod(0o700)
        registered = subprocess.run([str(self.bin / 'fm-check-register.sh'), 'zz-slow'],
                                    env=self.env, text=True, capture_output=True)
        self.assertEqual(registered.returncode, 0, registered.stdout + registered.stderr)
        env = dict(self.env, FM_ROOT_OVERRIDE=str(self.home), FM_POLL='1',
                   FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999',
                   FM_CHECK_TIMEOUT='1', FM_CHECK_FORCE_FALLBACK='1')
        result = subprocess.run([str(self.bin / 'fm-watch-local.sh')], env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        queue = (self.state / '.wake-queue').read_text()
        self.assertIn('zz-slow.check.sh', queue)
        self.assertIn('timed out after 1s', queue)
        self.assertFalse((self.home / 'ordinary-completed').exists())

    def watcher_budget_failure(self, kind):
        self.prepare_watcher()
        self.run_stage('arm')
        (self.state / 'lead.meta').unlink()
        (self.state / 'deploy.check.sh').unlink()
        (self.state / 'installed.check.sh').unlink()
        check = self.state / 'zz-after.check.sh'
        check.write_text('#!/usr/bin/env bash\ntouch "$FM_HOME/after-stage"\necho sibling-complete\n')
        check.chmod(0o700)
        registered = subprocess.run([str(self.bin / 'fm-check-register.sh'), 'zz-after'],
                                    env=self.env, text=True, capture_output=True)
        self.assertEqual(registered.returncode, 0, registered.stdout + registered.stderr)
        env = dict(self.env, FM_ROOT_OVERRIDE=str(self.home), FM_POLL='1',
                   FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999')
        if kind == 'invalid-config':
            (self.config / 'plan-leads.json').write_text('{')
        else:
            self.configure()
            self.script('fm-stage-transition.sh', '#!/usr/bin/env bash\necho not-a-budget\n')
        result = subprocess.run([str(self.bin / 'fm-watch-local.sh')], env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        queue = (self.state / '.wake-queue').read_text()
        self.assertIn('plan-stages.check.sh', queue)
        self.assertIn('UNKNOWN' if kind == 'invalid-config' else 'invalid stage check budget', queue)
        self.assertIn('sibling-complete', queue)
        self.assertTrue((self.home / 'after-stage').is_file())

    def test_watcher_reports_bad_stage_config_and_continues_sweep(self):
        self.watcher_budget_failure('invalid-config')

    def test_watcher_reports_bad_stage_budget_and_continues_sweep(self):
        self.watcher_budget_failure('invalid-output')

    def test_watcher_finishes_two_slow_relaunches_in_one_poll(self):
        self.prepare_watcher()
        self.settings['tasks']['second'] = self.settings['tasks']['lead'].copy()
        self.configure()
        self.red()
        self.run_stage('arm')
        env = dict(self.env, FM_ROOT_OVERRIDE=str(self.home), FM_POLL='1',
                   FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999',
                   FM_STAGE_TEST_CONTROL_SLEEP='16')
        with subprocess.Popen([str(self.bin / 'fm-watch-local.sh')], env=env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              start_new_session=True) as watcher:
            try:
                deadline = time.monotonic() + 20
                while not (self.home / 'calls').exists() and watcher.poll() is None:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                self.assertIsNone(watcher.poll())
                (self.state / 'second.meta').write_text(self.meta)
                first_beat = (self.state / '.last-watcher-beat').stat().st_mtime_ns
                time.sleep(2)
                self.assertGreater((self.state / '.last-watcher-beat').stat().st_mtime_ns, first_beat)
                out, err = watcher.communicate(timeout=50)
                self.assertEqual(watcher.returncode, 0, out + err)
            finally:
                if watcher.poll() is None:
                    os.killpg(watcher.pid, signal.SIGTERM)
                    watcher.communicate(timeout=10)
        self.assertEqual(self.calls(), ['lead', 'second'])
        self.assertEqual((self.home / 'completed').read_text().splitlines(), ['lead', 'second'])
        rows = json.loads((self.state / '.stage-transitions.json').read_text())['tasks']
        for task in ['lead', 'second']:
            self.assertEqual({e['outcome'] for e in rows[task]['events'].values()}, {'relaunched'})
        self.env.pop('FM_STAGE_TEST_CONTROL_SLEEP', None)
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead', 'second'])

    def test_pr_red_replay_same_task_and_new_head(self):
        self.red()
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])
        self.assertEqual((self.state / 'lead.meta').read_text(), self.meta)
        row = self.record()
        self.assertTrue({'due', 'next_step', 'task', 'estimate'} <= row.keys())
        event = next(iter(row['events'].values()))
        self.assertEqual(event['trigger'], 'pr-red')
        self.assertEqual(event['outcome'], 'relaunched')
        self.assertEqual(event['duplicate_count'], 1)
        self.pr(head=OTHER)
        self.put('statuses', {'sha': OTHER, 'statuses': []})
        self.red(head=OTHER)
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 2)

    def test_queue_drop_exact_head(self):
        self.queue('drop-old', OTHER)
        self.run_stage('check')
        self.assertEqual(self.calls(), [])
        self.queue('drop-new')
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])

    def test_merge_watch_deploy_red_installed_red_then_both_green(self):
        self.pr(merged=True)
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])
        self.assertFalse(self.record()['closed'])
        self.assertEqual(self.record()['next_step'], 'watch deploy and installed check')
        self.check('deploy', 'red')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 2)
        self.check('deploy', 'green')
        self.check('installed', 'red')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 3)
        self.check('installed', 'green')
        self.run_stage('check')
        self.assertTrue(self.record()['closed'])
        self.run_stage('can-close', 'lead')
        (self.state / 'lead.meta').write_text(self.meta.replace('branch=fm/lead', 'branch=fm/rebound'))
        self.run_stage('can-close', 'lead', good=False)
        (self.state / 'lead.meta').write_text(self.meta)
        self.check('installed', 'red', event='new-failure')
        self.run_stage('can-close', 'lead', good=False)

    def test_live_held_and_declared_wait_have_precedence(self):
        self.red()
        for state in ['live', 'held', 'paused', 'unknown']:
            with self.subTest(state=state):
                self.write('eligible', state)
                self.run_stage('check')
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.record()['events'])
        self.write('eligible', 'eligible')
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])

    def test_cap_three_per_hour_head_and_class(self):
        for number in range(1, 6):
            self.red(number)
            self.run_stage('check')
        self.assertEqual(len(self.calls()), 3)
        self.assertIn('capped', {e['outcome'] for e in self.record()['events'].values()})
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 3)
        ledger = self.state / '.stage-transitions.json'
        data = json.loads(ledger.read_text())
        row = data['tasks']['lead']
        for launch in row['launches']:
            launch['time'] -= 3601
        for event in row['events'].values():
            if event['outcome'] == 'capped':
                event['time'] -= 3601
        ledger.write_text(json.dumps(data))
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 4)
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 4)
        self.queue('different-class')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 5)

    def test_missing_empty_wrong_head_skipped_and_untrusted_proof_are_unknown(self):
        self.pr(merged=True)
        self.check('deploy', 'green')
        del self.settings['tasks']['lead']['installed_check']
        self.configure()
        self.run_stage('check')
        self.run_stage('check')
        self.assertFalse(self.record()['closed'])
        self.assertIn('no registered check', self.record()['detail'])
        self.settings['tasks']['lead']['installed_check'] = 'installed'
        self.configure()
        self.check('installed', 'green', head=OTHER)
        self.run_stage('check')
        self.assertFalse(self.record()['closed'])
        self.assertIn('head', self.record()['detail'])
        self.check('installed', 'green')
        with (self.state / 'installed.check.sh').open('a') as out:
            out.write('# unregistered replacement\n')
        self.run_stage('check')
        self.assertFalse(self.record()['closed'])
        item = self.settings['tasks']['lead']
        del item['deploy_check']
        self.configure()
        self.run_stage('check')
        self.assertFalse(self.record()['closed'])
        self.assertIn('no registered check', self.record()['detail'])
        item['deploy_check'] = 'deploy'
        self.configure()
        self.check('installed', 'green')
        for status in ['pending', 'unknown', 'skipped']:
            self.check('deploy', status)
            self.run_stage('check')
            self.assertFalse(self.record()['closed'])
        self.check('deploy', 'green')
        self.run_stage('check')
        self.assertTrue(self.record()['closed'])

    def test_failure_crash_reservation_and_raced_live_worker_do_not_duplicate(self):
        self.red()
        self.write('control-rc', '3')
        self.run_stage('check')
        self.assertFalse(self.record()['events'])
        self.write('control-rc', '1')
        self.run_stage('check')
        before = len(self.calls())
        self.write('control-rc', '0')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), before)
        ledger = self.state / '.stage-transitions.json'
        data = json.loads(ledger.read_text())
        for row in data['tasks']['lead']['events'].values():
            row['outcome'] = 'reserved'
        ledger.write_text(json.dumps(data))
        self.run_stage('check')
        self.assertEqual(len(self.calls()), before)
        self.assertIn('UNKNOWN action reserved', self.record()['detail'])

    def test_scope_dependencies_schema_home_and_registered_shim(self):
        self.run_stage('arm')
        self.assertTrue((self.state / 'plan-stages.check-trust').exists())
        self.red()
        self.write('api-down', '')
        self.run_stage('check')
        self.assertEqual(self.calls(), [])
        self.assertIn('UNKNOWN', self.record()['detail'])
        (self.home / 'api-down').unlink()
        (self.state / 'lead.meta').write_text(self.meta.replace('kind=ship', 'kind=secondmate'))
        self.run_stage('check')
        self.assertEqual(self.calls(), [])
        (self.state / 'lead.meta').write_text(self.meta)
        ledger = self.state / '.stage-transitions.json'
        data = json.loads(ledger.read_text())
        data['home'] = '/another/home'
        ledger.write_text(json.dumps(data))
        self.run_stage('check', good=False)
        self.run_stage('can-close', 'unconfigured')

    def test_legacy_status_red_and_queue_read_failure_do_not_hide_pr_red(self):
        self.put('statuses', {'sha': HEAD, 'statuses': [{'id': 8, 'state': 'failure'}]})
        self.write('queue.json', 'garbage')
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])
        self.assertIn('UNKNOWN', self.record()['detail'])

    def test_registered_queue_drop_exact_head(self):
        self.settings['tasks']['lead']['queue_check'] = 'queue-local'
        self.configure()
        self.check('queue-local', 'red', head=OTHER, event='native-drop-1')
        self.run_stage('check')
        self.assertEqual(self.calls(), [])
        self.check('queue-local', 'red', head=HEAD, event='native-drop-1')
        self.run_stage('check')
        self.run_stage('check')
        self.assertEqual(self.calls(), ['lead'])

    def tool(self, command, *args, good=True):
        result = subprocess.run([str(command), *args], env=self.env, cwd=self.home,
                                capture_output=True, text=True, timeout=45)
        if good:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def add_backlog(self, task):
        (self.home / 'data').mkdir(exist_ok=True)
        self.tool('tasks-axi', 'add', task, 'stage fixture task', '--kind', 'ship',
                  '--start', '--file', 'data/backlog.md')
        self.tool('tasks-axi', 'update', task, '--body', 'PR ' + URL, '--file', 'data/backlog.md')

    def backlog_state(self, task):
        result = self.tool('tasks-axi', 'show', task, '--file', 'data/backlog.md')
        return next(line.split(':', 1)[1].strip() for line in result.stdout.splitlines()
                    if line.startswith('  state:'))

    def accept_stage(self):
        self.pr(merged=True)
        self.run_stage('check')
        self.check('deploy', 'green')
        self.check('installed', 'green')
        self.run_stage('check')
        self.assertTrue(self.record()['closed'])

    def test_inactive_reconciliation_waits_for_both_receipts(self):
        self.add_backlog('lead')
        self.pr(merged=True)
        self.script('fm-crew-state.sh', '#!/usr/bin/env bash\necho "state: done · source: fixture"\n')
        self.script('gh', '#!/usr/bin/env bash\necho \'{"state":"MERGED","mergedAt":"2026-11-05T01:00:00Z","closedAt":"2026-11-05T01:00:00Z"}\'\n')
        self.env.update(FM_DATA_OVERRIDE=str(self.home / 'data'), FM_ROOT_OVERRIDE=str(self.home),
                        FM_INACTIVE_CREW_STATE_BIN=str(self.bin / 'fm-crew-state.sh'),
                        FM_INACTIVE_RECONCILE_BUDGET_SECS='30', FM_GH_CONDITIONAL='0')
        reconcile = ROOT / 'bin/fm-inactive-reconcile.sh'
        self.tool(reconcile, 'scan', '--startup')
        self.assertEqual(self.backlog_state('lead'), 'in_flight')
        self.run_stage('check')
        self.check('deploy', 'green')
        self.run_stage('check')
        self.tool(reconcile, 'scan', '--startup')
        self.assertEqual(self.backlog_state('lead'), 'in_flight')
        self.check('installed', 'green')
        self.run_stage('check')
        self.tool(reconcile, 'scan', '--startup')
        self.assertEqual(self.backlog_state('lead'), 'done')
        self.write('eligible', 'done')
        calls = self.calls()
        self.run_stage('check')
        self.assertTrue(self.record()['closed'])
        self.run_stage('can-close', 'lead')
        self.assertEqual(self.calls(), calls)

    def test_task_completion_aliases_and_accepted_close_replay(self):
        self.add_backlog('lead')
        wrapper = ROOT / 'bin/fm-tasks-axi.sh'
        for action in ['done', 'close']:
            self.tool(wrapper, action, 'lead', good=False)
            self.assertEqual(self.backlog_state('lead'), 'in_flight')
        self.accept_stage()
        for action in ['done', 'close']:
            if self.backlog_state('lead') == 'done':
                self.tool('tasks-axi', 'reopen', 'lead', '--file', 'data/backlog.md')
            result = self.tool(wrapper, action, 'lead')
            self.assertTrue(result.stdout.strip())
            self.assertEqual(self.backlog_state('lead'), 'done')
            self.write('eligible', 'done')
            calls = self.calls()
            self.run_stage('check')
            self.assertTrue(self.record()['closed'])
            self.run_stage('can-close', 'lead')
            self.assertEqual(self.calls(), calls)
        marker = self.state / 'lead.backlog-close'
        marker.write_text('accepted cleanup\n')
        self.tool('bash', '-c', '. "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; '
                  'fm_backlog_close_transition "$2/lead.meta" "$2/lead.backlog-close" "$3" lead "$2" --note replay',
                  '_', str(ROOT), str(self.state), str(self.home / 'data'))
        self.assertFalse((self.state / 'lead.meta').exists())
        self.assertFalse(marker.exists())
        self.assertEqual(self.backlog_state('lead'), 'done')
        self.add_backlog('ordinary')
        self.tool(wrapper, 'done', 'ordinary')
        self.assertEqual(self.backlog_state('ordinary'), 'done')
        (self.config / 'plan-leads.json').unlink()
        self.add_backlog('legacy')
        self.tool(wrapper, 'close', 'legacy')
        self.assertEqual(self.backlog_state('legacy'), 'done')

    def test_accepted_completion_revalidates_bindings_and_recovers_evidence(self):
        self.add_backlog('lead')
        self.accept_stage()
        self.tool(ROOT / 'bin/fm-tasks-axi.sh', 'done', 'lead')
        self.write('eligible', 'done')
        calls = self.calls()
        for defect in ['pr', 'branch', 'worktree', 'head', 'deploy', 'installed', 'api']:
            with self.subTest(defect=defect):
                if defect in ['pr', 'branch', 'worktree']:
                    key = {'pr': 'pr=' + URL, 'branch': 'branch=fm/lead',
                           'worktree': 'worktree=/isolated/lead'}[defect]
                    (self.state / 'lead.meta').write_text(self.meta.replace(key, key + '-changed'))
                elif defect == 'head':
                    pr = json.loads((self.home / 'pr.json').read_text())
                    pr['merge_commit_sha'] = OTHER
                    self.put('pr', pr)
                    self.check('deploy', 'green', head=OTHER)
                    self.check('installed', 'green', head=OTHER)
                elif defect in ['deploy', 'installed']:
                    self.check(defect, 'red', event='later-failure')
                else:
                    self.write('api-down', '')
                self.run_stage('check')
                self.assertIn('UNKNOWN', self.record()['detail'])
                self.run_stage('can-close', 'lead', good=False)
                self.assertEqual(self.backlog_state('lead'), 'done')
                self.assertEqual(self.calls(), calls)
                (self.state / 'lead.meta').write_text(self.meta)
                (self.home / 'api-down').unlink(missing_ok=True)
                self.pr(merged=True)
                self.check('deploy', 'green')
                self.check('installed', 'green')
                self.run_stage('check')
                self.assertTrue(self.record()['closed'])
                self.run_stage('can-close', 'lead')
                self.assertEqual(self.calls(), calls)

    def reset_ledger(self, data=None):
        if data is None:
            data = {'schema': 1, 'home': str(self.home.resolve()), 'tasks': {}}
        (self.state / '.stage-transitions.json').write_text(json.dumps(data))
        self.write('calls', '')

    def test_backlog_completion_receipt_matrix(self):
        self.add_backlog('lead')
        self.accept_stage()
        baseline = json.loads((self.state / '.stage-transitions.json').read_text())
        for state in ['queued', 'in_flight', 'done']:
            self.tool('tasks-axi', 'reopen', 'lead', '--file', 'data/backlog.md')
            if state != 'queued':
                self.tool('tasks-axi', 'start', 'lead', '--file', 'data/backlog.md')
            if state == 'done':
                self.tool('tasks-axi', 'done', 'lead', '--file', 'data/backlog.md')
            self.assertEqual(self.backlog_state('lead'), state)
            for closed in [False, True]:
                for verdict in ['green', 'red', 'pending', 'unknown']:
                    with self.subTest(state=state, closed=closed, verdict=verdict):
                        data = copy.deepcopy(baseline)
                        data['tasks']['lead']['closed'] = closed
                        self.reset_ledger(data)
                        self.write('eligible', 'done' if state == 'done' else 'eligible')
                        self.check('deploy', verdict, event='matrix-verdict')
                        self.run_stage('check')
                        if state == 'done':
                            self.assertEqual(self.calls(), [])
                            self.assertEqual(self.record()['closed'], closed)
                            allowed = closed and verdict == 'green'
                        else:
                            self.assertEqual(self.calls(), ['lead'] if verdict == 'red' else [])
                            allowed = verdict == 'green'
                            self.assertEqual(self.record()['closed'], allowed)
                        self.run_stage('can-close', 'lead', good=allowed)

    def test_open_completed_lead_processes_every_new_red_trigger(self):
        self.accept_stage()
        baseline = json.loads((self.state / '.stage-transitions.json').read_text())
        for trigger in ['deploy', 'installed', 'check', 'status', 'queue', 'queue-local']:
            with self.subTest(trigger=trigger):
                self.reset_ledger(copy.deepcopy(baseline))
                self.pr(merged=trigger in ['deploy', 'installed'])
                self.check('deploy', 'green')
                self.check('installed', 'green')
                self.put('checks', {'check_runs': []})
                self.put('statuses', {'sha': HEAD, 'statuses': []})
                self.queue()
                self.settings['tasks']['lead'].pop('queue_check', None)
                if trigger in ['deploy', 'installed']:
                    self.check(trigger, 'red', event='after-green')
                elif trigger == 'check':
                    self.red(7)
                elif trigger == 'status':
                    self.put('statuses', {'sha': HEAD, 'statuses': [{'id': 7, 'state': 'failure'}]})
                elif trigger == 'queue':
                    self.queue('after-green')
                else:
                    self.settings['tasks']['lead']['queue_check'] = 'queue-local'
                    self.check('queue-local', 'red', head=HEAD, event='after-green')
                self.configure()
                self.run_stage('check')
                self.assertEqual(self.calls(), ['lead'])
                self.assertFalse(self.record()['closed'])
                self.run_stage('check')
                self.assertEqual(self.calls(), ['lead'])

    def test_open_lead_guards_preserve_deferral_before_receipt_actions(self):
        self.accept_stage()
        baseline = json.loads((self.state / '.stage-transitions.json').read_text())
        for closed in [False, True]:
            for guard in ['held', 'paused', 'live', 'unknown']:
                for verdict in ['green', 'red']:
                    with self.subTest(closed=closed, guard=guard, verdict=verdict):
                        data = copy.deepcopy(baseline)
                        data['tasks']['lead']['closed'] = closed
                        self.reset_ledger(data)
                        self.write('eligible', guard)
                        self.check('deploy', verdict, event='guarded-result')
                        self.run_stage('check')
                        self.assertEqual(self.calls(), [])
                        self.assertEqual(self.record()['closed'], closed if guard == 'unknown' else False)
                        self.write('eligible', 'eligible')
                        self.run_stage('check')
                        self.assertEqual(self.calls(), ['lead'] if verdict == 'red' else [])
                        self.assertEqual(self.record()['closed'], verdict == 'green')

    def healthy_lead(self, merged):
        url = URL.replace('/project/', '/healthy/')
        self.settings['tasks']['healthy'] = {'deploy_check': 'healthy-deploy', 'installed_check': 'healthy-installed'}
        self.configure()
        (self.state / 'healthy.meta').write_text(self.meta.replace(URL, url).replace('/lead', '/healthy'))
        for name in ['pr', 'checks', 'statuses', 'queue']:
            data = json.loads((self.home / (name + '.json')).read_text())
            if name == 'pr':
                data['html_url'] = url
                data['merged'] = merged
                data['state'] = 'closed' if merged else 'open'
            self.put('healthy-' + name, data)
        self.check('healthy-deploy', 'green')
        self.check('healthy-installed', 'green')

    def test_non_object_receipts_leave_healthy_sibling_running(self):
        for check in ['deploy', 'installed', 'queue-local']:
            merged = check != 'queue-local'
            self.pr(merged=merged)
            self.healthy_lead(merged)
            self.check('deploy', 'green')
            self.check('installed', 'green')
            if check == 'queue-local':
                self.settings['tasks']['lead']['queue_check'] = check
                self.configure()
                self.red()
                self.put('healthy-checks', json.loads((self.home / 'checks.json').read_text()))
            else:
                self.settings['tasks']['lead'].pop('queue_check', None)
                self.configure()
            for value in [None, [], 7, 'bad', {'head': MERGED, 'status': [], 'event': 'x'},
                          {'head': MERGED, 'status': 'green', 'event': 'x', 'reason': []}]:
                with self.subTest(check=check, value=value):
                    self.check(check, 'green', head=MERGED if merged else HEAD)
                    self.put(check, value)
                    self.reset_ledger()
                    self.run_stage('check')
                    self.assertIn('UNKNOWN', self.record()['detail'])
                    self.assertIn('healthy', self.calls())

    def test_bad_forge_and_ledger_shapes_are_local_to_one_lead(self):
        self.red()
        self.healthy_lead(False)
        cases = [('pr', None), ('pr', []),
                 ('pr', {'html_url': URL, 'number': 42, 'head': None}),
                 ('checks', None), ('checks', {'check_runs': None}), ('checks', {'check_runs': [None]}),
                 ('checks', {'check_runs': [{'head_sha': HEAD, 'id': 1, 'conclusion': [], 'completed_at': None}]}),
                 ('checks', {'check_runs': [{'head_sha': [], 'id': 1, 'conclusion': None, 'completed_at': None}]}),
                 ('statuses', []), ('statuses', {'sha': HEAD, 'statuses': [None]}),
                 ('statuses', {'sha': HEAD, 'statuses': [{'id': 1, 'state': []}]}),
                 ('queue', {'data': None}), ('queue', {'data': {'repository': []}}),
                 ('queue', {'data': {'repository': {'pullRequest': {'timelineItems': {'nodes': [None]}}}}}),
                 ('queue', {'data': {'repository': {'pullRequest': {'timelineItems': {
                     'nodes': [{'id': 'drop', 'beforeCommit': []}]}}}}})]
        originals = {name: json.loads((self.home / (name + '.json')).read_text())
                     for name in ['pr', 'checks', 'statuses', 'queue']}
        for name, value in cases:
            with self.subTest(source=name, value=value):
                for source, original in originals.items():
                    self.put(source, original)
                self.put(name, value)
                self.reset_ledger()
                self.run_stage('check')
                self.assertIn('UNKNOWN', self.record()['detail'])
                self.assertIn('healthy', self.calls())
        for source, original in originals.items():
            self.put(source, original)
        valid = {'events': {}, 'launches': [], 'closed': False}
        bad_records = [None, [], dict(valid, events=None), dict(valid, launches=[None]),
                       dict(valid, closed=[]), dict(valid, events={'bad': None}),
                       dict(valid, identity=[None, []])]
        for value in bad_records:
            with self.subTest(ledger=value):
                data = {'schema': 1, 'home': str(self.home.resolve()), 'tasks': {'lead': value}}
                self.reset_ledger(data)
                out = self.run_stage('check')
                self.assertIn('lead: UNKNOWN:', out)
                self.assertIn('healthy', self.calls())

    def test_unlisted_scout_completion_preserves_parent_and_json_output(self):
        self.add_backlog('survey')
        (self.state / 'survey.meta').write_text(self.meta.replace('kind=ship', 'kind=scout'))
        result = self.tool(ROOT / 'bin/fm-tasks-axi.sh', 'done', 'survey', '--json')
        self.assertIsInstance(json.loads(result.stdout), dict)
        self.assertEqual(self.backlog_state('survey'), 'in_flight')

    def test_teardown_refuses_incomplete_stage_even_with_force(self):
        subject = os.environ.get('FM_STAGE_TEST_TEARDOWN_SUBJECT', str(ROOT / 'bin/fm-teardown.sh'))
        result = subprocess.run([subject, 'lead', '--force'], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('plan lead stage proof is incomplete', result.stderr)
        self.assertEqual((self.state / 'lead.meta').read_text(), self.meta)

    def test_pr_ready_arms_one_home_stage_check(self):
        self.script('gh', '''#!/usr/bin/env bash
case "$*" in
  *isDraft*) echo '{"isDraft":false}' ;;
  *headRefOid*) printf '%040d\\n' 0 ;;
  *) exit 1 ;;
esac
''')
        worktree = self.home / 'wt'
        worktree.mkdir()
        (self.state / 'lead.meta').write_text('kind=ship\nmode=no-mistakes\nworktree=' + str(worktree) + '\n')
        subject = os.environ.get('FM_STAGE_TEST_PR_SUBJECT', str(ROOT / 'bin/fm-pr-check.sh'))
        result = subprocess.run([subject, 'lead', URL], env=dict(self.env, FM_ROOT_OVERRIDE=str(ROOT)),
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.state / 'plan-stages.check.sh').is_file())
        self.assertTrue((self.state / 'plan-stages.check-trust').is_file())

    def test_concurrent_polls_and_interrupted_action_keep_one_reservation(self):
        self.red()
        self.script('fm-control.sh', '''#!/usr/bin/env bash
echo "$1" >> "$FM_HOME/calls"
echo "$$" > "$FM_HOME/control-pid"
touch "$FM_HOME/entered-control"
sleep 20
''')
        command = [str(self.bin / 'fm-stage-transition.sh'), 'check']
        first = subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        try:
            for _ in range(500):
                if (self.home / 'entered-control').exists():
                    break
                time.sleep(0.01)
            self.assertTrue((self.home / 'entered-control').exists())
            self.run_stage('check')
            self.assertEqual(self.calls(), ['lead'])
            # The action owns a separate group: stop only our recorded fixture
            # child, then terminate this check to model loss before its receipt.
            child = int((self.home / 'control-pid').read_text())
            child_group = os.getpgid(child)
            os.killpg(first.pid, signal.SIGKILL)
            try:
                os.killpg(child_group, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The shared timeout's owner-death guard already reaped it.
            first.communicate(timeout=5)
            self.run_stage('check')
            self.assertEqual(self.calls(), ['lead'])
            self.assertIn('reserved', {e['outcome'] for e in self.record()['events'].values()})
        finally:
            if first.poll() is None:
                os.killpg(first.pid, signal.SIGKILL)
                first.communicate(timeout=5)


unittest.main(argv=[sys.argv[0]] + ([os.environ['FM_STAGE_TEST_CASE']] if os.environ.get('FM_STAGE_TEST_CASE') else []))
PY
