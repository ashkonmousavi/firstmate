# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

FM_QUOTA_AXI_MIN=0.1.51
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-exclude-tools-lib.sh"

# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

# Candidate evaluation for the typed resolver (bin/fm-dispatch-resolve.sh) and
# the explicit-harness spawn gate below (fm_quota_gate_explicit).
# The resolver's through-reset gate stays resolver-only; the spawn gate applies
# its own fixed horizon instead.
# Prepend after FM_QUOTA_ROW_JQ:
#   quota_evaluate($q; $pmap; $profile)
#       one candidate's eligibility and quota evidence; $pmap is the
#       harness -> provider object fm_quota_provider_map prints. Adds
#       runway_class: through | short | exhausted | unknown over the
#       candidate's applicable rows. "short" is a known, established
#       projected_exhaustion row: its runway ends before its reset.
#   quota_runway_gate($cands)
#       applies the through-reset rule owned by docs/configuration.md,
#       "Typed dispatch resolution", marking refusals with runway_refused:
#       true and naming through-reset alternatives.
#   quota_rank_order($cands)
#       rankable eligible candidates by spendPriority, highest first, then
#       eligible unranked ones, then ineligible ones; the latter two groups
#       retain declared order.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_EVAL_JQ='
  def quota_rows($q; $p; $lane): (quota_row($q; $p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def quota_measured($q; $p; $lane):
    quota_row($q; $p; $lane) as $row |
    ($row != null and (["known", "partial"] | index($row.quotaSemantics.status)) != null);
  def quota_applicable($q; $p; $lane; $m):
    ($m | split("/") | last) as $bare |
    [quota_rows($q; $p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def quota_floor_state($q; $f; $p; $lane):
    if $f == null then "none"
    elif quota_row($q; $p; $lane) == null or (quota_measured($q; $p; $lane) | not) then "unknown"
    else [quota_rows($q; $p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def quota_evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null),
                 projectionConfidence: (.runway.projectionConfidence // null),
                 runwaySeconds: (.runway.usableRunwaySeconds // null),
                 exhaustsAt: (.runway.projectedExhaustedAt // null), spendPriority: (.selection.spendPriority // null)});
  def quota_runway_class($bounds):
    if ($bounds | length) == 0 then "unknown"
    elif any($bounds[]; .runway == "exhausted_now") then "exhausted"
    elif any($bounds[]; .status == "known" and .runway == "projected_exhaustion"
                        and .projectionConfidence == "established") then "short"
    elif all($bounds[]; .status == "known" and .runway == "through_reset") then "through"
    else "unknown" end;
  def quota_candidate_label($c): "\($c.profile.harness):\($c.profile.model // "-")";
  def quota_evaluate($q; $pmap; $c):
    ($c.provider // $pmap[$c.harness] // null) as $p | quota_lane($c.harness; $c.model) as $lane |
    if $p == null then {profile: $c, eligible: false, runway_class: "unknown", reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif quota_row($q; $p; $lane) == null then
      {profile: $c, provider: $p, eligible: true, unranked: true, runway_class: "unknown",
       reason: (if any($q.providers[]; .provider == $p)
                then "provider \($p) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                else "provider \($p) not in the quota snapshot" end)}
    else
      quota_applicable($q; $p; $lane; ($c.model // "")) as $rows |
      quota_evidence($rows) as $bounds |
      quota_floor_state($q; $c.floor; $p; $lane) as $profile_floor_state |
      quota_runway_class($bounds) as $runway_class |
      (if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([quota_rows($q; $p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (quota_measured($q; $p; $lane) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(quota_row($q; $p; $lane).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([quota_rows($q; $p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end) + {runway_class: $runway_class}
    end;
  def quota_through($cands):
    [$cands[] | select(.eligible and ((.unranked // false) | not) and .runway_class == "through")]
    | sort_by(-.spendPriority);
  def quota_runway_gate($cands):
    quota_through($cands) as $through |
    if ($through | length) == 0 then $cands
    else
      ($through | map("\(quota_candidate_label(.)) (spendPriority \(.spendPriority))") | join(", ")) as $names |
      $cands | map(
        if .runway_class == "short" or .runway_class == "exhausted" then
          .runway_class as $class |
          ((.bounds // []) | map(select(quota_runway_class([.]) == $class)) | first) as $row |
          # A candidate already ineligible keeps its own reason, with the
          # through-reset alternative appended.
          . + {eligible: false, unranked: false, runway_refused: true,
               reason: ((if .eligible
                        then "runway \($row.runway // .runway_class) at \($row.scope // "-")\(if $row.exhaustsAt then " ends \($row.exhaustsAt)" else "" end) before its reset"
                        else .reason end) + " while \($names) runs through its reset")}
        else . end)
    end;
  def quota_rank_order($cands):
    ([$cands[] | select(.eligible and ((.unranked // false) | not))] | sort_by(-.spendPriority))
    + [$cands[] | select(.eligible and (.unranked // false))]
    + [$cands[] | select(.eligible | not)];
'

# Explicit-harness spawn gate (bin/fm-spawn.sh, bin/fm-control.sh relaunch).
# docs/configuration.md "Crew dispatch profiles" owns the operator contract;
# this block owns the mechanics.
#   quota_gate_verdict($q; $c; $now)
#       refuse when an applicable row of the candidate's own provider row is
#       exhausted_now or at 0%, or when a known projected_exhaustion row ends
#       within FM_QUOTA_GATE_HORIZON_SECONDS of $now regardless of projection
#       confidence. The end is projectedExhaustedAt, else generatedAt plus
#       usableRunwaySeconds.
#   quota_gate_alternatives($q; $cands; $now; $kind; $backend; $remote)
#       the candidates whose own verdict is pass with a known spendPriority,
#       highest first.
FM_QUOTA_GATE_HORIZON_SECONDS=10800
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_GATE_JQ='
  def quota_gate_time($s):
    if ($s | type) == "string" then ($s | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
  def quota_gate_end($q; $b):
    (quota_gate_time($b.exhaustsAt)) as $at |
    if $at != null then $at
    elif ($b.runwaySeconds | type) == "number" and quota_gate_time($q.generatedAt) != null
    then quota_gate_time($q.generatedAt) + $b.runwaySeconds
    else null end;
  def quota_gate_hm($s): ($s | if . < 0 then 0 else . end | floor) as $t |
    "\($t / 3600 | floor)h\((($t % 3600) / 60) | floor)m";
  def quota_gate_verdict($q; $c; $now):
    ($c | del(.floor)) as $c |
    ($c.provider // null) as $p |
    if $c.quota_error then
      {verdict: "refuse", profile: $c, reason: $c.quota_error}
    elif $p == null then
      {verdict: "notice", profile: $c, reason: "harness \($c.harness) has no declared quota provider"}
    else
      quota_evaluate($q; {}; $c) as $e |
      ([($e.bounds // [])[] | select(.status == "known" and .runway == "projected_exhaustion")
        | . + {end: quota_gate_end($q; .)}]) as $proj |
      ([$proj[] | select(.end != null and (.end - $now) < ($ENV.FM_QUOTA_GATE_HORIZON_SECONDS | tonumber))]
        | sort_by(.end) | first) as $short |
      if $e.eligible == false then
        $e + {verdict: "refuse", reason: "provider \($p) \($e.reason)"}
      elif $short != null then
        $e + {verdict: "refuse", scope: $short.scope, pct: $short.pct,
              reason: "provider \($p) runway at \($short.scope) (\($short.pct // "-")% remaining) ends \($short.end | todate), \(quota_gate_hm($short.end - $now)) from now, within the \(quota_gate_hm($ENV.FM_QUOTA_GATE_HORIZON_SECONDS | tonumber)) spawn horizon"}
      elif any($proj[]; .end == null) then
        $e + {verdict: "notice", reason: "provider \($p) projects exhaustion at \([$proj[] | select(.end == null) | .scope] | join(", ")) with no end time"}
      elif ($e.unranked // false) then
        $e + {verdict: "notice"}
      else $e + {verdict: "pass"} end
    end;
  def quota_gate_launch_eligible($kind; $backend; $remote):
    ($kind != "secondmate" or
      (.harness as $h | ["muse", "gemini", "agy", "devin", "commandcode", "polytoken", "rovo"] | index($h) == null))
    and (.harness != "omp" or ($remote | not))
    and (.harness != "commandcode" or $backend == "tmux" or $backend == "herdr")
    and (.harness != "polytoken" or
      ((.model // "") != "" and .model != "default" and (.effort // "") != "" and .effort != "default"
       and (.model | test("[()]") | not)
       and (.model | startswith("@") or startswith("mg:") or startswith("modelgroup:") | not)));
  def quota_gate_alternatives($q; $cands; $now; $kind; $backend; $remote):
    [$cands[] | select(quota_gate_launch_eligible($kind; $backend; $remote))
     | quota_gate_verdict($q; .; $now)
     | select(.verdict == "pass" and (.spendPriority | type) == "number")]
    | sort_by(-.spendPriority);
'

# fm_quota_gate_snapshot <out-file>
# Writes one validated quota-axi --json snapshot. FM_QUOTA_SNAPSHOT_FILE, when
# set, names an already-captured snapshot to reuse instead of running
# quota-axi: the test seam. Control hands its verdict and evidence to its
# delegated launch instead of taking a second snapshot. FM_QUOTA_GATE_TIMEOUT
# bounds the live read (default 30 seconds). Fails, printing the cause, when
# no valid snapshot can be produced; callers treat that as disclosed uncertainty.
fm_quota_gate_snapshot() {
  local out=$1 src=${FM_QUOTA_SNAPSHOT_FILE:-}
  if [ -n "$src" ]; then
    [ -f "$src" ] && [ ! -L "$src" ] || { printf 'snapshot %s is not a regular file\n' "$src"; return 1; }
    cp -- "$src" "$out" 2>/dev/null || { printf 'snapshot %s is unreadable\n' "$src"; return 1; }
  else
    command -v quota-axi >/dev/null 2>&1 || { printf 'quota-axi is not installed\n'; return 1; }
    [ "$(type -t fm_run_timed)" = function ] || { printf 'no bounded runner for quota-axi\n'; return 1; }
    fm_run_timed "${FM_QUOTA_GATE_TIMEOUT:-30}" quota-axi --json >"$out" 2>/dev/null </dev/null \
      || { printf 'quota-axi --json failed or timed out\n'; return 1; }
  fi
  fm_quota_json_valid <"$out" || { printf 'quota-axi returned an invalid snapshot\n'; return 1; }
}

fm_quota_gate_account_eligible() {
  local harness=$1 model=$2 config=$3 mate=$4 selected pin providers provider
  selected=$(fm_worker_account_config "$harness" "$config" "$mate") || return 1
  pin=$(fm_worker_account_resolve "$harness" "$selected" "$selected/$(fm_worker_account_file "$harness")") || return 1
  if [ -z "$pin" ]; then
    [ "$selected" = "$config" ]
    return
  fi
  case "$harness" in
    pi|pi-signed)
      provider=$(fm_worker_account_pi_provider "$model") || return 1
      providers=${pin##*$'\t'}
      case " $providers " in *" $provider "*) ;; *) return 1 ;; esac
      ;;
  esac
}

fm_quota_gate_profile() {
  local profile=$1 snap=$2 profiles=$3 harness model family='' families
  harness=$(jq -r '.harness' <<<"$profile")
  model=$(jq -r '.model // ""' <<<"$profile")
  if [ "$harness" = omp ]; then
    family=$(fm_quota_provider_for_harness "$harness" "$model") || family=
  fi
  families=$(fm_quota_single_provider_table | jq -Rcn '[inputs | split(" ") | {key:.[0], value:.[1]}] | from_entries')
  jq -c --argjson profiles "$profiles" --argjson families "$families" --arg family "$family" \
    --slurpfile quota "$snap" "$FM_QUOTA_ROW_JQ"'
    . as $c | quota_lane(.harness; .model) as $lane |
    ([$profiles[] | select(.provider != null and .harness == $c.harness) |
      select((.model // "") == ($c.model // "") or ($lane != "" and quota_lane(.harness; .model) == $lane)) | .provider] | unique) as $declared |
    ([$quota[0].providers[] | select($lane != "" and .accountKey == $lane) | .provider] | unique) as $accounts |
    ([$families | to_entries[] | select($lane != "" and quota_lane(.key; "") == $lane) | .value] | unique) as $lanes |
    if .provider == null and ($declared|length) > 1 then
      . + {quota_error:"the configured account has conflicting quota family declarations"}
    else . + {provider:(.provider //
      (if ($declared|length) == 1 then $declared[0] else null end) // $families[.harness] //
      (if $family != "" then $family else null end) //
      (if ($accounts|length) == 1 then $accounts[0] else null end) //
      (if ($lanes|length) == 1 then $lanes[0] else null end))} end' <<<"$profile"
}

# fm_quota_gate_explicit <harness> <model> <rules-file> <snapshot-file> <kind> <backend> <config> [<mate-id>]
# Gates the caller model, one configured profile model, or harness-level quota.
# Alternatives are configured rule/default profiles, with their strings intact.
# Prints three lines: verdict, reason, and best alternative (or none).
fm_quota_gate_explicit() {
  local harness=$1 model=$2 rules=$3 snap=$4 kind=$5 backend=$6 config=$7 mate=${8:-}
  local cands requested out h profile resolved eligible='[]' remote=false
  if [ "$kind" = secondmate ] && [ "${FM_SKIP_SECONDMATE_SYNC:-0}" = 1 ] && [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" = 1 ]; then
    remote=true
  fi
  if [ "$(type -t fm_backend_visible_capture_supported)" != function ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"
  fi
  cands=$(fm_worker_account_profiles "$rules")
  requested=$(fm_worker_account_profile "$harness" "$model" "$cands")
  requested=$(fm_quota_gate_profile "$requested" "$snap" "$cands") || return 1
  while IFS= read -r profile; do
    h=$(jq -r '.harness' <<<"$profile")
    if [ "$h" = kimi ] || { [ "$h" = codex ] && [ "${FM_CODEX_TYPED_LAUNCH:-0}" = 1 ]; }; then
      fm_backend_visible_capture_supported "$backend" || continue
    fi
    if [ "$kind" != secondmate ]; then
      fm_exclude_tools_check "$h" 0 "$config" >/dev/null 2>&1 || continue
    fi
    fm_quota_gate_account_eligible "$h" "$(jq -r '.model // ""' <<<"$profile")" "$config" "$mate" >/dev/null 2>&1 || continue
    resolved=$(fm_quota_gate_profile "$profile" "$snap" "$cands") || continue
    eligible=$(jq -c --argjson profile "$resolved" '. + [$profile]' <<<"$eligible")
  done < <(jq -c --arg kind "$kind" --arg backend "$backend" --argjson remote "$remote" \
    "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ$FM_QUOTA_GATE_JQ"'.[] | select(quota_gate_launch_eligible($kind; $backend; $remote))' <<<"$cands")
  out=$(FM_QUOTA_GATE_HORIZON_SECONDS=$FM_QUOTA_GATE_HORIZON_SECONDS jq -r -n \
    --slurpfile quota "$snap" --argjson c "$requested" --argjson cands "$eligible" \
    --arg kind "$kind" --arg backend "$backend" --argjson remote "$remote" \
    "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ$FM_QUOTA_GATE_JQ"'
    def flat: tostring | gsub("[\t\r\n]"; " ");
    def best_line($best):
      $best | group_by(.provider) | map(
        "provider \(.[0].provider) (spendPriority \(.[0].spendPriority)): "
        + (map("--harness \(.profile.harness)" + (if (.profile.model // "") != "" then " --model \(.profile.model)" else "" end)
               + (if (.profile.effort // "") != "" then " --effort \(.profile.effort)" else "" end))
           | unique | join(", ")))
      | join("; ");
    ($quota[0]) as $q | now as $now |
    quota_gate_verdict($q; $c; $now) as $v |
    ($cands | map(select(.harness != $c.harness or (.model // "") != ($c.model // "")))) as $others |
    quota_gate_alternatives($q; $others; $now; $kind; $backend; $remote) as $alts |
    $v.verdict, (($v.reason // "ok") | flat),
    (if ($alts | length) == 0 then "none"
     else (best_line([$alts[] | select(.spendPriority == $alts[0].spendPriority)]) | flat) end)' 2>/dev/null) || {
    printf 'refuse\nthe quota check could not evaluate %s\nnone\n' "$harness"
    return 1
  }
  printf '%s\n' "$out"
  [ "$(printf '%s\n' "$out" | head -1)" != refuse ]
}

# fm_quota_gate_run <harness> <model> <rules-file> <override-reason> <who> <kind> <backend> <config> [<mate-id>] [<codex-selected-root>] [<launch-cwd>]
# The one caller-facing gate step. Takes the snapshot, gates, and prints the
# outcome on stderr. Sets FM_QUOTA_GATE_EVIDENCE to the one-line verdict and
# FM_QUOTA_GATE_SNAPSHOT_PATH to the snapshot it read (empty when none), so a
# caller can record or hand on exactly what it decided from. Returns 1 when
# the gate refuses and <override-reason> is empty; an override proceeds with
# a notice naming it.
# shellcheck disable=SC2034  # FM_QUOTA_GATE_* results are read by the sourcing callers
fm_quota_gate_run() {
  local harness=$1 model=$2 rules=$3 override=$4 who=$5 kind=$6 backend=$7 config=$8 mate=${9:-}
  local snap
  FM_QUOTA_GATE_EVIDENCE=
  FM_QUOTA_GATE_SNAPSHOT_PATH=
  FM_QUOTA_CODEX_ROOT=
  FM_QUOTA_CODEX_MODEL=
  if [ "$harness" = codex ] && { [ -e "$config/codex-accounts" ] || [ -L "$config/codex-accounts" ]; }; then
    # Gate the folder selection, never the unrelated ambient ~/.codex lane.
    # Reuse the ordinary gate below with an exact profile-only snapshot; other
    # providers remain unknown in this reading rather than borrowing a lane.
    snap=$(mktemp "${TMPDIR:-/tmp}/fm-codex-quota-gate.XXXXXX") || return 1
    local -a codex_args=()
    [ -z "${10:-}" ] || codex_args=(--folder "${10}")
    [ -z "${11:-}" ] || codex_args+=(--cwd "${11}")
    if ! python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-codex-accounts.py" quota \
      --config "$config/codex-accounts" --gate --model "$model" "${codex_args[@]}" >"$snap"; then
      rm -f "$snap"
      return 1
    fi
    FM_QUOTA_CODEX_ROOT=$(jq -er '.selectedRoot' "$snap") || { rm -f "$snap"; return 1; }
    FM_QUOTA_CODEX_MODEL=$(jq -er '.selectedModel' "$snap") || { rm -f "$snap"; return 1; }
    local FM_QUOTA_SNAPSHOT_FILE=$snap
    fm_quota_gate_run_folder "$harness" "$FM_QUOTA_CODEX_MODEL" "$rules" "$override" "$who" "$kind" "$backend" "$config" "$mate"
    local result=$?
    rm -f "$snap"
    return "$result"
  fi
  fm_quota_gate_run_folder "$@"
}

# Shared gate mechanics; the caller may provide an exact Codex folder snapshot.
# shellcheck disable=SC2034  # FM_QUOTA_GATE_* outputs are read by sourcing callers
fm_quota_gate_run_folder() {
  local harness=$1 model=$2 rules=$3 override=$4 who=$5 kind=$6 backend=$7 config=$8 mate=${9:-}
  local snap cause verdict reason alt out
  snap=$(mktemp "${TMPDIR:-/tmp}/fm-quota-gate.XXXXXX") || {
    echo "notice: $who could not stage a quota reading for $harness; launching without the quota check" >&2
    return 0
  }
  if ! cause=$(fm_quota_gate_snapshot "$snap"); then
    rm -f "$snap"
    FM_QUOTA_GATE_EVIDENCE="unchecked: $cause"
    echo "notice: $who launches $harness without the quota check: $cause" >&2
    return 0
  fi
  FM_QUOTA_GATE_SNAPSHOT_PATH=$snap
  out=$(fm_quota_gate_explicit "$harness" "$model" "$rules" "$snap" "$kind" "$backend" "$config" "$mate")
  verdict=$(printf '%s\n' "$out" | sed -n 1p)
  reason=$(printf '%s\n' "$out" | sed -n 2p)
  alt=$(printf '%s\n' "$out" | sed -n 3p)
  FM_QUOTA_GATE_EVIDENCE="$verdict: $reason"
  case "$verdict" in
    pass) return 0 ;;
    refuse) ;;
    *)
      echo "notice: $who quota check for $harness${model:+ $model} is uncertain, launching anyway: $reason" >&2
      return 0
      ;;
  esac
  [ "$alt" != none ] || alt='none with known runway and spendPriority in this reading'
  FM_QUOTA_GATE_EVIDENCE="$FM_QUOTA_GATE_EVIDENCE; best alternative: $alt"
  if [ -n "$override" ]; then
    echo "notice: $who quota check refuses $harness${model:+ $model} ($reason); proceeding under --quota-override: $override (best alternative was: $alt)" >&2
    return 0
  fi
  echo "error: $who refuses explicit harness $harness${model:+ model $model}: $reason. Best alternative: $alt. Pass --quota-override <reason> to launch $harness anyway; the override is recorded in the task record." >&2
  return 1
}

# fm_quota_provider_map <rules-file>
# Prints the harness -> provider JSON object quota_evaluate reads, from the
# single-provider table below, for every harness the rules file names. A
# harness without one authoritative provider maps to null.
fm_quota_provider_map() {
  local rules=$1 map='{}' h p
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
    map=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$map")
  done < <(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
    | map(.harness | select(. != null)) | unique | .[]' "$rules")
  printf '%s\n' "$map"
}

# fm_quota_axi_version_compatible <version-output>
# True when the printed `quota-axi --version` text meets FM_QUOTA_AXI_MIN.
# Callers that already captured a bounded --version pass that text here so they
# do not launch a second, unbounded version probe.
fm_quota_axi_version_compatible() {
  local output=${1-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  fm_quota_axi_version_compatible "$output"
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

# Reads the whole table before answering: leaving the loop early closes the
# pipe mid-write, and where SIGPIPE is ignored the writer prints a broken-pipe
# error on stderr.
fm_quota_single_provider_for_harness() {
  local harness provider found=''
  while read -r harness provider; do
    [ -z "$found" ] && [ "$harness" = "$1" ] && found=$provider || :
  done < <(fm_quota_single_provider_table)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}
