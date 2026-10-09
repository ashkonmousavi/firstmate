#!/usr/bin/env bash
set -u
cd "$1" || exit 1
release=$2
deadline=$((SECONDS + 300))
while [ ! -e "$release" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then : > "$release.expired"; exit 0; fi
  sleep 0.1
done
