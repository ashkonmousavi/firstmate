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

# Read-only checks of the per-task launch files a retained relaunch writes
# after the stop. Each owner's check mode runs the same validation as the
# write spawn performs: Devin hook config, polytoken config mirror, the Claude
# launch-brief operational inbox and Claude workspace trust.
fm_spawn_launch_files_admit() { # <state-real> <worktree> <project-or-mate-home>
  # shellcheck disable=SC2034 # record_directory is the owner's printf -v output.
  local state_real=$1 wt=$2 proj=$3 opstate record_directory
  local -a trust_args
  [ "$RAW_LAUNCH" = 0 ] || return 0
  case "$HARNESS" in
  devin)
    FM_KEEP_AI_TRAILERS="$KEEP_AI_TRAILERS" "$FM_ROOT/bin/fm-devin-config.sh" --check "$state_real" "$ID" prepare || return 1
    ;;
  polytoken)
    fm_polytoken_write_config "$(fm_polytoken_config_dir "$state_real" "$ID")" check || return 1
    ;;
  claude*)
    opstate=$STATE trust_args=("$wt" "$proj")
    if [ "$KIND" = secondmate ]; then
      opstate="$proj/state" trust_args=(--secondmate-home "$proj" "$ID")
    fi
    fm_operational_record_directory "$opstate" record_directory || {
      echo "error: task $ID's operational-inbox path cannot carry a launch doorbell" >&2
      return 1
    }
    "$FM_ROOT/bin/fm-claude-trust.sh" --check "${trust_args[@]}" >/dev/null || return 1
    ;;
  esac
  return 0
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
