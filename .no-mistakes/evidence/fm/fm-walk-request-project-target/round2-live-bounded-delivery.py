#!/usr/bin/env python3
"""Exercise real request-check CLI and real fm-send; probe only the private dispatcher boundary."""
import base64, ctypes, json, os, shutil, subprocess, tempfile, time
from pathlib import Path

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M6652CCZDGTN89BP9K68QCQS')
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # Adopt and await detached dispatch children.
CHECK = ROOT / 'bin/fm-walk-request-check.sh'
BASE = ROOT / 'bin/.fm-walk-request-check-base-validation.sh'
RELEASE = '0123456789abcdef0123456789abcdef01234567'
BRIEF = 'Disposable routing acceptance brief. No external walks are requested.\n'
PROBE = '''#!/usr/bin/env python3
import argparse,json,os,sys
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('brief'); p.add_argument('--bot', required=True); p.add_argument('--walk', required=True)
p.add_argument('--walk-owner', required=True); p.add_argument('--timeout', required=True)
p.add_argument('--once-key', required=True); p.add_argument('--project'); p.add_argument('--target')
a=p.parse_args()
with open(Path(os.environ['FM_HOME'])/'state/dispatch-calls.jsonl','a') as f:
 f.write(json.dumps({'argv':sys.argv[1:], 'brief_content':Path(a.brief).read_text(), **vars(a)})+'\\n')
if os.environ.get('VALIDATION_REQUIRE_ROUTE') == '1' and (a.project,a.target) != ('x','production'):
 print('explicit supported --project and --target required'); sys.exit(2)
print('dispatcher boundary accepted: project=%s target=%s walk=%s once-key=%s' % (a.project,a.target,a.walk,a.once_key))
'''

base_env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
results = []
scratch = ROOT / '.walk-route-validation'
scratch.mkdir(exist_ok=True)
created_base = not BASE.exists()
if created_base:
    BASE.write_bytes(subprocess.check_output(['git','show','2bafe15f26658147adf097c4f0dbef263761c814:bin/fm-walk-request-check.sh']))
    BASE.chmod(0o700)

def reap():
    end=time.monotonic()+5
    while True:
        try:
            pid,status=os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid:
            code=os.waitstatus_to_exitcode(status)
            print('awaited child exit='+str(code))
            assert code in (0,-15), ('unexpected child exit', pid, status)
        elif time.monotonic()>end:
            raise AssertionError('detached child has not exited')
        else:
            time.sleep(.03)

