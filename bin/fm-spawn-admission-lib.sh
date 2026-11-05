#!/usr/bin/env bash
# Shared read-only launch admission, used by spawn and pre-stop relaunch.
# Requires the capacity, backlog-transition and lease libraries.
# Callers supply spawn identity globals (ID, KIND, CONFIG, DATA, STATE,
# RELAUNCH, RELAUNCH_FROM_RELEASED); the released-copy hold exception remains
# owned by spawn. Backlog outputs retain the launch owner's transition context.
# These are observations, not reservations: spawn rechecks after the stop.

fm_spawn_capacity_admit() { # <home> <config> <state> <id> <kind> [sample=1]
  [ "$5" != secondmate ] || return 0
  if ! fm_capacity_read "$1" "$2" "$3" "$4" "${6:-1}"; then
    echo "deferred: $FM_CAPACITY_ERROR; task $4 stays queued" >&2
    return 75
  fi
}

# Deterministic launch configuration, read before any mutation so a malformed
# file refuses instead of launching a worker on a posture the captain did not
# choose. Spawn and the pre-stop relaunch preflight share this one owner.
# shellcheck disable=SC2034 # Outputs consumed by spawn's launch rendering.
fm_spawn_config_admit() {
  # config/claude-permission-mode (header above): resolved once per spawn or
  # relaunch, before any mutation, so a malformed file refuses instead of
  # launching a worker on a permission posture the captain did not choose.
  if ! CLAUDE_PERM_PRESENT=$(fm_config_source_present "$CONFIG/claude-permission-mode"); then
    return 1
  fi
  CLAUDE_PERMISSION_MODE=bypass
  if [ "$CLAUDE_PERM_PRESENT" = 1 ]; then
    if [ ! -f "$CONFIG/claude-permission-mode" ] || [ ! -r "$CONFIG/claude-permission-mode" ]; then
      echo "error: config/claude-permission-mode must be a readable regular file holding one of: bypass, auto" >&2
      return 1
    fi
    CLAUDE_PERMISSION_MODE=$(tr -d '[:space:]' <"$CONFIG/claude-permission-mode" || true)
    case "$CLAUDE_PERMISSION_MODE" in
    bypass | auto) ;;
    *)
      echo "error: config/claude-permission-mode holds '$CLAUDE_PERMISSION_MODE'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" >&2
      return 1
      ;;
    esac
  fi
  case "$CLAUDE_PERMISSION_MODE" in
  auto) CLAUDE_PERM_FLAG='--permission-mode auto' ;;
  *) CLAUDE_PERM_FLAG='--dangerously-skip-permissions' ;;
  esac
  if ! CODEX_APPROVAL_PRESENT=$(fm_config_source_present "$CONFIG/codex-approval-mode"); then
    return 1
  fi
  CODEX_APPROVAL_MODE=bypass
  if [ "$CODEX_APPROVAL_PRESENT" = 1 ]; then
    if [ ! -f "$CONFIG/codex-approval-mode" ] || [ ! -r "$CONFIG/codex-approval-mode" ]; then
      echo "error: config/codex-approval-mode must be a readable regular file holding one of: bypass, approve-for-me" >&2
      return 1
    fi
    if ! CODEX_APPROVAL_MODE=$(perl -0777 -pe 's/\A\s+|\s+\z//g' <"$CONFIG/codex-approval-mode"); then
      echo 'error: could not read config/codex-approval-mode' >&2
      return 1
    fi
    case "$CODEX_APPROVAL_MODE" in
      bypass | approve-for-me) ;;
      *)
        echo "error: config/codex-approval-mode holds '$CODEX_APPROVAL_MODE'; accepted values are: bypass (the default), approve-for-me" >&2
        return 1
        ;;
    esac
  fi
  case "$CODEX_APPROVAL_MODE" in
    approve-for-me) CODEX_APPROVAL_FLAG='--approve-for-me' ;;
    *) CODEX_APPROVAL_FLAG='--dangerously-bypass-approvals-and-sandbox' ;;
  esac
  # Resolve the opt-in Codex posture before any spawn or relaunch mutation.
  # docs/configuration.md owns config/codex-permission-mode and its limits.
  CODEX_PERMISSION_MODE=bypass
  if ! CODEX_PERM_PRESENT=$(fm_config_source_present "$CONFIG/codex-permission-mode"); then
    return 1
  fi
  if [ "$CODEX_PERM_PRESENT" = 1 ]; then
    if [ ! -f "$CONFIG/codex-permission-mode" ] || [ ! -r "$CONFIG/codex-permission-mode" ]; then
      echo "error: config/codex-permission-mode must be a readable regular file holding bypass or restricted" >&2
      return 1
    fi
    CODEX_PERMISSION_MODE=$(cat "$CONFIG/codex-permission-mode") || return 1
    case "$CODEX_PERMISSION_MODE" in
    bypass | restricted) ;;
    *)
      echo "error: config/codex-permission-mode must contain bypass or restricted" >&2
      return 1
      ;;
    esac
  fi
  # Restricted replaces whichever approval flag was selected above, and the task
  # record reports it so approval failover never treats the launch as bypass.
  if [ "$CODEX_PERMISSION_MODE" = restricted ]; then
    CODEX_APPROVAL_MODE=restricted
    CODEX_APPROVAL_FLAG='--sandbox workspace-write --ask-for-approval on-request'
  fi
  # config/lavish-axi-host is the primary-owned per-machine address for the
  # shared Lavish server. Read it once per launch and refuse malformed values so
  # every worker reaches the same server instead of starting a second one.
  if ! LAVISH_AXI_HOST_CONFIG_PRESENT=$(fm_config_source_present "$CONFIG/lavish-axi-host"); then
    return 1
  fi
  if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
    if [ ! -f "$CONFIG/lavish-axi-host" ] || [ ! -r "$CONFIG/lavish-axi-host" ]; then
      echo "error: config/lavish-axi-host must be a readable regular file" >&2
      return 1
    fi
    LAVISH_AXI_HOST=$(cat "$CONFIG/lavish-axi-host") || return 1
    case "$LAVISH_AXI_HOST" in
      ''|*[[:space:][:cntrl:]]*)
        echo "error: config/lavish-axi-host must contain one non-empty address without whitespace" >&2
        return 1
        ;;
    esac
  fi
  if ! KEEP_AI_TRAILERS=$(fm_config_source_present "$CONFIG/keep-ai-trailers"); then
    return 1
  fi
}

