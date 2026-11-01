import base64, ctypes, datetime, http.server, json, os, pathlib, shutil, signal, subprocess, sys, tempfile, threading, time
repo=pathlib.Path.cwd();base=pathlib.Path(tempfile.mkdtemp(prefix='cancel-',dir=repo/'.validation-tmp'))
assert ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)==0
phase='';arrived=threading.Event();release=threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        if phase in ('deadline','app-server') and 'accounts/check' in self.path:
            arrived.set();release.wait(20)
        body=json.dumps({'accounts':[{'id':'fm-live-synthetic-account','workspace_backend_origin':'https://chatgpt.com','account_routing_override':'NO_CONSTRAINT'}]} if 'accounts/check' in self.path else {'models':[]}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers()
        try:self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        print('Real vendor made local request '+self.path,flush=True)
        arrived.set();release.wait(20)
        self.send_response(503);self.end_headers()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
thread=threading.Thread(target=server.serve_forever);thread.start()
port=server.server_port
home=base/'home';home.mkdir()
root=base/'account';(root/'rules').mkdir(parents=True)
(root/'AGENTS.md').write_text('Disposable cancellation proof.\n')
(root/'rules/default.rules').write_text('prefix_rule(pattern=["echo"],decision="allow")\n')
(root/'config.toml').write_text(f'''cli_auth_credentials_store="file"
model="gpt-6.1-sol"
model_provider="isolated"
chatgpt_base_url="http://127.0.0.1:{port}/backend-api"
[model_providers.isolated]
name="isolated"
base_url="http://127.0.0.1:{port}/v1"
wire_api="responses"
requires_openai_auth=true
[features]
plugins=false
apps=false
''')
config=base/'codex-accounts';config.write_text(str(root)+'\n')
env={k:os.environ[k] for k in ('PATH','USER','LOGNAME') if k in os.environ};env.update(HOME=str(home),TMPDIR=str(base))
def children(pid):
    try:return [int(p) for p in pathlib.Path(f'/proc/{pid}/task/{pid}/children').read_text().split()]
    except FileNotFoundError:return []
def descendants(pid):
    result=[]
    for child in children(pid):result.append(child);result.extend(descendants(child))
    return result
def state(pid):
    try:return pathlib.Path(f'/proc/{pid}/stat').read_text().split(') ',1)[1].split()[0]
    except FileNotFoundError:return None
def jwt(value):return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
helper=None;owned=[];unrelated=subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'])
try:
    for phase in ('deadline','app-server','run_vendor'):
        arrived.clear();release.clear()
        if phase!='run_vendor':
            token=jwt({'alg':'none'})+'.'+jwt({'email':'synthetic@example.invalid','exp':int(time.time())+36000,'iat':int(time.time()),'https://api.openai.com/auth':{'chatgpt_account_id':'fm-live-synthetic-account','chatgpt_plan_type':'pro'}})+'.c3ludGhldGlj'
            auth={'auth_mode':'chatgpt','OPENAI_API_KEY':None,'tokens':{'id_token':token,'access_token':token,'refresh_token':'synthetic-refresh','account_id':'fm-live-synthetic-account'},'last_refresh':datetime.datetime.now(datetime.timezone.utc).isoformat()}
            verb=['guard']
        else:
            auth={'OPENAI_API_KEY':'sk-fm-live-synthetic'};verb=['maintain','--folder',str(root)]
        (root/'auth.json').write_text(json.dumps(auth))
        command=[sys.executable,str(repo/'bin/fm-codex-accounts.py'),*verb,'--config',str(config)]
        helper=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        reached=arrived.wait(8)
        owned=descendants(helper.pid)
        assert reached,f'{phase}: real vendor did not reach the delayed local service; helper={helper.pid}, exit={helper.poll()}'
        owned=descendants(helper.pid)
        print(f'{phase}: helper pid={helper.pid}, owned descendant pids={owned}',flush=True)
        assert owned,'expected a running real Codex process'
        print('Real executables: '+repr([os.readlink(f'/proc/{pid}/exe') for pid in owned]),flush=True)
        before=time.monotonic()
        if phase!='deadline':os.killpg(helper.pid,signal.SIGTERM)
        out,err=helper.communicate(timeout=14 if phase=='deadline' else 3)
        elapsed=time.monotonic()-before
        print(f'{phase}: helper exit={helper.returncode}, elapsed={elapsed:.3f}s, stdout={out!r}, stderr={err!r}',flush=True)
        assert helper.returncode==(0 if phase=='deadline' else 143) and not out and not err
        assert 9<=elapsed<14 if phase=='deadline' else elapsed<3
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            for pid in owned:
                try:os.waitpid(pid,os.WNOHANG)
                except ChildProcessError:pass
            if all(state(pid) is None for pid in owned):break
            time.sleep(.01)
        assert all(state(pid) is None for pid in owned),[(pid,state(pid)) for pid in owned]
        assert unrelated.poll() is None
        print(f'{phase}: all real Codex descendants reaped; unrelated process remained alive.',flush=True)
        release.set()
finally:
    release.set()
    if helper and helper.poll() is None:helper.send_signal(signal.SIGTERM);helper.wait(timeout=3)
    for pid in owned:
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
        try:os.waitpid(pid,0)
        except ChildProcessError:pass
    unrelated.terminate();unrelated.wait();server.shutdown();server.server_close();thread.join()
    shutil.rmtree(base)
    print('Disposable server, child processes and folders removed.',flush=True)
