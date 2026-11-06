#!/usr/bin/env bash
# Reconcile ended plan leads through PR, deploy and installed-check stages.
# Usage: fm-stage-transition.sh arm | check | budget | can-close <task-id>
# One authenticated watcher check per home; no daemon and no waiting worker.
# fm-pr-check.sh arms it when config/plan-leads.json exists. The plan owner
# supplies {"schema":1,"tasks":{"task-id":{"deploy_check":"check-id",
# "installed_check":"check-id"}}}.
# Optional queue_check reads a non-GitHub queue's registered head-bound drop
# verdict (red with a native event identity); native GitHub drops are also read.
# Tasks are explicit local ship leads; unlisted tasks retain existing behavior.
# Optional per-task relaunch_cap defaults to 3 attempts/hour/head/event class;
# capped events become eligible again after their one-hour window expires.
# check admits only unheld, unblocked Queued/In flight leads with no live
# worker or declared wait; known non-Done deferrals clear ledger completion.
# PR check/status red, queue drop, merge, deploy red and installed red trigger
# bounded relaunches in the same task, branch and copy, batched once per poll.
# due (epoch), next_step (text), task and estimate (seconds) are carried in
# state/.stage-transitions.json for the plan owner's wait-line renderer.
#
# A registered deploy/installed check is run from its authenticated snapshot
# with FM_STAGE_TASK and FM_STAGE_HEAD and must print a JSON object:
# {"head":"<exact PR/merged sha>","status":"green|red|pending|unknown",
#  "event":"<stable result/attempt identity>","reason":"<explanation>"}.
# A check's exit=0 alone is NOT green. Missing configuration, missing checks,
# wrong heads, skipped runs and unreadable dependencies remain UNKNOWN.
# GitHub reads use gh-axi's documented API path and base64 scalar transport;
# other forges remain UNKNOWN. No forge mutation or manual deploy is issued.
#
# Transitions use task+event+head; event includes its native attempt identity.
# A reservation is atomically saved before relaunch. A crash after reservation
# leaves outcome=reserved (UNKNOWN), requiring operator reconciliation rather
# than risking a duplicate launch. Failed launches are recorded and surfaced,
# never silently retried; proven admission deferrals remain eligible.
# Duplicate observations increment duplicate_count.
# Both merged-head receipts green close the ledger only when no new relaunch
# is owed. fm-backlog-transition-lib.sh gates new Done acceptance on can-close;
# fm-teardown.sh also requires it, including with --force.
# A Done row never relaunches and retains its accepted completion binding;
# can-close and later Done polls revalidate the same PR, branch, copy and head
# against fresh receipts. Still-open leads process new events even after green.
# Malformed receipt/forge values or task ledger records read UNKNOWN locally;
# an invalid registry or global ledger header refuses the entire stage sweep.
# FM_STAGE_CONTROL_TIMEOUT defaults to 600 seconds per relaunch; eligibility
# reads allow 60 seconds. budget returns 30 + lead_count * (control_timeout
# + 60 + 60) seconds; fm-watch.sh uses at least that bound for plan-stages,
# keeping its heartbeat fresh while waiting and other check deadlines unchanged.
# _eligible and _receipt are internal shell-library adapters, also used by the
# control plane for its under-lock stopped-only precondition.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME

case "${1:-}" in
  _run)
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    shift
    seconds=$1
    shift
    fm_exec_timed "$seconds" 1 "$@"
    ;;
  _eligible)
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
    id=${2:-}
    fm_pr_task_id_valid "$id" || exit 2
    meta="$STATE/$id.meta"
    [ "$(fm_meta_get "$meta" kind)" = ship ] \
      && [ -z "$(fm_meta_get "$meta" remote_host)" ] \
      || { echo unknown; exit; }
    fm_backlog_row_probe "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$id" \
      || { echo unknown; exit; }
    case "$FM_BACKLOG_ROW_STATE" in
      done\ *) echo done; exit ;;
      'in_flight no no'|'queued no no') ;;
      *) echo held; exit ;;
    esac
    fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 \
      || { echo unknown; exit; }
    line=$(status_current_line "$STATE/$id.status" ship)
    if status_is_paused_or_captain_held "$line"; then echo paused; exit; fi
    case "$(status_line_verb "$line")" in
      needs-decision|blocked) echo held; exit ;;
    esac
    current=$(FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$id")
    case "$current" in
      'state: paused '*|'state: parked '*|'state: blocked '*) echo paused; exit ;;
      'state: working '*) echo live; exit ;;
    esac
    case "$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")" in
      dead|missing) echo eligible ;;
      alive) echo live ;;
      *) echo unknown ;;
    esac
    exit ;;
  _receipt)
    # shellcheck source=bin/fm-pr-lib.sh
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    # shellcheck source=bin/fm-check-lib.sh
    . "$SCRIPT_DIR/fm-check-lib.sh"
    [ "$#" = 4 ] || exit 2
    fm_custom_check_snapshot_prepare "$STATE" "$2" || exit 1
    trap fm_custom_check_snapshot_cleanup EXIT
    FM_STAGE_TASK=$3 FM_STAGE_HEAD=$4 bash "$FM_CUSTOM_CHECK_SNAPSHOT"
    exit ;;
