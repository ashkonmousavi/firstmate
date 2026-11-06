exec(open('.nm-live/drive.py').read().split('try:\n run([\'bin/fm-lab-home.sh\'')[0])
try:
 account=L/'account'; text=(account/'config.toml').read_text(); lines=text.splitlines()
 text='\n'.join(f'base_url="http://127.0.0.1:{api.server_port}/v1"' if line.startswith('base_url=') else line for line in lines)+'\n'
 for name in ['custom_index','account_control']:
  text+=f'\n[mcp_servers.{name}]\ncommand={json.dumps(sys.executable)}\nargs={json.dumps([str(R/"tests/lane-profile-native.py"),"mcp",name,str(L/(name+".pid"))])}\n'
 (account/'config.toml').write_text(text)
 (L/'config/code-index-mcp-servers').write_text('custom_index\n')
 run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','lab','-x','160','-y','45','-c',str(R),'bash --noprofile --norc'])
 run(['tmux','-L','fm-lab','set-option','-g','default-shell','/bin/bash']); run(['tmux','-L','fm-lab','set-option','-g','default-command','bash --noprofile --norc'])
 env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','lab','#{socket_path},#{pid},#{session_id}']).stdout.strip().replace(',$',',')
 # Restore the original scratch remote so its already retained copies keep
 # their Treehouse project identity. Only this disposable repo is changed.
 run(['git','-C',L/'project','remote','set-url','origin',L/'origin.git'])
 id='live-alias'; d=L/'data'/id; d.mkdir(parents=True)
 (d/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with lane-profile-lab-ok.\n\n## Firstmate spec\nNo tools and no file changes.\n')
 for marker in L.glob('*.pid'): marker.unlink()
 run(['bin/fm-spawn.sh',id,L/'project','--mode','local-only','--yolo','off','--backend','tmux','--lane-profile','governance'])
 meta=L/'state'/(id+'.meta'); data=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
 observed={f.stem for f in L.glob('*.pid') if any(subprocess.run(['kill','-0',v],capture_output=True).returncode==0 for v in f.read_text().splitlines())}
 assert observed=={'retained','account_control'},observed
 native=codex_pids(data['window']); assert native
 for pid in native:
  proc_env=pathlib.Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
  assert ('CODEX_HOME='+str(account)).encode() in proc_env
 print(json.dumps({'scenario':'ship alias and selected-root startup','result':'pass','processes':sorted(observed),'native_codex_pids':sorted(native),'CODEX_HOME':str(account),'suppressed':['gitnexus','claude-context','custom_index']}),flush=True)
 (E/'alias-metadata.txt').write_text(meta.read_text())
 (E/'alias-screen.txt').write_text(run(['tmux','-L','fm-lab','capture-pane','-p','-t',data['window'],'-S','-80']).stdout)
 run(['bin/fm-control.sh',id,'exit'])
finally:
 stop=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
 print('private tmux stop exit='+str(stop.returncode),flush=True)
 api.shutdown(); api.server_close(); print('API stopped',flush=True)