# Worker-brief admission for ship and scout launches, including the Herdr
# lifecycle guard. Spawn and the pre-stop relaunch preflight (on a scratch
# copy carrying the pending progress note) share this one owner.
# shellcheck disable=SC2034 # CAPTAIN_INTENT feeds the launch-brief overlay.
fm_spawn_brief_admit() { # <brief>
  local brief=$1
  { [ "$KIND" = ship ] || [ "$KIND" = scout ]; } || return 0
  HERDR_LIFECYCLE_BRIEF_GUARD=$(fm_config_source_present "$CONFIG/herdr-lifecycle-spawn-guard") || return 1
  if [ "$HERDR_LIFECYCLE_BRIEF_GUARD" = 1 ]; then
    HERDR_LIFECYCLE_COMMAND=$(perl -ne '
      if (m{(bin/fm-herdr-lab\.sh|(?<![[:alnum:]_])herdr[[:space:]]+(?:session|server)[[:space:]]+(?:start|stop|delete|restart|reload-config|live-handoff)(?![[:alnum:]_-]))}) { print $1; exit }
    ' -- "$brief") || return 1
    if [ -n "$HERDR_LIFECYCLE_COMMAND" ] && ! grep -Fq '# Herdr isolation - HARD SAFETY CONTRACT' "$brief"; then
      echo "error: $brief names the Herdr lifecycle command \`$HERDR_LIFECYCLE_COMMAND\` but lacks the Herdr isolation contract; regenerate it with bin/fm-brief.sh --herdr-lab" >&2
      return 1
    fi
  fi
  if fm_brief_task_placeholders_present "$brief"; then
    echo "error: $brief still contains {TASK} or {FIRSTMATE_SPEC}; fill ## Captain's intent and ## Firstmate spec before spawn" >&2
    return 1
  fi
  if ! fm_brief_task_content_valid "$brief"; then
    echo "error: $brief must contain nonempty ## Captain's intent and ## Firstmate spec subsections (or a nonempty legacy # Task body) before spawn" >&2
    return 1
  fi
  if ADDRESS_LINE=$(fm_brief_intent_address_line "$brief"); then
    echo "error: $brief ## Captain's intent has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address before spawn, since the heading already records provenance" >&2
    return 1
  fi
  # shellcheck disable=SC2153 # MODE is supplied by spawn or relaunch preparation.
  if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
    if fm_brief_task_heading_present "$brief" "## Captain's intent"; then
      CAPTAIN_INTENT=$(fm_brief_task_heading_body "$brief" "## Captain's intent") || return 1
    else
      LEGACY_TASK_BODY=$(fm_brief_heading_body "$brief" "# Task") || return 1
      CAPTAIN_INTENT=$(fm_brief_marked_captain_words "$LEGACY_TASK_BODY") || return 1
      if [ -z "$(printf '%s' "$CAPTAIN_INTENT" | tr -d '[:space:]')" ]; then
        echo "error: legacy mixed # Task brief has no provenance-marked captain words for no-mistakes --intent; add [captain] lines or migrate to ## Captain's intent and ## Firstmate spec" >&2
        return 1
      fi
    fi
  fi
  return 0
}

# Slice admission for a fresh ship (relaunches are recovery and keep their
# scope; scouts and secondmates are knowledge or supervisor work). A home that
# has $FM_HOME/config/slicing.json runs the vertical-slicing validator's
# `gate` on the task body, the brief and, when present, data/<id>/prep.md,
# before any worktree, record or backlog move exists. The validator owns the
# policy contract (observe reports and returns 0; enforce returns 1 FAIL or
# 2 UNKNOWN, including a malformed policy); this function refuses on any
# nonzero gate result and prints the reasons. A home with no policy file is
# an explicit unconfigured bypass. The validator path is FM_SLICE_VALIDATOR,
# else the installed skills-master copy; when it yields no result, an unlisted
# project bypasses, observe launches with a notice, and other modes refuse
# listed projects or an unreadable projects list.
fm_spawn_slice_admit() { # <brief>
  local brief=$1 policy="$FM_HOME/config/slicing.json" validator mode out rc summary=
  [ "$KIND" = ship ] && [ "$RELAUNCH" -eq 0 ] || return 0
  [ -e "$policy" ] || return 0
  validator=${FM_SLICE_VALIDATOR:-$HOME/.config/skills-master/.agents/skills/vertical-slicing/scripts/slicing.py}
  mode=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("mode", ""))' "$policy" 2>/dev/null) || mode=
  local texts=(--text "$brief")
  [ ! -f "$DATA/$ID/prep.md" ] || texts+=(--text "$DATA/$ID/prep.md")
  if [ -r "$validator" ]; then
    out=$(python3 "$validator" gate --home "$FM_HOME" --project "$(basename "$PROJ_ABS")" --kind ship \
      --task-id "$ID" --code-root "$FM_ROOT" "${texts[@]}" 2>&1)
    rc=$?
    summary=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    v = json.loads(sys.stdin.read())
    print(v["state"] + ": " + "; ".join(r["code"] + " (" + r["source"] + ")" for r in v["reasons"]) if v["reasons"] else v["state"])
except Exception:
    sys.exit(1)' 2>/dev/null) || summary=
  else
    rc=2
    out="validator $validator is not readable"
  fi
  if [ -z "$summary" ]; then
    if python3 -c '
import json, sys
try:
    projects = json.load(open(sys.argv[1]))["projects"]
    if not isinstance(projects, list) or not all(isinstance(p, str) for p in projects):
        sys.exit(2)
    sys.exit(0 if sys.argv[2] not in projects else 1)
except Exception:
    sys.exit(2)' "$policy" "$(basename "$PROJ_ABS")" 2>/dev/null; then
      return 0
    fi
    if [ "$mode" = observe ]; then
      echo "notice: slice admission ($policy, observe) could not check $ID: $(printf '%s' "$out" | tail -1); launching" >&2
      return 0
    fi
    echo "error: spawn refused: slice admission ($policy, mode ${mode:-unreadable}) could not check $ID: $(printf '%s' "$out" | tail -1)" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "error: spawn refused: slice admission ($policy) refuses $ID: $summary; give the task, brief and prep one SLICE: <home>/<id> | <outcome> line from the accepted catalogue" >&2
    return 1
  fi
  case $summary in
  ok) ;;
  *) echo "notice: slice admission ($policy, ${mode:-observe}) would refuse $ID: $summary; launching" >&2 ;;
  esac
  return 0
}

# Duplicate-builder admission for a fresh ship spawn. bin/fm-open-pr-lookup.py
# owns which forge is read and what counts as an open pull request carrying
# this task (its head is the task's branch, or its body names the task on a
# SLICE or Task line anywhere in its body, including code examples).
# An open one refuses the spawn, naming each URL, unless
# --continue-pr names exactly that pull request on the task's branch; then the
# fresh copy starts at its head (SPAWN_CONTINUE_PR_*, freshen_spawn_worktree_base).
# A forge that cannot be read refuses as UNKNOWN unless --continue-pr or
# --no-forge-check <reason> was given. Relaunches, scouts, secondmates and
# local-only tasks never consult it. Every refusal exits 1, never the deferral
# exit, so a batch reports it as a failure rather than retrying it.
# Test seam, honored only with FM_TEST_SEAM=1: FM_OPEN_PR_LOOKUP replaces the
# lookup program (same arguments and JSON); tests/lib.sh points it at an offline
# stub so suites never reach a forge. Without FM_TEST_SEAM=1 it is ignored, so
# --no-forge-check stays the only way to skip the read.
SPAWN_CONTINUE_PR_URL=
SPAWN_CONTINUE_PR_HEAD=
# shellcheck disable=SC2034 # SPAWN_CONTINUE_PR_* feed spawn's copy freshening and task record.
fm_spawn_duplicate_admit() {
  local forge origin out rc state lines line number url branch head why others='' lookup
  [ "$KIND" = ship ] && [ "$RELAUNCH" -eq 0 ] || return 0
  [ "$MODE" != local-only ] || return 0
  if [ -n "${SPAWN_NO_FORGE_CHECK:-}" ]; then
    echo "notice: duplicate-builder check skipped for $ID by --no-forge-check: $SPAWN_NO_FORGE_CHECK" >&2
    return 0
  fi
  forge=$("$FM_ROOT/bin/fm-project-mode.sh" --forge "$(basename "$PROJ_ABS")") || {
    echo "error: $ID cannot launch: the registry entry for $(basename "$PROJ_ABS") does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    return 1
  }
  # The configured URL names the forge; url.<base>.insteadOf may point fetches at a mirror.
  origin=$(git -C "$PROJ_ABS" config --get remote.origin.url 2>/dev/null) || origin=
  lookup=$FM_ROOT/bin/fm-open-pr-lookup.py
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then lookup=${FM_OPEN_PR_LOOKUP:-$lookup}; fi
  out=$("$lookup" --forge "${forge:-none}" --origin "$origin" \
    --branch "$BRANCH" --task-id "$ID" --timeout "${FM_SPAWN_FORGE_TIMEOUT:-30}" \
    --github-hosts "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/github-hosts" 2>&1)
  rc=$?
  lines=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    v = json.loads(sys.stdin.read())
except Exception:
    print("state\tunknown\tthe pull request lookup printed no answer"); sys.exit(0)
if v.get("state") == "ok":
    print("state\tok\t")
    for p in v.get("prs", []):
        # read splits on tabs and collapses empty fields, so an unknown head prints as "-".
        print("pr\t%s\t%s\t%s\t%s\t%s" % (p["number"], p["url"], p["branch"], p.get("head") or "-", ",".join(p["why"])))
elif v.get("state") == "skip":
    print("state\tskip\t" + (v.get("notice") or ""))
else:
    print("state\tunknown\t" + ((v.get("provider") or "forge") + ": " + (v.get("error") or "unreadable")))' 2>/dev/null)
  state=$(printf '%s\n' "$lines" | awk -F'\t' '$1 == "state" { print $2; exit }')
  [ "$rc" -eq 0 ] || [ "$state" = unknown ] || state=unknown
  case $state in
  skip)
    line=$(printf '%s\n' "$lines" | awk -F'\t' '$1 == "state" { print $3; exit }')
    [ -z "$line" ] || echo "notice: duplicate-builder check skipped for $ID: $line" >&2
    [ -z "${SPAWN_CONTINUE_PR:-}" ] || {
      echo "error: spawn refused: --continue-pr $SPAWN_CONTINUE_PR needs a forge pull request, and $(basename "$PROJ_ABS") has none to read" >&2
      return 1
    }
    return 0
    ;;
  ok) ;;
  *)
    line=$(printf '%s\n' "$lines" | awk -F'\t' '$1 == "state" { print $3; exit }')
    [ -n "$line" ] || line=$(printf '%s' "$out" | tail -1)
    if [ -n "${SPAWN_CONTINUE_PR:-}" ]; then
      echo "notice: duplicate-builder check for $ID is UNKNOWN ($line); attaching to pull request $SPAWN_CONTINUE_PR's branch $BRANCH as --continue-pr asks" >&2
      return 0
    fi
    echo "error: spawn refused: duplicate-builder check for $ID is UNKNOWN: $line; a fresh builder is never launched blind - retry when the forge answers, attach with --continue-pr <N>, or pass --no-forge-check <reason>" >&2
    return 1
    ;;
  esac
  while IFS=$'\t' read -r line number url branch head why; do
    [ "$line" = pr ] || continue
    if [ -n "${SPAWN_CONTINUE_PR:-}" ] && [ "$number" = "$SPAWN_CONTINUE_PR" ] && [ "$branch" = "$BRANCH" ]; then
      SPAWN_CONTINUE_PR_URL=$url
      [ "$head" = - ] || SPAWN_CONTINUE_PR_HEAD=$head
      continue
    fi
    if [ -n "${SPAWN_CONTINUE_PR:-}" ] && [ "$number" = "$SPAWN_CONTINUE_PR" ]; then
      echo "error: spawn refused: pull request $url is on branch $branch, not this task's branch $BRANCH; --continue-pr attaches only to a pull request on $BRANCH" >&2
      return 1
    fi
    others="$others $url (branch $branch; $why)"
  done <<EOF
