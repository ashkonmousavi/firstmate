#!/usr/bin/env python3
import os,sys,json,subprocess
from pathlib import Path
args=sys.argv[1:]
if args==['--version']:
 os.execv('~/.local/bin/herdr',['herdr','--version'])
assert '--session' in args,args
i=args.index('--session');session=args[i+1];del args[i:i+2]
assert session=='fm-lab-v',session
mode=os.environ.get('FM_LIVE_FAULT','none')
log=Path(os.environ.get('FM_LIVE_CALL_LOG','.r/calls.jsonl'))
with log.open('a') as f:f.write(json.dumps({'fault':mode,'args':args})+'\n')
get=args[:2]==['pane','get']
if get and mode in ('plain-only','no-bottom','empty-bottom'):
 counter=Path('.r/get-count');n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
 if n>1:sys.exit(1)
if args[:2]==['pane','read'] and '--source' in args and args[args.index('--source')+1]=='recent':
 if mode=='no-bottom':sys.exit(1)
 if mode=='empty-bottom':sys.exit(0)
 if mode=='plain-only' and '--format' in args:sys.exit(1)
env=dict(os.environ);env['PATH']=':'.join(p for p in env['PATH'].split(':') if p!=str(Path('.r/bin').resolve()))
p=subprocess.run(['bin/fm-herdr-lab.sh','run',session,*args],capture_output=True,env=env)
if mode=='close-after-probe':
 with log.open('a') as f:f.write(json.dumps({'real_response':args,'rc':p.returncode,'stdout':p.stdout.decode(errors='replace'),'stderr':p.stderr.decode(errors='replace')})+'\n')
 if get and p.returncode==0:
  assert json.loads(p.stdout)['result']['pane']['scroll']['offset_from_bottom']>0
  closed=subprocess.run(['bin/fm-herdr-lab.sh','run',session,'pane','close',args[2]],capture_output=True,env=env)
  assert closed.returncode==0,closed.stderr
  with log.open('a') as f:f.write(json.dumps({'closed_after_positive_offset':args[2],'response':closed.stdout.decode(errors='replace')})+'\n')
if get and mode=='missing' and p.returncode==0:
 data=json.loads(p.stdout);data['result']['pane'].pop('scroll',None);sys.stdout.write(json.dumps(data))
else:
 sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr)
sys.exit(p.returncode)
