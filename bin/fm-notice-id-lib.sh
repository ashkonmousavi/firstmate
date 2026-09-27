#!/usr/bin/env bash
# Stable 16-hex delivery IDs for routine secondmate notices. Source only.
# The caller supplies a seed unique to one notice but stable across its retry.

fm_notice_delivery_id() {  # <seed>
  local seed=$1 digest
  [ -n "$seed" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$seed" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$seed" | sha256sum | awk '{print $1}') || return 1
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s' "$seed" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}') || return 1
  else
    return 1
  fi
  digest=${digest:0:16}
  [[ $digest =~ ^[a-f0-9]{16}$ ]] || return 1
  printf '%s' "$digest"
}
