#!/usr/bin/env python3
"""Read one home's numeric hard-floor/PSI/disk policy; never launch or write state.

Ceilings, slot estimates and the separate high-(anon+shmem) reserve remain with
their existing consumers. This reader's headroom is host MemAvailable bounded
by every finite cgroup high/max minus max(current-inactive_file, 0).
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil

GIB = 1024**3


def policy(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('numeric policy must not be a symlink')
    source = path.read_text().rstrip('\n')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate policy field: '+key)
            result[key] = value
        return result
    data = json.loads(source, object_pairs_hook=unique)
    if not isinstance(data, dict) or data.get('schema') != 'fm-machine-admission.v1':
        raise ValueError('missing/invalid machine admission schema')
    for key, low, high in [('memory_floor_gib',0,999999), ('disk_floor_gib',0,999999),
                           ('memory_full_avg60_max',0.000001,100)]:
        value = data.get(key)
        if type(value) not in (int,float) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError('missing/invalid '+key)
    paths = data.get('disk_paths')
    if not isinstance(paths,list) or not paths or any(not isinstance(p,str) or not p.startswith('/') or '\n' in p or '\r' in p for p in paths):
        raise ValueError('missing/invalid disk_paths')
    for key in ('runner_memory_floor_gib','runner_disk_floor_gib'):
        if key in data and (type(data[key]) not in (int,float) or not math.isfinite(data[key]) or not 0 <= data[key] <= 999999):
            raise ValueError('invalid '+key)
    return {**data, 'path':str(path), 'sha256':hashlib.sha256(source.encode()).hexdigest(),
            'memory':{'operator':'<','limit':data['memory_full_avg60_max']}}


def integer(text, name):
    if not re.fullmatch(r'[0-9]+', text):
        raise ValueError('missing/invalid '+name)
    return int(text)


def pressure(path):
    rows = [line.split() for line in Path(path).read_text().splitlines() if line.startswith('full ')]
    fields = [field[6:] for row in rows for field in row[1:] if field.startswith('avg60=')]
    if len(rows) != 1 or len(fields) != 1 or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', fields[0]):
        raise ValueError('missing/invalid memory full avg60: '+str(path))
    value = float(fields[0])
    if not math.isfinite(value) or not 0 <= value <= 100:
        raise ValueError('invalid PSI percentage: '+str(path))
    return value


def refusal_reasons(facts, rules, memory_floor=None, disk_floor=None):
    memory_floor = rules['memory_floor_gib'] if memory_floor is None else max(memory_floor, rules['memory_floor_gib'])
    disk_floor = rules['disk_floor_gib'] if disk_floor is None else disk_floor
    reasons = []
    if facts['effective_available_bytes'] <= memory_floor*GIB:
        reasons.append('Required cache-aware effective memory floor not met')
    if facts['memory_full_avg60'] >= rules['memory_full_avg60_max']:
        reasons.append('memory PSI full avg60 refuses')
    if not facts['disk_available_bytes'] or any(value <= disk_floor*GIB for value in facts['disk_available_bytes'].values()):
        reasons.append('Required free disk floor not met')
    return reasons


def measure(rules, meminfo='/proc/meminfo', pressure_file='/proc/pressure/memory',
            cgroup_file='/proc/self/cgroup', cgroup_root='/sys/fs/cgroup', disk_usage=shutil.disk_usage):
    rows = re.findall(r'^MemAvailable:\s+([0-9]+)\s+kB$', Path(meminfo).read_text(), re.M)
    if len(rows) != 1:
        raise ValueError(str(meminfo)+': missing/invalid MemAvailable')
    available = int(rows[0])*1024
    psi = pressure(pressure_file)
    ancestors = []
    if cgroup_file is not None:
        original = Path(cgroup_file).read_text()
        memberships = [line[3:] for line in original.splitlines() if line.startswith('0::')]
        if len(memberships) != 1 or not memberships[0].startswith('/') or '..' in Path(memberships[0]).parts:
            raise ValueError('missing/invalid unified cgroup membership')
        root = Path(cgroup_root)
        group = root/memberships[0].lstrip('/')
        while True:
            if not group.is_dir() or group.is_symlink():
                raise ValueError('missing/unsafe cgroup: '+str(group))
            current_file = group/'memory.current'
            if current_file.exists():
                current = integer(current_file.read_text().strip(), 'memory.current')
                values = [line.split()[1:] for line in (group/'memory.stat').read_text().splitlines() if line.startswith('inactive_file ')]
                if len(values) != 1 or len(values[0]) != 1:
                    raise ValueError('missing/invalid inactive_file')
                inactive = integer(values[0][0], 'inactive_file')
                working = max(current-inactive, 0)
                limits = []
                for name in ('memory.high','memory.max'):
                    text = (group/name).read_text().strip()
                    if text != 'max':
                        limits.append(integer(text, name))
                if limits:
                    available = min(available, min(limits)-working)
                ancestors.append({'path':str(group), 'working_set_bytes':working, 'finite_limits_bytes':limits})
                psi = max(psi, pressure(group/'memory.pressure'))
            elif any((group/name).exists() for name in ('memory.high','memory.max')):
                raise ValueError('memory controller is missing current/stat: '+str(group))
            elif (group/'memory.pressure').exists():
                psi = max(psi, pressure(group/'memory.pressure'))
            if group == root:
                break
            group = group.parent
        if Path(cgroup_file).read_text() != original:
            raise ValueError('cgroup membership changed during reading')
    facts = {'effective_available_bytes':available, 'memory_full_avg60':psi,
             'disk_available_bytes':{path:disk_usage(path).free for path in rules['disk_paths']},
             'cgroup_ancestors':ancestors, 'resource_policy_sha256':rules['sha256'],
             'memory_floor_gib':rules['memory_floor_gib'], 'policy':rules, 'readable':True}
    facts['refusal_reasons'] = refusal_reasons(facts,rules)
    facts['admitted'] = not facts['refusal_reasons']
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy', required=True)
    args = parser.parse_args()
    try:
        options = {}
        if os.environ.get('FM_TEST_SEAM') == '1':
            for env,key in [('FM_CAPACITY_MEMINFO','meminfo'),('FM_CAPACITY_PRESSURE_FILE','pressure_file'),
                            ('FM_RESOURCE_CGROUP_FILE','cgroup_file'),('FM_RESOURCE_CGROUP_ROOT','cgroup_root')]:
                if env in os.environ:
                    options[key] = os.environ[env]
            if options.get('cgroup_file') == '/dev/null':
                options['cgroup_file'] = None
        facts = measure(policy(args.policy), **options)
    except (OSError,ValueError,KeyError,TypeError) as error:
        facts = {'admitted':False,'readable':False,'refusal_reasons':[str(error)]}
    print(json.dumps(facts,sort_keys=True))
    return 0 if facts['admitted'] else 75


if __name__ == '__main__':
    raise SystemExit(main())
