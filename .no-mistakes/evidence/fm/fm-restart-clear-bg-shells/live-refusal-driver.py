import os, pathlib, shlex, signal, subprocess, tempfile, time
ROOT=pathlib.Path.cwd()
OUT=pathlib.Path('~/.no-mistakes/evidence/01M6A1RBDBTX6W12NDNV591RNK')
base=os.environ.copy()
for key in list(base):
    if key.startswith('FM_') or key in ('NO_MISTAKES_GATE','TMUX','CLAUDECODE','CLAUDE_CONFIG_DIR'):
        base.pop(key,None)
base.update(DISABLE_AUTOUPDATER='1',DISABLE_NONESSENTIAL_TRAFFIC='1',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
def run(args,env=base,check=True):
    p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if check and p.returncode: raise RuntimeError(f'{args}: rc={p.returncode}\n{p.stdout}')
    return p
for case in ('running','unreadable'):
    lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.'))
    env=base|{'FM_HOME':str(lab),'TMUX_TMPDIR':str(lab/'tmux'),'FM_TASK_INBOX':str(lab/'state/sm1.inbox')}
    restart=None
    bgpid=None
    try:
        run([ROOT/'bin/fm-lab-home.sh','create',lab])
        (lab/'tmux').mkdir()
        (lab/'config/supervision-host').touch()
        (lab/'config/secondmate-harness').write_text('claude\n')
        (lab/'state/sm1.meta').write_text(f'window=primary:fm-sm1\nendpoint_task_id=sm1\nworktree={lab}\nproject={lab}\nharness=claude\nkind=secondmate\nmode=secondmate\nhome={lab}\nbackend=tmux\n')
        def tmux(*args,check=True): return run(['tmux','-L','fm-lab',*args],env,check)
        system='This is an isolated live test. Operate only in FM_HOME. Do not delegate or use external services. You have no open records to persist. On a Firstmate instruction doorbell, read all *.msg in FM_TASK_INBOX using Bash, extract its corr= token and follow the request. For this adversarial test deliberately leave your background sleep running; explain it is a test fixture. Do not invoke stow or inspect other files. '+('Before reporting rename your own tmux window using tmux rename-window -t "$TMUX_PANE" fm-unreadable. ' if case=='unreadable' else '')+'Then append exactly done [corr=THE_TOKEN]: no open records; background shell deliberately left alone for test to "$FM_HOME/state/sm1.status" with Bash, preserving the actual correlation. Move the message to handled/. Reply ACKNOWLEDGED and stop. Do not run /exit.'
        prompt='Use Bash once with run_in_background=true to run sh -c '+shlex.quote('echo $$ > "$FM_HOME/background.pid"; exec sleep 600')+'. Then reply READY and stop, leaving the task running.'
        cli=['claude','--no-chrome','--permission-mode','dontAsk','--allowedTools','Bash,Read','--model','haiku','--effort','low','--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--system-prompt',system,prompt]
        tmux('new-session','-d','-s','primary','-n','fm-sm1','-c',ROOT,'-x','180','-y','45','-e','FM_HOME='+str(lab),shlex.join(cli))
        target='primary:fm-sm1'
        def capture(): return tmux('capture-pane','-p','-t','primary','-S','-0',check=False).stdout
        for _ in range(100):
            screen=capture()
            if (lab/'background.pid').exists() and 'READY' in screen and '1 shell' in screen: break
            time.sleep(1)
        else: raise RuntimeError('Claude did not start background task:\n'+screen)
        bgpid=int((lab/'background.pid').read_text())
        os.kill(bgpid,0)
        before_pid=tmux('display-message','-p','-t',target,'#{pane_pid}').stdout.strip()
        (OUT/f'{case}-before.txt').write_text(screen)
        env['TMUX']=tmux('display-message','-p','-t',target,'#{socket_path},#{pid},0').stdout.strip()
        env.update(FM_SECONDMATE_PERSIST_WAIT='120',FM_SECONDMATE_PERSIST_POLL='1',FM_SECONDMATE_BG_SHELL_WAIT='2')
        restart=subprocess.Popen(['bash',str(ROOT/'bin/fm-secondmate-restart.sh'),'sm1'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        result,_=restart.communicate(timeout=170)
        after=capture()
        (OUT/f'{case}-after.txt').write_text(after)
        status=(lab/'state/sm1.status').read_text() if (lab/'state/sm1.status').exists() else '(missing)'
        report=f'case: {case}\nrestart exit: {restart.returncode}\n{result}\nparent report:\n{status}\n'
        (OUT/f'{case}-restart.txt').write_text(report)
        print(report,flush=True)
        assert restart.returncode==3
        assert 'background-shell cleanup incomplete:' in result
        assert 'relaunch was not attempted' in result
        assert 'summary: 0 of 1 restarted, 0 nudged, 1 unreached' in result
        assert ('still running after 2s' if case=='running' else 'screen could not be read') in result
        os.kill(bgpid,0)
        assert before_pid==tmux('display-message','-p','-t','primary','#{pane_pid}').stdout.strip()
        assert 'Background work is running' not in after
        print(f'PASS: {case}: real restart refused, same Claude PID and background task alive, no picker',flush=True)
    finally:
        if restart and restart.poll() is None:
            restart.terminate()
            restart.communicate(timeout=15)
        run(['tmux','-L','fm-lab','kill-server'],env,check=False)
        if bgpid:
            try: os.kill(bgpid,signal.SIGTERM)
            except ProcessLookupError: pass
        import shutil
        shutil.rmtree(lab)
        print(f'TEARDOWN: {case} private tmux server stopped and disposable lab removed',flush=True)
