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

# Candidate evaluation for the typed resolver (bin/fm-dispatch-resolve.sh).
# Operator scope decision: resolver-only on this curated branch.
# Spawn-time (bin/fm-spawn.sh) runway-gate enforcement is deferred because this
# branch lacks the dispatch guard library and off-table spawn check it builds on.
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