$lines
EOF
  if [ -n "$others" ]; then
    echo "error: spawn refused: $ID already has an open pull request:$others - another builder may be on it; attach with --continue-pr <N>, close it first, or pass --no-forge-check <reason>" >&2
    return 1
  fi
  if [ -n "${SPAWN_CONTINUE_PR:-}" ] && [ -z "$SPAWN_CONTINUE_PR_URL" ]; then
    echo "error: spawn refused: --continue-pr $SPAWN_CONTINUE_PR is not an open pull request on $BRANCH for $ID" >&2
    return 1
  fi
  return 0
}

# Read-only checks of the per-task launch files a retained relaunch writes
# after the stop. Each owner's check mode runs the same validation as the
# write spawn performs: Devin hook config, polytoken config mirror, the Claude
# launch-brief operational inbox and Claude workspace trust. Trust reads the
# store the replacement launches under: a selected worker account
# (WORKER_ACCOUNT, root in WORKER_ACCOUNT_ROOT, empty for `ordinary`) replaces
# the ambient CLAUDE_CONFIG_DIR exactly as spawn's account selection does.
fm_spawn_launch_files_admit() { # <state-real> <worktree> <project-or-mate-home>
  # shellcheck disable=SC2034 # record_directory is the owner's printf -v output.
  local state_real=$1 wt=$2 proj=$3 opstate record_directory
  local -a trust_args trust_env=()
  [ "$RAW_LAUNCH" = 0 ] || return 0
  case "$HARNESS" in
  devin)
    FM_KEEP_AI_TRAILERS="$KEEP_AI_TRAILERS" "$FM_ROOT/bin/fm-devin-config.sh" --check "$state_real" "$ID" prepare || return 1
    ;;
  polytoken)
    fm_polytoken_write_config "$(fm_polytoken_config_dir "$state_real" "$ID")" check || return 1
    ;;
  claude*)
    # shellcheck disable=SC2153 # STATE is supplied by relaunch preparation.
    opstate=$STATE trust_args=("$wt" "$proj")
    if [ "$KIND" = secondmate ]; then
      opstate="$proj/state" trust_args=(--secondmate-home "$proj" "$ID")
    fi
    fm_operational_record_directory "$opstate" record_directory || {
      echo "error: task $ID's operational-inbox path cannot carry a launch doorbell" >&2
      return 1
    }
    if [ -n "${WORKER_ACCOUNT:-}" ]; then
      trust_env=(env -u CLAUDE_CONFIG_DIR)
      [ -z "${WORKER_ACCOUNT_ROOT:-}" ] || trust_env+=("CLAUDE_CONFIG_DIR=$WORKER_ACCOUNT_ROOT")
    fi
    "${trust_env[@]+"${trust_env[@]}"}" "$FM_ROOT/bin/fm-claude-trust.sh" --check "${trust_args[@]}" >/dev/null || return 1
    ;;
  esac
  return 0
}

# A ship task's recorded branch must be a valid branch name. Sets BRANCH.
fm_spawn_ship_branch_admit() { # <task-record>
  [ "$KIND" = ship ] || return 0
  BRANCH=$(fm_meta_get "$1" branch)
  [ -n "$BRANCH" ] || BRANCH="fm/$ID"
  git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 && return 0
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  return 1
}

# A retained relaunch of a worker needs its recorded project. Sets PROJ.
fm_spawn_relaunch_project_admit() { # <task-record>
  PROJ=$(fm_meta_get "$1" project)
  [ -n "$PROJ" ] && return 0
  echo "error: task $ID has no recorded project; refusing to relaunch" >&2
  return 1
}

