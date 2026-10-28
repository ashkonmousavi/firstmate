#!/usr/bin/env python3
import os
from pathlib import Path
import sys


def approved_path(raw, mate_home, main_home):
    path = Path(raw)
    if not path.is_absolute() or any(part.startswith('.') or part.casefold() in ('config', 'state') for part in path.parts):
        raise ValueError('brief path contains a private or relative component')
    resolved = path.resolve(strict=True)
    if any(part.startswith('.') or part.casefold() in ('config', 'state') for part in resolved.parts):
        raise ValueError('brief resolves to a private path')
    roots = []
    if mate_home:
        roots.append(Path(mate_home).resolve() / 'data' / 'walk-briefs')
    if main_home:
        roots.append(Path(main_home).resolve() / 'data' / 'from-main' / 'walk-lists')
    if not any(root in resolved.parents for root in roots):
        raise ValueError('brief is outside the requesting mate walk-briefs and MAIN walk-lists directories')
    if not resolved.is_file() or not os.access(resolved, os.R_OK):
        raise ValueError('brief must be a readable regular file')
    if any(char.isspace() or not char.isprintable() for char in str(resolved)):
        raise ValueError('brief must resolve to a single path token')
    return resolved


if __name__ == '__main__':
    try:
        print(approved_path(*sys.argv[1:]))
    except (OSError, RuntimeError, ValueError) as error:
        print(f'walk-request: {error}', file=sys.stderr)
        sys.exit(2)
