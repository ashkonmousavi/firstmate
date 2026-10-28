"""Live backstop CLI against disposable mate logs over loopback SSH.

Oracle: author's acceptance criteria, explicit input epochs and byte lengths.
The SSH fixture only dispatches fm-on's serialized read requests to the real
file and delta executables; it generates no reply data or backstop decisions.
Server API reference: https://asyncssh.readthedocs.io/en/latest/#simple-server
Run from the gate worktree after installing asyncssh into .test-backstop-tmp/deps.
"""
import asyncio, base64, hashlib, json, os, shlex, shutil, subprocess, sys, time
from pathlib import Path
import asyncssh

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
LAB = ROOT / '.test-backstop-tmp/live'
CALLS = []
RESULTS = []
TRANSCRIPT = []
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('HERDR_SESSION',)}
NOW = int(time.time())
OLD, FRESH = NOW - 2000, NOW - 5

class SSHServer(asyncssh.SSHServer):
    def begin_auth(self, username):
        return False

async def endpoint(process):
    try:
        command = shlex.split(process.command)
        assert command[:2] == ['fm-remote-entrypoint.sh', '1'], command
        root = Path(base64.b64decode(command[2]).decode())
        home = Path(base64.b64decode(command[3]).decode())
        args = base64.b64decode(command[4]).rstrip(b'\0').decode().split('\0')
        assert root == ROOT and home.is_relative_to(LAB), (root,home)
        assert args[0] in ('fm-remote-file.sh', 'fm-remote-delta-read.sh')
        assert args[1:] and ('state/parent-replies.status' in args)
        env = dict(ENV, FM_HOME=str(home), TMPDIR=str(LAB / 'tmp'))
        child = await asyncio.create_subprocess_exec(str(ROOT/'bin'/args[0]), *args[1:], env=env,
                    stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await child.communicate()
        CALLS.append({'home': str(home.relative_to(LAB)), 'argv': args, 'exit':child.returncode,
                      'stdout_bytes':len(out), 'stderr':err.decode(errors='replace')})
        process.stdout.write(out)
        process.stderr.write(err)
        process.exit(child.returncode)
    except Exception as error:
        process.stderr.write(repr(error).encode())
        process.exit(99)


def setup(name, remote, mirror='', state=None):
    home, mate = LAB/name/'main', LAB/name/'mate'
    for path in (home/'state', home/'data', home/'config', mate/'state'):
        path.mkdir(parents=True)
    (home/'state/.last-watcher-beat').touch()
    (mate/'state/parent-replies.status').write_text(remote)
    if mirror:
        (home/'state/.remote-reply-mirrored-lab-mate').write_text(mirror)
    if state is not None:
        (home/'state/.main-backstop.json').write_text(json.dumps(state))
    (home/'data/secondmates.md').write_text(f'- lab-mate - disposable (host: fm-test; root: {ROOT}; home: {mate}; scope: test; projects: test; added 2026-10-28)\n')
    return home, mate

async def run(home, label, candidate=None):
    args = [sys.executable, str(candidate or ROOT/'bin/fm-main-backstop.py'), '--home', str(home),
            '--code-root', str(ROOT), '--mate', 'lab-mate', '--send-enabled-file', str(home/'config/main-backstop-send-enabled')]
    child = await asyncio.create_subprocess_exec(*args, env=dict(ENV, FM_SSH_BIN=str(LAB/'ssh'), TMPDIR=str(LAB/'tmp')),
                   stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await asyncio.wait_for(child.communicate(), 25)
    journal = home/'state/.main-backstop.json'
    state = json.loads(journal.read_text()) if journal.exists() else None
    result = {'label':label,'argv':args,'exit':child.returncode,'stdout':out.decode(),'stderr':err.decode(),'state':state}
    TRANSCRIPT.append(result)
    print(json.dumps(result), flush=True)
    return result


def check(result):
    assert result['exit'] == 0, result
    return result['state']

def healthy(state):
    assert state['read_fails'] == {}, state
    assert not any('UNVERIFIED' in text for text in state.get('deferred_alarms',{}).values()), state

def record(name):
    RESULTS.append({'name':name,'result':'pass','live':True})

async def main():
    LAB.mkdir(parents=True)
    (LAB/'tmp').mkdir()
    server_key = asyncssh.generate_private_key('ssh-ed25519')
    listener = await asyncssh.create_server(SSHServer, '127.0.0.1', 0,
                 server_host_keys=[server_key], process_factory=endpoint, encoding=None)
    port = listener.get_port()
    (LAB/'known_hosts').write_text(f'[127.0.0.1]:{port} '+server_key.export_public_key().decode())
    (LAB/'ssh-config').write_text(f'Host fm-test\n HostName 127.0.0.1\n Port {port}\n User disposable\n BatchMode yes\n IdentityAgent none\n IdentitiesOnly yes\n IdentityFile none\n UserKnownHostsFile {LAB}/known_hosts\n GlobalKnownHostsFile /dev/null\n StrictHostKeyChecking yes\n')
    (LAB/'ssh').write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(LAB/'ssh-config'))+' "$@"\n')
    (LAB/'ssh').chmod(0o755)
    try:
        head = f'done [corr=sample] [at={OLD}]: landed the first item\n'
        plain = 'Desk page: no lane of mine owns /x/desk; résumé.\nStep 1, wiring: two follow-up swaps stay open.\n'
        rejected = 'done [at=01060]: grammar-rejected continuation\ndone [at=1060] [at=9000]: duplicate stamp continuation\n'
        further = f'done [at={FRESH}]: second entry\n'
        entry = head+plain+rejected
        home,mate = setup('whole', entry+further, entry)
        state = check(await run(home,'whole-file multiline and local mirror'))
        healthy(state)
        assert state['readers']['lab-mate']['pending_at'] == [FRESH]
        assert state['readers']['lab-mate']['offset'] == len((entry+further).encode())
        record('Whole-file multiline replies and mirror accept plain and grammar-rejected continuation lines')

        home,mate = setup('delta',head,head)
        check(await run(home,'delta bootstrap'))
        count=len(CALLS)
        with (mate/'state/parent-replies.status').open('a') as f: f.write(plain+rejected)
        state=check(await run(home,'delta starts with continuation at nonzero byte cursor'))
        healthy(state)
        assert state['readers']['lab-mate']['pending_at']==[]
        assert all(c['argv'][0]=='fm-remote-delta-read.sh' for c in CALLS[count:])
        with (mate/'state/parent-replies.status').open('a') as f:f.write(further)
        state=check(await run(home,'delta receives next entry'))
        healthy(state)
        assert state['readers']['lab-mate']['pending_at']==[FRESH]
        assert state['readers']['lab-mate']['offset']==len((entry+further).encode())
        (home/'state/.remote-reply-mirrored-lab-mate').write_text(entry+further)
        state=check(await run(home,'mirror catches up'))
        healthy(state)
        assert state['readers']['lab-mate']['pending_at']==[]
        record('Nonzero delta cursor accepts leading continuations, tracks UTF-8 byte length, and clears mirrored replies')

        home,mate=setup('zero',entry+further,entry,{'readers':{'lab-mate':{'offset':0,'prefix':hashlib.sha256(b'').hexdigest(),'pending_at':[]}}})
        count=len(CALLS)
        state=check(await run(home,'offset-zero valid delta'))
        healthy(state)
        assert state['readers']['lab-mate']['pending_at']==[FRESH]
        assert all(c['argv'][0]=='fm-remote-delta-read.sh' for c in CALLS[count:])
        record('Offset-zero delta accepts a parsed head followed by multiline content')

        for label,bad in [('plain','orphan continuation\n'),('duplicate','done [at=1060] [at=9000]: duplicate\n'),('zero','done [at=01060]: leading zero\n')]:
            for mode in ('whole','zero','mirror'):
                cursor={'offset':0,'prefix':hashlib.sha256(b'').hexdigest(),'pending_at':[OLD]}
                seeded={'readers':{'lab-mate':cursor},'episodes':{'lag-lab-mate':'existing-incident'},'lag_oldest':{'lab-mate':OLD}}
                home,mate=setup(f'corrupt-{label}-{mode}',bad+head if mode!='mirror' else head,
                                 bad+head if mode=='mirror' else '', seeded if mode!='whole' else None)
                for attempt in range(2):
                    state=check(await run(home,f'corrupt {label} {mode} attempt {attempt+1}'))
                    assert 'lab-mate' in state['read_fails']
                    if mode=='whole': assert 'lab-mate' not in state.get('readers',{})
                    else:
                        assert state['readers']['lab-mate']==cursor
                        assert state['episodes']['lag-lab-mate']=='existing-incident'
                assert any('REPLY DELIVERY UNVERIFIED' in s for s in state['deferred_alarms'].values())
        record('Corrupt leading lines fail whole-file, offset-zero delta, and local mirror reads without committing cursor progress or clearing lag')

        legacy={'episodes':[],'read_fails':[],'runner_fails':[],'last_nudge':4700,
                'readers':{'lab-mate':{'offset':12,'prefix':'a'*64,'stamp':OLD}}}
        home,mate=setup('legacy',entry+further,entry,legacy)
        state=check(await run(home,'legacy list state and obsolete reader bootstrap'))
        healthy(state)
        assert state['episodes']=={} and state['runner_fails']=={} and state['last_nudge']==4700
        assert state['readers']['lab-mate']['offset']==len((entry+further).encode())
        assert state['readers']['lab-mate']['pending_at']==[FRESH]
        record('Legacy list state runs cleanly, preserves last_nudge, and reboots obsolete reader records')

        legacy={'episodes':None,'read_fails':'old','runner_fails':42,'last_nudge':4700,
                'readers':{'lab-mate':{'offset':len(head.encode()),'prefix':hashlib.sha256(head.encode()).hexdigest(),'pending_at':[OLD]}}}
        home,mate=setup('valid-cursor',entry+further,head,legacy)
        count=len(CALLS)
        state=check(await run(home,'non-dict migration preserves a valid cursor'))
        healthy(state)
        assert state['last_nudge']==4700 and state['episodes']=={} and state['runner_fails']=={}
        assert state['readers']['lab-mate']['pending_at']==[FRESH]
        assert all(c['argv'][0]=='fm-remote-delta-read.sh' for c in CALLS[count:])
        record('Non-dict legacy bookkeeping resets while a valid byte cursor and last_nudge survive')

        home,mate=setup('lag',entry+further)
        state=check(await run(home,'multiline pending reply remains a lag incident'))
        healthy(state)
        assert state['readers']['lab-mate']['pending_at']==[OLD,FRESH]
        assert state['lag_oldest']['lab-mate']==OLD
        assert any(f'oldest_at={OLD} ingested_at=0' in text for text in state['deferred_alarms'].values())
        record('Multiline reads retain the oldest unmirrored reply and report delivery lag instead of claiming caught up')

        # Reproduce the original failures through the same real CLI, without modifying tracked source.
        base=LAB/'base'
        base.mkdir()
        for script in (ROOT/'bin').iterdir():
            if script.is_file() and script.name!='fm-main-backstop.py':(base/script.name).symlink_to(script)
        baseline=base/'fm-main-backstop.py'
        baseline.write_bytes(subprocess.check_output(['git','show','b1d56ea04800102e9718ff266d57992bcd5ac70a:bin/fm-main-backstop.py']))
        home,mate=setup('red-multiline',entry+further,head)
        state=check(await run(home,'BEFORE FIX: multiline read fails',baseline))
        assert 'lab-mate' in state['read_fails']
        home,mate=setup('red-delta',entry+further,head,{'readers':{'lab-mate':{'offset':len(head.encode()),'prefix':hashlib.sha256(head.encode()).hexdigest(),'pending_at':[]}}})
        state=check(await run(home,'BEFORE FIX: leading delta continuation fails',baseline))
        assert 'lab-mate' in state['read_fails']
        assert state['readers']['lab-mate']['offset']==len(head.encode())
        home,mate=setup('red-legacy',head,head,{'episodes':[],'read_fails':[],'runner_fails':[],'last_nudge':4700})
        result=await run(home,'BEFORE FIX: legacy list state crashes',baseline)
        assert result['exit']!=0 and 'TypeError: pop expected at most 1 argument, got 2' in result['stderr']
        RESULTS.append({'name':'Regression reproduction on base commit','result':'pass','live':True})
    finally:
        listener.close()
        await listener.wait_closed()
        (EVIDENCE/'live-backstop.json').write_text(json.dumps({'scenarios':RESULTS,'passes':TRANSCRIPT,'remote_calls':CALLS},indent=2)+'\n')
        shutil.rmtree(LAB)
    print(json.dumps({'scenarios':RESULTS,'disposable_listener_closed':True,'lab_removed':not LAB.exists()}),flush=True)

asyncio.run(main())
