import os,pathlib,signal,subprocess,time,shutil,sys
lab=pathlib.Path(sys.argv[1])
assert lab.parent==pathlib.Path.cwd() and lab.name.startswith(('.g','.i','.l','.d'))
rows=subprocess.check_output(['ps','-eo','pid=,ppid='],text=True).splitlines()
parents={int(r.split()[0]):int(r.split()[1]) for r in rows}
r=subprocess.run(['tmux','-L','fm-lab','list-panes','-a','-F','#{pane_pid}'],capture_output=True,text=True)
roots={int(p) for p in r.stdout.split() if p.isdigit()}
def owned(pid):
    seen=set()
    while pid in parents and pid not in seen:
        if pid in roots:return True
        seen.add(pid);pid=parents[pid]
    return False
def identity(pid):
    try:
        stat=(pathlib.Path('/proc')/str(pid)/'stat').read_text().rsplit(')',1)[1].split()
        return stat[19] if stat[0]!='Z' else None
    except (FileNotFoundError,ProcessLookupError):return None
saved={p:identity(p) for p in parents if owned(p)}
subprocess.run(['tmux','-L','fm-lab','kill-server'],capture_output=True)
for sig in (signal.SIGTERM,signal.SIGKILL):
    for p,i in saved.items():
        if i and identity(p)==i:
            try:os.kill(p,sig)
            except ProcessLookupError:pass
    for n in range(40):
        if not any(i and identity(p)==i for p,i in saved.items()):break
        time.sleep(.1)
remaining=[p for p,i in saved.items() if i and identity(p)==i]
if remaining:raise SystemExit(f'live disposable children remain: {remaining}')
# Native downloader children have been awaited before deletion.
shutil.rmtree(lab)
print(f'Cleanup verified: private tmux server and {len(saved)} observed descendants stopped; lab removed')
