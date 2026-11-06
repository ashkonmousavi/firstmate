#!/usr/bin/env python3
"""Real Firstmate CLIs and real gh, isolated behind a local GitHub API fixture.
No worker, forge write, credential store, default home, or default socket used.
"""
import datetime, http.server, json, os, pathlib, shutil, ssl, subprocess, tempfile, threading, time

ROOT = pathlib.Path.cwd()
OUT = pathlib.Path('~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='.routing-lab.', dir=ROOT))
requests = []
prs = []
labeled = (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=25)).strftime('%Y-%m-%dT%H:%M:%SZ')
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)

class API(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def reply(self, data, status=200):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('ETag', '"disposable-lab"')
        self.send_header('Connection', 'close')
        self.end_headers(); self.wfile.write(raw); self.close_connection = True
    def do_GET(self):
        requests.append({'method':'GET','path':self.path})
        if '/pulls?' in self.path:
            return self.reply([{'number':p['number'], 'head':{'ref':p['headRefName']}, 'labels':[{'name':'conflict'}]} for p in prs])
        if self.path == '/queue/status':
            return self.reply({'batches':[], 'forming_batches':[], 'waiting_pull_requests':[], 'pause':None})
        if self.path.startswith('/queue/show/'):
            return self.reply({'queued':False})
        if self.path == '/user': return self.reply({'login':'disposable-lab'})
        self.reply({'message':'fixture endpoint unavailable'},404)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
        query = body.get('query','')
        requests.append({'method':'POST','path':self.path,'query':query})
        if '/graphql' not in self.path: return self.reply({'message':'writes forbidden'},405)
        if 'pullRequests(' in query:
            return self.reply({'data':{'repository':{'pullRequests':{'nodes':prs,'pageInfo':{'hasNextPage':False,'endCursor':None}}}}})
        if 'timelineItems' in query:
            return self.reply({'data':{'repository':{'pullRequest':{'labels':{'nodes':[{'name':'conflict'}]},'timelineItems':{'nodes':[{'__typename':'LabeledEvent','createdAt':labeled,'label':{'name':'conflict'}}]}}}}})
        if 'pullRequest(' in query:
            return self.reply({'data':{'repository':{'pullRequest':{'state':'OPEN'}}}})
        if 'viewer' in query: return self.reply({'data':{'viewer':{'login':'disposable-lab'}}})
        return self.reply({'data':{}})

class Proxy(API):
    def do_CONNECT(self):
        requests.append({'method':'CONNECT','host':self.path})
        self.send_response(200,'Connection established'); self.end_headers()
        self.close_connection = True
        with ctx.wrap_socket(self.connection,server_side=True) as conn:
            API(conn,self.client_address,self.server)

def run(argv, env, expected=0, timeout=90):
    print('$ '+' '.join(map(str,argv)),flush=True)
    p = subprocess.run(list(map(str,argv)),cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    print(p.stdout,flush=True); print('exit:',p.returncode,flush=True)
    assert p.returncode == expected,(argv,p.returncode)
    return p.stdout

def home(name, backlog):
    h=LAB/name
    run(['bash','bin/fm-lab-home.sh','create',h],base)
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (h/'data/backlog.md').write_text(backlog)
    (h/'data/projects.md').write_text('- proj [direct-PR +yolo] - local fixture\n')
    (h/'projects/proj').mkdir()
    run(['git','init','-q','-b','main',h/'projects/proj'],base)
    run(['git','-C',h/'projects/proj','remote','add','origin','https://github.com/o/r.git'],base)
    return h

base=os.environ.copy()
for k in list(base):
    if k.startswith(('FM_', 'TASKS_AXI_', 'GH_', 'GITHUB_')) or k in ('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','NO_PROXY'):
        base.pop(k,None)
base.update(HOME=str(LAB/'user'),TMPDIR=str(LAB/'tmp'),GH_CONFIG_DIR=str(LAB/'gh'),GH_TOKEN='disposable-not-a-credential',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
for d in ('user','tmp','gh'): (LAB/d).mkdir()
server=None
try:
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(LAB/'key.pem'),'-out',str(LAB/'cert.pem'),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com,DNS:github.com,DNS:localhost'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    ctx.load_cert_chain(LAB/'cert.pem',LAB/'key.pem')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
    thread=threading.Thread(target=server.serve_forever);thread.start()
    address='http://127.0.0.1:'+str(server.server_port)
    base.update(HTTPS_PROXY=address,HTTP_PROXY=address,SSL_CERT_FILE=str(LAB/'cert.pem'),NO_PROXY='127.0.0.1,localhost')
    base['LAB_API']=address
    # This adapter supplies only Mergify's external queue protocol. It does not
    # replace Firstmate ranking, backlog/owner resolution, records, or guards.
    queue=LAB/'queue-api'
    queue.write_text('#!/usr/bin/env python3\nimport json,os,sys,urllib.request\np="/queue/status" if sys.argv[2]=="status" else "/queue/show/"+sys.argv[3]\nprint(urllib.request.urlopen(os.environ["LAB_API"]+p).read().decode())\n')
    queue.chmod(0o700)
    empty='## In flight\n## Queued\n## Done\n'
    h=home('main','## In flight\n## Queued\n- [ ] local - local open task (repo: proj) (kind: ship)\n## Done\n- [x] finished - completed task (repo: proj) (kind: ship)\n')
    mate=home('mate','## In flight\n## Queued\n- [ ] elsewhere - another home owns this task (repo: proj) (kind: ship)\n## Done\n')
    (h/'data/secondmates.md').write_text(f'- sm1 - local mate (home: {mate}; scope: proj; projects: proj; added 2026-11-05)\n')
    (h/'config/pr-triage-rules').write_text('repo=o/r\nproject=proj\ntitle=repair\n')
    for n,task in enumerate(('local','finished','elsewhere','unowned'),11):
        prs.append({'number':n,'url':f'https://github.com/o/r/pull/{n}','title':'repair '+task,'isDraft':False,'headRefName':'fm/'+task,'headRefOid':str(n)*20,'baseRefName':'main','mergeable':'CONFLICTING','author':{'login':'lab'},'labels':{'nodes':[]},'files':{'nodes':[]},'commits':{'nodes':[{'commit':{'statusCheckRollup':{'state':'FAILURE'}}}]}})
    env=base|{'FM_HOME':str(h),'FM_TEST_SEAM':'1','FM_PR_TRIAGE_MERGIFY_BIN':str(queue)}
    print('\n=== Real triage dry run: local, done, secondmate, unowned ===')
    text=run(['bash','bin/fm-pr-triage.sh'],env)
    for expected in ('refused:no task record for local','refused:task done','refused:owned by sm1: steered elsewhere','refused:no home owns unowned'):
        assert expected in text,expected
    assert 'fm-send.sh sm1 --one-way' in text
    assert not (h/'state/pr-triage.log').exists()
    assert not (h/'state/pr-triage').exists()
    print('Dry run left no triage records or steer markers.')
    print('\n=== Applied triage guards persist refusals, with no launches or sends ===')
    prs[:]=[p for p in prs if p['headRefName']!='fm/elsewhere']
    text=run(['bash','bin/fm-pr-triage.sh','--apply'],env)
    saved=(h/'state/pr-triage.log').read_text();print(saved)
    for expected in ('refused:no task record for local','refused:task done','refused:no home owns unowned'): assert expected in saved
    assert not (h/'state/pr-triage').exists()
    print('\n=== Orphan sweep names local tasks and routes unclaimed work to main ===')
    env=base|{'FM_HOME':str(h)}
    text=run(['bash','bin/fm-pr-orphan-sweep.sh'],env)
    assert "task local in this home's backlog" in text
    assert "no task in this home's backlog is named unowned" in text
    wake=(h/'state/.wake-queue').read_text();print(wake)
    again=run(['bash','bin/fm-pr-orphan-sweep.sh'],env)
    assert again.strip()==''
    assert (h/'state/.wake-queue').read_text()==wake
    print('Second sweep preserved the same durable wakes without duplicates.')
    print('\n=== A secondmate stays quiet for tasks outside its backlog ===')
    (mate/'.fm-secondmate-home').write_text('sm1\n')
    text=run(['bash','bin/fm-pr-orphan-sweep.sh'],base|{'FM_HOME':str(mate)})
    assert text.strip()==''
    assert not (mate/'state/.wake-queue').exists()
    print('\n=== Startup context re-emit uses native readiness and backlog ===')
    # A clean home avoids any worker recovery. The current real harness's
    # ancestry owns this lab lock; this does not fabricate a primary CLI.
    startup=home('startup','## In flight\n## Queued\n- [ ] eligible - ready task (repo: proj) (kind: scout)\n- [ ] blocked - depends on active task (repo: proj) (kind: scout) blocked-by: active\n## Done\n')
    # No projects means no clone/network sweeps in this re-emit.
    (startup/'data/projects.md').write_text('')
    (startup/'data/backlog.md').write_text('## In flight\n- [ ] active - active dependency (repo: proj) (kind: scout)\n## Queued\n- [ ] eligible - ready task (repo: proj) (kind: scout)\n- [ ] blocked - waits on active (repo: proj) (kind: scout) blocked-by: active\n## Done\n')
    env=base|{'FM_HOME':str(startup),'FM_SESSION_START_TIMEOUT':'90'}
    text=run(['bash','bin/fm-session-start.sh','--reemit'],env,timeout=110)
    (OUT/'round2-startup.txt').write_text(text)
    inflight=text.split('in flight:\n',1)[1].split('held (',1)[0]
    blocked=text.split('blocked queued:\n',1)[1].split('ready queued (',1)[0]
    ready=text.split('ready queued (dispatchable now):\n',1)[1].split('Full task bodies',1)[0]
    assert '  active,in_flight,' in inflight
    assert '  blocked,queued,' in blocked and '  eligible,' not in blocked
    assert '  eligible,queued,' in ready and '  blocked,' not in ready
    assert '\n●  STARTUP TRUNCATED' not in text
    # Wait for the real detached network child and read its actual status.
    status=startup/'state/.startup-network.status'
    deadline=time.monotonic()+95
    while status.exists() and time.monotonic()<deadline:
        values=dict(line.split('=',1) for line in status.read_text().splitlines() if '=' in line)
        if values.get('state') not in ('running','starting'): break
        time.sleep(.2)
    if status.exists():
        print('Detached startup result:',status.read_text())
        assert values.get('state') not in ('running','starting'),values
    print('All routing and startup observations matched the restored CLI contract.')
finally:
    if server:
        server.shutdown();server.server_close();thread.join()
    (OUT/'round2-local-api-requests.json').write_text(json.dumps(requests,indent=2)+'\n')
    shutil.rmtree(LAB)
