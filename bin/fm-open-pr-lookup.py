#!/usr/bin/env python3
"""List the open pull requests that already carry a ship task, for bin/fm-spawn.sh.

usage: fm-open-pr-lookup.py --forge <none|forgejo|gerrit|external> --origin <url>
                            --branch <branch> --task-id <id>
                            [--timeout <seconds>] [--github-hosts <file>]

Prints one JSON object on stdout and exits 0 when the answer is known, 3 when
it is not, and 2 on a usage error:
  {"state": "ok", "provider": P, "prs": [{"number", "url", "branch", "head", "why"}]}
  {"state": "skip", "reason": R, "notice": N}      no forge can hold a pull request here
  {"state": "unknown", "provider": P, "error": E}  the forge could not be read

A pull request carries the task when it is open and either its head branch is
<branch> ("why" holds "branch") or its body names <id> on a SLICE line
(SLICE: <home>/<id> | ...) or a Task line (Task:, Task-ID:, Task id:), outside
fenced code blocks ("why" holds "body"). Any other mention of the id, such as
"blocked by <id>" in prose, does not count. Closed and merged pull requests
never count.

Which forge is read comes from the project's registered binding
(bin/fm-project-mode.sh --forge) and its origin URL:
  forge=none     origin host github.com or a host listed in config/github-hosts
                 reads GitHub through gh; host gitlab.com or a host with a
                 "gitlab" label reads GitLab through glab; any other host is
                 unknown, because nothing says which forge serves it.
  forge=forgejo  reads Forgejo through "tea api" with the one tea login
                 registered for the origin host (bin/fm-pr-lib.sh fm_pr_forgejo_login).
  forge=gerrit, forge=external
                 skip with a notice: neither publishes a pull request a second
                 builder would push to.
  no origin, or a local-path or file: origin
                 skip with no notice: there is no forge to hold a pull request.
Every forge call runs under --timeout (default 30 s). A missing tool, a
timeout, a nonzero exit, output that is not the expected JSON, and a list that
reaches its page limit are all unknown, never an empty list.
"""
import argparse
import json
import os
import re
import subprocess
import sys

UNKNOWN_EXIT = 3
LIST_LIMIT = 100
FORGEJO_PAGE = 50
FORGEJO_PAGES = 20
SCP_ORIGIN = re.compile(r'^(?:[^@/\s]+@)?(\[[^\]]+\]|[^:/\s]+):(?!//)(.+)$')
URL_ORIGIN = re.compile(r'^(https?|ssh|git|git\+ssh|ssh\+git)://(?:[^@/\s]+@)?(\[[^\]]+\]|[^:/\s]+)(?::\d+)?/(.+)$')
FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})(.*)$')
DECOR = re.compile(r'^\s*(?:#{1,6}\s+)?(?:[-*+]\s+)?')
STRONG = re.compile(r'^(\*\*|__)(.*?)\1')
SLICE_LINE = re.compile(r'SLICE:\s*(.*)')
TASK_LINE = re.compile(r'(?i)task(?:[- ]id)?:\s*(.*)')


class Unknown(Exception):
    pass


def emit(obj, code=0):
    print(json.dumps(obj, sort_keys=True))
    sys.exit(code)


def parse_origin(origin):
    """(host, path) of a forge origin, or None for no origin or a local one."""
    origin = origin.strip()
    if not origin or origin.startswith('file:') or ':' not in origin \
            or ('/' in origin and origin.index('/') < origin.index(':')):
        return None
    if '://' in origin or re.match(r'^[A-Za-z][A-Za-z0-9+.-]*::', origin):
        match = URL_ORIGIN.fullmatch(origin)
    else:
        match = SCP_ORIGIN.fullmatch(origin)
    if not match:
        raise Unknown('origin is an unrecognized remote URL')
    host, path = match.groups()[-2:]
    path = path.strip('/')
    if path.endswith('.git'):
        path = path[:-4]
    return host.lower(), path


def github_hosts(path):
    try:
        with open(path) as handle:
            return {line.strip().lower() for line in handle if line.strip()}
    except OSError:
        return set()


