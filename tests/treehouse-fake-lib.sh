#!/usr/bin/env bash
# Stateful Treehouse lease adapter for scratch pool fixtures. It never invokes
# Treehouse or resets a checkout; only its explicit fixture state file changes.
fm_test_treehouse_pool() { # <fakebin> <pool-dir>
  printf '#!/usr/bin/env bash\nstate=%q\n' "$2/treehouse-state.json" > "$1/treehouse"
  cat >> "$1/treehouse" <<'FAKE'
set -eu
[ "${1:-}" != --root ] || shift 2
case "$*" in
  --version) echo v3.1.8; exit 0 ;;
  'get --help') echo '--lease --lease-holder --json'; exit 0 ;;
  'return --help') echo '--if-lease-id --if-lease-holder'; exit 0 ;;
esac
command=$1
shift
case "$command" in
  status)
    jq '[.worktrees[] | {name,path,status:(if .leased then "leased" else "available" end),lease_id:(.lease_id // ""),leased_at:null}]' "$state"
    ;;
  lease|get)
    if [ "$command" = lease ]; then name=$1; shift; else
      name=$(jq -er 'first(.worktrees[] | select(.leased != true)).name' "$state")
    fi
    holder=
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease-holder) holder=$2; shift 2 ;;
        --json) json=1; shift ;;
        *) shift ;;
      esac
    done
    jq --arg name "$name" --arg holder "$holder" \
      '(.worktrees[] | select(.name == $name)) += {leased:true,lease_id:("lease-"+$name),lease_holder:$holder}' \
      "$state" > "$state.new"
    mv "$state.new" "$state"
    if [ "$json" = 1 ]; then
      jq --arg name "$name" '.worktrees[] | select(.name == $name) | {path,lease_id,lease_holder}' "$state"
    else
      jq -r --arg name "$name" '.worktrees[] | select(.name == $name).path' "$state"
    fi
    ;;
  return)
    path=$1
    jq --arg path "$path" '(.worktrees[] | select(.path == $path)) += {leased:false,lease_id:"",lease_holder:""}' \
      "$state" > "$state.new"
    mv "$state.new" "$state"
    ;;
  *) exit 2 ;;
esac
FAKE
  chmod +x "$1/treehouse"
}
