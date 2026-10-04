import pathlib,tempfile,subprocess,os,shutil
root=pathlib.Path.cwd();e=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M42JD1EGCXV3KJW39JC23GXS');lab=pathlib.Path(tempfile.mkdtemp(prefix='.live-optional-',dir=root));logs=[]
env=dict(os.environ)
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE'):env.pop(k,None)
env['FM_HOME']=str(lab)
def run(args):
 p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);logs.append('$ '+subprocess.list2cmdline(args)+'\n'+p.stdout+'[exit '+str(p.returncode)+']');return p
try:
 p=run(['bash','bin/fm-brief.sh','optional-review','proj','--scout','--prep-review','fixture-plan']);assert p.returncode==0,p.stdout
 artifact=lab/'data'/'optional-review'/'brief.md';assert artifact.exists();(e/'optional-review-brief.md').write_bytes(artifact.read_bytes())
 p=run(['bash','bin/fm-brief.sh','forbidden-review','proj','--mode','no-mistakes','--prep-review','fixture-plan']);assert p.returncode!=0 and '--scout' in p.stdout,p.stdout
 assert not (lab/'data'/'forbidden-review'/'brief.md').exists()
 print('Optional scout preparation-review scaffold succeeds; ship use is refused with the scout requirement.')
finally:
 shutil.rmtree(lab);logs.append('Disposable home removed.')
 (e/'live-optional-review-transcript.log').write_text('\n\n'.join(logs)+'\n')
