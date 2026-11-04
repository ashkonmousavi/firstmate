"""Run the public capacity command before/after the shared predicate fix."""
import json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path('~/.no-mistakes/worktrees/049a88734b0e/01M6JCBKW17X5BMNY1G2F12DMV')
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6JCBKW17X5BMNY1G2F12DMV')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.regression.',dir=root/'.test-phase-tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','REX_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE')}
env['FM_HOME']=str(lab)
socket_dir=None
with (evidence/'base-regression.txt').open('w') as log:
    def run(args,expected=0):
        p=subprocess.run([str(x) for x in args],cwd=root,env=env,text=True,capture_output=True,timeout=40)
        log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr+f'\n[exit {p.returncode}]\n')
        log.flush()
        assert p.returncode==expected,(args,p.returncode,p.stderr)
        return p.stdout
    try:
        run(['bash','bin/fm-lab-home.sh','create',lab])
        socket_dir=run(['bash','bin/fm-lab-home.sh','tmux-dir',lab]).strip()
        env['TMUX_TMPDIR']=socket_dir
        run(['tmux','-L','fm-lab','new-session','-d','-x','100','-y','30','-s','primary','-n','control','bash --noprofile --norc'])
        socket=run(['tmux','-L','fm-lab','display-message','-p','-t','primary:control','#{socket_path}']).strip()
        env['TMUX']=socket+',0,0'
        (lab/'config'/'lane-capacity').write_text('8 0\n')
        (lab/'config'/'machine-admission.json').write_text(json.dumps({'schema':'fm-machine-admission.v1','memory_floor_gib':0,'memory_full_avg60_max':100,'disk_floor_gib':0,'disk_paths':[str(lab)]}))
        (lab/'data'/'secondmates.md').write_text('')
        for name in ('x-nav-slice','x-ux-status-states'):
            (lab/'state'/f'{name}.meta').write_text(f'kind=ship\nbackend=tmux\nwindow=primary:{name}\nworktree=\n')
        shutil.copytree(root/'bin',lab/'base-bin')
        old=subprocess.run(['git','show','b8a95e97990828467e77ee534fc4c5b6ff3f2e40:bin/fm-project-capacity-lib.sh'],cwd=root,text=True,capture_output=True,check=True).stdout
        (lab/'base-bin'/'fm-project-capacity-lib.sh').write_text(old)
        before=json.loads(run(['bash',lab/'base-bin'/'fm-capacity.sh','--json']))
        after=json.loads(run(['bash','bin/fm-capacity.sh','--json']))
        assert before['lanes']==2 and before['free_lanes']==6
        assert after['lanes']==0 and after['free_lanes']==8
        log.write('REPRODUCED: identical missing endpoints and explicit-empty records count as 2 seats with the base predicate, 0 seats with the target predicate.\n')
    finally:
        if socket_dir:
            run(['tmux','-L','fm-lab','kill-server'])
            run(['bash','bin/fm-lab-home.sh','teardown',lab])
        shutil.rmtree(lab)
        log.write('CLEANUP: private server, socket directory and lab removed.\n')
print('Base regression reproduced through public capacity CLI; target restores both free seats.')
