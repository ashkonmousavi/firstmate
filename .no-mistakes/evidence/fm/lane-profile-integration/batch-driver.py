exec(open('.nm-live/drive.py').read().split('try:\n run([\'bin/fm-lab-home.sh\'')[0])
try:
 for folder in [L/'user/.codex',L/'account']:
  lines=(folder/'config.toml').read_text().splitlines()
  (folder/'config.toml').write_text('\n'.join(f'base_url="http://127.0.0.1:{api.server_port}/v1"' if line.startswith('base_url=') else line for line in lines)+'\n')
 run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','lab','-x','160','-y','45','-c',str(R),'bash --noprofile --norc'])
 run(['tmux','-L','fm-lab','set-option','-g','default-shell','/bin/bash']); run(['tmux','-L','fm-lab','set-option','-g','default-command','bash --noprofile --norc'])
 env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','lab','#{socket_path},#{pid},#{session_id}']).stdout.strip().replace(',$',',')
 for id in ['live-batch-one','live-batch-two']:
  d=L/'data'/id; d.mkdir(parents=True)
  (d/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with lane-profile-lab-ok.\n\n## Firstmate spec\nNo tools and no file changes.\n')
 for marker in L.glob('*.pid'): marker.unlink()
 run(['bin/fm-spawn.sh','live-batch-one='+str(L/'project'),'live-batch-two='+str(L/'project'),'--scout','--backend','tmux','--lane-profile','ci-tooling'])
 observed={f.stem for f in L.glob('*.pid')}
 assert observed=={'retained','account_control'},observed
 for name in observed: assert len((L/(name+'.pid')).read_text().splitlines())==2
 for id in ['live-batch-one','live-batch-two']:
  meta=L/'state'/(id+'.meta'); data=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
  assert data['lane_profile']=='ci-tooling'
  native=codex_pids(data['window']); assert native
  print(json.dumps({'scenario':'batch forwarding','task':id,'profile':data['lane_profile'],'codex_pids':sorted(native),'result':'pass'}),flush=True)
  (E/(id+'-metadata.txt')).write_text(meta.read_text())
  run(['bin/fm-control.sh',id,'exit'])
finally:
 stop=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
 print('private tmux stop exit='+str(stop.returncode),flush=True)
 api.shutdown(); api.server_close(); print('API stopped',flush=True)
