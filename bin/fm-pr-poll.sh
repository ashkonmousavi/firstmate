#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change.
# On GitHub, only while the pull request is OPEN, it also emits exactly one of
# `conflict:<added-at>` (a label named conflict has been applied for at least 15 minutes)
# or `conflict-clear` (the label is absent or still younger than that).
# CLOSED and other non-open, non-merged states emit nothing.
# GitHub label lookup and JSON failures return nonzero. An unproved label age
# emits no observation, so it cannot be read as a merge or as a conflict.
# GitHub reads are conditional (bin/fm-gh-etag-lib.sh): one REST read of the
# pull request with the ETag from the last tick. A 304 costs no rate-limit
# budget and replays the facts stored for that ETag, so the conflict-label age
# is still re-evaluated against the clock without another request. A 200 reads
# state and labels from the same body and asks GraphQL for the label timeline
# only while a conflict label is present. Without jq, the helper, a state
# directory (FM_STATE_OVERRIDE, else FM_HOME/state), or a usable REST answer,
# the original gh pr view and GraphQL reads run unchanged.
# The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and tea for Forgejo, so an upstream checkout
# needs no extra tooling to follow GitHub or GitLab. The Gerrit and Forgejo
# branches additionally need jq, which bin/fm-pr-check.sh refuses to arm those
# watches without.
set -u
LC_ALL=C
export LC_ALL

# Seconds a GitHub label named conflict must already have been applied before
# this poll reports it. Younger than this, and a pull request with no such
# label, both report conflict-clear so the watcher stays quiet.
FM_PR_POLL_CONFLICT_MIN_AGE=900

_fm_pr_poll_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_pr_poll_dir" != "${BASH_SOURCE[0]}" ] || _fm_pr_poll_dir=.
if [ -f "$_fm_pr_poll_dir/fm-gh-etag-lib.sh" ] && [ ! -L "$_fm_pr_poll_dir/fm-gh-etag-lib.sh" ]; then
  # shellcheck source=bin/fm-gh-etag-lib.sh
  . "$_fm_pr_poll_dir/fm-gh-etag-lib.sh"
fi

fm_pr_poll_epoch() {  # <iso8601>
  local ts=$1 epoch
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].*Z) ;;
    *) return 1 ;;
  esac
  epoch=$(date -u -d "$ts" +%s 2>/dev/null) || {
    command -v python3 >/dev/null 2>&1 || return 1
    epoch=$(python3 -c 'import datetime, sys
s = sys.argv[1]
if s.endswith("Z"):
    s = s[:-1] + "+00:00"
print(int(datetime.datetime.fromisoformat(s).timestamp()))' "$ts" 2>/dev/null) || return 1
  }
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$epoch"
}

# Print the verdict for facts already in hand: conflict-clear, conflict:<ts>,
# or nothing when the label's age cannot be proved.
# fm_pr_poll_verdict <present> <labeled_at> <unlabeled_at>
fm_pr_poll_verdict() {
  local present=$1 labeled_at=$2 unlabeled_at=$3 now='' applied='' age=''
  case "$present" in
    false) printf '%s\n' conflict-clear; return 0 ;;
    true) ;;
    *) return 0 ;;
  esac
  if [ -z "$labeled_at" ] || { [ -n "$unlabeled_at" ] && [[ "$unlabeled_at" > "$labeled_at" ]]; }; then
    return 0
  fi
  now=$(date -u +%s 2>/dev/null) || return 0
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  applied=$(fm_pr_poll_epoch "$labeled_at") || return 0
  age=$((now - applied))
  if [ "$age" -ge "$FM_PR_POLL_CONFLICT_MIN_AGE" ]; then
    printf 'conflict:%s\n' "$labeled_at"
  else
    printf '%s\n' conflict-clear
  fi
}

