#!/usr/bin/env python3
"""Run from the gate worktree. Real CLI/backend; no substituted dependencies.

Oracle: author intent, modified by recorded R1 decision allowing work origins.
Rejects unsourced asks, mutation on refusal, invalid owner custody, or regressions
in accepted calls and the external-wait remedy. All data is disposable.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path(__file__).resolve().parent
events = []
results = []
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE', 'TMUX')}


def run(home, executable, *args, expected=0):
    command = [str(ROOT / executable), *map(str, args)]
    e = dict(env, FM_HOME=str(home), TMPDIR=str(home / 'tmp'))
    p = subprocess.run(command, cwd=ROOT, env=e, text=True, capture_output=True, timeout=45)
    events.append({'command': shlex.join(command), 'FM_HOME': str(home),
                   'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    if expected == 'refusal':
        assert p.returncode != 0, events[-1]
        assert "a wait that is firstmate's own is not a captain call" in p.stderr, events[-1]
        assert 'fm-tasks-axi.sh hold <id> --reason <text> --kind external --until YYYY-MM-DD' in p.stderr, events[-1]
    else:
        assert p.returncode == expected, events[-1]
    return p.stdout


def axi(home, *args, **kw):
    return run(home, 'bin/fm-tasks-axi.sh', *args, **kw)


def hold(home, *args, **kw):
    return run(home, 'bin/fm-captain-hold.sh', 'hold', *args, **kw)


def refusal(home, *args):
    before = (home / 'data/backlog.md').read_bytes()
    hold(home, *args, expected='refusal')
    assert (home / 'data/backlog.md').read_bytes() == before, 'Refusal changed backlog'


def show(home, task):
    return axi(home, 'show', task, '--full')


def field(shown, name):
    value = next(line.split(': ', 1)[1] for line in shown.splitlines() if line.startswith('  ' + name + ': '))
    if value.startswith('"'):
        return json.loads(value)
    return value


def expect_held(home, task, kind):
    shown = show(home, task)
    assert field(shown, 'held') == 'yes', shown
    assert field(shown, 'hold_kind') == kind, shown
    return shown


def acceptance(home, task):
    text = 'Please explain the freeze exception and wait for my choice.'
    return {'version': 1, 'origin_home': str(home), 'origin_task_id': task,
            'expected_body_sha256': None, 'interpretation_owner': 'intake',
            'interpretation_complete': True,
            'sources': [{'session_id': 'disposable-session', 'message_uuid': 'lab-owner-message',
                         'file_ref': 'disposable-conversation.json', 'source_custody': 'complete',
                         'full_text': text, 'full_text_sha256': hashlib.sha256(text.encode()).hexdigest()}],
            'requirements': [{'id': 'r1', 'kind': 'explanation', 'source_message_uuid': 'lab-owner-message',
                              'text_ref': text, 'safe_text': None, 'source_binding': 'verified_complete',
                              'disposition': 'pending', 'proof_refs': [], 'superseded_by': [],
                              'proof_kind': 'reply', 'acceptance_level': 'source'}], 'corrections': []}


def scenario(name, fn):
    start = len(events)
    try:
        fn()
        results.append({'name': name, 'result': 'pass', 'live': True, 'events': [start, len(events)]})
    except Exception as exc:
        results.append({'name': name, 'result': 'fail', 'live': True, 'events': [start, len(events)], 'error': str(exc)})
        raise


try:
    with tempfile.TemporaryDirectory(prefix='.fm-lab-hold-', dir=ROOT) as temp:
        home = Path(temp)
        # Mark the empty stock home through the supported lab-home writer.
        p = subprocess.run([str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)],
                           env=env, cwd=ROOT, text=True, capture_output=True, timeout=15)
        assert p.returncode == 0, p.stderr
        (home / 'tmp').mkdir()
        (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
        (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')

        def new_waits():
            for task, reason in [('freeze-wait', 'wait until the freeze ends'),
                                 ('date-wait', 'revisit on 2099-01-01'),
                                 ('dependency-wait', 'wait for the other task to finish')]:
                refusal(home, task, '--title', task, '--reason', reason)
        scenario('New unsourced freeze, date and dependency waits are refused with the external-hold remedy and no task created', new_waits)

        def existing_waits():
            axi(home, 'add', 'existing-wait', 'Existing task', '--body', 'Original work body')
            refusal(home, 'existing-wait', '--reason', 'wait until freeze ends', '--until', '2099-01-01')
            # A real backend legacy captain hold predates the new gate.
            axi(home, 'hold', 'existing-wait', '--reason', 'legacy captain wait', '--kind', 'captain')
            refusal(home, 'existing-wait', '--reason', 'defer the old unsourced wait', '--until', '2099-02-01')
            expect_held(home, 'existing-wait', 'captain')
        scenario('Existing tasks and legacy unsourced captain re-holds are refused without altering their body, reason or hold state', existing_waits)

        def invalid_owner():
            refusal(home, 'owner-new', '--title', 'Missing source', '--reason', 'captain choice',
                    '--origin', 'review-origin', '--origin-kind', 'owner-request')
            axi(home, 'add', 'owner-prose', 'Unverified owner prose', '--body', 'Owner message: lab-owner-message\nCaptain hold origin: review-origin\nCaptain hold origin-kind: owner-request')
            refusal(home, 'owner-prose', '--reason', 'captain choice')
            refusal(home, 'owner-prose', '--reason', 'captain choice', '--origin', 'new-origin')
            axi(home, 'add', 'owner-malformed', 'Invalid acceptance', '--body', '```Owner request acceptance v1\n{}\n```')
            refusal(home, 'owner-malformed', '--reason', 'captain choice', '--origin', 'review-origin', '--origin-kind', 'owner-request')
            refusal(home, 'owner-malformed', '--reason', 'captain choice')
        scenario('Owner-request attribution rejects origin-only, inherited unverified prose, and malformed acceptance records before mutation', invalid_owner)

        def valid_owner():
            for task, kind in [('owner-valid', 'owner-request'), ('owner-unattributed', None)]:
                packet = home / (task + '.json')
                packet.write_text(json.dumps(acceptance(home, task)))
                packet.chmod(0o600)
                axi(home, 'add', task, 'Bound request', '--owner-request-file', packet)
                before = field(show(home, task), 'body')
                section = before[before.index('```Owner request acceptance v1'):]
                args = ['--origin-kind', kind] if kind else []
                hold(home, task, '--reason', 'captain choice on the bound request', *args)
                shown = expect_held(home, task, 'captain')
                assert section in field(shown, 'body'), shown
                stamp = field(shown, 'body').splitlines()[0]
                hold(home, task, '--reason', 'captain deferred the bound request', '--until', '2099-01-01')
                shown = expect_held(home, task, 'captain')
                assert field(shown, 'body').splitlines()[0] == stamp, shown
                assert section in field(shown, 'body'), shown
                if kind:
                    assert 'Captain hold origin-kind: owner-request' in field(shown, 'body'), shown
        scenario('Validated owner messages permit captain holds with explicit or omitted attribution and survive a deferred re-hold', valid_owner)

        def work_origins():
            for task, kind in [('finding-call', 'finding'), ('pipeline-call', 'pipeline-outcome'), ('ordinary-call', None)]:
                args = ['--origin-kind', kind] if kind else []
                hold(home, task, '--title', task, '--reason', 'captain choice raised by review', '--origin', 'review-origin', *args)
                shown = expect_held(home, task, 'captain')
                assert 'Captain hold origin: review-origin' in field(shown, 'body'), shown
                hold(home, task, '--reason', 'captain choice still pending')
                shown = expect_held(home, task, 'captain')
                assert 'Captain hold origin: review-origin' in field(shown, 'body'), shown
                if kind:
                    assert 'Captain hold origin-kind: ' + kind in field(shown, 'body'), shown
            # Explicitly switching to owner-request requires validated custody.
            refusal(home, 'finding-call', '--reason', 'claim owner provenance', '--origin-kind', 'owner-request')
            run(home, 'bin/fm-decision-hold.sh', 'hold', 'review-origin', 'merge-choice', '--title', 'Merge choice', '--reason', 'captain route choice')
            shown = expect_held(home, 'review-origin-decision-merge-choice', 'captain')
            assert 'Captain hold origin: review-origin' in field(shown, 'body'), shown
        scenario('Recorded decision compatibility: finding, pipeline and unattributed work origins, preserved origins and legacy callers remain accepted', work_origins)

        def external_wait():
            axi(home, 'add', 'plain-freeze', 'Wait for freeze', '--body', 'Work resumes after the freeze')
            axi(home, 'hold', 'plain-freeze', '--reason', 'wait until the freeze ends', '--kind', 'external', '--until', '2099-01-01')
            shown = expect_held(home, 'plain-freeze', 'external')
            assert 'captain' not in field(shown, 'hold_kind'), shown
            refusal(home, 'plain-freeze', '--reason', 'misclassify the external wait')
            expect_held(home, 'plain-freeze', 'external')
        scenario('The recommended plain external hold works, and trying to convert that unsourced wait into an owner ask is refused', external_wait)

        events.append({'persisted_backlog': (home / 'data/backlog.md').read_text()})
finally:
    (EVIDENCE / 'hold-provenance-transcript.json').write_text(json.dumps({'scenarios': results, 'events': events}, indent=2) + '\n')
    (EVIDENCE / 'hold-provenance-transcript.txt').write_text('\n\n'.join(
        ('$ FM_HOME=' + event['FM_HOME'] + ' ' + event['command'] + '\nexit: ' + str(event['exit']) + '\n' + event['stdout'] + event['stderr'])
        if 'command' in event else ('Final disposable backlog:\n' + event['persisted_backlog']) for event in events) + '\n')
    print(json.dumps(results, indent=2))