esac

exec python3 - "$SCRIPT_DIR" "$STATE" "$@" <<'PY'
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

scripts, state, *args = sys.argv[1:]
scripts, state = Path(scripts), Path(state)
home = Path(os.environ['FM_HOME']).resolve()
config = Path(os.environ.get('FM_CONFIG_OVERRIDE', home / 'config')) / 'plan-leads.json'
ledger = state / '.stage-transitions.json'
ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]*')
SHA = re.compile(r'(?:[0-9a-f]{40}|[0-9a-f]{64})')
RED = {'failure', 'error', 'timed_out', 'cancelled', 'action_required', 'startup_failure'}


class DependencyError(ValueError):
    def __init__(self, command, code):
        super().__init__('dependency refused: ' + Path(command).name)
        self.code = code


def typed(value, kind, label):
    if type(value) is not kind:
        raise ValueError('invalid ' + label + ': expected ' + kind.__name__)
    return value


def sha(value):
    if not SHA.fullmatch(typed(value, str, 'head')):
        raise ValueError('invalid head')
    return value


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError('unavailable ordinary file: ' + path.name)
    return typed(json.loads(path.read_text()), dict, path.name)


def load_ledger():
    data = read_json(ledger) if ledger.exists() else {'schema': 1, 'home': str(home), 'tasks': {}}
    if (typed(data.get('schema'), int, 'ledger schema') != 1
            or typed(data.get('home'), str, 'ledger home') != str(home)):
        raise ValueError('stage ledger schema/home mismatch')
    typed(data.get('tasks'), dict, 'ledger tasks')
    return data


def task_record(value):
    typed(value, dict, 'task record')
    typed(value.get('closed'), bool, 'completion')
    events = typed(value.get('events'), dict, 'events')
    for key, event in events.items():
        typed(event, dict, 'event')
        if typed(event.get('key'), str, 'event key') != key:
            raise ValueError('event key mismatch')
        typed(event.get('trigger'), str, 'event trigger')
        typed(event.get('time'), int, 'event time')
        sha(event.get('head'))
        if typed(event.get('outcome'), str, 'event outcome') not in {'reserved', 'relaunched', 'failed', 'capped'}:
            raise ValueError('invalid event outcome')
        if typed(event.get('duplicate_count'), int, 'duplicate count') < 0:
            raise ValueError('invalid duplicate count')
    for launch in typed(value.get('launches'), list, 'launches'):
        typed(launch, dict, 'launch')
        typed(launch.get('time'), int, 'launch time')
        sha(launch.get('head'))
        for trigger in typed(launch.get('triggers'), list, 'launch triggers'):
            typed(trigger, str, 'launch trigger')
    for field in ['task', 'pr', 'detail', 'next_step']:
        if field in value:
            typed(value[field], str, field)
    for field in ['due', 'estimate']:
        if field in value:
            typed(value[field], int, field)
    if 'head' in value:
        sha(value['head'])
    if 'identity' in value:
        identity = typed(value['identity'], list, 'task identity')
        if len(identity) != 2 or any(type(part) is not str for part in identity):
            raise ValueError('invalid task identity')
    return value


