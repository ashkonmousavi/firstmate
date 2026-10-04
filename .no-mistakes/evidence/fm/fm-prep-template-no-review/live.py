import os, re, subprocess, shutil, json
from pathlib import Path
root=Path.cwd()
evidence=Path('/home/tegris/.no-mistakes/evidence/01M43C5X37ANEHYTB6YAW1JDX1')
lab=root/'.test-phase/live'
home=lab/'home'
lab.mkdir()
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key in ('NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX'): env.pop(key)
env.update(FM_HOME=str(home),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1',TMPDIR=str(root/'.test-phase/tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=(evidence/'live-cli-transcript.txt').open('w')
results=[]
def run(args, expected=None, cwd=root, useenv=None):
 p=subprocess.run(args,cwd=cwd,env=useenv or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
 log.write('$ '+__import__('shlex').join(map(str,args))+'\n'+p.stdout+'\nraw exit: '+str(p.returncode)+'\n');log.flush()
 if expected is not None: assert p.returncode==expected,(args,p.returncode,p.stdout)
 return p

def gate(path, refusal=None):
 p=run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1"','_',str(path)])
 assert (p.returncode==1 and p.stdout=='') if refusal is None else (p.returncode==0 and refusal in p.stdout),p.stdout
 return p

def section(s,heading,value):
 lines=s.splitlines(keepends=True); start=next(i for i,l in enumerate(lines) if l.strip()==heading)+1
 end=next((i for i in range(start,len(lines)) if lines[i].startswith('## ')),len(lines))
 return ''.join(lines[:start])+value+'\n\n'+''.join(lines[end:])

def record(id,q1='no',q2='no',surgical=False):
 run(['bash','bin/fm-brief.sh',id,'--prep']+(['--surgical'] if surgical else []),0)
 prep=home/'data'/id/'prep.md'
 s=prep.read_text()
 (evidence/('fresh-'+id+'.md')).write_text(s)
 gate(prep,'Tier')
 values={'Q1':q1,'Q2':q2,'UI_WIRING':'no, no UI change.','Q1_REASON':'Confined CLI preparation path.','Q2_REASON':'No shared caller changes in the compact fixture.','CAPTAIN_RULINGS':'"Preserve the exact literal marker." Source: disposable task intent.','SCREEN_AND_REGION':'n/a: CLI preparation artifact only.','RED_FIRST_PROOF':'Run emitted grep on marker and unrelated rows, remove marker to require raw exit 1, restore to require raw exit 0.','FIXTURE_ARITHMETIC':'n/a: no arithmetic assertions.','DATA_PATH_REACHABILITY':'fm-brief creates prep.md; public completeness gate reads it; real fm-spawn emits launch-brief.md.','SCOPE_ONLY_AS_ASKED':'Check literal marker preparation and handoff; no real worker or installed acceptance.','AUTHOR_GATE_CHECK':'bash -c \' . bin/fm-dod-lib.sh; fm_prep_unfilled_reason "$1" \' _ '+str(prep)+'; final-byte result belongs in this handoff transcript, empty output/raw exit 1.','OUTCOME':'Marker selection','OBSERVABLE_RESULT':'Only the marker row is returned','WHERE_AND_HOW':"`grep -F '<!-- marker -->' output.html`",'EXPECTED_VALUE':'`<!-- marker -->`'}
 for i in range(1,6): values['C'+str(i)]='yes';values['C'+str(i)+'_EVIDENCE']='bin/owned.sh:1; rg owned reported the sole owned file; no shared, data, security, permission, money, install or server path touched; emitted check reproduced with independent marker expectation.'
 s=re.sub(r'\{([A-Z0-9_]+)\}',lambda m:values.get(m[1],'n/a: disposable CLI fixture.'),s)
 if not surgical:s=section(s,'## 1. Intent and boxes','Preserve the exact literal marker in the requested handoff.')
 prep.write_text(s);gate(prep)
 return prep

spec_heading="## Accepted specification for --intent (preparation record, not the captain's words)"
intent_heading='## Captain intent authorized for --intent'
def accepted(s):
 return s.split(spec_heading+'\n',1)[1].split(intent_heading+'\n',1)[0].rstrip()+'\n'
def brief(id,mode):
 d=home/'data'/id;d.mkdir(exist_ok=True,parents=True)
 (d/'brief.md').write_text("# Task\n## Captain's intent\nPreserve the exact literal marker.\n\n## Firstmate spec\nCheck the emitted contract.\n\n# Definition of done\nDelivery contract: mode="+mode+'\n')
def spawn(id,mode,blocked=None):
 brief(id,mode)
 p=run(['bash','bin/fm-spawn.sh',id,str(project),'claude','--mode',mode,'--yolo','off'])
 assert p.returncode!=0,p.stdout
 dest=home/'data'/id/'launch-brief.md'
 if blocked:
  assert blocked in p.stdout and not dest.exists(),p.stdout
 else:
  assert dest.exists(),p.stdout
  assert 'cannot ship before a separate agent reviews' not in p.stdout
  assert not (home/'data'/id/'prep-review').exists()
  assert not (home/'state'/(id+'.meta')).exists()
  shutil.copyfile(dest,evidence/(id+'-launch.md'))
 return dest,p
try:
 run(['bash','bin/fm-lab-home.sh','create',str(home)],0)
 # A directory occupying the private socket path makes connection/creation impossible.
 socket=home/'tmux'/'refusing';socket.mkdir(parents=True)
 env['TMUX']=str(socket)+',1,0'
 project=home/'projects'/'proj';project.mkdir()
 run(['git','-C',str(project),'init','-q'],0)
 for id,q1,q2,surgical in [('all-no','no','no',False),('tier-one','no','yes',False),('tier-two','yes','no',False),('surgical','yes','no',True)]:
  prep=record(id,q1,q2,surgical)
  spawn(id,'direct-PR')
  results.append({'scenario':'Valid '+id+' record admits to launch rendering without review','result':'pass','live':True})
 # All common fields, forbidden n/a, structural sections and exact outcome columns.
 prep=record('incomplete');baseline=prep.read_text()
 fields=['Captain rulings','Screen and region','Red-first proof','Fixture arithmetic','Data path reachability','Scope only as asked','Author gate check']
 for field in fields:
  for value in (None,'','{UNFILLED}','<!-- example only -->'):
   prep.write_text(re.sub(r'^- '+re.escape(field)+r':.*\n', '' if value is None else '- '+field+': '+value+'\n',baseline,flags=re.M));gate(prep,field)
 for field in ('Scope only as asked','Author gate check'):
  prep.write_text(re.sub(r'^- '+re.escape(field)+r':.*','- '+field+': n/a: unnecessary',baseline,flags=re.M));gate(prep,field)
 for index in range(1,5):
  lines=baseline.splitlines();n=next(i for i,l in enumerate(lines) if l.startswith('| Marker selection |'))
  cells=lines[n].split('|');cells[index]=' ';lines[n]='|'.join(cells)
  prep.write_text('\n'.join(lines)+'\n');gate(prep,'Expected outcomes')
 prep.write_text(section(baseline,'## 1. Intent and boxes',''));gate(prep,'Intent and boxes')
 prep.write_text(re.sub(r'^- Scope only as asked:.*\n','',baseline,flags=re.M));spawn('incomplete','direct-PR','Scope only as asked')
 prep.write_text(baseline);gate(prep)
 results.append({'scenario':'Incomplete common fields and malformed outcomes refuse public admission','result':'pass','live':True})
 # Genuine list continuation remains valid for every author answer.
 for field in fields:
  prep.write_text(re.sub(r'^- '+re.escape(field)+r': (.*)$',lambda m:'- '+field+':\n '+m[1],baseline,flags=re.M));gate(prep)
 prep.write_text(baseline)
 # Complete legacy declarations cannot waive completeness; certainty remains enforced.
 legacy=baseline.replace('## Tier\n','## Tier\n- Prep review exemption: server-install\n- Changes unit: no\n- Changes setting: no\n- Changes pin: no\n- Changes store version: no\n')
 prep.write_text(legacy);gate(prep)
 prep.write_text(re.sub(r'^- Scope only as asked:.*\n','',legacy,flags=re.M));gate(prep,'Scope only as asked')
 compact=home/'data/surgical/prep.md';original=compact.read_text()
 compact.write_text(re.sub(r'^(- C2 .*): yes$',r'\1: unsure',original,flags=re.M));gate(compact,'C2');compact.write_text(original)
 results.append({'scenario':'Author continuations, surgical certainty and legacy install boundary','result':'pass','live':True})
 # Preserve heading-followed-indented executable literal in both substantive sections.
 command="    grep -F '<!-- marker -->' output.html"
 for mode in ('no-mistakes','direct-PR','local-only'):
  id='handoff-'+mode.lower();prep=record(id,'yes','no')
  s=section(prep.read_text(),'## 2. Behaviour spec','### Marker check\n'+command)
  s=section(s,'## 11. Definition of done','### Exact check\n'+command);prep.write_text(s);gate(prep)
  p=run(['bash','-c','. bin/fm-dod-lib.sh; fm_prep_accepted_spec "$1"','_',str(prep)],0)
  expected=p.stdout;(evidence/(id+'-accepted-spec.md')).write_text(expected)
  assert expected.count(command)==2 and "`<!-- marker -->`" in expected
  dest,_=spawn(id,mode);emitted=dest.read_text()
  if mode=='no-mistakes':
   assert accepted(emitted)==expected.rstrip()+'\n'
   assert emitted.split(intent_heading+'\n',1)[1].strip()=='Preserve the exact literal marker.'
  else:assert spec_heading not in emitted
  # Actual emitted checks use a separately declared marker-only oracle, including missing marker.
  for state,text,want_rc,want_output in [('baseline','unrelated\n<!-- marker -->\n',0,'<!-- marker -->\n'),('fault','unrelated\n',1,''),('restore','unrelated\n<!-- marker -->\n',0,'<!-- marker -->\n')]:
   (lab/'output.html').write_text(text)
   for check in [l for l in expected.splitlines() if l.startswith('    grep ')]:
    p=run(['bash','-c',check],want_rc,cwd=lab);assert p.stdout==want_output
  # Promotion operates on isolated durable task metadata, without a running worker.
  (home/'state'/(id+'.meta')).write_text('window=fm-'+id+'\nkind=scout\nworktree='+str(project)+'\n')
  run(['bash','bin/fm-promote.sh',id,'--mode',mode,'--yolo','off'],0)
  assert 'kind=ship' in (home/'state'/(id+'.meta')).read_text()
  for file in ('ship-instructions.md','brief.md'):
   dest=home/'data'/id/file;s=dest.read_text()
   assert (accepted(s)==expected.rstrip()+'\n') if mode=='no-mistakes' else spec_heading not in s
   shutil.copyfile(dest,evidence/(id+'-'+file))
 results.append({'scenario':'Exact literals survive ordinary and promoted handoff in all modes; emitted check fails on missing marker','result':'pass','live':True})
 # Navigation install uses real registered disposable homes and actual file copy.
 prep=record('nav-source');sm=lab/'nav';(sm/'data/nav-preps').mkdir(parents=True)
 src=sm/'data/nav-preps/nav-install.md';shutil.copyfile(prep,src)
 (home/'data/secondmates.md').write_text('- nav - navigation (home: '+str(sm)+'; scope: wayfinding; projects: firstmate; added 2026-10-04)\n')
 before=src.read_bytes();run(['bash','bin/fm-prep-install.sh','nav-install'],0)
 dest=home/'data/nav-install/prep.md';assert before==dest.read_bytes()==src.read_bytes()
 run(['cmp',str(src),str(dest)],0)
 shutil.copyfile(dest,evidence/'installed-nav-prep.md')
 src.write_text(re.sub(r'^- Scope only as asked:.*\n','',src.read_text(),flags=re.M))
 run(['bash','bin/fm-prep-install.sh','nav-install','--force'],1);assert dest.read_bytes()==before
 results.append({'scenario':'Nav-prep installs exact bytes and refuses incomplete source without rewriting destination','result':'pass','live':True})
except Exception as exc:
 log.write('DRIVER FAILURE: '+repr(exc)+'\n');raise
finally:
 (evidence/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
 log.write('TEARDOWN: removing only disposable workspace lab; no server or worker created.\n');log.close()
 shutil.rmtree(lab)
print(json.dumps(results,indent=2))