fm_spawn_existing_dir() {
  local path=$1
  [ -d "$path" ] || {
    echo "error: firstmate home does not exist or is not a directory: $path" >&2
    return 1
  }
  cd "$path" && pwd -P
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(fm_spawn_existing_dir "$home") || return 1
  abs_active_home=$(fm_spawn_existing_dir "$FM_HOME")
  abs_root=$(fm_spawn_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

# A secondmate's home must be a seeded secondmate home for this id, outside
# the active home and the Firstmate repo. Sets PROJ_ABS.
fm_spawn_secondmate_home_admit() { # <id> <home>
  [ -n "$2" ] || {
    echo "error: no firstmate home supplied or registered for $1" >&2
    return 1
  }
  # shellcheck disable=SC2034 # Spawn and the relaunch preflight use the resolved home.
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$1" "$2") || return 1
}

# A registered secondmate must be bound to this home. Sets SECONDMATE_PROJECTS.
fm_spawn_secondmate_registry_admit() { # <id> <home>
  [ -e "$DATA/secondmates.md" ] || [ -L "$DATA/secondmates.md" ] || return 0
  if ! secondmate_registry_validate_bindings "$DATA/secondmates.md" resolve_path "$1" "$2"; then
    echo "error: $SECONDMATE_REGISTRY_ERROR" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Spawn records the registered projects.
  SECONDMATE_PROJECTS=$SECONDMATE_REGISTRY_MATCH_PROJECTS
}

# Ship delivery-contract admission: the registry posture, the brief's
# delivery contract line and ship branch, the recorded task flags, external
# review protections and the self-repository publication gate must agree.
# <brief> is read; <source-brief> is the file named in re-scaffold advice.
# Sets PROJ_NAME, STANDING_MODE and the EXTERNAL_* launch settings.
# shellcheck disable=SC2034 # Outputs consumed by spawn's launch and task record.
fm_spawn_delivery_admit() { # <brief> <source-brief>
  local brief=$1 source_brief=$2 STANDING_FORGE STANDING_PR BRIEF_MODE BRIEF_FORGE BRIEF_BRANCH BRIEF_CONSENT BRIEF_PR
  local forge_scaffold pr_scaffold backup_urls shared_urls gate_rc
  [ "$KIND" = ship ] || return 0
  PROJ_NAME=$(basename "$PROJ_ABS")
  # The parser's own refusal reaches the operator here rather than being
  # discarded: an entry it refuses (an unknown forge token, or a forge on
  # local-only) resolves to no posture at all, and launching on the silent
  # default is how a mistyped forge would hand a Gerrit project the
  # pull-request contract.
  if ! STANDING_FORGE=$("$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJ_NAME" 2>/dev/null); then
    "$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJ_NAME" >/dev/null || true
    echo "error: $ID cannot launch: the registry entry for $PROJ_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    return 1
  fi
  [ -n "$STANDING_FORGE" ] || STANDING_FORGE=none
  STANDING_MODE=$("$FM_ROOT/bin/fm-project-mode.sh" --raw "$PROJ_NAME" 2>/dev/null | cut -d' ' -f1) || STANDING_MODE=
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
  BRIEF_FORGE=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]forge=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
  [ -n "$BRIEF_FORGE" ] || BRIEF_FORGE=none
  BRIEF_BRANCH=$(sed -n 's/^Ship branch: //p' "$brief" | head -n 1)
  if [ -n "$BRIEF_BRANCH" ]; then
    [ "$BRIEF_BRANCH" = "$BRANCH" ] || {
      echo "error: branch mismatch for $ID: the brief says branch=$BRIEF_BRANCH but this spawn selected branch=$BRANCH" >&2
      return 1
    }
  elif [ "$BRANCH" != "fm/$ID" ]; then
    # A relaunch's branch comes from the meta record (--branch-prefix is refused
    # there), so a promoted scout whose brief never carried a Ship branch line
    # must relaunch on that recorded branch rather than be refused.
    if [ "$RELAUNCH" -eq 1 ]; then
      echo "warning: $brief records no ship branch; relaunching on the task's recorded branch $BRANCH" >&2
    else
      echo "error: $brief records no ship branch; regenerate it with --branch-prefix before spawning $BRANCH" >&2
      return 1
    fi
  else
    echo "warning: $brief records no ship branch; defaulting to legacy branch $BRANCH" >&2
  fi
  if [ -z "$BRIEF_MODE" ]; then
    echo "warning: $brief records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode $MODE - confirm its definition of done matches" >&2
  elif [ "$BRIEF_MODE" != "$MODE" ]; then
    echo "error: delivery mismatch for $ID: the brief says mode=$BRIEF_MODE but this spawn passed --mode $MODE; correct the flag or re-scaffold the brief so the worker's instructions and the task record agree" >&2
    return 1
  fi
  # A firstmate-repository contribution records its one-task publication consent
  # as an upstream-consent= token on that same line; like mode and forge, the
  # brief and the spawn flag must agree so the worker's contract and the task
  # record carry the same authority.
  BRIEF_CONSENT=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]upstream-consent=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
  if [ "$BRIEF_CONSENT" != "$UPSTREAM_CONSENT" ]; then
    echo "error: upstream-consent mismatch for $ID: $brief records upstream-consent=${BRIEF_CONSENT:-none} but this spawn passed ${UPSTREAM_CONSENT:-none}; correct the flag or re-scaffold the brief so the worker's contract and the task record agree" >&2
    return 1
  fi
  # The registered forge is the captain's confirmed binding (bin/fm-project-mode.sh)
  # and is never inferred here from a remote, host, or protocol. A brief that
  # disagrees with it would tell the worker to open a pull request a Gerrit
  # server does not have, or to publish a change to a forge that is not Gerrit.
  if [ "$BRIEF_FORGE" != "$STANDING_FORGE" ]; then
    if [ "$STANDING_FORGE" = none ]; then
      forge_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE"
    else
      forge_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE --forge $STANDING_FORGE"
    fi
    echo "error: forge mismatch for $ID: $PROJ_NAME is registered forge=$STANDING_FORGE but $source_brief records forge=$BRIEF_FORGE; keep the filled ## Captain's intent and ## Firstmate spec bodies, remove $source_brief, re-scaffold it with $forge_scaffold, then re-fill those two subsections, so the worker's publication matches the project's forge" >&2
    return 1
  fi
  # The registered PR-text binding is read the same way: a brief that disagrees
  # would hand the pipeline's pr step the text a person owns, or the worker text
  # the pipeline owns. direct-PR already leaves the text to the worker, so a
  # conditional-policy project's direct-PR task expects none.
  if ! STANDING_PR=$("$FM_ROOT/bin/fm-project-mode.sh" --pr "$PROJ_NAME" 2>/dev/null); then
    "$FM_ROOT/bin/fm-project-mode.sh" --pr "$PROJ_NAME" >/dev/null || true
    echo "error: $ID cannot launch: the registry entry for $PROJ_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    return 1
  fi
  [ -n "$STANDING_PR" ] || STANDING_PR=auto
  [ "$MODE" = no-mistakes ] || STANDING_PR=auto
  BRIEF_PR=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]pr=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
  [ -n "$BRIEF_PR" ] || BRIEF_PR=auto
  if [ "$BRIEF_PR" != "$STANDING_PR" ]; then
    pr_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE"
    [ "$STANDING_FORGE" = none ] || pr_scaffold="$pr_scaffold --forge $STANDING_FORGE"
    [ "$STANDING_PR" = auto ] || pr_scaffold="$pr_scaffold --pr $STANDING_PR"
    echo "error: PR-text mismatch for $ID: $PROJ_NAME is registered pr=$STANDING_PR but $source_brief records pr=$BRIEF_PR; keep the filled ## Captain's intent and ## Firstmate spec bodies, remove $source_brief, re-scaffold it with $pr_scaffold, then re-fill those two subsections, so the worker owns the PR text exactly when the project says so" >&2
    return 1
  fi
  # Merge authority on a Gerrit forge is refused rather than quietly dropped, on
  # the captain's decision of 2026-09-15: a Code-Review+2 is a positive
  # attributed claim that a named human approved, and firstmate must not
  # manufacture one.
  if [ "$STANDING_FORGE" = gerrit ] && [ "$YOLO" = on ]; then
    echo "error: --yolo on is refused for $ID: $PROJ_NAME is registered forge=gerrit, where yolo is inactive because a Code-Review+2 is a positive attributed claim that a named human approved and firstmate must not manufacture one (captain's decision 2026-09-15); spawn with --yolo off" >&2
    return 1
  fi
  # An external review tool uploads its own snapshot, so this task must never
  # push a task branch to the shared origin (docs/external-review-forge.md).
  # Every protection the captain configured is validated before any endpoint
  # exists, so a worker never launches without it.
  if [ "$STANDING_FORGE" = external ]; then
    if [ "$YOLO" = on ]; then
      echo "error: --yolo on is refused for $ID: $PROJ_NAME is registered forge=external, where firstmate can neither observe nor perform the review tool's approval or merge; spawn with --yolo off" >&2
      return 1
    fi
    fm_external_review_adapter_body "$CONFIG" >/dev/null || return 1
    fm_external_review_backup "$CONFIG" || return 1
    EXTERNAL_REVIEW=1
    EXTERNAL_BACKUP_REMOTE=$FM_REVIEW_BACKUP_REMOTE
    EXTERNAL_BACKUP_PREFIX=$FM_REVIEW_BACKUP_PREFIX
    if [ -n "$EXTERNAL_BACKUP_REMOTE" ]; then
      fm_external_review_prefix_disjoint "$EXTERNAL_BACKUP_PREFIX" "$(fm_ship_branch_prefix "$BRANCH" "$ID")" || return 1
      backup_urls=$(fm_external_review_remote_urls "$PROJ_ABS" "$EXTERNAL_BACKUP_REMOTE")
      if [ -z "$backup_urls" ]; then
        echo "error: $ID cannot launch: config/external-review-backup names the remote $EXTERNAL_BACKUP_REMOTE, which $PROJ_ABS does not have; add it with git remote add, or remove the file to ship without a backup" >&2
        return 1
      fi
      shared_urls=$(fm_external_review_remote_urls "$PROJ_ABS" origin)
      if [ -n "$shared_urls" ] && printf '%s\n' "$backup_urls" | grep -Fqx -f <(printf '%s\n' "$shared_urls"); then
        echo "error: $ID cannot launch: the backup remote $EXTERNAL_BACKUP_REMOTE points at the project's shared origin; a durable copy must go to storage only the captain controls" >&2
        return 1
      fi
    fi
  fi
  # Self-repository publication gate (bin/fm-role-lib.sh): a ship task whose
  # project is firstmate's own repository may launch a publishing contract only
  # under an explicit grant - this home's maintainer scope in
  # config/firstmate-role, or this one task's recorded upstream consent. Every
  # other project passes through unchanged; local-only publishes nothing and
  # never reaches this gate.
  if [ "$MODE" != local-only ]; then
    gate_rc=0
    fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$PROJ_ABS" "$FM_ROOT" "$UPSTREAM_CONSENT" || gate_rc=$?
    case $gate_rc in
    0 | 2) ;;
    *)
      echo "error: spawn refused for $ID: $FM_ROLE_PUB_DENIAL" >&2
      echo "error: to let this home publish to ${FM_ROLE_PUB_TARGET:-that repository}, write 'maintainer ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>}' into $CONFIG/firstmate-role (docs/configuration.md \"Firstmate role\"), or pass --upstream-consent ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>} for this one task with the captain's explicit approval" >&2
      return 1
      ;;
    esac
  fi
  return 0
}