def save(value):
    if ledger.is_symlink() or (ledger.exists() and ledger.stat().st_nlink != 1):
        raise ValueError('unsafe stage ledger')
    fd, name = tempfile.mkstemp(prefix='.stage-write-', dir=state)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, sort_keys=True, separators=(',', ':'))
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, ledger)
        directory = os.open(state, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def run(command, timeout=5):
    # The existing timeout owner bounds descendants and handles owner death.
    # A timed-out control call may have published, so keep its reservation.
    result = subprocess.run([str(scripts / 'fm-stage-transition.sh'), '_run', str(timeout)]
                            + [str(v) for v in command], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True)
    if result.returncode:
        raise DependencyError(command[0], result.returncode)
    return result.stdout.strip()


def api(endpoint, query=None):
    command = ['gh-axi', 'api', 'POST' if query else 'GET', endpoint,
               '--jq', 'tojson | @base64', '--full']
    if query:
        command += ['--raw-field', 'query=' + query]
    return typed(json.loads(base64.b64decode(run(command), validate=True)), dict, 'forge response')


def metadata(task):
    path = state / (task + '.meta')
    if path.is_symlink() or not path.is_file():
        raise ValueError('task metadata unavailable')
    values = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep:
            values[key] = value
    if values.get('kind') != 'ship' or values.get('remote_host'):
        raise ValueError('not a local ship lead')
    if any(not values.get(field) for field in ['worktree', 'branch', 'pr']):
        raise ValueError('task identity or PR unavailable')
    return values


def receipt(check, task, head):
    if not check:
        return {'status': 'unknown', 'reason': 'no registered check configured'}
    if not isinstance(check, str) or not ID.fullmatch(check) or check == 'plan-stages':
        raise ValueError('invalid stage check id')
    result = typed(json.loads(run([scripts / 'fm-stage-transition.sh', '_receipt', check, task, head])),
                   dict, 'receipt ' + check)
    if sha(result.get('head')) != head:
        raise ValueError('check result does not match merged head: ' + check)
    if typed(result.get('status'), str, 'receipt status') not in {'green', 'red', 'pending', 'unknown'}:
        raise ValueError('unreadable stage verdict: ' + check)
    if not isinstance(result.get('event'), str) or not result['event']:
        raise ValueError('stage check has no event identity: ' + check)
    if 'reason' in result:
        typed(result['reason'], str, 'receipt reason')
    return result


def proof(call):
    try:
        return call()
    except (ValueError, OSError, KeyError, TypeError) as exc:
        return {'status': 'unknown', 'reason': str(exc)}


def observe(settings, task, meta):
    url = meta.get('pr', '')
    match = re.fullmatch(r'https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)', url)
    if not match:
        raise ValueError('no supported canonical PR recorded')
    repo, number = match.groups()
    row = api('/repos/' + repo + '/pulls/' + number)
    if (typed(row['html_url'], str, 'PR URL') != url
            or str(typed(row['number'], int, 'PR number')) != number):
        raise ValueError('PR identity mismatch')
    head = sha(typed(row['head'], dict, 'PR head')['sha'])
    pr_state = typed(row['state'], str, 'PR state')
    events = []
    if typed(row['merged'], bool, 'merged'):
        merged = sha(row['merge_commit_sha'])
        events.append(('merged', str(number), merged))
        deploy = proof(lambda: receipt(settings.get('deploy_check'), task, merged))
        installed = proof(lambda: receipt(settings.get('installed_check'), task, merged))
        for kind, result in [('deploy-red', deploy), ('installed-red', installed)]:
            if result['status'] == 'red':
                events.append((kind, result['event'], merged))
        green = deploy['status'] == installed['status'] == 'green'
        detail = 'deploy=' + deploy['status'].upper() + ' installed=' + installed['status'].upper()
        detail += '; ' + str(deploy.get('reason', '')) + '; ' + str(installed.get('reason', ''))
        return events, merged, green, detail
    if pr_state != 'open':
        raise ValueError('PR closed without merge')
    unknown = []
    try:
        checks = api('/repos/' + repo + '/commits/' + head + '/check-runs?filter=latest&per_page=100')
        for check in typed(checks['check_runs'], list, 'check runs'):
            typed(check, dict, 'check run')
            if sha(check['head_sha']) != head:
                raise ValueError('PR check head mismatch')
            conclusion = check['conclusion']
            check_id = typed(check['id'], int, 'check id')
            completed_at = check['completed_at']
            if completed_at is not None:
                typed(completed_at, str, 'check completion')
            if conclusion is not None and typed(conclusion, str, 'check conclusion') in RED:
                events.append(('pr-red', str(check_id) + ':'
                               + typed(completed_at, str, 'check completion'), head))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        unknown.append(str(exc))
    try:
        statuses = api('/repos/' + repo + '/commits/' + head + '/status')
        if sha(statuses['sha']) != head:
            raise ValueError('commit status head mismatch')
        for status in typed(statuses['statuses'], list, 'commit statuses'):
            typed(status, dict, 'commit status')
            status_id = typed(status['id'], int, 'status id')
            if typed(status['state'], str, 'commit state') in RED:
                events.append(('pr-red', 'status:' + str(status_id), head))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        unknown.append(str(exc))
    owner, name = repo.split('/')
    query = ('query { repository(owner:' + json.dumps(owner) + ',name:' + json.dumps(name)
             + ') { pullRequest(number:' + number + ') { timelineItems(last:100,'
             'itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]) { nodes {'
             ' ... on RemovedFromMergeQueueEvent { id beforeCommit { oid } } } } } } }')
    try:
        timeline = api('graphql', query)
        for field in ['data', 'repository', 'pullRequest', 'timelineItems']:
            timeline = typed(timeline[field], dict, 'queue ' + field)
        for drop in typed(timeline['nodes'], list, 'queue nodes'):
            typed(drop, dict, 'queue event')
            drop_id = typed(drop['id'], str, 'queue id')
            commit = drop.get('beforeCommit')
            if commit is not None and sha(typed(commit, dict, 'queue commit')['oid']) == head:
                events.append(('queue-drop', drop_id, head))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        unknown.append(str(exc))
    if settings.get('queue_check'):
        drop = proof(lambda: receipt(settings['queue_check'], task, head))
        if drop['status'] == 'red':
            events.append(('queue-drop', 'check:' + drop['event'], head))
        elif drop['status'] == 'unknown':
            unknown.append('queue check: ' + str(drop.get('reason', 'unknown result')))
    return events, head, False, 'PR watch; no deploy proof before merge' + (
        '; UNKNOWN: ' + '; '.join(unknown) if unknown else '')


def completion(settings, task, current, meta):
    if (not current.get('closed') or current.get('pr') != meta.get('pr')
            or current.get('identity') != [meta.get('worktree'), meta.get('branch')]):
        raise ValueError(task + ': deploy and installed checks are not both green')
    _, head, green, detail = observe(settings, task, meta)
    if head != current.get('head') or not green:
        raise ValueError(task + ': current deploy/installed evidence is not green for the closed head')
    return detail


def main():
    if not args or args[0] not in {'arm', 'check', 'budget', 'can-close'}:
        raise ValueError('usage: fm-stage-transition.sh arm | check | budget | can-close <task>')
    action = args[0]
    if not config.exists() and not config.is_symlink():
        if action == 'budget':
            print(30)
        return
    settings = read_json(config)
    if typed(settings.get('schema'), int, 'registry schema') != 1 or not isinstance(settings.get('tasks'), dict):
        raise ValueError('invalid plan-leads schema')
    tasks = settings['tasks']
    for task, item in tasks.items():
        if not ID.fullmatch(task) or not isinstance(item, dict):
            raise ValueError('invalid plan lead')
        cap = item.get('relaunch_cap', 3)
        if type(cap) is not int or not 1 <= cap <= 20:
            raise ValueError('invalid relaunch cap for ' + task)
    control_timeout = max(1, int(os.environ.get('FM_STAGE_CONTROL_TIMEOUT', '600')))
    eligibility_timeout = 60
    if action == 'budget':
        print(30 + len(tasks) * (control_timeout + eligibility_timeout + 60))
        return
    if action == 'arm':
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        shim = state / 'plan-stages.check.sh'
        if shim.is_symlink():
            raise ValueError('unsafe stage check shim')
        fd, name = tempfile.mkstemp(prefix='.stage-shim-', dir=state)
        with os.fdopen(fd, 'w') as out:
            out.write('#!/usr/bin/env bash\nexec env FM_HOME=' + shlex.quote(str(home))
                      + ' FM_STATE_OVERRIDE=' + shlex.quote(str(state))
                      + ' FM_CONFIG_OVERRIDE=' + shlex.quote(str(config.parent)) + ' '
                      + shlex.quote(str(scripts / 'fm-stage-transition.sh')) + ' check\n')
        os.chmod(name, 0o700)
        os.replace(name, shim)
        run([scripts / 'fm-check-register.sh', 'plan-stages'])
        return
    if action == 'can-close' and args[1] not in tasks:
        return
    data = load_ledger()
    if action == 'can-close':
        task = args[1]
        if task not in tasks:
            return
        current = task_record(data['tasks'].get(task, {'events': {}, 'launches': [], 'closed': False}))
        meta = metadata(task)
        completion(tasks[task], task, current, meta)
        return
    # A POSIX advisory lock dies with its owner, including on interrupted checks.
    lock = state / '.stage-transitions.lock'
    if lock.is_symlink():
        raise ValueError('unsafe stage lock')
    with lock.open('a') as held:
        try:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        data = load_ledger()
        for task, item in tasks.items():
            now = int(time.time())
            record = data['tasks'].setdefault(task, {'events': {}, 'launches': [], 'closed': False})
            old = None
            try:
                task_record(record)
                old = (record.get('detail'), record.get('next_step'), record.get('closed'))
                record.update(task=task, due=now + 300, next_step='reconcile stage', estimate=300)
                meta = metadata(task)
                eligibility = run([scripts / 'fm-stage-transition.sh', '_eligible', task], eligibility_timeout)
                if eligibility not in {'done', 'eligible', 'held', 'paused', 'live', 'unknown'}:
                    raise ValueError('unreadable stage eligibility')
                if eligibility == 'done':
                    detail = completion(item, task, record, meta)
                    record.update(detail=detail, next_step='teardown after deploy and installed green', due=now)
                else:
                    # Missing/reused task identity must never inherit an old close.
                    identity = [meta.get('worktree'), meta.get('branch')]
                    if record.get('identity', identity) != identity:
                        raise ValueError('task identity changed; explicit plan reconciliation required')
                    if eligibility != 'unknown':
                        record['closed'] = False
                    if not record['closed']:
                        record.update(identity=identity, pr=meta.get('pr'))
                    if eligibility != 'eligible':
                        record.update(detail='deferred: ' + eligibility, next_step='wait for eligible ended worker')
                    else:
                        events, head, green, detail = observe(item, task, meta)
                        record.update(head=head, detail=detail, next_step='watch deploy and installed check')
                        # Batch all triggers observed in one poll into one bounded
                        # relaunch; later events wait while that worker is alive.
                        launch = []
                        for kind, event, event_head in events:
                            key = task + '|' + kind + ':' + event + '|' + event_head
                            prior = record['events'].get(key)
                            if prior and not (prior['outcome'] == 'capped' and prior['time'] <= now - 3600):
                                prior['duplicate_count'] += 1
                                if prior['outcome'] in {'reserved', 'failed', 'capped'}:
                                    record['detail'] += '; UNKNOWN action ' + prior['outcome'] + ': ' + kind
                                continue
                            count = sum(e['time'] > now - 3600 and e['head'] == event_head
                                        and kind in e['triggers'] for e in record['launches'])
                            outcome = 'capped' if count >= item.get('relaunch_cap', 3) else 'reserved'
                            record['events'][key] = dict(trigger=kind, key=key, time=now, head=event_head,
                                                        outcome=outcome, duplicate_count=0)
                            if outcome == 'capped':
                                record['detail'] += '; relaunch cap reached: ' + task + ' ' + kind
                            else:
                                launch.append(key)
                        if launch:
                            record['launches'] = [e for e in record['launches'] if e['time'] > now - 3600]
                            record['launches'].append(dict(time=now, head=head,
                                                           triggers=list({record['events'][k]['trigger'] for k in launch})))
                            save(data)
                            note = ('Stage transition: ' + ', '.join(record['events'][k]['trigger'] for k in launch)
                                    + '; head=' + head + '. Continue this same task, branch and copy. '
                                    'Do bounded repair only; never deploy manually or idle-wait holding a seat. '
                                    'The registered plan-stages check owns deploy/installed observation.')
                            try:
                                run([scripts / 'fm-control.sh', task, 'relaunch', '--if-stopped', '--note', note],
                                    control_timeout)
                                outcome = 'relaunched'
                                record['detail'] += '; relaunched: ' + task
                            except DependencyError as exc:
                                if exc.code == 3:
                                    for key in launch:
                                        del record['events'][key]
                                    record['launches'].pop()
                                    launch = []
                                    record['detail'] += '; deferred: pre-launch refusal'
                                else:
                                    outcome = 'failed'
                                    record['detail'] += '; UNKNOWN relaunch failed: ' + task
                            except (ValueError, OSError):
                                outcome = 'failed'
                                record['detail'] += '; UNKNOWN relaunch failed: ' + task
                            for key in launch:
                                record['events'][key]['outcome'] = outcome
                            # A relaunch is work owed, even if all checks just read
                            # green. Wait for its bounded return before closure.
                            green = False
                        if green:
                            record.update(closed=True, next_step='teardown after deploy and installed green', due=now)
            except (ValueError, OSError, KeyError, TypeError) as exc:
                if old is None:
                    print(task + ': UNKNOWN: ' + str(exc))
                    continue
                record.update(detail='UNKNOWN: ' + str(exc), next_step='repair stage evidence')
            save(data)
            if (record['detail'], record['next_step'], record['closed']) != old:
                print(task + ': ' + record['detail'] + '; next=' + record['next_step'])


try:
    main()
except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
    print('plan-stages: UNKNOWN: ' + str(error))
    sys.exit(1)
PY
