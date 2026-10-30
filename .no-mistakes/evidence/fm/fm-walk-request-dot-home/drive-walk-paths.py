#!/usr/bin/env python3
"""Drive real walk request CLIs; expected behavior comes from the supplied owner intent.
Rejects the former whole-path private-part check and cross-home literal bypass.
All fixture homes are disposable and beneath the gate worktree.
"""
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
LOG = (EVIDENCE / 'live-walk-paths.log').open('w')
ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
ENV['PYTHONDONTWRITEBYTECODE'] = '1'
HELPER = ROOT / 'bin/fm-walk-request-path.py'
CARRIER = ROOT / 'bin/fm-walk-request.sh'
RELEASE = '0123456789abcdef0123456789abcdef01234567'
scenarios = []
seq = 0

def emit(s):
    print(s, file=LOG, flush=True)

def run(args, expected=0, env=None):
    p = subprocess.run([str(a) for a in args], env=env or ENV, text=True, capture_output=True, timeout=15)
    emit('$ ' + shlex.join(str(a) for a in args))
    emit(f'exit={p.returncode}\nstdout={p.stdout.rstrip()}\nstderr={p.stderr.rstrip()}')
    assert p.returncode == expected, f'expected exit {expected}, got {p.returncode}: {p.stderr}'
    return p.stdout.strip()

def write(path, data='Walk this checkpoint.\nExpected: the saved item appears.\n'):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    return path

def home(path, id=None, parent=None, remote=False):
    (path/'state').mkdir(parents=True)
    if id:
        write(path/'.fm-secondmate-home', id+'\n')
        binding = 'schema=fm-secondmate-parent.v1\n'
        binding += 'route=remote\nparent_host=disposable-main\n' if remote else f'route=local\nparent_home={parent}\n'
        write(path/'.fm-secondmate-parent', binding)
    return path

def carrier(mate, brief, expected=0):
    env = dict(ENV, FM_HOME=str(mate))
    emit(f'FM_HOME={mate}')
    return run([CARRIER, '--brief', brief, '--release', RELEASE, '--walks', 'checkpoint', '--bot', 'Walker'], expected, env)

def channel(path):
    return path.read_bytes() if path.exists() else b''

def actions(raw, mate, main, target=None):
    global seq
    for action in ['path','encode','stage']:
        seq += 1
        if action == 'stage':
            args = [sys.executable, HELPER, action, main, f'{seq:016x}', 'local', raw, mate]
        else:
            args = [sys.executable, HELPER, action, raw, mate, main]
        out = run(args, 0 if target else 2)
        if target:
            if action == 'path':
                assert out == str(target.resolve())
            elif action == 'encode':
                assert base64.b64decode(out) == target.read_bytes()
            else:
                assert Path(out).read_bytes() == target.read_bytes()
                emit('persisted snapshot bytes=' + repr(Path(out).read_bytes()))
        elif action == 'stage':
            assert not (main/'data/walk-requests'/f'{seq:016x}'/'brief.md').exists()

def scenario(name, work):
    emit('\nSCENARIO: '+name)
    work()
    emit('PASS: '+name)
    scenarios.append({'name':name, 'result':'pass', 'live':True})

