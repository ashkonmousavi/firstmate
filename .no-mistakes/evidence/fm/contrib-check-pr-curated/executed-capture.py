import json, pathlib, sys, tarfile
root, dest = map(pathlib.Path, sys.argv[1:])
proof = []
for home in sorted(root.iterdir()):
    if not home.is_dir(): continue
    row = {'scenario_home':home.name,'cli':'bin/fm-contributions.sh poll','outputs':{},'records':[]}
    for rel in ('poll.out','poll.err','forge/calls','forge/scan-delay','forge/settling','forge/timeout-tools','state/.wake-queue','state/contributions.check.sh'):
        p=home/rel
        if p.is_file(): row['outputs'][rel]=p.read_text(errors='replace')
    for p in sorted((home/'data').glob('*/contributions.json')):
        try: data=json.loads(p.read_text())
        except (ValueError, OSError) as exc:
            row.setdefault('intentionally_unreadable_records',[]).append(dict(path=str(p.relative_to(home)),error=str(exc)))
            continue
        if not isinstance(data,dict) or not isinstance(data.get('records'),list):
            row.setdefault('intentionally_invalid_records',[]).append(str(p.relative_to(home)))
            continue
        for record in data['records']:
            if not isinstance(record,dict): continue
            obs=record.get('observation') or {}
            if not isinstance(obs,dict): obs={}
            row['records'].append({'task':data['task'], **{k:v for k,v in record.items() if k!='observation'},'observation':{k:v for k,v in obs.items() if k!='events'},'observation_events_count':len(obs.get('events',[]))})
    if row['records'] or row['outputs']: proof.append(row)
(dest/'cli-state-evidence.json').write_text(json.dumps(proof,indent=2)+'\n')
with tarfile.open(dest/'disposable-cli-records.tar.gz','w:gz') as archive:
    for home in sorted(root.iterdir()):
        if not home.is_dir(): continue
        for rel in ('poll.out','poll.err','forge/calls','forge/scan-delay','forge/settling','forge/timeout-tools','state/.wake-queue','state/contributions.check.sh'):
            p=home/rel
            if p.is_file(): archive.add(p,arcname=str(p.relative_to(root)))
        for p in sorted((home/'data').glob('*/contributions.json')):
            archive.add(p,arcname=str(p.relative_to(root)))
print('Retained product output and persisted records for',len(proof),'isolated homes')
