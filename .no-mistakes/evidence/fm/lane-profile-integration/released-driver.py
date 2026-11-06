# Additional live scenario using the same disposable runtime and seeded released state.
exec(open('.nm-live/drive.py').read().split('try:\n run([\'bin/fm-lab-home.sh\'')[0])
try:
 for folder in [L/'user/.codex',L/'account']:
  lines=(folder/'config.toml').read_text().splitlines()
  (folder/'config.toml').write_text('\n'.join(f'base_url="http://127.0.0.1:{api.server_port}/v1"' if line.startswith('base_url=') else line for line in lines)+'\n')
 run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','lab','-x','160','-y','45','-c',str(R),'bash --noprofile --norc'])
 run(['tmux','-L','fm-lab','set-option','-g','default-shell','/bin/bash']); run(['tmux','-L','fm-lab','set-option','-g','default-command','bash --noprofile --norc'])
 env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','lab','#{socket_path},#{pid},#{session_id}']).stdout.strip().replace(',$',',')
 id='live-released'; branch='fm/'+id; url='https://github.com/lab-fixture/repo/pull/7'
 P=L/'released-project'
 if not P.exists(): run(['git','clone','--quiet',L/'project',P])
 run(['git','-C',P,'remote','set-url','origin','https://github.com/lab-fixture/repo.git'])
 run(['git','-C',P,'config','url.file://'+str(L/'origin.git')+'.insteadOf','https://github.com/lab-fixture/repo.git'])
 head=run(['git','-C',P,'rev-parse','HEAD']).stdout.strip()
 run(['git','-C',P,'push','origin','HEAD:refs/heads/'+branch])
 tools=L/'tools'; tools.mkdir(exist_ok=True)
 # This is external forge data, not a replacement for any Firstmate, Git,
 # Treehouse, terminal, Codex, or MCP implementation under test.
 fields=f'state=OPEN\nmerged=false\nhead={head}\nhead_path=lab-fixture/repo\nhead_branch={branch}\n'
 (tools/'gh').write_text('#!/usr/bin/env bash\ncat <<\'FIELDS\'\n'+fields+'FIELDS\n')
 (tools/'gh').chmod(0o755); env['PATH']=str(tools)+':'+env['PATH']
 d=L/'data'/id; d.mkdir(parents=True,exist_ok=True)
 (d/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with lane-profile-lab-ok.\n\n## Firstmate spec\nNo tools and no file changes.\n')
 data={'window':'lab:fm-'+id,'endpoint_task_id':id,'worktree':str(L/'state'/(id+'.released-copy')),'released_head':head,'released_branch':branch,'released_pr':url,'project':str(P),'harness':'codex','kind':'ship','mode':'local-only','yolo':'off','branch':branch,'model':'default','effort':'default','lane_profile':'governance','spawn_gen':'s1793930000.1.1','pr':url}
 meta=L/'state'/(id+'.meta'); meta.write_text(''.join(k+'='+v+'\n' for k,v in data.items()))
 print('Seeded released-copy metadata; external forge fixture reports OPEN; all runtime tools real.',flush=True)
 for marker in L.glob('*.pid'): marker.unlink()
 p=run(['bin/fm-control.sh',id,'relaunch','--model','default','--note','Recreate released copy using the selected account and governance startup.'])
 after=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
 assert after['worktree']!=data['worktree'] and pathlib.Path(after['worktree']).exists()
 assert after['account']==str(L/'account') and after['lane_profile']=='governance'
 assert run(['git','-C',after['worktree'],'rev-parse','HEAD']).stdout.strip()==head
 assert {f.stem for f in L.glob('*.pid')}=={'retained'}
 print(json.dumps({'scenario':'released default-model governance relaunch','result':'pass','account':after['account'],'lane_profile':after['lane_profile'],'worktree':after['worktree'],'head':head,'live_mcp':['retained']}),flush=True)
 (E/'released-metadata.txt').write_text(meta.read_text())
 (E/'released-screen.txt').write_text(run(['tmux','-L','fm-lab','capture-pane','-p','-t',after['window'],'-S','-100']).stdout)
 run(['bin/fm-control.sh',id,'exit'])
finally:
 result=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
 print('private tmux stop exit='+str(result.returncode),flush=True)
 api.shutdown(); api.server_close(); print('API stopped',flush=True)
