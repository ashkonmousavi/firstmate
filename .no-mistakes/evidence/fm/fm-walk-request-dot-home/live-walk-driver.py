#!/usr/bin/env python3
"""Run from the gate worktree. Oracle: supplied owner intent and R1 decision.
All real CLI calls run against disposable homes; no transport/dispatcher is invoked.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path.cwd()
HELPER = ROOT / 'bin/fm-walk-request-path.py'
CARRIER = ROOT / 'bin/fm-walk-request.sh'
RELEASE = '0123456789abcdef0123456789abcdef01234567'
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
serial = 0

def run(args, expected=0, extra=None):
    proc = subprocess.run([str(a) for a in args], env=env | (extra or {}), text=True, capture_output=True, timeout=15)
    print(json.dumps({'command':[str(a) for a in args], 'exit':proc.returncode, 'stdout':proc.stdout.strip(), 'stderr':proc.stderr.strip()}), flush=True)
    assert proc.returncode == expected, (args, proc.returncode, expected)
    return proc.stdout.strip()

def file(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path

with tempfile.TemporaryDirectory(prefix='.live-walk-', dir=ROOT) as scratch:
    scratch = Path(scratch)
    main = scratch / '.treehouse/config/state/MAIN'
    mate = scratch / '.treehouse/config/state/mate'
    mainbrief = file(main / 'data/from-main/walk-lists/brief.md', b'MAIN public walk: verify checkout.\n')
    matebrief = file(mate / 'data/walk-briefs/brief.md', b'Mate public walk: verify checkout.\n')
    for home in (main, mate):
        (home/'state').mkdir()
    file(mate/'.fm-secondmate-home', b'live-mate\n')
    file(mate/'.fm-secondmate-parent', f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={main}\n'.encode())
    channel = main / 'state/live-mate.status'
    carrier_env = {'FM_HOME': str(mate), 'FM_STATE_OVERRIDE': str(mate/'state')}
    def carrier(brief, accepted):
        before = channel.read_bytes() if channel.exists() else b''
        out = run([CARRIER,'--brief',brief,'--release',RELEASE,'--walks','desktop','--bot','Walker'], 0 if accepted else 2, carrier_env)
        after = channel.read_bytes() if channel.exists() else b''
        if accepted:
            assert out.startswith('corr=') and 'once-key=desktop@'+RELEASE in out
            assert after.startswith(before) and len(after) > len(before)
            assert f'brief={Path(brief).resolve()}'.encode() in after[len(before):]
            print('PERSISTED CHANNEL '+after[len(before):].decode().strip(), flush=True)
        else:
            assert after == before, 'refused brief changed the parent channel'

    print('SCENARIO 1: homes below dot/config/state ancestors publish local requests')
    carrier(matebrief, True)
    carrier(mainbrief, True)
    # Confirm that the reported baseline rejects this same valid brief.
    baseline = subprocess.run(['git','show','2bafe15f26658147adf097c4f0dbef263761c814:bin/fm-walk-request-path.py'], capture_output=True, check=True).stdout
    old = file(scratch/'baseline-path.py', baseline)
    run(['python3',old,'path',matebrief,mate,main], 2)
    print('SCENARIO 1 PASS; baseline reproduces original refusal')

    print('SCENARIO 2: symlinked home roots accept alias and canonical paths')
    matealias = scratch/'mate-alias'
    mainalias = scratch/'main-alias'
    matealias.symlink_to(mate, target_is_directory=True)
    mainalias.symlink_to(main, target_is_directory=True)
    for mhome, phome in ((mate, main), (matealias, mainalias)):
        for brief in (matebrief, matealias/'data/walk-briefs/brief.md', mainbrief, mainalias/'data/from-main/walk-lists/brief.md'):
            # A literal alias is approved only when that alias is the supplied home.
            if mhome == mate and ('-alias/' in str(brief)):
                continue
            assert run(['python3',HELPER,'path',brief,mhome,phome]) == str(brief.resolve())
    print('SCENARIO 2 PASS')

    print('SCENARIO 3: public cross-home links work; private literal paths are refused in either direction')
    for source, alias, target in ((matebrief.parent,matealias/'data/walk-briefs',mainbrief), (mainbrief.parent,mainalias/'data/from-main/walk-lists',matebrief)):
        for part in ('public-link.md','.hidden.md','.private/brief.md','config/brief.md','state/brief.md','Config/brief.md','State/brief.md'):
            link = source/part
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
            for literal in (link,alias/part):
                for action in ('path','encode','stage'):
                    serial += 1
                    args = [action,literal,matealias,mainalias] if action != 'stage' else ['stage',mainalias,f'{serial:016x}','local',literal,matealias]
                    out = run(['python3',HELPER,*args], 0 if part == 'public-link.md' else 2)
                    if part == 'public-link.md':
                        if action == 'path': assert out == str(target)
                        elif action == 'encode': assert base64.b64decode(out) == target.read_bytes()
                        else:
                            assert Path(out).read_bytes() == target.read_bytes()
                            print('STAGED BRIEF '+out+' '+repr(Path(out).read_text()), flush=True)
                if literal == link: carrier(literal, part == 'public-link.md')
    print('SCENARIO 3 PASS')

    print('SCENARIO 4: resolved private targets, escapes, relative and outside literal paths are refused')
    badpaths=[]
    for part in ('.secret.md','config/secret.md','state/secret.md'):
        private = file(matebrief.parent/part,b'private fixture\n')
        public = matebrief.parent/('resolve-'+str(len(badpaths))+'.md')
        public.symlink_to(private)
        badpaths += [private,public]
    outside = file(scratch/'outside.md',b'outside fixture\n')
    escape = matebrief.parent/'escape.md'
    escape.symlink_to(outside)
    outsidealias = scratch/'outside-link.md'
    outsidealias.symlink_to(matebrief)
    badpaths += [escape, outsidealias, matebrief.parent, 'relative.md', str(matebrief.parent)+'/../walk-briefs/brief.md']
    for bad in badpaths: carrier(bad, False)
    print('SCENARIO 4 PASS; all refused calls left channel bytes unchanged')

    print('SCENARIO 5: remote carrier publishes exact inline UTF-8 from a dot-ancestor home')
    file(mate/'.fm-secondmate-parent',b'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=disposable-fixture\n')
    remote = mate/'state/parent-replies.status'
    run([CARRIER,'--brief',matebrief,'--release',RELEASE,'--walks','remote','--bot','Walker'],extra=carrier_env)
    line = remote.read_text()
    payload = next(x.split('=',1)[1] for x in line.split() if x.startswith('brief64='))
    assert base64.b64decode(payload) == matebrief.read_bytes()
    print('PERSISTED REMOTE CHANNEL '+line.strip(),flush=True)
    print('SCENARIO 5 PASS')
print('Disposable homes removed; all live path/carrier scenarios passed.')
