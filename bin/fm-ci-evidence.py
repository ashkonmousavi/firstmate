#!/usr/bin/env python3
"""Preserve CI producer evidence in the ephemeral runner's retained _diag tree.

The existing fm-fork payload trims _work/home but retains _diag. Hosted artifact
copies are optional; this local receipt is required and never changes test status.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile

# Same provisional per-runner evidence budget as the existing EEL retention path.
# No history is deleted to satisfy it; capacity/retention remain operator-owned.
MAX_BYTES = 1024 ** 3


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            h.update(block)
    return h.hexdigest()


def value(env, key, pattern):
    result = env.get(key, '')
    if not isinstance(result, str) or not re.fullmatch(pattern, result):
        raise ValueError('missing/invalid '+key)
    return result


def ordinary(path, directory=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise ValueError('unsafe evidence path: '+str(path))
    return info


def preserve(slot, inputs, required, workspace, env):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}', slot):
        raise ValueError('invalid evidence slot')
    repository = value(env, 'GITHUB_REPOSITORY', r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
    if '..' in repository.split('/'):
        raise ValueError('invalid repository path')
    run = value(env, 'GITHUB_RUN_ID', r'[1-9][0-9]{0,30}')
    attempt = value(env, 'GITHUB_RUN_ATTEMPT', r'[1-9][0-9]{0,10}')
    job = value(env, 'GITHUB_JOB', r'[A-Za-z0-9_-]+')
    runner = value(env, 'RUNNER_NAME', r'fmfork-(?:laptop|server)-[0-9]+-[a-f0-9]{32}')
    status = value(env, 'FM_CI_JOB_STATUS', r'success|failure|cancelled|skipped')
    temp = Path(env.get('RUNNER_TEMP', ''))
    if not temp.is_absolute() or temp.name != '_temp' or temp.parent.name != '_work':
        raise ValueError('RUNNER_TEMP must name the configured runner _work/_temp')
    for part in (temp, temp.parent, temp.parent.parent):
        ordinary(part, directory=True)
    sha = subprocess.check_output(['git', '-C', str(workspace), 'rev-parse', 'HEAD'], text=True).strip()
    if not re.fullmatch(r'[a-f0-9]{40}', sha) or env.get('GITHUB_SHA') != sha:
        raise ValueError('checked Git SHA does not match this workflow execution')
    pr_head = env.get('FM_CI_PR_HEAD_SHA', '')
    if pr_head and not re.fullmatch(r'[a-f0-9]{40}', pr_head):
        raise ValueError('invalid PR head SHA')
    diag = temp.parent.parent/'_diag'
    diag.mkdir(mode=0o700, exist_ok=True)
    ordinary(diag, directory=True)
    root = diag/'fm-ci-evidence'
    root.mkdir(mode=0o700, exist_ok=True)
    info = ordinary(root, directory=True)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('evidence root must be private and owned by this runner')
    files, missing = [], []
    for raw in dict.fromkeys([*inputs, *required]):
        path = Path(raw)
        try:
            relative = path.relative_to(temp)
        except ValueError:
            raise ValueError('input is outside RUNNER_TEMP') from None
        if '..' in relative.parts:
            raise ValueError('input traverses RUNNER_TEMP')
        current = temp
        for component in relative.parts[:-1]:
            current /= component
            if current.exists() or current.is_symlink():
                ordinary(current, directory=True)
        if not path.exists() and not path.is_symlink():
            missing.append(str(path))
            continue
        info = ordinary(path)
        files.append({'source':str(path), 'relative':str(relative), 'bytes':info.st_size,
                      'sha256':digest(path)})
    if status == 'success' and any(path in missing or not any(f['source']==path and f['bytes']>0 for f in files) for path in required):
        raise ValueError('successful producer lacks required evidence')
    metadata = {'schema':'fm-ci-evidence.v1', 'repository':repository, 'run_id':run,
                'run_attempt':attempt, 'job':job, 'slot':slot, 'runner':runner,
                'checked_sha':sha, 'pr_head_sha':pr_head, 'job_status':status,
                'inputs':files, 'required':required, 'missing':missing}
    destination = root/repository/run/attempt/slot/sha
    receipt = destination/'receipt.json'
    archive = destination/'evidence.tar.gz'
    result = {'archive':str(archive), 'receipt':str(receipt)}
    if destination.exists() or destination.is_symlink():
        ordinary(destination, directory=True)
        ordinary(receipt); ordinary(archive)
        prior = json.loads(receipt.read_text())
        if {k:v for k,v in prior.items() if k!='archive_sha256'} != metadata or prior.get('archive_sha256') != digest(archive):
            raise ValueError('evidence identity already exists with different or damaged bytes')
        return result
    used = 0
    for path in root.rglob('*'):
        info = path.lstat()
        if path.is_dir():
            ordinary(path, directory=True)
        else:
            ordinary(path); used += info.st_size
    total = sum(f['bytes'] for f in files)
    allowance = min(MAX_BYTES-used, shutil.disk_usage(root).free)
    if total + 65536 > allowance:
        raise ValueError('evidence budget unavailable; existing history preserved')
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    for parent in destination.parents:
        ordinary(parent, directory=True)
        if parent == root:
            break
    with tempfile.TemporaryDirectory(prefix='.pending-', dir=destination.parent) as staging:
        stage = Path(staging)
        bundle_path = stage/'evidence.tar.gz'
        with tarfile.open(bundle_path, 'w:gz') as bundle:
            for index, entry in enumerate(files):
                path = Path(entry['source'])
                bundle.add(path, arcname='inputs/'+str(index)+'/'+path.name, recursive=False)
                if digest(path) != entry['sha256']:
                    raise ValueError('producer evidence changed during archival')
        if bundle_path.stat().st_size + 65536 > allowance:
            raise ValueError('archive exceeded available evidence budget')
        metadata['archive_sha256'] = digest(bundle_path)
        (stage/'receipt.json').write_text(json.dumps(metadata, indent=2)+'\n')
        # Same filesystem publication; no partial receipt claims a complete archive.
        stage.rename(destination)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--slot', required=True)
    parser.add_argument('--input', action='append', default=[])
    parser.add_argument('--require', action='append', default=[])
    args = parser.parse_args()
    try:
        result = preserve(args.slot, args.input, args.require, Path.cwd(), os.environ)
        print(json.dumps(result, sort_keys=True))
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a') as stream:
                stream.write('Persistent runner evidence: `'+os.environ['RUNNER_NAME']+'` / `'+result['receipt']+'`\n')
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('::error::required local CI evidence unavailable: '+str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
