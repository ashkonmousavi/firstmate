import json,os,pathlib,subprocess,sys
payload=sys.stdin.read(); home=pathlib.Path(os.environ['FM_HOME']); data=json.loads(payload)
p=subprocess.run(['bash',os.environ['LAB_GUARD'],'--claude','--state-claims'],input=payload,text=True,capture_output=True)
with (home/'events.jsonl').open('a') as f:f.write(json.dumps({'payload':data,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr})+'\n')
path=pathlib.Path(data['transcript_path'])
if path.is_file():(home/('transcript-'+str(len((home/'events.jsonl').read_text().splitlines()))+'.jsonl')).write_bytes(path.read_bytes())
sys.stdout.write(p.stdout);sys.stderr.write(p.stderr);sys.exit(p.returncode)
