"""Local SSH + genuine remote lanes; no synthetic exit codes or delta records.
Run: PYTHONPATH=$PWD/.gate-test-tmp/deps python3 <this-file>
Oracle: user intent (three reissues, four-read budget, two-pass escalation),
plus the remote-job exit-76 contract. SIGSTOP freezes only a lab reader group
so the genuine lane must preempt it for a genuinely queued short command.
"""
import asyncio, base64, hashlib, json, os, shlex, shutil, signal, tempfile, time
from pathlib import Path
import asyncssh
ROOT = Path.cwd()
EVID = Path(__file__).parent
BASE = Path(tempfile.mkdtemp(prefix='live-', dir=ROOT / '.gate-test-tmp'))
EVENTS = []
SCENARIOS = []
CHILDREN = set()
POLICY = lambda args, n: False
DELTA_COUNT = 0

def memory(home):
    return json.loads((home/'state/.main-backstop.json').read_text())

def notes(home):
    path=home/'state/inbox/notes'
    # inbox layout is retained in evidence via all lab state files below.
    return '\n'.join(p.read_text() for p in (home/'state').rglob('*') if p.is_file() and p.suffix not in ('.lock', '.json'))

async def run(*argv, env=None, timeout=35):
    p=await asyncio.create_subprocess_exec(*map(str,argv),env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    CHILDREN.add(p)
    try:
        out,err=await asyncio.wait_for(p.communicate(),timeout)
        return p.returncode,out,err
    finally:
        if p.returncode is None:
            p.kill()
            await p.wait()
        CHILDREN.discard(p)

async def bash(script, *args, env):
    rc,out,err=await run('bash','-c','set -eu\n. "$1/bin/fm-remote-job-lib.sh"\nshift\n'+script,'lab',ROOT,*args,env=env)
    assert rc==0,(rc,out,err)
    return out.decode().strip()

class Server(asyncssh.SSHServer):
    def begin_auth(self, username): return False

async def connection(proc):
    global DELTA_COUNT
    job=None
    try:
        argv=shlex.split(proc.command)
        assert argv[0]=='fm-remote-entrypoint.sh' and argv[1]=='1',argv
        root=Path(base64.b64decode(argv[2]).decode())
        home=Path(base64.b64decode(argv[3]).decode())
        args=base64.b64decode(argv[4]).rstrip(b'\0').decode().split('\0')
        assert root==ROOT and home.is_relative_to(BASE)
        env=dict(os.environ, HOME=str(BASE/'account'),FM_ROOT_OVERRIDE=str(ROOT),FM_REMOTE_JOB_STATE_ROOT=str(BASE/'jobs'), FM_REMOTE_JOB_TIMEOUT='20',FM_REMOTE_JOB_QUEUE_TIMEOUT='30',FM_REMOTE_JOB_ACTIVE_POLL_SECONDS='0.05',TMPDIR=str(BASE/'tmp'))
        for k in ['FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
            env.pop(k,None)
        job=await bash('fm_remote_job_stage "$HOME" "$1" "$2" "${@:3}" </dev/null >/dev/null\nprintf "%s" "$FM_REMOTE_JOB_ID"',ROOT,home,*args,env=env)
        jobdir=BASE/'jobs/jobs'/job
        is_delta=args[0]=='fm-remote-delta-read.sh'
        if is_delta: DELTA_COUNT+=1
        preempt=is_delta and POLICY(args,DELTA_COUNT)
        blocker=None
        if preempt:
            blocker=await bash('fm_remote_job_stage "$HOME" "$1" "$2" fm-remote-file.sh get state/parent-replies.status 1048576 </dev/null >/dev/null\nprintf "%s" "$FM_REMOTE_JOB_ID"',ROOT,home,env=env)
        p=await asyncio.create_subprocess_exec(str(ROOT/'bin/fm-remote-job-worker.sh'),'--lane',job,env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        CHILDREN.add(p)
        stopped=None
        try:
            if preempt:
                deadline=time.monotonic()+8
                while time.monotonic()<deadline:
                    # These pipes appear only after the git validation group exits.
                    if (jobdir/'.stdout.pipe').exists() and (jobdir/'.claim/group').exists():
                        try:
                            stopped=int((jobdir/'.claim/group').read_text())
                            os.killpg(stopped,signal.SIGSTOP)
                            break
                        except (OSError,ValueError): pass
                    if p.returncode is not None: break
                    await asyncio.sleep(0.001)
                assert stopped is not None,'reader completed before fault injection'
            out,err=await asyncio.wait_for(p.communicate(),25)
            assert p.returncode==0,(out,err)
        finally:
            if p.returncode is None:
                p.kill()
                await p.wait()
            CHILDREN.discard(p)
        rc=int((jobdir/'exit').read_text())
        stdout=(jobdir/'stdout').read_bytes()
        stderr=(jobdir/'stderr').read_bytes()
        event={'command':args,'exit':rc,'job':job,'queued_command':blocker,'frozen_reader_group':stopped,'stdout_bytes':len(stdout),'stderr_bytes':len(stderr)}
        EVENTS.append(event)
        if preempt:
            assert rc==76 and stdout==stderr==b'',event
        if blocker:
            brc,bout,berr=await run(ROOT/'bin/fm-remote-job-worker.sh','--lane',blocker,env=env)
            assert brc==0 and int((BASE/'jobs/jobs'/blocker/'exit').read_text())==0,(brc,bout,berr)
            event['queued_command_exit']=0
            await bash('fm_remote_job_reap "$HOME" "$1"',blocker,env=env)
        await bash('fm_remote_job_reap "$HOME" "$1"',job,env=env)
        proc.stdout.write(stdout)
        proc.stderr.write(stderr)
        proc.exit(rc)
    except Exception as e:
        EVENTS.append({'error':repr(e),'job':job})
        proc.stderr.write(repr(e).encode())
        proc.exit(70)
        raise

async def main():
    global POLICY, DELTA_COUNT
    for p in [BASE/'account',BASE/'tmp']:
        p.mkdir()
    key=asyncssh.generate_private_key('ssh-ed25519')
    server=await asyncssh.create_server(Server,'127.0.0.1',0,server_host_keys=[key],process_factory=connection,encoding=None)
    port=server.get_port()
    sshconfig=BASE/'ssh_config'
    sshconfig.write_text(f'Host lab-peer\n HostName 127.0.0.1\n Port {port}\n User lab\n StrictHostKeyChecking no\n UserKnownHostsFile {BASE}/known_hosts\n GlobalKnownHostsFile /dev/null\n IdentityAgent none\n IdentitiesOnly yes\n IdentityFile none\n PreferredAuthentications none\n LogLevel ERROR\n')
    ssh=BASE/'ssh'
    ssh.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(sshconfig))+' "$@"\n')
    ssh.chmod(0o755)
    remote=BASE/'remote'
    (remote/'state').mkdir(parents=True)
    log=remote/'state/parent-replies.status'
    initial=b'working [at=1000]: initial reply\n'
    now=int(time.time())
    def home(name):
        h=BASE/name
        (h/'state').mkdir(parents=True)
        (h/'data').mkdir()
        (h/'state/.afk').touch()
        (h/'state/.remote-reply-mirrored-lab-peer').write_text('working [at=1000]: mirrored\n')
        (h/'data/secondmates.md').write_text(f'- lab-peer - isolated test (host: lab-peer; root: {ROOT}; home: {remote}; scope: test; projects: lab; added 2026-10-28)\n')
        return h
    env=dict(os.environ,FM_SSH_BIN=str(ssh),TMPDIR=str(BASE/'tmp'))
    for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
        env.pop(k,None)
    async def guard(h,label):
        start=time.monotonic()
        rc,out,err=await run('python3',ROOT/'bin/fm-main-backstop.py','--home',h,'--code-root',ROOT,'--mate','lab-peer',env=env,timeout=65)
        assert rc==0,(rc,out,err)
        observation={'pass':label,'seconds':round(time.monotonic()-start,3),'stdout':out.decode(),'stderr':err.decode(),'journal':memory(h)}
        with (EVID/'backstop-live-transcript.jsonl').open('a') as f:
            f.write(json.dumps(observation)+'\n')
        print(label, out.decode().strip(),flush=True)
        return observation
    try:
        # Three reissues on EACH of three data windows, plus a no-data tail:
        # only three successful reads consume the four-slot budget.
        log.write_bytes(initial)
        h=home('retry-and-budget')
        await guard(h,'bootstrap-retry')
        payload=b''.join((f'done [at={now-10+i}]: '.encode()+b'x'*39900+b'\n continuation line\n') for i in range(3))
        log.write_bytes(initial+payload)
        before=len(EVENTS)
        DELTA_COUNT=0
        POLICY=lambda args,n: (n-1)%4<3
        obs=await guard(h,'three-preemptions-per-window')
        attempts=EVENTS[before:]
        assert len(attempts)==16,attempts
        for i in range(0,16,4):
            group=attempts[i:i+4]
            assert [a['exit'] for a in group]==[76,76,76,0 if i<12 else 75],group
            assert all(a['command']==group[0]['command'] for a in group),group
        rec=obs['journal']['readers']['lab-peer']
        assert rec['offset']==len(initial+payload) and rec['prefix']==hashlib.sha256(initial+payload).hexdigest(),rec
        assert rec['pending_at']==[now-10,now-9,now-8],rec
        assert not obs['journal']['read_fails']
        SCENARIOS.append({'name':'Reissue a preempted read at the identical cursor; three retries per window leave all four scan slots available, including multiline data and exit-75 tail','result':'pass','live':True})
        # First data window progresses; next cursor is preempted four times.
        log.write_bytes(initial)
        h=home('exhaustion-and-recovery')
        POLICY=lambda args,n: False
        await guard(h,'bootstrap-exhaustion')
        log.write_bytes(initial+payload)
        start=len(EVENTS)
        DELTA_COUNT=0
        POLICY=lambda args,n: n>1
        first=await guard(h,'progress-then-four-preemptions')
        attempts=EVENTS[start:]
        assert len(attempts)==5 and [x['exit'] for x in attempts]==[0,76,76,76,76],attempts
        preserved=first['journal']['readers']['lab-peer']
        assert preserved['offset']>len(initial) and preserved['offset']<len(initial+payload)
        assert all(x['command'][2:]==attempts[1]['command'][2:] for x in attempts[1:]),attempts
        assert 'lab-peer' in first['journal']['read_fails'] and 'UNVERIFIED' not in notes(h)
        start=len(EVENTS)
        POLICY=lambda args,n: True
        second=await guard(h,'second-preempted-pass-alarms')
        attempts=EVENTS[start:]
        assert len(attempts)==4 and all(a['exit']==76 for a in attempts),attempts
        assert second['journal']['readers']['lab-peer']==preserved
        assert 'REPLY DELIVERY UNVERIFIED lab-peer' in notes(h)
        inbox_files={str(p.relative_to(h)):p.read_text() for p in (h/'state').rglob('*') if p.is_file() and 'inbox' in str(p.relative_to(h))}
        (EVID/'backstop-live-inbox.json').write_text(json.dumps(inbox_files,indent=2))
        SCENARIOS.append({'name':'Persist successful cursor progress before retry exhaustion; four preemptions tolerate one pass and the next failed pass writes a durable UNVERIFIED alarm','result':'pass','live':True})
        POLICY=lambda args,n: False
        recovered=await guard(h,'lane-clears-and-resumes')
        rec=recovered['journal']['readers']['lab-peer']
        assert rec['offset']==len(initial+payload) and rec['prefix']==hashlib.sha256(initial+payload).hexdigest()
        assert not recovered['journal']['read_fails'] and 'read-lab-peer' not in recovered['journal']['episodes']
        assert log.read_bytes()==initial+payload
        SCENARIOS.append({'name':'When the lane clears, the next cron pass resumes at the preserved cursor, reaches the tail and clears the read incident without modifying the reply log','result':'pass','live':True})
    finally:
        server.close()
        await server.wait_closed()
        for p in list(CHILDREN):
            if p.returncode is None: p.kill()
            await p.wait()
        (EVID/'backstop-live-jobs.json').write_text(json.dumps(EVENTS,indent=2))
        (EVID/'backstop-live-results.json').write_text(json.dumps(SCENARIOS,indent=2))
        shutil.rmtree(BASE)
    assert len(SCENARIOS)==3
    print('All live scenarios passed; local SSH server and lane children stopped; disposable homes removed.',flush=True)

if __name__=='__main__':
    asyncio.run(main())
