import pathlib,tempfile,shutil,re,subprocess,os
root=pathlib.Path.cwd();e=pathlib.Path('/home/tegris/.no-mistakes/evidence/01M42JD1EGCXV3KJW39JC23GXS');lab=pathlib.Path(tempfile.mkdtemp(prefix='.live-conditional-',dir=root));logs=[]
env=dict(os.environ)
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE'):env.pop(k,None)
env['FM_HOME']=str(lab)
def run(args):
 p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);logs.append('$ '+subprocess.list2cmdline(args)+'\n'+p.stdout+'[exit '+str(p.returncode)+']');return p
try:
 for name,surgical in [('ui',False),('compact',True)]:
  assert run(['bash','bin/fm-brief.sh',name,'--prep']+(['--surgical'] if surgical else [])).returncode==0
  path=lab/'data'/name/'prep.md';src=path.read_text()
  v={'Q1':'no','Q2':'no','UI_WIRING':'yes, Settings configuration control.' if not surgical else 'no, isolated CLI check.', 'SCREEN_AND_REGION':'n/a: CLI only.', 'CAPTAIN_RULINGS':'Explicit ruling: omit separate prep review; source supplied intent.', 'INTENT_AND_BOXES':'Check conditional preparation fields in isolation.'}
  for i in range(1,6):v['C'+str(i)]='yes';v['C'+str(i)+'_EVIDENCE']='Concrete isolated evidence; no production modification.'
  filled=re.sub(r'\{([A-Z0-9_]+)\}',lambda m:v.get(m[1],'Concrete isolated observation and expected result.' if m[1] in ['RED_FIRST_PROOF','FIXTURE_ARITHMETIC','DATA_PATH_REACHABILITY','SCOPE_ONLY_AS_ASKED','AUTHOR_GATE_CHECK','OUTCOME','OBSERVABLE_RESULT','WHERE_AND_HOW','EXPECTED_VALUE'] else 'n/a: no additional behavior applies to this isolated check.'),src)
  def gate(text):
   path.write_text(text);return run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1"','_',str(path)])
  if not surgical:
   p=gate(filled);assert p.returncode==0 and 'Screen and region' in p.stdout,p.stdout
   p=gate(filled.replace('- Screen and region: n/a: CLI only.','- Screen and region: Settings screen, configuration region, fixture layout reference.'));assert p.returncode==1 and not p.stdout,p.stdout
  else:
   p=gate(filled);assert p.returncode==1 and not p.stdout,p.stdout
   p=gate(re.sub(r'(?m)^- Captain rulings:.*$','- Captain rulings: n/a: no additional ruling.',filled));assert p.returncode==0 and 'Captain rulings' in p.stdout,p.stdout
 print('UI declaration requires concrete screen/region; compact preparation requires concrete intent/rulings rather than n/a.')
finally:
 shutil.rmtree(lab);logs.append('Disposable home removed.')
 (e/'live-conditional-transcript.log').write_text('\n\n'.join(logs)+'\n')
