"""Real Polytoken 0.9.4 catalog and Firstmate relaunch quota refusal.
The offline catalog configuration points at loopback port 9, uses no real
credential, and never starts a model session or a Polytoken daemon.
"""
import pathlib,os,json,subprocess,shutil
R=pathlib.Path.cwd();L=R/'.p';EV=pathlib.Path(__file__).parent
E=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','TMUX','FM_TEST_SEAM']:E.pop(k,None)
E.update(HOME=str(R/'.poly/u'),XDG_CONFIG_HOME=str(R/'.poly/u/.config'),PATH=str(R/'.poly/bin')+':'+E['PATH'],GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMUX_TMPDIR=str(L/'t'))
log=open(EV/'live-polytoken-transcript.log','w',buffering=1)
def cmd(args,code=0):
 log.write('$ '+' '.join(args)+'\n');p=subprocess.run(args,env=E,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
 log.write(p.stdout+'exit='+str(p.returncode)+'\n');assert p.returncode==code,p.stdout
 return p.stdout
L.mkdir();cmd(['bin/fm-lab-home.sh','create',str(L/'h')]);(L/'t').mkdir()
project=L/'project';project.mkdir();cmd(['git','-C',str(project),'init','-q','-b','main'])
cmd(['git','-C',str(project),'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null','commit','--allow-empty','-qm','seed'])
wt=L/'worktree';cmd(['git','-C',str(project),'worktree','add','-q','--detach',str(wt)])
cmd(['tmux','-L','fm-lab','new-session','-d','-s','launcher','-n','fm-poly','-x','120','-y','40','-c',str(wt),'bash','--noprofile','--norc'])
try:
 E['TMUX']=cmd(['tmux','-L','fm-lab','display-message','-p','-t','launcher','#{socket_path}']).strip()+',0,0';E['FM_HOME']=str(L/'h')
 H=L/'h';(H/'config/backlog-backend').write_text('manual\n')
 p=json.load(open(R/'tests/fixtures/quota-axi-healthy.json'));p['providers'].append({'provider':'blocked','quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'},'selection':{'spendPriority':-1}}]}})
 f=L/'quota.json';f.write_text(json.dumps(p));E['FM_QUOTA_SNAPSHOT_FILE']=str(f)
 (H/'config/crew-dispatch.json').write_text(json.dumps({'default':[{'harness':'polytoken','model':'zai/glm-5.3-flash','provider':'blocked'},{'harness':'codex','model':'gpt-6.1-sol'}]}))
 d=H/'data/poly';d.mkdir();(d/'brief.md').write_text("# Task\n## Captain's intent\nDisposable quota refusal probe.\n## Firstmate spec\nNo work is authorized.\n")
 meta=H/'state/poly.meta';meta.write_text(f'window=launcher:fm-poly\nendpoint_task_id=poly\nworktree={wt}\nproject={project}\nharness=grok\nkind=scout\nmodel=grok-4.7\neffort=default\nspawn_gen=s1.1.1\n')
 before=meta.read_bytes()
 catalog=cmd(['polytoken','print','models']);assert 'zai/glm-5.3-flash(low)' in catalog
 out=cmd(['bin/fm-control.sh','poly','relaunch','--harness','polytoken','--model','zai/glm-5.3-flash','--effort','low','--note','quota refusal'],1)
 assert 'provider blocked runway exhausted_now' in out and '--harness codex --model gpt-6.1-sol' in out
 assert meta.read_bytes()==before
 log.write('Real offline native catalog accepted the model; exhausted quota refused; metadata byte-identical.\n')
finally:
 cmd(['tmux','-L','fm-lab','kill-server'])
 shutil.rmtree(L)
 log.close()
