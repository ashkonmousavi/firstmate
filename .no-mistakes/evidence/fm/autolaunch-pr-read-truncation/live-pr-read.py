import base64
import binascii
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
scratch = Path(tempfile.mkdtemp(prefix='live-pr-', dir=ROOT / '.test-scratch'))
requests = []
mode = 'long'

def pr_value(number):
    if number == 1 and mode == 'malformed':
        return 'not JSON'
    checks = [dict(__typename='CheckRun', isRequired=True, status='COMPLETED', conclusion='SUCCESS') for _ in range(34)]
    if mode == 'red':
        checks[-1]['conclusion'] = 'FAILURE'
    return dict(headRefOid='a' * 40, isDraft=False, state='MERGED' if number == 2 else 'OPEN',
                mergeCommit=dict(oid='b' * 40) if number == 2 else None,
                commits=dict(nodes=[dict(commit=dict(statusCheckRollup=dict(contexts=dict(nodes=checks))))]))

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.headers.get('Transfer-Encoding') == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if not size:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                assert self.rfile.read(2) == b'\r\n'
            body = b''.join(chunks)
        else:
            body = self.rfile.read(int(self.headers['Content-Length']))
        payload = json.loads(body)
        number = payload['variables']['number']
        requests.append(dict(path=self.path, number=number, mode=mode))
        body = json.dumps(dict(data=dict(repository=dict(pullRequest=pr_value(number))))).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

server = None
thread = None
transcript = []
def record(message):
    print(message, flush=True)
    transcript.append(message)

def write(home, path, text):
    p = home / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)

def command(args, env, input=None):
    p = subprocess.run(args, env=env, input=input, text=True, capture_output=True, timeout=60)
    return p

def new_home(name):
    home = scratch / name
    subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(home)], check=True, capture_output=True)
    write(home, '.tasks.toml', '[tasks]\nadapter = "markdown"\nfile = "data/backlog.md"\n')
    write(home, 'config/autolaunch-steps', 'act first second\n')
    write(home, 'data/backlog.md', '## In flight\n- [ ] first - PR read (repo: proj) (kind: ship)\n  SLICE: id=first role=owner\n- [ ] second - independent PR (repo: proj) (kind: ship)\n  SLICE: id=second role=owner\n## Queued\n## Done\n')
    for owner, number in [('first', 1), ('second', 2)]:
        write(home, f'state/{owner}.meta', f'kind=ship\nmode=local-only\nproject={home}/projects/proj\npr=https://github.com/lab/proj/pull/{number}\n')
    write(home, 'state/second.pr-poll-merge-notified', 'provider=github\nhost=github.com\npath=lab/proj\nnumber=2\n')
    return home

try:
    cert = scratch / 'cert.pem'
    key = scratch / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], check=True, capture_output=True)
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GH_', 'GITHUB_', 'TASKS_AXI_'))}
    env.update(GH_HOST=f'localhost:{server.server_port}', GH_ENTERPRISE_TOKEN='disposable-local-token', GH_TOKEN='disposable-local-token',
               GH_CONFIG_DIR=str(scratch / 'gh-config'), SSL_CERT_FILE=str(cert), GH_NO_UPDATE_NOTIFIER='1', GH_NO_EXTENSION_UPDATE_NOTIFIER='1', GH_TELEMETRY='false', GH_PROMPT_DISABLED='1', NO_PROXY='localhost,127.0.0.1', XDG_CACHE_HOME=str(scratch / 'cache'))
    query = json.dumps(dict(query='query($number:Int!){repository(owner:"lab",name:"proj"){pullRequest(number:$number){headRefOid}}}', variables=dict(number=1)))
    args = ['gh-axi', 'api', 'POST', '/graphql', '--input', '-', '--jq', '.data.repository.pullRequest | @base64']
    short = command(args, env, query)
    full = command(args + ['--full'], env, query)
    assert short.returncode == full.returncode == 0, (short.stderr, full.stderr)
    truncated = short.stdout.strip().strip('"')
    decoded = json.loads(base64.b64decode(full.stdout.strip().strip('"'), validate=True))
    assert len(decoded['commits']['nodes'][0]['commit']['statusCheckRollup']['contexts']['nodes']) == 34
    assert '(truncated)' in truncated, repr(truncated[-100:])
    record(f'Real gh-axi default output: {len(short.stdout)} bytes; tail={truncated[-40:]!r}')
    record(f'Real gh-axi --full output: {len(full.stdout)} bytes; 34 checks decoded successfully')
    try:
        base64.b64decode(truncated, validate=True)
    except binascii.Error as error:
        record(f'Reproduced original default-output failure: {error}')
    else:
        raise AssertionError('Default output unexpectedly decoded without --full')
    (EVIDENCE / 'forge-default-truncated.txt').write_text(short.stdout)
    (EVIDENCE / 'forge-full-base64.txt').write_text(full.stdout)

    for scenario in ['long', 'red', 'malformed', 'dry']:
        mode = 'long' if scenario == 'dry' else scenario
        home = new_home(scenario)
        runenv = dict(env, FM_HOME=str(home))
        before = {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
        start_requests = len(requests)
        cli = ['bash', 'bin/fm-autolaunch.sh', '--steps-only'] + (['--dry-run'] if scenario == 'dry' else [])
        result = command(cli, runenv)
        record(f'\n{scenario}: {" ".join(cli)} exit={result.returncode}\nstdout={result.stdout!r}\nstderr={result.stderr!r}')
        assert result.returncode == 0, result.stderr
        calls = requests[start_requests:]
        assert [x['number'] for x in calls] == [1, 2], calls
        record('Local GraphQL requests: ' + json.dumps(calls))
        if scenario == 'dry':
            after = {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
            assert before == after, (before.keys(), after.keys())
            record('Dry pass read both PRs and left all lab files unchanged.')
        else:
            stamp = json.loads((home / 'state/autolaunch-steps.pass').read_text())
            assert stamp['owners'] == ['first', 'second']
            cache = home / 'state/first.step-pr'
            if scenario == 'malformed':
                assert not cache.exists()
                record('Undecodable PR JSON skipped; no first.step-pr cache written.')
            else:
                facts = json.loads(cache.read_text())['facts']
                assert facts['head'] == 'a' * 40
                assert facts['checks'] == ('red' if scenario == 'red' else 'started')
                record('Persisted first PR facts: ' + json.dumps(facts, sort_keys=True))
                (EVIDENCE / f'{scenario}-pr-cache.json').write_bytes(cache.read_bytes())
            rows = [json.loads(x) for x in (home / 'data/second/slice-steps.log').read_text().splitlines()]
            assert any(x['step'] == 'merged' and x['merge'] == 'b' * 40 for x in rows)
            record('Independent second PR transition: ' + json.dumps(rows, sort_keys=True))
            record('Published pass completion: ' + json.dumps(stamp, sort_keys=True))
            (EVIDENCE / f'{scenario}-second-steps.jsonl').write_bytes((home / 'data/second/slice-steps.log').read_bytes())
            (EVIDENCE / f'{scenario}-pass.json').write_text(json.dumps(stamp) + '\n')
    record('\nAll production CLI scenarios passed without FM_TEST_SEAM or replacement executables.')
finally:
    if server:
        server.shutdown()
        server.server_close()
    if thread:
        thread.join(timeout=10)
        assert not thread.is_alive()
    shutil.rmtree(scratch)
    record('Local TLS server stopped and all disposable homes removed.')
    (EVIDENCE / 'live-pr-read.log').write_text('\n'.join(transcript) + '\n')
