import os, subprocess, time, pathlib, json, html
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M68P0P3YHBVJF2JJFA12JV05')
env=os.environ.copy()
for key in list(env):
    if key in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
        env.pop(key,None)
env['FM_EXIT_PICKER_LIVE']='1'
env['TMPDIR']=str(root/'.test-tmp')
with (evidence/'live-e2e.log').open('w') as log:
    proc=subprocess.Popen(['bash','tests/fm-control-exit-picker-live-e2e.test.sh'],env=env,stdout=log,stderr=subprocess.STDOUT)
    sock=str(root/f'.ep-{proc.pid}.sock')
    records=[]
    previous=''
    start=time.monotonic()
    while proc.poll() is None:
        if pathlib.Path(sock).exists():
            cap=subprocess.run(['tmux','-S',sock,'capture-pane','-p','-t','live:fm-picker'],capture_output=True,text=True)
            if cap.returncode==0 and cap.stdout!=previous:
                previous=cap.stdout
                records.append({'elapsed':round(time.monotonic()-start,2),'screen':cap.stdout})
        if time.monotonic()-start>300:
            proc.terminate()
            try: proc.wait(timeout=15)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
            break
        time.sleep(.15)
    code=proc.wait()
(evidence/'terminal-screens.json').write_text(json.dumps(records,indent=2))
frames=[]
for index,r in enumerate(records):
    if ('Background work is running' in r['screen'] and 'Enter to confirm' in r['screen']) or ('Claude and background' in r['screen']):
        frames.append((index,r))
# Keep a final real captured grid too. No invented terminal content is added.
if records: frames.append((len(records)-1,records[-1]))
page='<html><meta charset="utf-8"><title>Real Claude exit picker terminal captures</title><style>body{background:#181818;color:#eee;font:16px system-ui;padding:25px}pre{background:#090909;color:#ddd;padding:20px;white-space:pre;overflow:auto;font:13px monospace;border:1px solid #555}h2{font-size:18px}</style><h1>Real Claude Code: exit-picker validation</h1><p>Captured directly from the isolated tmux terminal during the live regression. See live-e2e.log for control outputs and preservation assertions.</p>'
for index,r in frames:
    page+=f'<h2>Terminal at {r["elapsed"]} seconds (frame {index})</h2><pre>'+html.escape(r['screen'])+'</pre>'
page+='</html>'
(evidence/'claude-picker.html').write_text(page)
(evidence/'live-result.json').write_text(json.dumps({'exit_code':code,'captured_frames':len(records),'picker_frames':len(frames)-bool(records)},indent=2))
print((evidence/'live-e2e.log').read_text())
print(f'live regression exit status: {code}; retained {len(records)} real terminal frames')
raise SystemExit(code)