# A secondmate reads its home's charter, or else its task brief. Sets BRIEF.
fm_spawn_secondmate_brief_select() { # <secondmate-home>
  if [ -f "$1/data/charter.md" ]; then
    BRIEF="$1/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
}

fm_spawn_brief_present_admit() {
  [ -f "$BRIEF" ] && return 0
  echo "error: task $ID has no brief at inaccessible data path $BRIEF" >&2
  return 1
}

# The shared Treehouse project lock serializes this project's slot
# allocation and return. A secondmate takes none; Orca takes it only when
# project capacity is declared.
fm_spawn_project_lock_applies() {
  [ "$KIND" != secondmate ] && { [ "$BACKEND" != orca ] || [ -n "${SPAWN_PROJECT_CAPACITY_ANY:-}" ]; }
}

# Sets SPAWN_TREEHOUSE_PROJECT_LOCK.
fm_spawn_project_lock_resolve() { # <project-dir>
  SPAWN_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$1") && return 0
  echo "error: could not resolve the shared Treehouse project lock for $1" >&2
  return 1
}

fm_spawn_project_lock_busy() { # <project-dir>
  if [ "$RELAUNCH_FROM_RELEASED" = 1 ]; then
    echo "deferred: another Treehouse slot allocation or return is in progress for $1; the released copy of $ID was not recreated and nothing changed" >&2
  elif [ "$BACKEND" = orca ]; then
    echo "error: another spawn or cleanup holds the shared project lock for $1; refusing to race its capacity admission" >&2
  else
    echo "error: another Treehouse slot allocation or return is in progress for $1; refusing to race it" >&2
  fi
  return 75
}

# Read-only: refuses when the project lock could not be taken now, because
# another spawn or cleanup holds it or is reclaiming it.
fm_spawn_project_lock_admit() { # <project-dir>
  fm_spawn_project_lock_applies || return 0
  fm_spawn_project_lock_resolve "$1" || return 1
  fm_lock_acquire_check "$SPAWN_TREEHOUSE_PROJECT_LOCK" && return 0
  fm_spawn_project_lock_busy "$1"
}

# Every retained copy recorded in this project's pool must be claimed by one
# task record; spawn then holds them, while check mode only refuses.
fm_spawn_retained_copies_admit() { # [check]
  [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] || return 0
  fm_treehouse_protect_recorded_copies "$STATE" "$PROJ_ABS" "${1:-}"
}

fm_spawn_backlog_close_admit() {
  [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ] || return 0
  echo "error: task $ID has a pending authoritative backlog close at $STATE/$ID.backlog-close; finish or repair that close before dispatching a new worker" >&2
  return 1
}

fm_spawn_backlog_admit() {
  # shellcheck disable=SC2034 # Output context consumed by spawn at publication.
  BACKLOG_TRANSITION=0
  BACKLOG_ROW_STATE=
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
    # shellcheck disable=SC2034 # Output context consumed by spawn at publication.
    BACKLOG_TRANSITION=1
    if fm_backlog_row_probe "$DATA" "$ID"; then
      BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
    elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; add it first (bin/fm-tasks-axi.sh add $ID '<title>' --kind $KIND) and re-run" >&2
      return 1
    else
      echo "error: task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)" >&2
      return 75
    fi
    spawn_preflight_actor=$(fm_lease_actor) || return "$FM_LEASE_REFUSE_EXIT"
    if [ "$RELAUNCH" -ne 1 ] && [ "$spawn_preflight_actor" = branch ] && fm_lease_away_relocated; then
      if [ "$BACKLOG_ROW_STATE" != "queued no no" ]; then
        echo "error: spawn refused - the supervision branch under the away-posture record may dispatch only queued unblocked work (already queued, or filed by the branch from the captain's away words); task $ID has no dispatchable backlog item in this home" >&2
        [ "${BACKLOG_ROW_STATE%% *}" != queued ] || return 75
        return 1
      fi
    elif [ "$RELAUNCH_FROM_RELEASED" = 1 ] && released_backlog_hold_is_teardown_own; then
      # Lifted only at the commit point below, once the worker is launched, so
      # every refusal before then leaves the item held exactly as teardown left it.
      # shellcheck disable=SC2034 # Spawn lifts the released-copy hold at commit.
      RELEASED_LIFT_HOLD=1
    elif ! fm_backlog_row_dispatchable "$BACKLOG_ROW_STATE"; then
      echo "error: this home's backlog item $ID is not dispatchable in state $BACKLOG_ROW_STATE; refusing before creating its endpoint or local copy" >&2
      [ "$RELAUNCH" -ne 0 ] || [ "${BACKLOG_ROW_STATE%% *}" != queued ] || return 75
      return 1
    fi
  else
    BACKLOG_GATE_STATUS=$?
    if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 1
    fi
  fi
  return 0
}