def names_task(body, task_id):
    """True when a SLICE or Task line outside fences names task_id."""
    fenced = ''
    for raw in (body or '').splitlines():
        fence = FENCE.match(raw)
        if fenced:
            if fence and fence[1][0] == fenced[0] and len(fence[1]) >= len(fenced) \
                    and not fence[2].strip(' \t'):
                fenced = ''
            continue
        if fence and (fence[1][0] != '`' or '`' not in fence[2]):
            fenced = fence[1]
            continue
        line = STRONG.sub(r'\2', DECOR.sub('', raw))
        for pattern, separator in ((SLICE_LINE, r'[\s`|]'), (TASK_LINE, r'[\s`|,;]')):
            match = pattern.match(line)
            if match:
                value = STRONG.sub(r'\2', match.group(1)).lstrip('`')
                value = re.split(separator, value, maxsplit=1)[0].rstrip('.,;:')
                value = value.rsplit('/', 1)[-1].rsplit(':', 1)[-1]
                if value == task_id:
                    return True
    return False


def run(cmd, timeout, env=None):
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise Unknown(f'{cmd[0]} is not on PATH')
    except subprocess.TimeoutExpired:
        raise Unknown(f'{cmd[0]} did not answer within {timeout} s')
    if done.returncode != 0:
        tail = (done.stderr or done.stdout).strip().splitlines()
        raise Unknown(f'{cmd[0]} exited {done.returncode}' + (f': {tail[-1][:200]}' if tail else ''))
    try:
        return json.loads(done.stdout)
    except ValueError:
        raise Unknown(f'{cmd[0]} did not print JSON')


def records(value, cmd, fields):
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise Unknown(f'{cmd} did not print a list of pull requests')
    for item in value:
        for field, kind in fields:
            if field not in item or not isinstance(item[field], kind):
                raise Unknown(f'{cmd} printed a pull request without valid {field}')
    return value


def github(host, path, branch, task_id, timeout):
    env = dict(os.environ, GH_HOST=host)
    repo = path if host == 'github.com' else f'{host}/{path}'
    fields = 'number,url,headRefName,headRefOid,body,state'
    found = []
    for extra in (['--head', branch], ['--search', f'"{task_id}" in:body']):
        cmd = ['gh', 'pr', 'list', '-R', repo, '--state', 'open', *extra, '--json', fields, '-L', str(LIST_LIMIT)]
        items = records(run(cmd, timeout, env), 'gh pr list',
                        [('number', int), ('url', str), ('headRefName', str),
                         ('state', str), ('body', (str, type(None))),
                         ('headRefOid', (str, type(None)))])
        if len(items) >= LIST_LIMIT:
            raise Unknown(f'gh pr list reached its limit of {LIST_LIMIT}; the list may be incomplete')
        for item in items:
            if item['state'].upper() != 'OPEN':
                continue
            found.append((item['number'], item['url'], item['headRefName'],
                          item['headRefOid'] or '', item['body'] or ''))
    return found


def gitlab(host, path, branch, task_id, timeout):
    env = dict(os.environ, GITLAB_HOST=host)
    repo = f'https://{host}/{path}'
    found = []
    for extra in (['--source-branch', branch], ['--search', task_id]):
        cmd = ['glab', 'mr', 'list', '-R', repo, *extra, '-F', 'json', '-P', str(LIST_LIMIT)]
        items = records(run(cmd, timeout, env), 'glab mr list',
                        [('iid', int), ('web_url', str), ('source_branch', str),
                         ('state', str), ('description', (str, type(None))),
                         ('sha', (str, type(None)))])
        if len(items) >= LIST_LIMIT:
            raise Unknown(f'glab mr list reached its limit of {LIST_LIMIT}; the list may be incomplete')
        for item in items:
            if item['state'] != 'opened':
                continue
            found.append((item['iid'], item['web_url'], item['source_branch'],
                          item['sha'] or '', item['description'] or ''))
    return found


