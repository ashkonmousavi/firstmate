# Shared crew-dispatch schema used by bootstrap and fm-dispatch-select.sh.
# Usage: jq -sr -f bin/fm-crew-dispatch-validate.jq CONFIG
#        [--argjson typed true --argjson verified_harnesses JSON --arg provider_re RE]
# Input is a slurped JSON stream. Valid input emits nothing; a schema refusal
# emits its reason. JSON parse failures remain jq errors for callers to report.
# typed=true (bootstrap, while typed dispatch resolution is active) also
# validates the resolver-only rule approval/min_confidence/floor and profile
# provider/floor fields that bin/fm-dispatch-resolve.sh applies in code.
def typed: ($ARGS.named.typed // false) == true;
def verified_list: $ARGS.named.verified_harnesses // ["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","agy","muse","rovo","omp","devin"];
def provider_id($p): ($p | type) == "string" and ($p | test($ARGS.named.provider_re // "^[a-z0-9]+(-[a-z0-9]+)*\\z"));
def verified($h): verified_list | index($h);
def effort_ok($h; $m; $e):
  if $e == null then true
  elif ($e | type) != "string" then false
  elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
  elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
  elif $h == "grok" then (["low","medium","high"] | index($e))
  elif $h == "agy" then (["low","medium","high"] | index($e))
  elif $h == "pi" or $h == "pi-signed" or $h == "omp" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "rovo" then (["low","medium","high","max"] | index($e))
  elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
  else true
  end;
def profiles($value):
  if ($value | type) == "array" then $value
  elif ($value | type) == "object" then [$value]
  else []
  end;
def configured_profiles:
  ([(.rules // [])[]? | profiles(.use?)[]?]
    + (if has("default") then [profiles(.default)[]?] else [] end));
def malformed_optional_fields($items):
  ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
  or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)))
  or (typed and ($items | any(has("provider") and (provider_id(.provider) | not))));
# A quota floor, on a rule or a profile: bin/fm-dispatch-resolve.sh applies
# it in code against one quota-axi row, so scope and min_percent must be
# concrete; a rule floor also names the provider whose row it reads.
def floor_bad($f; $need_provider):
  ($f | type) != "object"
  or (($f.scope | type) != "string") or (($f.scope | length) == 0)
  or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
  or (if $need_provider
      then (provider_id($f.provider) | not)
      else ($f | has("provider"))
      end);
def malformed_profile_floors($items):
  ($items | any(has("floor") and floor_bad(.floor; false)));
def selections: [(.rules // [])[]? | select(has("select"))];
def bad_efforts:
  configured_profiles
  | map({h: .harness, m: .model, e: .effort})
  | map(select(.e != null))
  | map(select((.h | type) == "string" and verified(.h)))
  | map(select(. as $p | effort_ok($p.h; $p.m; $p.e) | not))
  | map("\(.h):\(.e)")
  | unique;
if length != 1 then "expected exactly one JSON object"
else .[0] |
if type != "object" then "top-level value must be an object"
elif has("rules") and (.rules | type) != "array" then "rules must be an array"
elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
elif [(.rules // [])[]? | profiles(.use?)[]? | select(has("off") and (.off | type) != "boolean")] | length > 0 then "use profile off must be a boolean"
elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then
  if typed then "use profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  else "use profile model and effort must be non-empty strings when present"
  end
elif typed and malformed_profile_floors([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile floor needs scope and min_percent 0..100"
elif typed and ([(.rules // [])[]? | select(has("approval") and .approval != "captain")] | length > 0) then "approval must be \"captain\" when present"
elif typed and ([(.rules // [])[]? | select(has("floor") and floor_bad(.floor; true))] | length > 0) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
elif typed and ([(.rules // [])[]? | select(has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1))] | length > 0) then "min_confidence must be a number from 0 through 1 when present"
elif [selections[] | select((.select | type) != "string" or (.select | length) == 0)] | length > 0 then "select must be a non-empty string"
elif [selections[].select | select(. != "ordered" and . != "quota-balanced")] | length > 0 then
  "unknown select: " + ([selections[].select | select(. != "ordered" and . != "quota-balanced")] | unique | join(", "))
elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
elif has("default") and ([profiles(.default)[]? | select(has("off") and (.off | type) != "boolean")] | length) > 0 then "default profile off must be a boolean"
elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then
  if typed then "default profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  else "default profile model and effort must be non-empty strings when present"
  end
elif typed and has("default") and malformed_profile_floors([profiles(.default)[]?]) then "default profile floor needs scope and min_percent 0..100"
else
  (configured_profiles
    | map(.harness)
    | map(select(. != null))
    | map(select(. as $h | verified($h) | not))
    | unique) as $bad_harnesses
  | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
    elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
    else empty
    end
end
end
