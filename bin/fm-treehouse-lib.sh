#!/usr/bin/env bash

FM_TREEHOUSE_VERSION=3.1.8

fm_treehouse_supports_lease() {
  local version major minor patch floor_major floor_minor floor_patch get_help return_help option
  version=$(treehouse --version 2>/dev/null) || return 1
  version=${version#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r major minor patch <<< "$version"
  IFS=. read -r floor_major floor_minor floor_patch <<< "$FM_TREEHOUSE_VERSION"
  if ! (( major > floor_major || (major == floor_major && minor > floor_minor) ||
    (major == floor_major && minor == floor_minor && patch >= floor_patch) )); then
    return 1
  fi
  get_help=$(treehouse get --help 2>/dev/null) || return 1
  return_help=$(treehouse return --help 2>/dev/null) || return 1
  for option in lease lease-holder json; do
    printf '%s\n' "$get_help" | grep -Eq "(^|[^[:alnum:]_-])--$option([^[:alnum:]_-]|$)" || return 1
  done
  for option in if-lease-id if-lease-holder; do
    printf '%s\n' "$return_help" | grep -Eq "(^|[^[:alnum:]_-])--$option([^[:alnum:]_-]|$)" || return 1
  done
}
