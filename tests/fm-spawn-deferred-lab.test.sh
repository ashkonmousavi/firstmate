#!/usr/bin/env bash
# Oracle: marked stock lab homes may drive lifecycle inside a gate, while
# relocated data is refused. Reject a retry helper inventing an override that
# makes an otherwise permitted stock-home retry fail before launch.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-deferred-lab)
command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required'
for variant in stock redundant relocated; do
  case_dir="$TMP/$variant"
  mkdir -p "$case_dir"
  lab=$("$ROOT/bin/fm-lab-home.sh" create "$case_dir/home") || fail 'lab create'
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  fm_test_tasks_toml "$lab/.tasks.toml"
  tasks-axi add retry-one 'retry lab guard' --kind ship --file "$lab/data/backlog.md" >/dev/null || fail 'task add'
  data="$lab/data"
  if [ "$variant" = relocated ]; then
    data="$case_dir/data"
    mkdir -p "$data"
    cp "$lab/data/backlog.md" "$data/backlog.md"
    fm_test_tasks_toml "$case_dir/.tasks.toml"
  fi
  cat > "$case_dir/capacity" <<'EOF'
#!/bin/bash
printf 'capacity: free_lanes=1\n'
EOF
  cat > "$case_dir/spawn" <<'EOF'
#!/bin/bash
. "$FM_DEFERRED_LAB_GUARD"
fm_refuse_if_gate_agent
printf '%s\n' "$1" > "$FM_DEFERRED_LAB_STARTED"
EOF
  chmod 755 "$case_dir/capacity" "$case_dir/spawn"
  export FM_DEFERRED_LAB_GUARD="$ROOT/bin/fm-gate-refuse-lib.sh" FM_DEFERRED_LAB_STARTED="$case_dir/started"
  data_args=()
  [ "$variant" = stock ] || data_args=("FM_DATA_OVERRIDE=$data")
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$lab" NO_MISTAKES_GATE=1 "${data_args[@]}" \
    "$ROOT/bin/fm-spawn-deferred.sh" record retry-one -- "$case_dir/spawn" retry-one || fail 'record'
  out=$(env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$lab" NO_MISTAKES_GATE=1 FM_SPAWN_DEFERRED_CAPACITY_BIN="$case_dir/capacity" "${data_args[@]}" \
    "$ROOT/bin/fm-spawn-deferred.sh" retry) || fail 'retry'
  case "$variant" in
    relocated)
      [ ! -e "$case_dir/started" ] || fail 'relocated data passed the lifecycle guard'
      assert_contains "$out" 'failed retry-one exit 3' 'relocated data did not retain gate refusal'
      ;;
    *)
      [ -f "$case_dir/started" ] || fail "$variant stock lab retry never reached permitted lifecycle: $out"
      assert_equals retry-one "$(cat "$case_dir/started")" 'retry identity'
      assert_contains "$out" 'started retry-one' 'stock lab retry failed'
      ;;
  esac
  pass "deferred retry lab guard: $variant data"
done
