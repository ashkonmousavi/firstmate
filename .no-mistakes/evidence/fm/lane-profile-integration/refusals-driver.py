import os,pathlib,subprocess,json
R=pathlib.Path.cwd(); L=R/'.nm-live'; E=pathlib.Path('~/.no-mistakes/evidence/01M6Q77424A407CBW237T5PJ6A')
env={'PATH':os.environ['PATH'],'HOME':str(L/'user'),'FM_HOME':str(L/'home'),'FM_SPAWN_NO_GUARD':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','DISABLE_AUTOUPDATER':'1','NO_MISTAKES_NO_UPDATE_CHECK':'1','TMUX_TMPDIR':str(R/'.l/tmux'),'TREEHOUSE_ROOT':str(L/'pool')}
def run(args):
 p=subprocess.run([str(a) for a in args],env=env,capture_output=True,text=True,timeout=100)
 print('$ '+repr([str(a) for a in args])+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode),flush=True)
 return p
for profile in ['typo','','governance;false']:
 p=run(['bin/fm-spawn.sh','live-refusal',L/'project','--scout','--lane-profile',profile])
 assert p.returncode==1 and 'unknown --lane-profile' in p.stderr
 assert not (L/'home/state/live-refusal.meta').exists()
print('PASS malformed profile names refuse before provisioning',flush=True)
config=L/'home/config'; (config/'crew-harness').write_text('codex\n'); (config/'lane-capacity').write_text('10 0\n'); (config/'machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(L)]}))
activity=L/'user/.config/skills-master/.agents/skills/activity/activity.sh'; activity.parent.mkdir(parents=True); activity.write_text("#!/usr/bin/env bash\nprintf '%s\\n' '{\"readable\":true,\"lanes\":0,\"target\":10,\"free_lanes\":10}'\n"); activity.chmod(0o755)
p=run(['git','clone','--quiet',R/'.l/project',L/'refusal-project']); assert p.returncode==0
codex=L/'user/.codex'; codex.mkdir(); (codex/'config.toml').write_text('this is invalid TOML [\n'); env['CODEX_HOME']=str(codex)
p=run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','lab','-x','160','-y','45','-c',R,'bash --noprofile --norc']); assert p.returncode==0
try:
 run(['tmux','-L','fm-lab','set-option','-g','default-shell','/bin/bash']); run(['tmux','-L','fm-lab','set-option','-g','default-command','bash --noprofile --norc'])
 env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','lab','#{socket_path},#{pid},#{session_id}']).stdout.strip().replace(',$',',')
 id='live-discovery-bad'; brief=L/'home/data'/id; brief.mkdir(); (brief/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with lab-ok.\n\n## Firstmate spec\nNo file changes.\n')
 p=run(['bin/fm-spawn.sh',id,L/'refusal-project','--scout','--backend','tmux','--lane-profile','governance'])
 assert p.returncode==1 and 'lane-profile could not read a valid Codex MCP server list' in p.stderr
 assert not (L/'home/state'/(id+'.meta')).exists()
 print('PASS native Codex discovery failure refuses reduced startup without publishing task metadata',flush=True)
finally:
 p=run(['tmux','-L','fm-lab','kill-server']); assert p.returncode==0