# Read the conflict label's presence and its latest labeled and unlabeled
# times from the GraphQL timeline into FM_PR_POLL_PRESENT, _LABELED_AT and
# _UNLABELED_AT. A failed read returns nonzero and sets nothing usable.
fm_pr_poll_github_timeline() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 raw line query jqprog
  FM_PR_POLL_PRESENT=''
  FM_PR_POLL_LABELED_AT=''
  FM_PR_POLL_UNLABELED_AT=''
  query=$(cat <<'EOF'
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      labels(first: 100) { nodes { name } }
      timelineItems(first: 100, after: $endCursor, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on LabeledEvent { createdAt label { name } }
          ... on UnlabeledEvent { createdAt label { name } }
        }
      }
    }
  }
}
EOF
)
  jqprog=$(cat <<'EOF'
.data.repository.pullRequest as $pr
| if $pr == null then error("no pull request") else
  "present=\($pr.labels.nodes // [] | map(.name) | index("conflict") != null)",
  ($pr.timelineItems.nodes[]?
    | select(.label.name == "conflict")
    | if .__typename == "LabeledEvent" then "labeled_at=\(.createdAt)"
      elif .__typename == "UnlabeledEvent" then "unlabeled_at=\(.createdAt)"
      else empty end)
  end
EOF
)
  raw=$(gh api graphql --paginate -f owner="$owner" -f repo="$repo" -F number="$number" \
    -f query="$query" --jq "$jqprog") || return $?
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      present=*) FM_PR_POLL_PRESENT=${line#present=} ;;
      labeled_at=*) FM_PR_POLL_LABELED_AT=${line#labeled_at=} ;;
      unlabeled_at=*) FM_PR_POLL_UNLABELED_AT=${line#unlabeled_at=} ;;
    esac
  done <<EOF
$raw
EOF
}

# Print conflict or conflict-clear. Silence (no output, success) means the
# conflict label is present but its age cannot be proved.
fm_pr_poll_github_conflict() {  # <owner> <repo> <number>
  fm_pr_poll_github_timeline "$1" "$2" "$3" || return $?
  fm_pr_poll_verdict "$FM_PR_POLL_PRESENT" "$FM_PR_POLL_LABELED_AT" "$FM_PR_POLL_UNLABELED_AT"
}

# The conditional-read cache directory, or failure when this run has no state
# directory it can name. FM_STATE_OVERRIDE wins, then FM_HOME/state; the code
# root is never guessed, because a secondmate home shares this code.
fm_pr_poll_cache_dir() {
  local state=${FM_STATE_OVERRIDE:-}
  [ -n "$state" ] || { [ -n "${FM_HOME:-}" ] && state=$FM_HOME/state; }
  [ -n "$state" ] && [ -d "$state" ] && [ ! -L "$state" ] || return 1
  printf '%s/gh-etag\n' "$state"
}

# Facts for one open PR, stored beside its ETag: the tag they are valid for and
# the label facts. Replayed only while the helper reports the same tag again
# (a 304), which proves the pull request has not changed since they were read.
fm_pr_poll_facts_read() {  # <file> <etag>
  local file=$1 etag=$2 line tag='' ok=0
  FM_PR_POLL_PRESENT=''
  FM_PR_POLL_LABELED_AT=''
  FM_PR_POLL_UNLABELED_AT=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      etag=*) tag=${line#etag=} ;;
      present=*) FM_PR_POLL_PRESENT=${line#present=} ;;
      labeled_at=*) FM_PR_POLL_LABELED_AT=${line#labeled_at=} ;;
      unlabeled_at=*) FM_PR_POLL_UNLABELED_AT=${line#unlabeled_at=}; ok=1 ;;
    esac
  done < "$file"
  [ "$ok" = 1 ] && [ -n "$tag" ] && [ "$tag" = "$etag" ]
}