try:
  with tempfile.TemporaryDirectory(prefix='fm-walk-live-', dir=ROOT/'.walk-validation-tmp') as tmp:
    tmp = Path(tmp)
    main = home(tmp/'.main/config/state/firstmate')
    mate = home(tmp/'.treehouse/config/state/firstmate-80f9ac/9/firstmate', 'mate', main)
    brief = write(mate/'data/walk-briefs/brief.md')
    shared = write(main/'data/from-main/walk-lists/brief.md', 'Shared checkpoint brief.\n')
    ma = tmp/'mate-alias'; ma.symlink_to(mate, target_is_directory=True)
    pa = tmp/'main-alias'; pa.symlink_to(main, target_is_directory=True)
    write(mate/'.fm-secondmate-parent', f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={pa}\n')
    status = main/'state/mate.status'

    def hidden_local():
        for configured in [mate, ma]:
            for raw in [brief, shared, pa/'data/from-main/walk-lists/brief.md'] + ([ma/'data/walk-briefs/brief.md'] if configured == ma else []):
                out = carrier(configured, raw)
                corr = out.splitlines()[0]
                assert corr.startswith('corr=')
                line = status.read_text().splitlines()[-1]
                assert corr in line
                assert f'brief={raw.resolve()} release={RELEASE}' in line
                emit('persisted parent channel: '+line)
        actions(brief, ma, pa, brief)
        actions(shared, ma, pa, shared)
    scenario('Homes below dot, config and state ancestors publish local mate and MAIN briefs through real or aliased home paths', hidden_local)

    def hidden_remote():
        remote = home(tmp/'.treehouse/remote/firstmate', 'remote', remote=True)
        rb = write(remote/'data/walk-briefs/brief.md', 'Remote brief: café ✓\n')
        out = carrier(remote, rb)
        line = (remote/'state/parent-replies.status').read_text().splitlines()[-1]
        fields = line.split()
        payload = next(f[len('brief64='):] for f in fields if f.startswith('brief64='))
        assert base64.b64decode(payload) == rb.read_bytes()
        assert out.splitlines()[0] in line
        emit('persisted remote channel: '+line)
        bad = write(remote/'data/walk-briefs/.hidden.md')
        before = channel(remote/'state/parent-replies.status')
        carrier(remote, bad, 2)
        assert channel(remote/'state/parent-replies.status') == before
    scenario('A remote mate in a hidden home publishes exact UTF-8 brief bytes inline and refuses a hidden brief without appending', hidden_remote)

    def public_cross():
        for source, target in [(mate/'data/walk-briefs', shared), (main/'data/from-main/walk-lists', brief)]:
            link = source/'approved.md'; link.symlink_to(target)
            for raw in [link, (ma if source.is_relative_to(mate) else pa)/link.relative_to(mate if source.is_relative_to(mate) else main)]:
                actions(raw, ma, pa, target)
                carrier(ma, raw)
                assert f'brief={target}' in status.read_text().splitlines()[-1]
    scenario('Public cross-home symlinks work in both directions for publication, path resolution, encoding and snapshot staging', public_cross)

    def cross_private():
        before = channel(status)
        for src, src_alias, target in [(mate/'data/walk-briefs', ma/'data/walk-briefs', shared), (main/'data/from-main/walk-lists', pa/'data/from-main/walk-lists', brief)]:
            for suffix in ['.hidden.md', '.private/brief.md', 'config/brief.md', 'state/brief.md', 'Config/brief.md', 'State/brief.md']:
                raw = src/suffix; raw.parent.mkdir(parents=True, exist_ok=True); raw.symlink_to(target)
                for literal in [raw, src_alias/suffix]:
                    actions(literal, ma, pa)
                    carrier(ma, literal, 2)
        assert channel(status) == before
        emit('parent channel unchanged after every cross-home private literal refusal')
    scenario('Private literal symlinks into the other approved home are refused in both directions through configured aliases and resolved roots', cross_private)

    def below_private():
        before = channel(status)
        for suffix in ['.secret.md', '.inner/item.md', 'config/item.md', 'state/item.md', 'CONFIG/item.md', 'STATE/item.md']:
            target = write(mate/'data/walk-briefs'/suffix)
            link = mate/'data/walk-briefs'/('link-'+str(len(list((mate/'data/walk-briefs').iterdir())))+'.md')
            link.symlink_to(target)
            for raw in [target, link]:
                actions(raw, mate, main)
                carrier(mate, raw, 2)
        assert channel(status) == before
    scenario('Dotfiles, hidden directories, config and state below the home are refused directly and via public symlinks', below_private)

    def escape():
        before = channel(status)
        other = write(tmp/'other/data/walk-briefs/brief.md')
        outside_link = tmp/'outside-link.md'; outside_link.symlink_to(brief)
        escaped = mate/'data/walk-briefs/escape.md'; escaped.symlink_to(other)
        outside_in_home = write(mate/'data/unapproved.md')
        traversal = str(mate/'data/walk-briefs')+'/../walk-briefs/brief.md'
        directory = mate/'data/walk-briefs'
        for raw in [outside_link, escaped, other, outside_in_home, traversal, directory, 'relative.md']:
            actions(raw, ma, pa)
            carrier(ma, raw, 2)
        assert channel(status) == before
    scenario('Outside literal aliases, escapes to another mate, unapproved directories, traversal and relative paths cannot publish or stage a brief', escape)

    # Execute the previous implementation to reproduce the owner-reported regression.
    base = tmp/'baseline-validator.py'
    p = subprocess.run(['git','show','2bafe15f26658147adf097c4f0dbef263761c814:bin/fm-walk-request-path.py'], capture_output=True, check=True)
    base.write_bytes(p.stdout)
    emit('\nBASELINE REGRESSION REPRODUCTION')
    run([sys.executable, base, 'path', brief, mate, main], 2)
    emit('The identical approved hidden-home brief was refused before the fix and accepted above by the target product.')
  emit('\nAll disposable fixture homes removed.')
  (EVIDENCE/'live-walk-scenarios.json').write_text(json.dumps(scenarios, indent=2)+'\n')
  print(json.dumps({'result':'pass','scenarios':len(scenarios),'commands':seq, 'evidence':str(EVIDENCE/'live-walk-paths.log')}))
except Exception as exc:
  emit('FAIL: '+repr(exc))
  raise
finally:
  LOG.close()
