#!/usr/bin/env bash
# Contract-derived stage transitions through the executable's public interface.
# No live worker, forge write, daemon, deployed app or machine install.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export FM_STAGE_TEST_ROOT="$ROOT"
python3 - <<'PY'
import base64
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
if [ "${1:-}" = _eligible ]; then cat "$FM_HOME/eligible"; exit; fi
exec "$(dirname "$0")/fm-stage-real.sh" "$@"
''')
        self.script('fm-control.sh', '''#!/usr/bin/env bash
[ "$2" = relaunch ] && [ "$3" = --if-stopped ] || exit 9
printf '%s\n' "$1" >> "$FM_HOME/calls"
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
elif '/actions/workflows/' in path: name='workflow'
else: sys.exit(9)
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
                             text=True, capture_output=True, timeout=20)
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
        self.queue('different-class')
        self.run_stage('check')
        self.assertEqual(len(self.calls()), 4)

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
        item['deploy_workflow'] = 'deploy.yml'
        self.configure()
        for runs in [[], [{'head_sha': OTHER, 'id': 1, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'success'}],
                     [{'head_sha': MERGED, 'id': 1, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'skipped'}]]:
            self.put('workflow', {'workflow_runs': runs})
            self.run_stage('check')
            self.assertFalse(self.record()['closed'])
        self.check('installed', 'green')
        self.put('workflow', {'workflow_runs': [{'head_sha': MERGED, 'id': 1, 'run_attempt': 1,
                                               'status': 'completed', 'conclusion': 'success'}]})
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
