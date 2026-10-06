import json
import os
import pathlib
import shlex
import shutil
import subprocess

root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/tegris/.no-mistakes/evidence/01M49D1DVEJXN3RZT15AD8YR2G')
lab = root / '.gate-cd-validation/native'
if lab.exists(): shutil.rmtree(lab)
lab.mkdir()
(lab / 'AGENTS.md').touch()
(lab / 'bin').mkdir(exist_ok=True)
for directory in ['projects/foo', 'projects/my clone', 'outside/projects/foo', '.codex', 'logs', 'sqlite']:
    (lab / directory).mkdir(parents=True, exist_ok=True)
subprocess.run(['git', 'init', '-q', str(lab)], check=True)
for name in ['fm-cd-pretool-check.sh', 'fm-hook-host-lib.sh', 'fm-cd-command-policy.mjs', 'fm-arm-command-policy.mjs']:
    shutil.copy2(root / 'bin' / name, lab / 'bin' / name)
config = json.loads((root / '.codex/hooks.json').read_text())
hook = next(hook for entry in config['hooks']['PreToolUse'] for hook in entry['hooks'] if 'fm-cd-pretool-check.sh' in hook['command'])
payload_log = evidence / 'r4-codex-supported-payloads.jsonl'
shim = lab / 'bin/record-fm-cd-pretool-check.sh'
shim.write_text('#!/usr/bin/env bash\npayload=$(cat)\nprintf "%s\\n" "$payload" >> ' + shlex.quote(str(payload_log)) + '\nprintf "%s" "$payload" | ' + hook['command'] + '\n')
shim.chmod(0o700)
(lab / '.codex/hooks.json').write_text(json.dumps({'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': str(shim), 'timeout': 10}]}]}}))
cases = [
    ('relative-protected-unchecked', lab / 'bin', 'cd ../projects/foo', True),
    ('relative-unrelated', lab / 'outside', 'cd projects/foo', True),
    ('absolute-protected', lab / 'outside', 'cd ' + shlex.quote(str(lab / 'projects/foo')), False),
    ('absolute-unrelated', lab / 'bin', 'cd ' + shlex.quote(str(lab / 'outside/projects/foo')), True),
    ('home-protected', lab / 'outside', 'cd ~/' + str(lab.relative_to(pathlib.Path('/home/tegris'))) + '/projects/"my clone"', False),
    ('home-unrelated', lab / 'bin', 'cd ~/' + str(lab.relative_to(pathlib.Path('/home/tegris'))) + '/outside/projects/foo', True),
    ('control', lab, 'printf "native-control\\n"', True),
]
instructions = []
for number, (name, cwd, command, _) in enumerate(cases, 1):
    sentinel = shlex.quote(str(lab / (name + '.sentinel')))
    command += ' > ' + sentinel if name == 'control' else ' && touch ' + sentinel
    instructions.append(str(number) + '. workdir ' + json.dumps(str(cwd)) + ', command ' + command)
prompt = 'Isolated hook test. Perform exactly seven separate exec_command calls in this order, using each specified workdir parameter. Do not retry or bypass any denied command and run no other commands. ' + '\n'.join(instructions) + '\nThen report the outcomes.'
args = ['codex', 'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--enable', 'hooks', '--dangerously-bypass-hook-trust', '-s', 'workspace-write', '-c', 'approval_policy="never"', '-c', 'projects={' + json.dumps(str(lab)) + '={trust_level="trusted"}}', '-c', 'log_dir=' + json.dumps(str(lab / 'logs')), '--cd', str(lab), prompt]
env = os.environ.copy()
env.update(FM_HOME=str(lab), CODEX_HOME=os.environ.get('CODEX_HOME', '/home/tegris/.codex'), TMPDIR=str(root / '.gate-cd-validation/tmp'))
for name in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE']:
    env.pop(name, None)
with (evidence / 'r4-codex-supported-result.log').open('w') as log:
    result = subprocess.run(args, cwd=lab, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=180)
observed = {name: (lab / (name + '.sentinel')).exists() for name, _, _, _ in cases}
expected = {name: allowed for name, _, _, allowed in cases}
state = {'version': subprocess.check_output(['codex', '--version'], text=True).strip(), 'exit': result.returncode, 'observed': observed, 'expected': expected, 'invocation': args[:-1], 'lab': str(lab)}
(evidence / 'r4-codex-supported-state.json').write_text(json.dumps(state, indent=2) + '\n')
print(json.dumps(state, indent=2), flush=True)
assert result.returncode == 0
assert observed == expected
payloads = [json.loads(line) for line in payload_log.read_text().splitlines()]
assert len(payloads) == len(cases), len(payloads)
assert all(p['cwd'] == str(lab) and 'workdir' not in p['tool_input'] for p in payloads)
print('Native Codex supported coverage passed: seven real tool calls, anchored denials and relative/control allows.', flush=True)
