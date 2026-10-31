#!/usr/bin/env python3
"""Drive the real resolver CLI. Only external classifier/telemetry inputs are controlled.
Run from the gate worktree: python3 /path/to/drive-resolver.py /path/to/evidence-dir
No vendor credentials, operator FM_HOME, or fleet lifecycle are used.
"""
import copy, datetime as dt, http.server, json, os, pathlib, re, shlex, shutil
import socket, ssl, subprocess as sp, sys, tempfile, threading
ROOT=pathlib.Path.cwd()
OUT=pathlib.Path(sys.argv[1]); OUT.mkdir(parents=True,exist_ok=True)
CURL=shutil.which('curl'); QUOTA=shutil.which('quota-axi')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='.dispatch-drive-',dir=ROOT))
SERVER=None; THREAD=None
TRANS=[]; RESULTS=[]; ANSWER={'choice':'rule_1','confidence':.99}
def save(name,value):
 (OUT/name).write_text(value if isinstance(value,str) else json.dumps(value,indent=2)+'\n')
def run(args,env=None):
 r=sp.run(args,env=env,cwd=ROOT,text=True,capture_output=True,timeout=30)
 if r.returncode: raise RuntimeError(f'{args[0]} exited {r.returncode}: {r.stdout} {r.stderr}')
 return r.stdout