resolve_directory_input() {
  local name=$1 path=$2 resolved raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: $name directory contains an invalid control byte" >&2
    return 1
  fi
  case "$path" in
  /*)
    printf '%s\n' "$path"
    return 0
    ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

resolve_pi_executable() {
  local candidate dir
  candidate=$(type -P -- "$1" 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
  /*) printf '%s\n' "$candidate" ;;
  *)
    dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$dir" "$(basename "$candidate")"
    ;;
  esac
}

# Pi's CLI surface is version-dependent, so probe the resolved executable's help
# before composing the optional regular-TUI flag. An absent or inconclusive probe
# omits the flag so older Pi versions can still spawn.
pi_supports_tui_mode() {
  local executable=$1 help
  help=$("$executable" --help 2>&1) || return 1
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--tui-mode([[:space:]=]|$)'
}

# Same help-probe shape as pi_supports_tui_mode for the session-scoped project
# trust flag. A seeded secondmate home carries tracked .pi/extensions that gate
# Pi behind "Trust project folder?" on first launch; --approve trusts that
# launch cwd for the run without rewriting ~/.pi/agent/trust.json.
pi_supports_approve() {
  local executable=$1 help
  help=$("$executable" --help 2>&1) || return 1
  # Pi prints "--approve, -a"; allow comma (and any non-token char) after the name.
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--approve([^[:alnum:]_-]|$)'
}

# omp pre-launch model validation. `omp models --json` (omp 18.1.11) prints
# {"models":[{"provider","id","selector":"<provider>/<id>",...}]} for built-in and
# auto-discovered providers only; it never lists a provider an extension
# registers at runtime (claude-bridge is the verified example), so the check is
# scoped exactly to what the listing can prove: a <provider>/<id> whose provider
# IS listed must be listed too, a provider the listing does not know passes
# through with a notice, a bare fuzzy pattern is omp's own matcher's job, and an
# unreadable listing establishes nothing (harness-adapters model-and-effort.md).
omp_model_validate() { # <omp-bin> <model> [<profile>]
  local bin=$1 model=$2 profile=${3:-} provider listing providers
  local -a profile_args=()
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$model" in */*) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  # A pinned profile has its own provider logins, so list its catalog.
  [ -z "$profile" ] || profile_args=(--profile "$profile")
  listing=$(OMP_SKIP_SETUP=1 "$bin" "${profile_args[@]+"${profile_args[@]}"}" models --json 2>/dev/null) || return 0
  providers=$(printf '%s' "$listing" | jq -r '.models[]?.provider // empty' 2>/dev/null | sort -u) || return 0
  [ -n "$providers" ] || return 0
  provider=${model%%/*}
  if ! printf '%s\n' "$providers" | grep -qxF -- "$provider"; then
    echo "notice: omp provider '$provider' is not in 'omp models --json' (extension-registered providers are never listed); launching '$model' unvalidated" >&2
    return 0
  fi
  if printf '%s' "$listing" | jq -e --arg m "$model" '.models[]? | select(.selector == $m)' >/dev/null 2>&1; then
    return 0
  fi
  echo "error: omp model '$model' is not listed by 'omp models --json' although provider '$provider' is; choose a listed <provider>/<id> or omit --model" >&2
  return 1
}

# agy pre-launch model validation. `agy models` (agy 1.2.0) prints one model per
# line as "<id>\t<label>" for the account's catalog only; model ids are bare
# (gemini-3.8-flash-high), never provider-prefixed. A requested model absent
# from a reachable listing is concrete unsupported evidence and refuses the
# spawn, so a stale id (the unlisted bare gemini-3.8-flash) fails loudly here
# instead of wedging a worker pane. The listing is a remote fetch that needs
# network and a signed-in account, so the probe runs under the shared hard
# bound (bin/fm-timeout-lib.sh) with stdin detached: a stalled fetch or a
# sign-in prompt can never block the spawn before any pane exists. An
# unreachable listing establishes nothing (harness-adapters
# model-and-effort.md) and launches unvalidated with a notice.
agy_model_validate() {  # <agy-bin> <model>
  local bin=$1 model=$2 listing rc=0 bound=${FM_AGY_MODELS_TIMEOUT:-15}
  case "$bound" in ''|*[!0-9]*|0*) bound=15 ;; esac
  [ -n "$model" ] && [ "$model" != default ] || return 0
  listing=$(fm_run_timed "$bound" "$bin" models 2>/dev/null < /dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$listing" ]; then
    if [ "$rc" -eq 124 ]; then
      echo "notice: 'agy models' did not answer within ${bound}s; launching with --model '$model' unvalidated" >&2
    else
      echo "notice: 'agy models' listing is unreachable (exit $rc); launching with --model '$model' unvalidated" >&2
    fi
    return 0
  fi
  if printf '%s\n' "$listing" | awk '{print $1}' | grep -qxF -- "$model"; then
    return 0
  fi
  echo "error: agy model '$model' is not listed by 'agy models'; choose a listed id or omit --model" >&2
  return 1
}

# kiro pre-launch model validation. `kiro-cli chat --agent-engine v2
# --list-models -f json` (kiro-cli 2.21.4) prints
# {"models":[{"model_id":"<id>",...}],"default_model":"auto"} for the account's
# catalog; model ids are bare (claude-opus-5, auto), never provider-prefixed. A
# requested model absent from a reachable listing is concrete unsupported
# evidence and refuses the spawn, so a stale id fails loudly here instead of
# wedging a worker pane. The listing is a remote fetch that needs network and a
# signed-in account, so the probe runs under the shared hard bound
# (bin/fm-timeout-lib.sh) with stdin detached: a stalled fetch or a sign-in
# prompt can never block the spawn before any pane exists. model_ids are read
# with grep/sed rather than jq so the check has no extra dependency. An
# unreachable listing establishes nothing (harness-adapters model-and-effort.md)
# and launches unvalidated with a notice. The field pattern tolerates whitespace
# around the JSON colon so a pretty-printed listing still yields model ids
# instead of refusing every requested model. A listing that yields no model_id at
# all - a renamed field, or an empty catalog - also establishes nothing about
# whether the model exists, so it takes the same unvalidated-launch notice; only
# a listing that parses and omits the requested id is unsupported evidence.
kiro_model_validate() {  # <kiro-bin> <model>
  local bin=$1 model=$2 listing ids rc=0 bound=${FM_KIRO_MODELS_TIMEOUT:-15}
  case "$bound" in ''|*[!0-9]*|0*) bound=15 ;; esac
  [ -n "$model" ] && [ "$model" != default ] || return 0
  listing=$(fm_run_timed "$bound" "$bin" chat --agent-engine v2 --list-models -f json 2>/dev/null < /dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$listing" ]; then
    if [ "$rc" -eq 124 ]; then
      echo "notice: 'kiro-cli --list-models' did not answer within ${bound}s; launching with --model '$model' unvalidated" >&2
    else
      echo "notice: 'kiro-cli --list-models' listing is unreachable (exit $rc); launching with --model '$model' unvalidated" >&2
    fi
    return 0
  fi
  ids=$(printf '%s' "$listing" | grep -oE '"model_id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed 's/.*:[[:space:]]*"//;s/"$//')
  if [ -z "$ids" ]; then
    echo "notice: 'kiro-cli --list-models' listing carries no model_id; launching with --model '$model' unvalidated" >&2
    return 0
  fi
  if printf '%s\n' "$ids" | grep -qxF -- "$model"; then
    return 0
  fi
  echo "error: kiro model '$model' is not listed by 'kiro-cli --list-models'; choose a listed model_id or omit --model" >&2
  return 1
}

# kiro's hook commands are single-token absolute paths, so a hook path carrying
# whitespace or a shell-special character cannot be delivered as one token under
# both interpretations - a shell splits or expands it, an argv split does not,
# and no quoting fixes both. kiro has no second state source, so the seeded
# busy record would never clear and the supervisor would read the worker as
# provably working forever. Refuse alongside the model check, before any
# worktree or pane exists, and name the path. The physical resolution is what
# gets embedded, so that is what is checked; an unresolvable state dir falls
# back to the configured string.
kiro_hook_path_validate() {  # <state-dir> <id>
  local state=$1 id=$2 real
  real=$(cd "$state" 2>/dev/null && pwd -P) || real=$state
  [ -n "$real" ] || real=$state
  case "$real/$id.kiro-home" in
    *[[:space:]\'\"\\\$\`\;\&\|\<\>\(\)\*\?\[\]\{\}\!]*)
      echo "error: kiro hook scripts would live under '$real/$id.kiro-home', whose path contains whitespace or a shell-special character; kiro hook commands must be a single unquoted token, so point FM_HOME or FM_STATE_OVERRIDE at a path free of both" >&2
      return 1 ;;
  esac
  return 0
}

resolve_kimi_binary() {
  local candidate dir fallback
  candidate=$(command -v kimi 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  fallback="${HOME:-}/.kimi-code/bin/kimi"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: kimi executable not found; searched PATH for 'kimi' and fallback '$fallback'" >&2
  return 1
}

resolve_muse_binary() {
  local candidate dir
  candidate=$(command -v muse 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  echo "error: muse executable not found on PATH; install Muse Code or select a different verified harness" >&2
  return 1
}

resolve_rovo_binary() {
  local candidate dir fallback
  candidate=$(command -v rovo 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  fallback="${HOME:-}/.local/bin/rovo"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: rovo executable not found; searched PATH for 'rovo' and fallback '$fallback'" >&2
  return 1
}

# muse_credential_present: 0 when a launched muse pane can reach its provider
# without an interactive login. muse offers exactly two credential paths
# (verified, muse 0.1.0-R708.1): the META_API_KEY environment variable, which
# always takes priority, and a stored credential written by `muse auth set` or
# `muse login` into <config>/muse/auth.json. This is a PREFLIGHT rather than a
# rendered-screen check because an unauthenticated pane does not exit - it sits
# on an OAuth device-code prompt ("Sign in at this page ... Waiting for
# approval...") waiting for a human who is not there, which would look to
# supervision like a wedged worker rather than a missing credential.
muse_worker_meta_api_key_present() {
  local session worker_env
  if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
    case $'\n'"$LAUNCH_ENV_NAMES"$'\n' in
    *$'\nMETA_API_KEY\n'*) ;;
    *) return 1 ;;
    esac
  fi
  [ "$BACKEND" = tmux ] || return 1
  if [ -n "${TMUX:-}" ]; then
    fm_backend_source tmux >/dev/null 2>&1 || return 1
    session=$(fm_backend_tmux_own_session 2>/dev/null) || return 1
  else
    tmux has-session -t firstmate 2>/dev/null || return 1
    session=firstmate
  fi
  worker_env=$(tmux show-environment -t "$session" META_API_KEY 2>/dev/null) || return 1
  case "$worker_env" in
  META_API_KEY=?*) return 0 ;;
  esac
  return 1
}

muse_credential_present() {
  local auth=$1
  [ -s "$auth" ] || muse_worker_meta_api_key_present
}

fm_spawn_codex_launch_gate_supported() {
  case "$BACKEND" in tmux|herdr|zellij|cmux|orca|paseo) return 0 ;; *) return 1 ;; esac
}

fm_spawn_codex_positional_brief_probe() {
  ! fm_spawn_codex_launch_gate_supported || [ "${FM_CODEX_TYPED_LAUNCH:-0}" != 1 ]
}


fm_spawn_launch_env_admit() {
  if ! LAUNCH_ENV_ENABLED=$(fm_config_source_present "$CONFIG/launch-env-allowlist"); then
    return 1
  fi
  LAUNCH_ENV_NAMES=
  if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
    if [ ! -f "$CONFIG/launch-env-allowlist" ] || [ ! -r "$CONFIG/launch-env-allowlist" ]; then
      echo "error: config/launch-env-allowlist must be a readable regular file" >&2
      return 1
    fi
    if ! LAUNCH_ENV_NAMES=$(jq -Rrs '
      split("\n") | map(select(. != "" and (startswith("#") | not))) |
      if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
      else error("expected environment names only") end
    ' "$CONFIG/launch-env-allowlist" 2>/dev/null); then
      echo "error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments" >&2
      return 1
    fi
  fi
    return 0
}

# shellcheck disable=SC2034,SC2153
fm_spawn_adapter_admit() {
  # muse, gemini, devin, commandcode, polytoken, cortex, and kiro are verified as CREWMATE/SCOUT adapters only. A secondmate is
  # a firstmate instance, so it needs a primary supervision protocol.
  # gemini has none: docs/supervision-protocols/ carries no gemini wake protocol
  # and this task verified only crewmate-side launch, busy state, interrupt, and
  # exit, so a gemini secondmate is refused rather than stood up on an unverified
  # supervision path. muse has none either, and its
  # Claude-compatible hook dialect explicitly rejects the model-reawakening and
  # asyncRewake handlers that firstmate's primary turn-end supervision is built on
  # (muse 0.1.0-R708.1). Refusing here keeps that gap loud instead of standing up a
  # secondmate whose supervision cycle could never be armed.
  # devin has none either: only its worker lifecycle hooks are verified, and
  # docs/supervision-protocols/ carries no devin wake protocol (devin 3000.11.1).
  # commandcode has none either: only its worker busy mod is verified, and
  # docs/supervision-protocols/ carries no Command Code wake protocol (1.74.1).
  # polytoken has none either: only the crewmate/scout lifecycle is verified;
  # docs/supervision-protocols/ carries no polytoken primary wake protocol.
  # cortex has none either: only its worker lifecycle hooks are verified, and
  # docs/supervision-protocols/ carries no cortex wake protocol (cortex 1.1.104).
  # kiro has none either: this task verified only crewmate-side launch, busy state,
  # interrupt, exit, and resume on the V2 engine, and docs/supervision-protocols/
  # carries no kiro wake protocol (kiro-cli 2.21.4).
  if [ "$KIND" = secondmate ] && { [ "$HARNESS" = muse ] || [ "$HARNESS" = gemini ] || [ "$HARNESS" = devin ] || [ "$HARNESS" = commandcode ] || [ "$HARNESS" = polytoken ] || [ "$HARNESS" = cortex ] || [ "$HARNESS" = kiro ]; }; then
    echo "error: $HARNESS is a verified crewmate/scout adapter only and cannot run a secondmate; it has no primary supervision protocol. Select a harness verified for secondmates." >&2
    return 1
  fi

  # rovo carries the same primary-supervision gap as muse: no turn-end hook, no
  # verified primary integration, so a secondmate (a firstmate instance that must
  # itself act as a primary) could never be supervised. Refuse loudly rather than
  # standing one up with no way to arm its watch cycle.
  if [ "$KIND" = secondmate ] && [ "$HARNESS" = rovo ]; then
    echo "error: rovo is a verified crewmate/scout adapter only and cannot run a secondmate; it has no primary supervision protocol. Select a harness verified for secondmates." >&2
    return 1
  fi

  # Command Code's idle placeholder reads empty only with a Command Code pane
  # identity, which tmux and Herdr supply and zellij, cmux, orca, paseo, and tern do not, so
  # there the composer would never read empty and steering would stall.
  if [ "$HARNESS" = commandcode ] && [ "$BACKEND" != tmux ] && [ "$BACKEND" != herdr ]; then
    echo "error: commandcode is verified on the tmux and herdr backends only; backend=$BACKEND cannot prove its composer empty. Select backend tmux or herdr." >&2
    return 1
  fi

  # Cortex's titled composer box is proven only with a Cortex pane identity,
  # which tmux and Herdr supply and zellij, cmux, orca, paseo, rex, and t3code do not, so there the
  # composer would never read empty and steering would stall.
  if [ "$HARNESS" = cortex ] && [ "$BACKEND" != tmux ] && [ "$BACKEND" != herdr ]; then
    echo "error: cortex is verified on the tmux and herdr backends only; backend=$BACKEND cannot prove its composer empty. Select backend tmux or herdr." >&2
    return 1
  fi

  EXCLUDE_TOOLS=
  if [ "$KIND" != secondmate ]; then
    EXCLUDE_TOOLS=$(fm_exclude_tools_check "$HARNESS" "$RAW_LAUNCH" "$CONFIG") || return 1
  fi

  case "$HARNESS" in
  devin)
    DEVIN_BIN=$(command -v devin) || {
      echo "error: devin executable not found on PATH" >&2
      return 1
    }
    ;;
  commandcode)
    COMMANDCODE_BIN=$(command -v commandcode) || {
      echo "error: commandcode executable not found on PATH" >&2
      return 1
    }
    ;;
  cortex)
    CORTEX_BIN=$(command -v cortex) || {
      echo "error: cortex executable not found on PATH" >&2
      return 1
    }
    ;;
  pi | pi-signed)
    PI_BIN=$(resolve_pi_executable "$HARNESS") || {
      echo "error: $HARNESS executable not found on PATH; install it or select a different verified harness" >&2
      return 1
    }
    ;;
  cursor)
    # `cursor` is not the CLI name, and the legacy alias `agent` is far too
    # generic to launch on its name alone, so resolution runs through the
    # verified owner rather than a bare command lookup. Refusing here keeps a
    # missing install a loud spawn refusal instead of a pane that dies with a
    # command-not-found the supervisor would read as a wedged worker.
    CURSOR_BIN=$(fm_cursor_resolve_binary) || return 1
    if [ -n "$MODEL" ] && [ "$MODEL" != default ]; then
      if CURSOR_MODELS=$(fm_cursor_list_models "$CURSOR_BIN"); then
        if ! printf '%s\n' "$CURSOR_MODELS" | fm_cursor_catalog_has_model "$MODEL"; then
          echo "error: Cursor model '$MODEL' is not available from '$CURSOR_BIN --list-models'; choose an id listed by that command or omit --model" >&2
          return 1
        fi
      fi
    fi
    ;;
  omp)
    OMP_BIN=$(resolve_pi_executable omp) || {
      echo "error: omp executable not found on PATH; install Oh My Pi or select a different verified harness" >&2
      return 1
    }
    OMP_WORKER_CFG="$FM_ROOT/.omp/fm-worker-overlay.yml"
    [ -f "$OMP_WORKER_CFG" ] || {
      echo "error: omp worker posture overlay missing at $OMP_WORKER_CFG; a worker launched without it can park on the captain's own approval or plan-mode settings" >&2
      return 1
    }
    ;;
  agy)
    AGY_BIN=$(resolve_pi_executable agy) || {
      echo "error: agy executable not found on PATH; install Antigravity CLI or select a different verified harness" >&2
      return 1
    }
    ;;
  kiro)
    KIRO_BIN=$(resolve_pi_executable kiro-cli) || {
      echo "error: kiro-cli executable not found on PATH; install Kiro CLI or select a different verified harness" >&2
      return 1
    }
    ;;
  polytoken)
    POLYTOKEN_BIN=$(fm_polytoken_binary) || {
      echo "error: polytoken executable not found; install Polytoken CLI or select a different verified harness" >&2
      return 1
    }
    ;;
  esac

  fm_backend_validate_harness "$BACKEND" "$HARNESS" || return 1
  # Ultra is an explicit native capability, never a Pi thinking-level alias.
  # Validate the fully resolved profile before worktree or endpoint provisioning.
  if [ "$EFFORT" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$HARNESS" "$MODEL" "$EFFORT" || return 1
    [ "$RAW_LAUNCH" = 0 ] || {
      echo "error: --effort ultra requires the canonical --harness pi or pi-signed launch so its native flag cannot be omitted" >&2
      return 1
    }
  fi
  # Per-secondmate omp profile pin (header above): resolved before any endpoint,
  # worktree, or record exists, and before the catalog check that must read the
  # same profile. A ship or scout passes no mate, so it never reads a pin.
  OMP_PROFILE_MATE=
  [ "$KIND" != secondmate ] || OMP_PROFILE_MATE=$ID
  OMP_PROFILE_RAW=
  [ "$RAW_LAUNCH" = 0 ] || OMP_PROFILE_RAW=$ARG3
  OMP_PROFILE_PIN=$(fm_omp_profile_select "$HARNESS" "$CONFIG" "$OMP_PROFILE_MATE" "$OMP_PROFILE_RAW") || return 1
  if [ "$HARNESS" = omp ]; then
    omp_model_validate "$OMP_BIN" "$MODEL" "$OMP_PROFILE_PIN" || return 1
  fi
  if [ "$HARNESS" = agy ]; then
    agy_model_validate "$AGY_BIN" "$MODEL" || return 1
  fi
  # polytoken's model validation composes firstmate's model and effort axes into
  # the launch model reference (bin/fm-polytoken-lib.sh owns the reasoning): the
  # base model must be concrete and listed, and effort maps to the nearest
  # compatible selectable `<model>(<effort>)` reference. Resolved
  # before the busy wiring arms, so the generated launch command carries the
  # composed reference and task metadata keeps the separate axes.
  if [ "$HARNESS" = polytoken ] && [ "$RAW_LAUNCH" -eq 0 ]; then
    POLYTOKEN_MODEL_REF=$(fm_polytoken_launch_ref "$POLYTOKEN_BIN" "$MODEL" "$EFFORT") || return 1
  elif [ "$HARNESS" = polytoken ]; then
    POLYTOKEN_MODEL_REF=$(fm_polytoken_model_ref "$POLYTOKEN_BIN" "$MODEL" "$EFFORT") || return 1
  fi
  if [ "$HARNESS" = kiro ]; then
    kiro_model_validate "$KIRO_BIN" "$MODEL" || return 1
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      kiro_hook_path_validate "$STATE" "$ID" || return 1
    fi
  fi

  case "$RAW_LAUNCH:$HARNESS:$LAUNCH" in
  0:muse:*|*__MUSEBIN__*)
    MUSE_BIN=$(resolve_muse_binary) || return 1
    MUSE_CONFIG_HOME=$(resolve_directory_input XDG_CONFIG_HOME "${XDG_CONFIG_HOME:-${HOME:-}/.config}") || return 1
    MUSE_DATA_HOME=$(resolve_directory_input XDG_DATA_HOME "${XDG_DATA_HOME:-${HOME:-}/.local/share}") || return 1
    MUSE_AUTH_FILE="$MUSE_CONFIG_HOME/muse/auth.json"
    if ! muse_credential_present "$MUSE_AUTH_FILE"; then
      if [ -n "${META_API_KEY:-}" ]; then
        echo "error: muse has no worker-reachable credential; META_API_KEY is set for fm-spawn but cannot be proven present in the $BACKEND worker environment. Store the fleet credential at '$MUSE_AUTH_FILE' with 'muse login' or 'muse auth set --api-key-stdin'. The secret will not be copied into the launch command." >&2
      else
        echo "error: muse has no worker-reachable credential; META_API_KEY cannot be proven present in the $BACKEND worker environment and '$MUSE_AUTH_FILE' is absent or empty. Store the fleet credential with 'muse login' or 'muse auth set --api-key-stdin'." >&2
      fi
      return 1
    fi
    ;;
  esac
  case "$RAW_LAUNCH:$HARNESS:$LAUNCH" in
  0:kimi:*|*__KIMIBIN__*)
    KIMI_BIN=$(resolve_kimi_binary) || return 1
    if [ "$KIND" != secondmate ] && ! "$FM_ROOT/bin/fm-kimi-turnend-hook.sh" check; then
      echo "error: refusing Kimi spawn because the global turn-end hook could not be installed safely" >&2
      return 1
    fi
    fm_backend_visible_capture_supported "$BACKEND" || {
      echo "error: refusing Kimi spawn because backend '$BACKEND' has no verified viewport-bounded capture; Kimi 2.0.0 gates a fresh worktree on a trust dialog that can only be answered and confirmed cleared from a scrollback-free read of the live pane" >&2
      return 1
    }
    ;;
  esac
  # The codex typed-brief gates answer codex's own folder-trust and update
  # dialogs from the live pane, so a backend with no viewport-bounded capture
  # cannot prove a dialog cleared and the typed path is refused at preflight,
  # the same boundary the kimi gate draws. The default positional launch keeps
  # the brief on the launch command; its first-turn gate answers dialogs only
  # where the viewport is readable.

  if [ "$HARNESS" = codex ] && [ "$RAW_LAUNCH" -ne 1 ] \
    && ! fm_spawn_codex_positional_brief_probe; then
    fm_backend_visible_capture_supported "$BACKEND" || {
      echo "error: refusing codex spawn because backend '$BACKEND' has no verified viewport-bounded capture; codex gates a fresh worktree on a trust dialog whose clearing can only be proven from a scrollback-free read of the live pane" >&2
      return 1
    }
  fi

  case "$RAW_LAUNCH:$HARNESS:$LAUNCH" in
  0:rovo:*|*__ROVOBIN__*)
    ROVO_BIN=$(resolve_rovo_binary) || return 1
    ;;
  esac
  return 0
}
