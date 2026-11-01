"""Disposable real-Claude Stop verification; invoke with WORKTREE EVIDENCE_DIR."""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, evidence = map(Path, sys.argv[1:3])
lab = root / '.test-state-claim-tmp' / 'live-cases'
lab.mkdir()
version = subprocess.check_output(['claude', '--version'], text=True).strip()
settings = json.loads((root / '.claude/settings.json').read_text())
tracked = next(h for group in settings['hooks']['Stop'] for h in group['hooks']
               if 'fm-turnend-guard.sh' in h.get('command', ''))
recorder = lab / 'record.py'
recorder.write_text('''import json, os, pathlib, subprocess, sys
payload = sys.stdin.read()
p = subprocess.run(['sh', '-c', os.environ['CLAIM_TRACKED_COMMAND']], input=payload, text=True, capture_output=True)
with (pathlib.Path(os.environ['FM_HOME']) / 'stop-events.jsonl').open('a') as f:
    f.write(json.dumps({'payload': json.loads(payload), 'rc': p.returncode, 'stderr': p.stderr}) + '\\n')
sys.stdout.write(p.stdout)
sys.stderr.write(p.stderr)
sys.exit(p.returncode)
''')
for reader in ('gh', 'gh-axi'):
    fixture = lab / reader
    fixture.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FM_HOME/read-events"
