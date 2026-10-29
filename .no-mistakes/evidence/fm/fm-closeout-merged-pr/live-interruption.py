import os, pathlib, subprocess, json, time, signal, shutil, fcntl, traceback
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M64E68ZHNYGVBAFEHRS8HAMS'); H=R/'.closeout-interruption'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))};env.update(FM_HOME=str(H),FM_INACTIVE_RECONCILE_BUDGET_SECS='30')
log=(E/'live-interruption.log').open('w',buffering=1)
results=[]; child=None; boardlock=None
def run(args):
    p=subprocess.run(list(map(str,args)),env=env,cwd=R,capture_output=True,text=True,timeout=40)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    assert p.returncode==0
    return p.stdout

def descendants(pid):
    found=[]
    try: children=pathlib.Path('/proc/'+str(pid)+'/task/'+str(pid)+'/children').read_text().split()
    except OSError: return found
    for c in children:
        c=int(c);found.append(c);found+=descendants(c)
    return found

def snap(label):
    for p in [H/'data/backlog.md',H/'data/x-reconcile.json',*sorted((H/'state/terminal-outcomes').glob('backlog-pr-*.closed'))]:
        if p.exists():
            shutil.copyfile(p,E/(label+'-'+p.name));log.write('PERSISTED '+p.name+'\n'+p.read_text()+'\n')
try:
    run([R/'bin/fm-lab-home.sh','create',H]);(H/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
    run([R/'bin/fm-tasks-axi.sh','add','kill-cut','Signal boundary validation','--body','https://github.com/cli/cli/pull/1'])
    run([R/'bin/fm-tasks-axi.sh','start','kill-cut'])
    boardlock=(H/'data/x-reconcile.json.lock').open('w');fcntl.flock(boardlock,fcntl.LOCK_EX)
    child=subprocess.Popen([str(R/'bin/fm-inactive-reconcile.sh'),'scan','--startup'],env=env,cwd=R,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    deadline=time.monotonic()+25; passpid=None; killed=False
    while time.monotonic()<deadline and child.poll() is None:
        if passpid is None:
            for pid in descendants(child.pid):
                try: cmd=pathlib.Path('/proc/'+str(pid)+'/cmdline').read_bytes().split(b'\0')
                except OSError: continue
                if b'_backlog-pr-pass' in cmd and b'bash' in cmd[0]: passpid=pid;break
        if passpid and '- [x] kill-cut ' in (H/'data/backlog.md').read_text():
            os.kill(passpid,signal.SIGSTOP)
            receipts=list((H/'state/terminal-outcomes').glob('backlog-pr-*.closed'))
            assert len(receipts)==1 and 'status=closing\n' in receipts[0].read_text()
            log.write('Observed committed Done and status=closing; sent SIGSTOP then SIGKILL to owned backlog pass PID '+str(passpid)+'\n')
            os.kill(passpid,signal.SIGKILL);killed=True;break
        time.sleep(.001)
    out,err=child.communicate(timeout=40);log.write(out+err+'scan_exit='+str(child.returncode)+'\n')
    assert killed,'failed to drive the signal window'
    assert child.returncode==0
    snap('kill-before-recovery')
    fcntl.flock(boardlock,fcntl.LOCK_UN);boardlock.close();boardlock=None
    run([R/'bin/fm-inactive-reconcile.sh','scan','--startup'])
    assert '  state: done\n' in run([R/'bin/fm-tasks-axi.sh','show','kill-cut','--full'])
    assert 'status=closed\n' in receipts[0].read_text()
    d=json.loads((H/'data/x-reconcile.json').read_text());assert any(x['id']=='kill-cut' and x['finding']=='fix' and x['detail']=='closed: PR 1 merged 2019-10-04T16:01:04Z' for x in d['items'])
    snap('kill-recovered');log.write('PASS: killed after committed close, recovered dated evidence from durable intent\n')
    results.append(dict(name='Killing the backlog pass after Done commits leaves a closing intent; next scan recovers dated board evidence',result='pass',live=True,evidence='live-interruption.log',reason=''))
except Exception as e:
    log.write(traceback.format_exc());results.append(dict(name='Killing the backlog pass after Done commits leaves a closing intent; next scan recovers dated board evidence',result='fail',live=True,evidence='live-interruption.log',reason=str(e)))
finally:
    if child and child.poll() is None:
        child.terminate();child.communicate(timeout=40)
    if boardlock: boardlock.close()
    shutil.rmtree(H,ignore_errors=True)
    (E/'interruption-scenarios.json').write_text(json.dumps(results,indent=2)+'\n');log.close()
if any(x['result']!='pass' for x in results):raise SystemExit(1)