fm_pr_poll_facts_write() {  # <file> <etag> <present> <labeled_at> <unlabeled_at>
  local file=$1 tmp
  tmp="$file.tmp.$$"
  { printf 'etag=%s\npresent=%s\nlabeled_at=%s\nunlabeled_at=%s\n' "$2" "$3" "$4" "$5" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$file"; } 2>/dev/null || rm -f -- "$tmp"
}

# The whole GitHub tick for one pull request: print merged, conflict:<ts>,
# conflict-clear, or nothing. Nonzero means a read failed.
fm_pr_poll_github() {  # <owner> <repo> <number> <url>
  local owner=$1 repo=$2 number=$3 url=$4 dir='' key facts state='' present etag='' verdict=''
  if command -v jq >/dev/null 2>&1 && declare -F fm_gh_etag_get >/dev/null \
     && dir=$(fm_pr_poll_cache_dir) \
     && key="pr-poll.$owner.$repo.$number" \
     && fm_gh_etag_get "$dir" "$key" "repos/$owner/$repo/pulls/$number"; then
    etag=$FM_GH_ETAG_VALUE
    facts="$dir/$key.facts"
    if [ "$FM_GH_ETAG_STATUS" = 304 ] && fm_pr_poll_facts_read "$facts" "$etag"; then
      # Nothing about the pull request changed since these facts were proved,
      # so only the clock can move the verdict.
      fm_pr_poll_verdict "$FM_PR_POLL_PRESENT" "$FM_PR_POLL_LABELED_AT" "$FM_PR_POLL_UNLABELED_AT"
      return 0
    fi
    state=$(jq -r 'if .merged == true then "MERGED" elif .state == "open" then "OPEN" elif .state == "closed" then "CLOSED" else "" end' \
      "$FM_GH_ETAG_BODY" 2>/dev/null) || state=''
    case "$state" in
      MERGED) printf '%s\n' merged; return 0 ;;
      CLOSED) return 0 ;;
      OPEN)
        present=$(jq -r 'if (.labels | type) == "array" then (.labels | map(.name) | index("conflict") != null | tostring) else "" end' \
          "$FM_GH_ETAG_BODY" 2>/dev/null) || present=''
        case "$present" in
          false)
            fm_pr_poll_facts_write "$facts" "$etag" false '' ''
            printf '%s\n' conflict-clear
            return 0 ;;
          true)
            fm_pr_poll_github_timeline "$owner" "$repo" "$number" || return $?
            verdict=$(fm_pr_poll_verdict "$FM_PR_POLL_PRESENT" "$FM_PR_POLL_LABELED_AT" "$FM_PR_POLL_UNLABELED_AT")
            # Only a timeline that agrees the label is present and proves its age
            # is stored; anything else is asked again next tick, exactly as the
            # original reads did every tick.
            [ "$FM_PR_POLL_PRESENT" != true ] || [ -z "$verdict" ] \
              || fm_pr_poll_facts_write "$facts" "$etag" true "$FM_PR_POLL_LABELED_AT" "$FM_PR_POLL_UNLABELED_AT"
            [ -z "$verdict" ] || printf '%s\n' "$verdict"
            return 0 ;;
        esac ;;
    esac
    # An unreadable REST answer falls through to the original reads.
  fi
  state=$(gh pr view "$url" --json state -q .state) || return $?
  if [ "$state" = MERGED ]; then
    printf '%s\n' merged
  elif [ "$state" = OPEN ]; then
    fm_pr_poll_github_conflict "$owner" "$repo" "$number" || return $?
  fi
}

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    fm_pr_poll_github "$owner" "$repo" "$number" "$url" || exit $?
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  forgejo)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
    esac
    owner=${path%%/*}
    repo=${path#*/}
    [ "$owner" != "$path" ] || exit 0
    for segment in "$owner" "$repo"; do
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || exit 0
      case "$segment" in
        .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    command -v tea >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    # tea addresses a repo by slug only; the host comes from a named login
    # rather than a URL the way gh and glab take one, so the login registered
    # for this exact host is resolved fresh on every poll rather than trusted
    # from anywhere durable. Refuse to guess when zero or more than one
    # registered login matches, rather than picking one arbitrarily.
    # The list is parsed as JSON, never split on quotes per line, so a login
    # printed as one compact object still matches; this is the same filter
    # bin/fm-pr-lib.sh's fm_pr_forgejo_login applies.
    login=$(
      tea login list --output json 2>/dev/null | jq -er --arg h "$host" '
        if type == "array" then
          [ .[]
            | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
                     and (.url | type) == "string")
            | select((.url
                      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                      | sub("[/?#].*$"; "")
                      | sub("^.*@"; "")
                      | sub(":[0-9]+$"; "")) == $h)
            | .name ]
          | if length == 1 then .[0] else error("not exactly one matching login") end
        else
          error("login list is not an array")
        end' 2>/dev/null
    ) || exit 0
    [ -n "$login" ] || exit 0
    # tea's single-PR view ignores field selection, so the one pull request
    # is read by number from the REST record through "tea api", which keeps
    # the credential inside tea. "tea api" exits 0 on an HTTP error with the
    # error body as output, so only a boolean merged field of true wakes this
    # poll and every other reading stays silent.
    merged=$(tea api --login "$login" --repo "$owner/$repo" \
      "/repos/{owner}/{repo}/pulls/$number" 2>/dev/null | jq -r '
        if type == "object" and (.merged | type) == "boolean"
        then .merged | tostring
        else error("invalid pull request record")
        end' 2>/dev/null) || exit 0
    [ "$merged" = true ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