if [ "$2" = list ]; then printf '12\\n'; else printf 'state: MERGED\\n'; fi
''')
    fixture.chmod(0o755)
curl_fixture = lab / 'curl'
curl_fixture.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FM_HOME/read-events"\nprintf "HTTP/1.1 200 OK\\n"\n')
curl_fixture.chmod(0o755)

cases = []
def add(name, message, command=None, blocked=False):
    cases.append((name, message, command, blocked))

for reader in ('gh', 'gh-axi'):
    add('aggregate-' + reader, '12 PRs merged in the last hour.',
        f'{lab / reader} pr list --state merged --json number --jq length')
    for option in ('--limit 9', '-L 9'):
        add('named-' + reader + '-' + option.replace(' ', ''), 'PR 9 is merged.',
            f'{lab / reader} pr list --state merged {option} --json number --jq length', True)
add('aggregate-no-read', '12 PRs merged in the last hour.', blocked=True)
for wording in ('read it live', 'read live'):
    add(wording.replace(' ', '-'), f'I just {wording}: https://github.com/example/repo/pull/9 merged.',
        f'{lab / "gh"} pr view 9')
add('read-live-unsupported-pr', 'I just read it live: https://github.com/example/repo/pull/9 merged.', blocked=True)
add('read-live-unsupported-deploy', 'I read it live: the site is live.', f'{lab / "gh"} pr view 9', True)
for style, opening, closing in (('single', "'", "'"), ('double', '"', '"'),
                                ('curly-single', '‘', '’'), ('curly-double', '“', '”')):
    contraction = 'I’ve' if style.startswith('curly') else "I've"
    history = f'The guard blocked {opening}{contraction} checked: PR 9 is merged.{closing} earlier.'
    add('history-' + style, history)
    add('history-then-claim-' + style, history + ' PR 10 is merged.', f'{lab / "gh"} pr view 9', True)
    for field, message in (
        ('id', f'PR {opening}#9{closing} is merged.'),
        ('host', f'The site {opening}https://one.example{closing} is live.'),
        ('lane', f'{opening}Lane alpha{closing} is running.'),
        ('status', f'PR 9 is {opening}merged{closing}.'),
    ):
        command = (f'{lab / "curl"} https://other.example/health' if field == 'host' else
                   f'bash {root / "bin/fm-crew-state.sh"} beta' if field == 'lane' else
                   f'{lab / "gh"} pr view 10')
        add('short-' + style + '-' + field, message, command, True)
add('three-word-quote', 'Earlier I said "PR 9 merged".', blocked=True)
add('four-word-quote', 'Earlier I said "PR 9 is merged".')
add('multiline-history', 'The guard blocked ‘I’ve checked: PR 9 is merged.\nThe site is live.’ earlier.')
add('quoted-id-matching-read', 'PR "#9" is merged.', f'{lab / "gh"} pr view 9')
add('quoted-host-matching-read', 'The site "https://one.example" is live.', f'{lab / "curl"} https://one.example/health')
add('quoted-lane-matching-read', '"Lane alpha" is running.', f'bash {root / "bin/fm-crew-state.sh"} alpha')
summary = []
retry_names = set(sys.argv[3:])
if retry_names:
    prior_summary = json.loads((evidence / 'live-scenarios.json').read_text())['cases']
try:
    for index, (name, message, command, blocked) in enumerate(cases):
        if retry_names and name not in retry_names:
            summary.append(prior_summary[index])
            continue
        home = lab / f'{index:02}-{name}'
        subprocess.run(['bash', str(root / 'bin/fm-lab-home.sh'), 'create', str(home)], check=True, capture_output=True)
        (home / '.claude').mkdir()
        (home / 'bin').symlink_to(root / 'bin', target_is_directory=True)
        (home / 'AGENTS.md').touch()
        subprocess.run(['git', 'init', '-q', str(home)], check=True)
        hook = dict(tracked, command=f'python3 "{recorder}"')
        (home / '.claude/settings.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [hook]}]}}))
        prompt = ('This is an isolated Stop-hook regression with disposable forge data. '
                  + (f'First use Bash to run exactly this command: {command}\n' if command else 'Do not call any tools. ')
                  + 'Reply with exactly the following text, preserving punctuation and quotation marks, with no code fence:\n'
                  + message + '\nIf a Stop hook blocks this reply, repeat that exact same reply without calling tools. '
                  'Do not correct or qualify it: this test also checks the one-block loop exemption.')
        env = {k: v for k, v in os.environ.items() if k not in (
            'CLAUDECODE', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
            'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'GROK_AGENT', 'GROK_HOOK_EVENT',
            'CLAUDE_CONFIG_DIR', 'CLAUDE_PROJECT_DIR')}
        env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), FM_STATE_OVERRIDE=str(home / 'state'),
                   FM_CONFIG_OVERRIDE=str(home / 'config'), FM_DATA_OVERRIDE=str(home / 'data'),
                   FM_PROJECTS_OVERRIDE=str(home / 'projects'), CLAIM_TRACKED_COMMAND=tracked['command'],
                   CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false', CLAUDE_CODE_SEND_FEEDBACK='0', GH_HOST='github.com')
        args = ['claude', '-p', prompt, '--dangerously-skip-permissions', '--model', 'haiku', '--effort', 'low',
                '--setting-sources', 'project,local', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                '--settings', '{"feedbackDrafts":"off"}', '--system-prompt', 'Follow the regression prompt exactly.',
                '--tools', 'Bash', '--output-format', 'stream-json', '--verbose']
        record = {'name': name, 'date': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'version': version, 'message': message, 'command': command, 'expected_stop_exits': [2, 0] if blocked else [0]}
        try:
            p = subprocess.run(args, cwd=home, env=env, capture_output=True, text=True, timeout=180)
            (evidence / f'{index:02}-{name}-stream.jsonl').write_text(p.stdout)
            (evidence / f'{index:02}-{name}-stderr.log').write_text(p.stderr)
            record['cli_exit'] = p.returncode
            events = [json.loads(row) for row in (home / 'stop-events.jsonl').read_text().splitlines()]
            record['stop_events'] = events
            reads = (home / 'read-events').read_text().splitlines() if (home / 'read-events').exists() else []
            record['executed_fixture_reads'] = reads
            stream = [json.loads(line) for line in p.stdout.splitlines() if line.startswith('{')]
            assert p.returncode == 0, p.stderr[-1500:]
            assert any(row.get('type') == 'result' and not row.get('is_error') for row in stream), 'no successful Claude result'
            assert events and events[0]['rc'] == record['expected_stop_exits'][0], 'unexpected initial Stop exit'
            assert events[0]['payload']['stop_hook_active'] is False, 'initial Stop must be inactive'
            assert events[0]['payload']['last_assistant_message'].strip() == message, 'model did not preserve initial test text'
            if blocked:
                assert 'State claim needs a same-turn read' in events[0]['stderr'], 'wrong blocker'
            if command:
                transcript = Path(events[0]['payload']['transcript_path']).read_text()
                (evidence / f'{index:02}-{name}-transcript.jsonl').write_text(transcript)
                rows = [json.loads(row) for row in transcript.splitlines()]
                calls, completed = set(), set()
                for row in rows:
                    content = row.get('message', {}).get('content', [])
                    if not isinstance(content, list): continue
                    for block in content:
                        if row.get('type') == 'assistant' and block.get('type') == 'tool_use' and block.get('name') == 'Bash' and block.get('input', {}).get('command') == command:
                            calls.add(block['id'])
                        if row.get('type') == 'user' and block.get('type') == 'tool_result' and not block.get('is_error'):
                            completed.add(block['tool_use_id'])
                assert calls & completed, 'fixture read not completed through real Claude Bash'
                if str(lab / 'gh') in command or str(lab / 'curl') in command:
                    assert reads, 'missing fixture invocation'
            else:
                pass  # evaluate_live.py checks the exact reads BEFORE the first reply.
            record['result'] = 'pass'
        except Exception as error:
            record['result'] = 'fail'
            record['error'] = repr(error)
        (evidence / f'{index:02}-{name}-stop.json').write_text(json.dumps(record, indent=2))
        summary.append({k: record[k] for k in ('name', 'message', 'command', 'expected_stop_exits', 'result')})
        print(json.dumps({'case': name, 'result': record['result'], 'exits': [e['rc'] for e in record.get('stop_events', [])], 'error': record.get('error')}), flush=True)
finally:
    (evidence / 'live-scenarios.json').write_text(json.dumps({'version': version, 'cases': summary}, indent=2))
    shutil.rmtree(lab)
sys.exit(0 if len(summary) == len(cases) and all(c['result'] == 'pass' for c in summary) else 1)