def run(args, env, expected=0):
    p=subprocess.run([str(x) for x in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
    print('$ '+ ' '.join(str(x) for x in args))
    print(p.stdout.strip() or '(silent)')
    print('exit='+str(p.returncode))
    assert p.returncode==expected, (p.returncode,p.stdout)
    return p.stdout

def fixture(root,label,project=None,target=None,strict=False,typed_route=False):
    lab=root/label
    run([ROOT/'bin/fm-lab-home.sh','create',lab],base_env)
    (lab/'data/bin').mkdir()
    dispatcher=lab/'data/bin/fm-grok-bot-dispatch.sh'
    dispatcher.write_text(PROBE); dispatcher.chmod(0o700)
    (lab/'state/route-mate.meta').write_text('kind=secondmate\nbackend=tmux\nwindow=fm-lab:fm-route-mate\nharness=codex\nhome='+str(lab)+'\n')
    corr='abcdef0123456789'
    line=f'note [corr={corr}]: walk-request: walks=desk-step brief64={base64.b64encode(BRIEF.encode()).decode()} release={RELEASE} bot=J01Walker'
    if typed_route: line+=' project=untrusted target=other'
    (lab/'state/route-mate.status').write_text(line+'\n')
    env=dict(base_env, FM_HOME=str(lab), FM_ROOT_OVERRIDE=str(ROOT), FM_STATE_OVERRIDE=str(lab/'state'), TMUX=str(lab/'no-server-socket')+',0,0')
    if project is not None: env['FM_WALK_REQUEST_PROJECT']=project
    if target is not None: env['FM_WALK_REQUEST_TARGET']=target
    if strict: env['VALIDATION_REQUIRE_ROUTE']='1'
    return lab,corr,env

def collect(lab,corr,env):
    log=lab/f'state/walk-requests/{corr}.desk-step.log'
    end=time.monotonic()+10
    while not log.exists() or '__FM_WALK_DISPATCH_EXIT__=' not in log.read_text():
        assert time.monotonic()<end, 'dispatch never completed'
        time.sleep(.05)
    reap()
    print('DISPATCH REPORT:\n'+log.read_text())
    run([CHECK,'check'],env)
    messages=list((lab/'state/route-mate.inbox').glob('*.msg'))
    assert len(messages)==1, messages
    print('REAL FM-SEND INBOX:\n'+messages[0].read_text())
    assert 'dispatcher boundary accepted' in messages[0].read_text()
    assert 'delivery=fire-and-forget' in messages[0].read_text()
    calls=[json.loads(x) for x in (lab/'state/dispatch-calls.jsonl').read_text().splitlines()]
    assert len(calls)==1, calls
    call=calls[0]
    assert call['brief_content']==BRIEF
    assert (call['bot'],call['walk'],call['walk_owner'],call['timeout'],call['once_key']) == ('J01Walker','desk-step','route-mate','1800','desk-step@'+RELEASE)
    run([CHECK,'check'],env)
    assert len((lab/'state/dispatch-calls.jsonl').read_text().splitlines())==1
    assert len(list((lab/'state/route-mate.inbox').glob('*.msg')))==1
    return call

try:
    with tempfile.TemporaryDirectory(prefix='bounded-live-',dir=scratch) as td:
        lab,corr,env=fixture(Path(td),'contended','x','production',strict=True)
        run([CHECK,'check'],env)
        log=lab/f'state/walk-requests/{corr}.desk-step.log'
        end=time.monotonic()+10
        while not log.exists() or '__FM_WALK_DISPATCH_EXIT__=0' not in log.read_text():
            assert time.monotonic()<end
            time.sleep(.05)
        reap()
        holder_script=r"""
. "$1/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$FM_HOME/state/route-mate.meta")
fm_lock_try_create "$lock" || exit 1
trap 'fm_lock_release "$lock"' EXIT
printf 'lock held\n'
read -r release
"""
        holder=subprocess.Popen(['bash','-c',holder_script,'lock-holder',str(ROOT)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            assert holder.stdout.readline().strip()=='lock held'
            print('Real fm-send target metadata lock held by another live process.')
            bounded=dict(env,FM_CHECK_TIMEOUT='4',FM_TASK_INBOX_LOCK_WAIT_SECS='20')
            for n in range(3):
                start=time.monotonic()
                run([CHECK,'check'],bounded)
                elapsed=time.monotonic()-start
                print('sweep='+str(n+1)+' elapsed='+str(round(elapsed,3))+'s registered_bound=4s')
                assert elapsed<4
                assert not list((lab/'state/route-mate.inbox').glob('*.msg'))
            record=lab/f'state/walk-requests/{corr}.record'
            print('PENDING RECORD:\n'+record.read_text())
            assert 'phase=delivered' not in record.read_text()
        finally:
            out,err=holder.communicate('release\n',timeout=5)
            print('lock-holder exit='+str(holder.returncode)+' '+out+err)
            assert holder.returncode==0
        call=collect(lab,corr,env)
        assert (call['project'],call['target'])==('x','production')
        print('Recovered real inbox delivery after releasing contention; repeated sweep remained idempotent.')
finally:
    if created_base: BASE.unlink()
    try: scratch.rmdir()
    except OSError: pass
    print('Disposable homes removed; holder and dispatch children awaited.')
