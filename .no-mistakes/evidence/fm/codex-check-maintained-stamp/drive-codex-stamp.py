#!/usr/bin/env python3
"""Drive real Firstmate and installed Codex against an isolated local model API.
Oracle: author's six-day maintenance policy, success/failure boundary, and byte preservation.
The local HTTP response provider substitutes only the external model service.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import threading
import time

REPO = Path('~/.no-mistakes/worktrees/049a88734b0e/01M6F73V2MFRH20X4XJX9AVPBG')
EVIDENCE = Path('~/.no-mistakes/evidence/01M6F73V2MFRH20X4XJX9AVPBG')
CODEX = shutil.which('codex')
assert CODEX
requests = []
mode = 'ok'

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        body = json.loads(raw)
        requests.append({'path': self.path, 'mode': mode, 'model': body.get('model'),
                         'maintenance_prompt': 'Reply with the single word OK. Do not use tools.' in json.dumps(body)})
        if mode == 'fail':
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': {'type': 'invalid_request_error', 'message': 'Disposable provider intentionally rejects maintenance'}}).encode())
            return
        item = {'id': 'msg_lab', 'type': 'message', 'status': 'completed', 'role': 'assistant',
                'content': [{'type': 'output_text', 'text': 'OK', 'annotations': []}]}
        response = {'id': 'resp_lab', 'object': 'response', 'created_at': int(time.time()),
                    'status': 'completed', 'model': body.get('model'), 'output': [item],
                    'usage': {'input_tokens': 10, 'output_tokens': 1, 'total_tokens': 11}}
        events = [
            {'type': 'response.created', 'response': dict(response, status='in_progress', output=[])},
            {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
            {'type': 'response.completed', 'response': response},
        ]
        payload = ''.join('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n' for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

server = None
for port in range(9660, 9700):
    try:
        server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Provider)
        break
    except OSError:
        continue
assert server is not None, 'No available loopback test port in approved range'
thread = threading.Thread(target=server.serve_forever)
thread.start()
transcript = []
scenarios = []
def note(value):
    print(value, flush=True)
    transcript.append(value)

def facts(path):
    data = path.read_bytes()  # These bytes are synthetic fixture data created by this driver.
    info = path.stat()
    return {'sha256': hashlib.sha256(data).hexdigest(), 'mtime_ns': info.st_mtime_ns,
            'size': info.st_size, 'inode': info.st_ino, 'mode': stat.S_IMODE(info.st_mode)}

def aged(path, days):
    t = time.time() - days * 86400
    os.utime(path, (t, t))

try:
    with tempfile.TemporaryDirectory(prefix='.codex-stamp-lab-', dir=REPO) as temp:
        lab = Path(temp)
        for d in ('user', 'tmp', 'state', 'shared/rules'):
            (lab/d).mkdir(parents=True)
        env = {'PATH': os.environ['PATH'], 'HOME': str(lab/'user'), 'TMPDIR': str(lab/'tmp'),
               'USER': os.environ.get('USER', 'lab'), 'LOGNAME': os.environ.get('LOGNAME', 'lab')}
        shared = lab/'shared'
        (shared/'AGENTS.md').write_text('Respond OK. Do not use tools.\n')
        (shared/'rules/default.rules').write_text('prefix_rule(pattern=["false"], decision="forbidden")\n')
        (shared/'config.toml').write_text(f'''model = "gpt-5.5"
model_provider = "stamp_lab"
cli_auth_credentials_store = "file"
web_search = "disabled"
[features]
enable_request_compression = false
[model_providers.stamp_lab]
name = "Disposable local maintenance test provider"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
''')
        accounts = [lab/'server folder', lab/'laptop-folder']
        for i, account in enumerate(accounts):
            account.mkdir()
            (account/'auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'synthetic-local-only-'+('x'*(i+1))})+'\n')
            (account/'auth.json').chmod(0o600)
            aged(account/'auth.json', 7+i)
            for name in ('config.toml', 'AGENTS.md', 'rules'):
                (account/name).symlink_to(shared/name)
        config = lab/'codex-accounts'
        config.write_text(''.join(str(a)+'\n' for a in accounts))
        originals = {a: facts(a/'auth.json') for a in accounts}
        note('Installed runner: '+subprocess.check_output([CODEX, '--version'], text=True, env=env).strip())
        note('Isolation: synthetic file-backed API-key records, HOME/CODEX_HOME/TMPDIR in worktree, loopback-only model endpoint.')
        note('The model endpoint is deterministic; no production OAuth/token refresh or production credentials are exercised.')
        def run(command, account=None, expected=0, script=None):
            args = ['python3', str(script or REPO/'bin/fm-codex-accounts.py'), command,
                    '--config', str(config), '--codex', CODEX]
            if account:
                args += ['--folder', str(account)]
            if command == 'register':
                args += ['--state', str(lab/'state')]
            result = subprocess.run(args, capture_output=True, text=True, env=env, cwd=REPO, timeout=145)
            display = (' '.join(args)).replace(str(lab), '$LAB').replace(str(REPO), '$REPO')
            note('$ '+display)
            note(f'exit={result.returncode}; stdout={result.stdout.strip()!r}; stderr={result.stderr.strip().replace(str(lab), "$LAB")!r}')
            assert result.returncode == expected, f'{command}: expected {expected}, got {result.returncode}'
            if expected == 0:
                assert result.stdout == '' and result.stderr == '', 'healthy check/maintain must be silent'
            return result
        # Show the exact reported regression on the base code, using the real runner.
        baseline = lab/'base-codex-accounts.py'
        baseline.write_bytes(subprocess.check_output(['git', 'show', '1b243d56ec210817ec716bb40103936480896c7f:bin/fm-codex-accounts.py'], cwd=REPO))
        run('check', accounts[0], expected=1, script=baseline)
        run('maintain', accounts[0], script=baseline)
        run('check', accounts[0], expected=1, script=baseline)
        assert facts(accounts[0]/'auth.json') == originals[accounts[0]]
        note('BASE REPRODUCTION: maintain exits 0, auth file stays unchanged, next check still exits 1.')
        for account in accounts:
            run('check', account, expected=1)
            run('maintain', account)
            stamp = account/'.fm-codex-maintained'
            assert stamp.is_file() and stat.S_IMODE(stamp.stat().st_mode) == 0o600
            time.strptime(stamp.read_text().strip(), '%Y-%m-%dT%H:%M:%SZ')
            assert facts(account/'auth.json') == originals[account]
            note(f'{account.name}: auth bytes, mtime, size, inode and mode unchanged; stamp mode=0600 and UTC timestamp only.')
            run('check', account)
            run('check', account)
        scenarios.append('Successful maintenance clears stale checks for both account folders and remains green on repeated polling.')
        # Failed first maintenance and failed repeated maintenance must not create or renew a stamp.
        account = accounts[0]
        stamp = account/'.fm-codex-maintained'
        stamp.unlink()
        mode = 'fail'
        run('maintain', account, expected=1)
        assert not stamp.exists()
        run('check', account, expected=1)
        mode = 'ok'
        run('maintain', account)
        aged(stamp, 7)
        stale_stamp = facts(stamp)
        mode = 'fail'
        run('maintain', account, expected=1)
        assert facts(stamp) == stale_stamp
        run('check', account, expected=1)
        scenarios.append('Rejected Codex maintenance neither creates nor renews success stamps; stale checks stay red.')
        # Expired markers must alert, recent credential writes still suffice, future markers cannot silence checks.
        mode = 'ok'
        run('maintain', account)
        assert facts(stamp)['mtime_ns'] > stale_stamp['mtime_ns']
        assert facts(account/'auth.json') == originals[account]
        run('check', account)
        note('RECURRING MAINTENANCE: existing expired marker renewed; unchanged credentials now check green.')
        aged(stamp, 6 - 60 / 86400)
        run('check', account)
        aged(stamp, 6)
        run('check', account, expected=1)
        note('SIX-DAY BOUNDARY: 60 seconds before the deadline is green; six days old is red.')
        aged(account/'auth.json', 0)
        run('check', account)
        os.utime(account/'auth.json', ns=(originals[account]['mtime_ns'], originals[account]['mtime_ns']))
        aged(stamp, -1)
        run('check', account, expected=1)
        stamp.unlink()
        stamp.symlink_to(accounts[1]/'.fm-codex-maintained')
        run('check', account, expected=1)
        stamp.unlink()
        stamp.mkdir()
        run('check', account, expected=1)
        stamp.rmdir()
        run('maintain', account)
        scenarios.append('Expired, future-dated, linked and non-file stamps cannot hide stale credentials; a recent credential write still passes.')
        # A marker is no substitute for auth/configuration, and follows moved independent folders.
        saved_auth = (account/'auth.json').read_bytes()
        (account/'auth.json').unlink()
        run('check', account, expected=1)
        (account/'auth.json').write_bytes(saved_auth)
        (account/'auth.json').chmod(0o600)
        os.utime(account/'auth.json', ns=(originals[account]['mtime_ns'], originals[account]['mtime_ns']))
        (account/'config.toml').unlink()
        run('check', account, expected=1)
        (account/'config.toml').symlink_to(shared/'config.toml')
        moved = lab/'moved server folder'
        account.rename(moved)
        accounts[0] = moved
        config.write_text(''.join(str(a)+'\n' for a in accounts))
        run('check', moved)
        scenarios.append('A fresh stamp cannot bypass missing sign-in/configuration and continues to work when its account folder moves.')
        # Execute the real registered watcher command, rather than merely reading it.
        args = ['python3', str(REPO/'bin/fm-codex-accounts.py'), 'register', '--config', str(config),
                '--codex', CODEX, '--state', str(lab/'state')]
        result = subprocess.run(args, capture_output=True, text=True, env=dict(env, FM_HOME=str(lab)), cwd=REPO, timeout=30)
        note('$ python3 $REPO/bin/fm-codex-accounts.py register --config $LAB/codex-accounts --codex '+CODEX+' --state $LAB/state')
        note(f'exit={result.returncode}; stdout={result.stdout.strip().replace(str(lab), "$LAB")!r}; stderr={result.stderr.strip().replace(str(lab), "$LAB")!r}')
        assert result.returncode == 0
        watchers = sorted((lab/'state').glob('*.check.sh'))
        assert len(watchers) == 2
        for watcher in watchers:
            result = subprocess.run(['bash', str(watcher)], capture_output=True, text=True, env=env, cwd=REPO, timeout=30)
            note(f'$ bash $LAB/state/{watcher.name}: exit={result.returncode}; stdout={result.stdout!r}; stderr={result.stderr!r}')
            assert result.returncode == 0 and not result.stdout and not result.stderr
        scenarios.append('Registering both account watchers and executing their generated commands produces silent green checks.')
        for account in accounts:
            expected = originals.get(account, originals[lab/'server folder'])
            # A deliberate delete/recreate boundary probe changes the first inode, not its contents or timestamps.
            actual = facts(account/'auth.json')
            assert all(actual[k] == expected[k] for k in ('sha256', 'mtime_ns', 'size', 'mode'))
        assert len(requests) >= 7 and all(r['maintenance_prompt'] for r in requests)
        note('REAL CODEX MODEL REQUESTS: '+json.dumps(requests))
        note('SCENARIOS: '+json.dumps(scenarios))
        note('PASS: all account-stamp scenarios completed; no source or credential content changes.')
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=10)
    note('CLEANUP: local provider stopped and joined; disposable account/home/temp folders removed.')
    (EVIDENCE/'live-codex-stamp.log').write_text('\n'.join(transcript)+'\n')
