#!/usr/bin/env python3
import base64
import os
from pathlib import Path
import sys
import tempfile


MAX_BYTES = 65536


def private_part(part):
    return part.startswith('.') or part.casefold() in ('config', 'state')


def below(path, base):
    try:
        return path.relative_to(base).parts
    except ValueError:
        return None


def approved_path(raw, mate_home, main_home):
    path = Path(raw)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('brief path contains a private or relative component')
    resolved = path.resolve(strict=True)
    # Each approved root is a (home, subdirectory) pair; the private-part check
    # applies only below the home, never to the home's own ancestors.
    roots = []
    if mate_home:
        roots.append((Path(mate_home), ('data', 'walk-briefs')))
    if main_home:
        roots.append((Path(main_home), ('data', 'from-main', 'walk-lists')))
    for home, _ in roots:
        literal = below(path, home)
        if literal is None:
            literal = below(path, home.resolve())
        if literal is not None:
            if any(private_part(part) for part in literal):
                raise ValueError('brief path contains a private or relative component')
            break
    else:
        raise ValueError('brief is outside the requesting mate walk-briefs and MAIN walk-lists directories')
    for home, sub in roots:
        real_home = home.resolve()
        under = below(resolved, real_home)
        if under is None or under[:len(sub)] != sub or len(under) <= len(sub):
            continue
        if any(private_part(part) for part in under):
            raise ValueError('brief resolves to a private path')
        break
    else:
        if any(private_part(part) for part in path.parts + resolved.parts):
            raise ValueError('brief path contains a private or relative component')
        raise ValueError('brief is outside the requesting mate walk-briefs and MAIN walk-lists directories')
    if not resolved.is_file() or not os.access(resolved, os.R_OK):
        raise ValueError('brief must be a readable regular file')
    if any(char.isspace() or not char.isprintable() for char in str(resolved)):
        raise ValueError('brief must resolve to a single path token')
    return resolved


def text_bytes(data):
    if len(data) > MAX_BYTES:
        raise ValueError('brief exceeds 64 KiB')
    text = data.decode('utf-8')
    if any((ord(char) < 32 and char not in '\t\r\n') or 127 <= ord(char) <= 159 for char in text):
        raise ValueError('brief must be UTF-8 text, not binary')
    return data


def read_brief(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError('brief must be a regular file')
    with path.open('rb') as source:
        return text_bytes(source.read(MAX_BYTES + 1))


def snapshot_path(main_home, corr, create=False):
    if len(corr) != 16 or any(char not in '0123456789abcdef' for char in corr):
        raise ValueError('invalid request identity')
    folder = Path(main_home).resolve(strict=True)
    for part in ('data', 'walk-requests', corr):
        folder /= part
        if folder.is_symlink():
            raise ValueError('brief snapshot directory must not be a symlink')
        if create:
            folder.mkdir(mode=0o700, exist_ok=True)
        if not folder.is_dir():
            raise ValueError('brief snapshot directory is unavailable')
    path = folder / 'brief.md'
    if path.is_symlink():
        raise ValueError('brief snapshot must not be a symlink')
    return path


def stage(main_home, corr, mode, source, mate_home):
    path = snapshot_path(main_home, corr, create=True)
    if not path.exists():
        if mode == 'inline':
            if len(source) > 4 * ((MAX_BYTES + 2) // 3):
                raise ValueError('brief exceeds 64 KiB')
            data = text_bytes(base64.b64decode(source, validate=True))
        elif mode == 'local':
            data = read_brief(approved_path(source, mate_home, main_home))
        else:
            raise ValueError('remote requests must carry an inline brief')
        name = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
                name = output.name
                output.write(data)
            os.replace(name, path)
        finally:
            if name and os.path.exists(name):
                os.unlink(name)
    read_brief(path)
    return path


if __name__ == '__main__':
    try:
        action, *args = sys.argv[1:]
        if action in ('path', 'encode'):
            path = approved_path(*args)
            data = read_brief(path)
            print(path if action == 'path' else base64.b64encode(data).decode('ascii'))
        elif action == 'stage':
            print(stage(*args))
        elif action == 'snapshot':
            path = snapshot_path(*args)
            read_brief(path)
            print(path)
        else:
            raise ValueError('invalid brief operation')
    except (OSError, RuntimeError, ValueError) as error:
        print(f'walk-request: {error}', file=sys.stderr)
        sys.exit(2)