def forgejo_login(host, timeout):
    logins = run(['tea', 'login', 'list', '--output', 'json'], timeout)
    if not isinstance(logins, list):
        raise Unknown('tea login list did not print a list')
    names = []
    for login in logins:
        if not isinstance(login, dict) or not isinstance(login.get('name'), str) or not login['name']:
            continue
        url = login.get('url') if isinstance(login.get('url'), str) else ''
        bare = re.sub(r':[0-9]+$', '', re.sub(r'^.*@', '', re.sub(r'[/?#].*$', '', re.sub(r'^[A-Za-z][A-Za-z0-9+.-]*://', '', url))))
        if bare.lower() == host:
            names.append(login['name'])
    if len(names) != 1:
        raise Unknown(f'tea has {len(names)} logins for {host}; exactly one is needed')
    return names[0]


def forgejo(host, path, branch, task_id, timeout):
    login = forgejo_login(host, timeout)
    found = []
    for page in range(1, FORGEJO_PAGES + 1):
        cmd = ['tea', 'api', '--login', login, '--repo', path,
               f'/repos/{{owner}}/{{repo}}/pulls?state=open&limit={FORGEJO_PAGE}&page={page}']
        items = records(run(cmd, timeout), 'tea api',
                        [('number', int), ('html_url', str), ('head', dict),
                         ('state', str), ('body', (str, type(None)))])
        for item in items:
            head = item['head']
            records([head], 'tea api head', [('ref', str), ('sha', (str, type(None)))])
            if item['state'] != 'open':
                continue
            found.append((item['number'], item['html_url'], head['ref'], head['sha'] or '', item['body'] or ''))
        if not items:
            return found
    raise Unknown(f'tea api reached its page limit of {FORGEJO_PAGES}; the list may be incomplete')


def main(argv):
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('--forge', required=True, choices=('none', 'forgejo', 'gerrit', 'external'))
    parser.add_argument('--origin', required=True)
    parser.add_argument('--branch', required=True)
    parser.add_argument('--task-id', required=True)
    parser.add_argument('--timeout', type=float, default=30.0)
    parser.add_argument('--github-hosts', default='')
    args = parser.parse_args(argv)
    if args.forge in ('gerrit', 'external'):
        emit({'state': 'skip', 'reason': f'forge={args.forge}',
              'notice': f'forge={args.forge} publishes no pull request a second builder would push to'})
    try:
        origin = parse_origin(args.origin)
    except Unknown as err:
        emit({'state': 'unknown', 'provider': '', 'error': str(err)}, UNKNOWN_EXIT)
    if origin is None:
        emit({'state': 'skip', 'reason': 'no forge origin', 'notice': ''})
    host, path = origin
    if args.forge == 'forgejo':
        provider, reader = 'forgejo', forgejo
    elif host == 'github.com' or host in github_hosts(args.github_hosts):
        provider, reader = 'github', github
    elif host == 'gitlab.com' or 'gitlab' in host.split('.'):
        provider, reader = 'gitlab', gitlab
    else:
        emit({'state': 'unknown', 'provider': '',
              'error': f'origin host {host} is neither github.com, a config/github-hosts host, nor a GitLab host'},
             UNKNOWN_EXIT)
    try:
        rows = reader(host, path, args.branch, args.task_id, args.timeout)
    except Unknown as err:
        emit({'state': 'unknown', 'provider': provider, 'error': str(err)}, UNKNOWN_EXIT)
    prs = {}
    for number, url, head_branch, head, body in rows:
        why = []
        if head_branch == args.branch:
            why.append('branch')
        if names_task(body, args.task_id):
            why.append('body')
        if not why:
            continue
        entry = prs.setdefault(number, {'number': number, 'url': url, 'branch': head_branch, 'head': head, 'why': []})
        entry['why'] = sorted(set(entry['why']) | set(why))
    emit({'state': 'ok', 'provider': provider, 'prs': [prs[n] for n in sorted(prs)]})


if __name__ == '__main__':
    main(sys.argv[1:])
