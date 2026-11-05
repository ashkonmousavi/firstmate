#!/usr/bin/env bash
# bin/fm-open-pr-lookup.py protocol fixture: answers "no forge" for every call.
# Fixture origins such as https://github.com/o/r would otherwise send every fresh
# ship spawn in the suite to the real network, and refuse as UNKNOWN where gh has
# no sign-in (CI). tests/fm-spawn-duplicate-builder.test.sh drives the real lookup.
echo '{"notice": "", "reason": "test fixture", "state": "skip"}'