class Classifier(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert self.path=='/v1/systemone'
  criteria=request['questions']['rule']['criteria']
  choice=ANSWER['choice']; probabilities={key:0.0 for key in criteria}; probabilities[choice]=1.0
  response={'model':'isolated-protocol-classifier','answers':{'rule':{'type':'choice','choice':choice,'confidence':ANSWER['confidence'],'probabilities':probabilities}},'usage':{'input_tokens':0,'output_tokens':0}}
  data=json.dumps(response).encode(); self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
def win(id,used,elapsed=.5,seconds=18000,kind='session'):
 now=dt.datetime.now(dt.timezone.utc)
 f=lambda x:x.isoformat().replace('+00:00','Z')
 return {'id':id,'label':'session' if id=='five_hour' else id,'kind':kind,'percentUsed':used,'percentRemaining':100-used,'startsAt':f(now-dt.timedelta(seconds=seconds*elapsed)),'resetsAt':f(now+dt.timedelta(seconds=seconds*(1-elapsed))),'windowSeconds':seconds}
def provider(name,windows,account=None):
 p={'provider':name,'label':name,'source':'oauth','windows':windows,'state':{'status':'fresh','stale':False,'refreshedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'sourcesTried':['oauth']}}
 if account:p['accountKey']=account
 return p
def raw_providers():
 return [provider('claude',[win('five_hour',1,.99),win('seven_day',60,.5,604800,'weekly')]),provider('codex',[win('five_hour',60)]),provider('grok',[win('credits',40)]),provider('zai',[win('five_hour',45)])]
PROFILES=[{'harness':'claude','model':'sonnet','effort':'high'},{'harness':'codex','model':'gpt-5.6-sol'},{'harness':'grok','model':'grok-test','effort':'high'},{'harness':'pi','model':'zai/glm-test','provider':'zai','effort':'high'}]
def cfg(profiles=PROFILES):
 return {'rules':[{'when':'A routine implementation task with a known solution.','use':copy.deepcopy(profiles)}],'default':copy.deepcopy(profiles)}
def must(text,fragment):
 if fragment not in text:raise AssertionError(f'Missing {fragment!r}\n{text}')
def never(text,fragment):
 if fragment in text:raise AssertionError(f'Unexpected {fragment!r}\n{text}')
def selected(text,harness):must(text,f"  profile: --harness '{harness}'")
def evidence_case(name,config,providers=None,protocol=None,choice='rule_1',confidence=.99,expect='clear',want=None,refused=(),not_refused=(),baseline=False):
 ANSWER.update(choice=choice,confidence=confidence)
 (LAB/'home/config/crew-dispatch.json').write_text(json.dumps(config))
 env=dict(ENV)
 if protocol is None:
  (LAB/'snapshot.json').write_text(json.dumps({'schemaVersion':3,'providers':providers}))
  q=json.loads(run([QUOTA,'--json'],env))
 else:q=protocol;env['PATH']=str(LAB/'protocol-bin')+os.pathsep+env['PATH']
 (LAB/'quota.json').write_text(json.dumps(q))
 save(name+'-quota.json',q)
 r=sp.run([str(ROOT/'bin/fm-dispatch-resolve.sh'),str(LAB/'brief.md'),'--project','disposable-runway-check'],env=env,cwd=ROOT,text=True,capture_output=True,timeout=30)
 save(name+'.txt',f'$ bin/fm-dispatch-resolve.sh <isolated-brief> --project disposable-runway-check\nexit: {r.returncode}\n{r.stdout}\n{r.stderr}')
 assert r.returncode==0,(name,r.returncode,r.stderr)
 must(r.stdout,'  status: '+expect)
 if want:selected(r.stdout,want)
 for h in refused:must(r.stdout,next(line for line in r.stdout.splitlines() if f'candidate: {h}:' in line and 'not eligible:' in line and 'runs through its reset' in line))
 for h in not_refused:
  line=next(line for line in r.stdout.splitlines() if f'candidate: {h}:' in line); never(line,'not eligible')
 TRANS.append(f'=== {name} ===\n{r.stdout}')
 RESULTS.append({'name':name,'result':'pass','exit':r.returncode,'input':'real quota-axi snapshot mode' if protocol is None else 'controlled external quota JSON protocol'})
 if baseline:
  base=LAB/'baseline';base.mkdir()
  archive=sp.run(['git','archive','baae6e980da1cc4a9ab7d49dcf9d4837f6c92cd2','bin'],cwd=ROOT,capture_output=True,check=True)
  sp.run(['tar','-x','-C',str(base)],input=archive.stdout,check=True)
  old=sp.run([str(base/'bin/fm-dispatch-resolve.sh'),str(LAB/'brief.md')],env=env,cwd=ROOT,text=True,capture_output=True,timeout=30)
  save('before-fix.txt',f'exit: {old.returncode}\n{old.stdout}\n{old.stderr}')
  assert old.returncode==0
  selected(old.stdout,'claude')
  never(old.stdout,'before its reset while')
 return r.stdout,q
try:
 (LAB/'home/config').mkdir(parents=True);(LAB/'tmp').mkdir();(LAB/'bin').mkdir();(LAB/'protocol-bin').mkdir()
 (LAB/'brief.md').write_text("# Task\n## Captain's intent\nImplement the already specified small change.\n## Firstmate spec\nUse the matched configured profile array and current quota evidence.\n")
 run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(LAB/'key.pem'),'-out',str(LAB/'cert.pem'),'-days','1','-subj','/CN=api.typesafe.ai','-addext','subjectAltName=DNS:api.typesafe.ai'])
 for port in range(9610,9700):
  try:SERVER=http.server.HTTPServer(('127.0.0.1',port),Classifier);break
  except OSError:continue
 assert SERVER is not None,'No isolated loopback port available'
 tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(LAB/'cert.pem',LAB/'key.pem');SERVER.socket=tls.wrap_socket(SERVER.socket,server_side=True)
 THREAD=threading.Thread(target=SERVER.serve_forever);THREAD.start()
 shim=LAB/'bin/curl';shim.write_text('#!/bin/sh\nexec '+shlex.quote(CURL)+' --noproxy "*" --cacert '+shlex.quote(str(LAB/'cert.pem'))+' --connect-to '+shlex.quote(f'api.typesafe.ai:443:127.0.0.1:{SERVER.server_port}')+' "$@"\n');shim.chmod(0o755)
 shim=LAB/'protocol-bin/quota-axi';shim.write_text('#!/bin/sh\nexec cat '+shlex.quote(str(LAB/'quota.json'))+'\n');shim.chmod(0o755)
 ENV={'PATH':str(LAB/'bin')+os.pathsep+os.environ['PATH'],'HOME':str(LAB/'home'),'FM_HOME':str(LAB/'home'),'XDG_CONFIG_HOME':str(LAB/'home/xdg-config'),'XDG_CACHE_HOME':str(LAB/'home/xdg-cache'),'TMPDIR':str(LAB/'tmp'),'TYPESAFE_API_KEY':'isolated-noncredential','QUOTA_AXI_SNAPSHOT':str(LAB/'snapshot.json')}
 # Oracle: the intent requires through-reset Grok/Z.ai over short Claude/Codex,
 # even with Claude's larger scalar. Base revision must exhibit that bug.
 out,q=evidence_case('01-short-provider-refusal',cfg(),raw_providers(),want='grok',refused=['claude','codex'],baseline=True)
 live=copy.deepcopy(q)
 # Rank oracle: Grok has more unused allowance at equal cycle position than Z.ai.
 ps=[provider('grok',[win('credits',40)]),provider('zai',[win('five_hour',45)])]
 c=cfg([PROFILES[3],PROFILES[2]])
 out,_=evidence_case('02-rank-over-array-order',c,ps,want='grok')
 assert out.index('candidate: grok:')<out.index('candidate: pi:')
 # All tight: retain the higher spendPriority choice, no new gate or summary.
 ps=raw_providers()
 out,_=evidence_case('03-all-tight-selection',cfg(PROFILES[:2]),ps,want='claude',not_refused=['claude','codex'])
 never(out,'runway_note');never(out,'every rankable candidate is tight')
 # Confidence is external quota evidence. Early/unknown/missing cannot justify refusal.
 for conf in ['early','unknown',None]:
  v=copy.deepcopy(live)
  bound=v['providers'][0]['quotaSemantics']['effectiveAvailability'][0]
  bound['runway']['projectionConfidence']=conf
  out,_=evidence_case('04-uncertain-'+str(conf),cfg(),protocol=v,want='claude',not_refused=['claude'])
 # A healthy provider outside the selected array cannot activate the gate.
 # An early-only alternate also cannot activate it or produce an all-tight claim.
 v=copy.deepcopy(live)
 gp=next(p for p in v['providers'] if p['provider']=='grok')
 gp['quotaSemantics']['effectiveAvailability'][0]['runway']={'status':'projected_exhaustion','projectionConfidence':'early','projectedExhaustedAt':'2030-01-01T01:00:00Z'}
 out,_=evidence_case('04-unknown-alternate-no-refusal',cfg(PROFILES[:3]),protocol=v,want='claude',not_refused=['claude','codex','grok'])
 never(out,'every rankable candidate is tight');never(out,'runway_note')
 # An unknown spendPriority keeps through-reset evidence unranked; it cannot gate.
 gp['quotaSemantics']['effectiveAvailability'][0]['runway']={'status':'through_reset'}
 gp['quotaSemantics']['effectiveAvailability'][0]['selection']={'status':'unknown'}
 out,_=evidence_case('04-unranked-through-no-refusal',cfg(PROFILES[:3]),protocol=v,want='claude',not_refused=['claude','codex','grok'])
 must(out,'eligible, unranked')
 # Unrelated named-model exhaustion must not contaminate the selected model.
 ps=[provider('claude',[win('five_hour',30),win('model:other',75,.5,604800,'model')]),provider('grok',[win('credits',40)])]
 out,_=evidence_case('08-unrelated-model-scope',cfg([PROFILES[0],PROFILES[2]]),ps,want='claude',not_refused=['claude'])
 # Independent worked dates distinguish weak and established scope evidence.
 for scopes in [('all_models','model:sonnet'),('all_products','product:sonnet')]:
  for conf in ['early','unknown',None]:
   for reverse in [False,True]:
    v=copy.deepcopy(live); cp=next(p for p in v['providers'] if p['provider']=='claude')
    weak=copy.deepcopy(cp['quotaSemantics']['effectiveAvailability'][0]);strong=copy.deepcopy(weak)
    weak['scope']=scopes[0];weak['runway']={'status':'projected_exhaustion','projectedExhaustedAt':'2030-01-01T01:00:00Z'}
    if conf is not None:weak['runway']['projectionConfidence']=conf
    strong['scope']=scopes[1];strong['runway']={'status':'projected_exhaustion','projectionConfidence':'established','projectedExhaustedAt':'2030-01-01T02:00:00Z'}
    cp['quotaSemantics']['effectiveAvailability']=[strong,weak] if reverse else [weak,strong]
    name=f'05-mixed-{scopes[1].split(":")[0]}-{conf}-{reverse}'
    out,_=evidence_case(name,cfg(),protocol=v,want='grok',refused=['claude'])
    refusal=next(line for line in out.splitlines() if 'candidate: claude:' in line)
    must(refusal,f'at {scopes[1]} ends 2030-01-01T02:00:00Z before its reset')
 # Default and fallback use the same gate; ambiguous/approval evidence never launches.
 evidence_case('06-default-routing',cfg(),raw_providers(),choice='default',want='grok',refused=['claude','codex'])
 c=cfg();c['rules'][0]['floor']={'provider':'claude','scope':'all_models','min_percent':90}
 evidence_case('06-floor-default',c,raw_providers(),want='grok',refused=['claude','codex'])
 evidence_case('06-ambiguous-evidence',cfg(),raw_providers(),confidence=.4,expect='ambiguous',refused=['claude','codex'])
 c=cfg();c['rules'][0]['approval']='captain'
 evidence_case('06-approval-evidence',c,raw_providers(),expect='escalate',refused=['claude','codex'])
 # Ties remain explicit; an exhausted/zero candidate cannot become eligible all-tight.
 ps=[provider('grok',[win('credits',40)]),provider('zai',[win('five_hour',40)])]
 out,_=evidence_case('07-genuine-tie',cfg([PROFILES[2],PROFILES[3]]),ps,expect='escalate');must(out,'genuine spendPriority tie');never(out,'  profile:')
 ps=[provider('claude',[win('five_hour',100)]),provider('codex',[win('five_hour',60)])]
 out,_=evidence_case('07-exhaustion-still-blocks',cfg(PROFILES[:2]),ps,want='codex');must(out,'not eligible: runway exhausted_now')
 # Account-aware selection cannot borrow a healthy unrelated account row.
 v=copy.deepcopy(live);v['schemaVersion']=6
 for p in v['providers']:p['accountKey']='default'
 p=next(p for p in v['providers'] if p['provider']=='codex');p['accountKey']='codex-home'
 other=copy.deepcopy(p);other['accountKey']='openai-codex-work';other['quotaSemantics']=copy.deepcopy(next(p for p in v['providers'] if p['provider']=='grok')['quotaSemantics']);v['providers'].insert(0,other)
 out,_=evidence_case('08-schema6-account-isolation',cfg(),protocol=v,want='grok',refused=['codex'])
 save('resolver-live-transcript.txt','\n'.join(TRANS))
 save('live-results.json',RESULTS)
 print(json.dumps({'result':'pass','cases':len(RESULTS),'baseline':'short Claude selected before fix; through-reset Grok selected after fix','children':'TLS server stopped in finally'}))
finally:
 if SERVER:SERVER.shutdown();SERVER.server_close()
 if THREAD:THREAD.join(timeout=5);assert not THREAD.is_alive()
 shutil.rmtree(LAB)
