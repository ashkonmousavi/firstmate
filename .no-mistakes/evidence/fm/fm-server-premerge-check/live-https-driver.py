import base64, concurrent.futures, http.server, json, os, pathlib, socketserver, ssl, subprocess, threading, urllib.parse
root=pathlib.Path.cwd(); work=root/'.gate-live-tmp'/'tls'; work.mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M43N3J3TDN0AXXAC4TEG5ZJ9')
env=dict(os.environ,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
def command(*args,**kw):
    return subprocess.check_output(args,env=env,stderr=subprocess.PIPE,**kw).decode().strip()
repo=work/'source'; command('git','init','-q','-b','main',str(repo))
package=repo/'docs/ssot/q-v2/tools'; package.mkdir(parents=True,exist_ok=True)
(package/'check_plan.py').write_text('import json\nprint(json.dumps({"fresh": True}))\n')
(repo/'content').write_text('base\n')
command('git','-C',str(repo),'add','.'); command('git','-C',str(repo),'commit','-qm','base')
base=command('git','-C',str(repo),'rev-parse','HEAD')
(repo/'candidate').write_text('head\n'); command('git','-C',str(repo),'add','.'); command('git','-C',str(repo),'commit','-qm','head')
head=command('git','-C',str(repo),'rev-parse','HEAD'); tree=command('git','-C',str(repo),'rev-parse','HEAD^{tree}')
command('git','clone','-q','--bare',str(repo),str(work/'origin.git'))
command('git','-C',str(work/'origin.git'),'update-ref','refs/heads/main',base)
command('git','-C',str(work/'origin.git'),'update-ref','refs/pull/7/head',head)
command('git','-C',str(repo),'remote','add','origin','https://github.com/origin.git')
binpath=work/'fake-bin'; binpath.mkdir(exist_ok=True)
(binpath/'gh').write_text('#!/bin/sh\n[ "$*" = "auth token --hostname github.com" ] || exit 1\nprintf "scoped github.com retrieval\\n" >> "$FM_TLS_GH_LOG"\n[ "$FM_TLS_GH_FAIL" != 1 ] || exit 1\nprintf "fixture-token\\n"\n')
(binpath/'callback').write_text('#!/bin/sh\nprintf "called\\n" >> "$FM_TLS_INHERITED_LOG"\nprintf "fixture-token\\n"\n')
for p in binpath.iterdir(): p.chmod(0o700)
command('openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(work/'key.pem'),'-out',str(work/'cert.pem'),'-days','1','-subj','/CN=github.com','-addext','subjectAltName=DNS:github.com,DNS:other.invalid,DNS:github.com.evil.invalid,DNS:evilgithub.com')
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(work/'cert.pem',work/'key.pem')
events=[]; rejected=False; redirected=False
expected={'Basic '+base64.b64encode(value).decode() for value in (b'x-access-token:fixture-token',b'user:fixture-token')}
class GitHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def serve(self):
        auth=self.headers.get('Authorization')
        events.append({'host':self.headers.get('Host'),'method':self.command,'authorization_present':bool(auth),'accepted':auth in expected and not rejected})
        if redirected and self.headers.get('Host')=='github.com':
            self.send_response(302); self.send_header('Location','https://other.invalid'+self.path); self.end_headers(); return
        if auth not in expected or rejected:
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm="local fixture"'); self.end_headers(); return
        url=urllib.parse.urlsplit(self.path)
        cgi=dict(env,GIT_PROJECT_ROOT=str(work),GIT_HTTP_EXPORT_ALL='1',PATH_INFO=url.path,QUERY_STRING=url.query,REQUEST_METHOD=self.command,CONTENT_TYPE=self.headers.get('Content-Type',''),CONTENT_LENGTH=self.headers.get('Content-Length','0'),REMOTE_USER='fixture')
        r=subprocess.run(['git','http-backend'],env=cgi,input=self.rfile.read(int(cgi['CONTENT_LENGTH'])),capture_output=True,timeout=10)
        if r.returncode: events.append({'backend_error':r.stderr.decode()}); self.send_error(500); return
        headers,body=r.stdout.split(b'\r\n\r\n',1)
        fields=[x.decode().split(': ',1) for x in headers.split(b'\r\n')]
        self.send_response(next((int(v.split()[0]) for k,v in fields if k=='Status'),200))
        for k,v in fields:
            if k!='Status': self.send_header(k,v)
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET=serve
    do_POST=serve
class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_CONNECT(self):
        assert self.path.split(':')[0] in ('github.com','other.invalid','github.com.evil.invalid','evilgithub.com')
        self.send_response(200); self.end_headers(); self.wfile.flush()
        with ctx.wrap_socket(self.connection,server_side=True) as conn:
            GitHandler(conn,self.client_address,self.server)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
plain=http.server.ThreadingHTTPServer(('127.0.0.1',0),GitHandler)
plain_thread=threading.Thread(target=plain.serve_forever,daemon=True); plain_thread.start()
results=[]
try:
    for name,url,fail,reject,code in [
        ('allowed HTTPS github.com','https://github.com/origin.git',False,False,0),
        ('allowed username prompt','https://user@github.com/origin.git',False,False,0),
        ('missing login','https://github.com/origin.git',True,False,2),
        ('rejected credential','https://github.com/origin.git',False,True,2),
        ('cross-host redirect refusal','https://github.com/origin.git',False,False,2),
        ('HTTP authentication refusal',f'http://127.0.0.1:{plain.server_port}/origin.git',False,False,2),
        ('different host','https://other.invalid/origin.git',False,False,2),
        ('deceptive suffix','https://github.com.evil.invalid/origin.git',False,False,2),
        ('deceptive prefix','https://evilgithub.com/origin.git',False,False,2),
        ('deceptive userinfo','https://github.com@other.invalid/origin.git',False,False,2)]:
        command('git','-C',str(repo),'remote','set-url','origin',url)
        before=command('git','-C',str(repo),'show-ref')+command('git','-C',str(repo),'status','--porcelain')+(repo/'.git/config').read_text()
        events.clear(); rejected=reject; redirected=name=='cross-host redirect refusal'
        ghlog=work/'gh.log'; ghlog.write_text(''); ilog=work/'inherited.log'; ilog.write_text('')
        callenv=dict(env,PATH=str(binpath)+':'+env['PATH'],https_proxy=f'http://127.0.0.1:{server.server_port}',HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',NO_PROXY='',no_proxy='',http_proxy='',HTTP_PROXY='',ALL_PROXY='',all_proxy='',GIT_SSL_CAINFO=str(work/'cert.pem'),GIT_ASKPASS=str(binpath/'callback'),SSH_ASKPASS=str(binpath/'callback'),GH_HOST='other.invalid',FM_TLS_GH_LOG=str(ghlog),FM_TLS_GH_FAIL='1' if fail else '0',FM_TLS_INHERITED_LOG=str(ilog))
        if redirected: callenv['GIT_TRACE']=str(evidence/'redirect-git-trace.log')
        r=subprocess.run(['bash',str(root/'bin/fm-q-premerge-plan-check.sh'),str(repo),'7'],env=callenv,capture_output=True,text=True,timeout=30)
        after=command('git','-C',str(repo),'show-ref')+command('git','-C',str(repo),'status','--porcelain')+(repo/'.git/config').read_text()
        entry={'scenario':name,'url':url,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'requests':list(events),'gh_retrievals':ghlog.read_text().splitlines(),'inherited_callback_called':bool(ilog.read_text()),'source_unchanged':before==after}
        results.append(entry)
        assert r.returncode==code,entry
        assert before==after and not ilog.read_text(),entry
        if code==0: assert r.stdout.strip()==f'fresh base={base} head={head} tree={tree}' and any(e['accepted'] for e in events),entry
        if name.startswith(('different','deceptive','cross-host','HTTP')): assert not ghlog.read_text() and not any(e['authorization_present'] for e in events),entry
        assert 'fixture-token' not in r.stdout+r.stderr,entry
        print(name+': '+r.stdout.strip()+r.stderr.strip(),flush=True)
finally:
    server.shutdown(); server.server_close(); thread.join()
    plain.shutdown(); plain.server_close(); plain_thread.join()
    (evidence/'real-git-https.json').write_text(json.dumps(results,indent=2)+'\n')
