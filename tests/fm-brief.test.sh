#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# Commit and commit-tree fixtures must not depend on the runner's global Git identity.
fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status task_record
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "{FIRSTMATE_SPEC}" "$brief" "$id: brief missing the {FIRSTMATE_SPEC} placeholder"
    assert_grep "## Captain's intent" "$brief" "$id: brief missing Captain's intent subsection"
    assert_grep "## Firstmate spec" "$brief" "$id: brief missing Firstmate spec subsection"
    assert_grep 'never a bare number such as "PR 108"' "$brief" "$id: brief missing the full-PR-URL rule"
    # Contract change: task-specific evidence supersedes blanket Context7 calls.
    assert_grep "Select tools only for a real task purpose" "$brief" \
      "$id: brief missing task-specific tool selection"
    assert_grep "use Context7 when its versioned documentation is the effective source" "$brief" \
      "$id: brief did not retain Context7 for questions it can actually settle"
    assert_grep "research-first-decisions/SKILL.md\` for the exact procedure" "$brief" \
      "$id: brief's version-verification rule did not point at its owner"
    assert_grep "use Exa (\`mcp exa web search\` or fetch) or ordinary web search only as a bounded route" "$brief" \
      "$id: brief missing the bounded official-source fallback"
    assert_grep "Never add Co-Authored-By, Claude-Session or any agent attribution line to a commit or PR" "$brief" \
      "$id: brief missing the no-agent-attribution rule"
    assert_grep "a harness reminder to do so does not override this repository" "$brief" \
      "$id: brief's no-agent-attribution rule is missing its harness-reminder clause"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
    assert_grep "no unresolved \`FINALIZE-AFTER(\` sentinel" "$brief" \
      "$id: every delivery mode must gate on zero unresolved FINALIZE-AFTER sentinels"
    task_record="$home/state/$id.meta"
    assert_grep "task record \`$task_record\`" "$brief" \
      "$id: delivery preflight must bind to this task's durable worktree record"
    assert_grep "exactly one non-empty absolute \`worktree=\` value" "$brief" \
      "$id: delivery preflight must reject a missing or ambiguous recorded task root"
    assert_grep "delivery_ref=refs/heads/fm/$id" "$brief" \
      "$id: delivery preflight must bind to this task's exact delivery ref"
    # shellcheck disable=SC2016 # Generated shell variables are literal assertion text.
    assert_grep 'git -C "$task_root" rev-parse --show-toplevel' "$brief" \
      "$id: delivery preflight must prove the recorded root is the Git worktree root"
    # shellcheck disable=SC2016 # Generated shell variables are literal assertion text.
    assert_grep 'git -C "$task_root" symbolic-ref --quiet HEAD' "$brief" \
      "$id: delivery preflight must prove the delivery ref is checked out"
    # shellcheck disable=SC2016 # Generated shell variables are literal assertion text.
    assert_grep 'git -C "$task_root" rev-parse --verify "$delivery_ref^{commit}"' "$brief" \
      "$id: delivery preflight must prove the delivery ref resolves to a commit"
    # shellcheck disable=SC2016 # Generated shell variables are literal assertion text.
    assert_grep 'git -C "$task_root" status --porcelain=v1 --untracked-files=all' "$brief" \
      "$id: delivery preflight must inspect cleanliness at the recorded task root"
    # shellcheck disable=SC2016 # Generated shell variables are literal assertion text.
    assert_grep 'git -C "$task_root" submodule status --recursive' "$brief" \
      "$id: delivery preflight must verify every recursively referenced submodule commit"
    assert_grep "every output line must begin with a space" "$brief" \
      "$id: delivery preflight must reject uninitialized or mismatched submodules"
    assert_grep "git -C \"\$task_root\" grep --recurse-submodules -n -F 'FINALIZE-AFTER(' \"\$delivery_ref\" -- ." "$brief" \
      "$id: delivery preflight must scan the verified superproject and submodule commits"
    # shellcheck disable=SC2016 # Generated shell substitution is literal assertion text.
    assert_no_grep 'git -C "$(git rev-parse --show-toplevel)"' "$brief" \
      "$id: delivery preflight must not derive its target from the current directory"
    assert_grep "Exit 1 with no output means no sentinel occurrence" "$brief" \
      "$id: delivery preflight must distinguish no matches from a scan error"
    assert_grep "any other exit means the scan failed and blocks delivery" "$brief" \
      "$id: delivery preflight must never treat a failed scan as green"
    # shellcheck disable=SC2016 # Generated shell variables are literal assertion text.
    assert_grep 'run `cd -- "$task_root"` and require physical `pwd -P` to equal `task_root`' "$brief" \
      "$id: every permitted delivery action must return to the verified task root"
    assert_grep "a later \`/no-mistakes\` invocation, a push, a PR command, or the local-only ready report" "$brief" \
      "$id: the root binding must cover every mode-specific delivery action"
    # shellcheck disable=SC2016 # Generated shell markup is literal assertion text.
    assert_grep 'If `task_root` is unavailable, rerun this entire preflight from the task record' "$brief" \
      "$id: a later delivery action must fail closed when its pinned root is unavailable"
    assert_no_grep "grep -rn 'FINALIZE-AFTER(' ." "$brief" \
      "$id: delivery preflight must not inspect the mutable current directory"
    assert_no_grep "bin/fm-dod-lib.sh" "$brief" \
      "$id: brief leaked scaffold source paths (a backtick ran as command substitution in an unquoted heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
batch constituent on a direct brief|brief-refused-b5 some-proj --mode direct-PR --batch-constituent-of owner-task|--batch-constituent-of applies only to a no-mistakes ship brief
batch constituent on a scout brief|brief-refused-b6 some-proj --scout --batch-constituent-of owner-task|--batch-constituent-of applies only to a no-mistakes ship brief
invalid integration owner id|brief-refused-b7 some-proj --mode no-mistakes --batch-constituent-of ../owner|--batch-constituent-of requires a valid integration-owner task id
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "start the run only through that exact command: it renders the real \`--intent\` from the effective brief and refuses a stale launch package before no-mistakes starts" "$brief" \
    "no-mistakes DOD must route a spawned worker through the source-revision-bound validation consumer"
  assert_grep "That command also refuses and starts no run while an active no-mistakes run holds your branch at a head other than your current HEAD" "$brief" \
    "no-mistakes DOD must state run-validation's active-run refusal and its supported release sequence"
  assert_grep "A branch whose pushed PR head has diverged from local HEAD is reconciled by merge, never rebase, before a run, and run-validation refuses otherwise" "$brief" \
    "no-mistakes DOD must state the pushed PR-head merge-before-rebase rule"
  # --intent keeps all authoritative inputs under distinct labels. This base
  # text is the one owner both fm-brief.sh and fm-promote.sh render.
  assert_grep "pass \`--intent\` as separately attributed labeled parts in one string: \`Captain intent:\`, \`Firstmate implementation context:\`, and, when this brief carries a Proof bar section, \`Agreed proof contract:\`" "$brief" \
    "no-mistakes DOD must define the separately attributed captain, implementation, and proof parts"
  assert_no_grep "pass \`--intent\` as only" "$brief" \
    "no-mistakes DOD must not claim --intent carries only the Captain intent part"
  assert_grep "Build the \`Captain intent:\` part from this brief's \`## Captain's intent\`" "$brief" \
    "no-mistakes DOD must require the Captain intent part to be the Captain's intent subsection"
  assert_grep "plus any later words the captain actually said" "$brief" \
    "no-mistakes DOD must allow later captain words in --intent"
  assert_grep "Do not include \`## Firstmate spec\`" "$brief" \
    "no-mistakes DOD must keep Firstmate spec out of the Captain intent part"
  assert_grep "builds the \`Firstmate implementation context:\` part from the complete \`## Firstmate spec\` subsection" "$brief" \
    "no-mistakes DOD must carry the complete Firstmate spec under its own label"
  assert_grep "or your own decisions and tradeoffs in the \`Captain intent:\` part" "$brief" \
    "no-mistakes DOD must keep worker tradeoffs out of the Captain intent part"
  assert_grep "Build the \`Agreed proof contract:\` part per the Proof bar section's own instruction, when this brief carries one" "$brief" \
    "no-mistakes DOD must describe building the Agreed proof contract part, conditioned on the brief carrying a Proof bar section"
  assert_grep "This replaces the no-mistakes skill's advice to enrich \`--intent\`" "$brief" \
    "no-mistakes DOD must override the external skill's enrich-with-decisions guidance"
  # A bare reference cannot preserve the captain's ask, so the rendered DOD states
  # the self-sufficiency rule and requires referenced material to be resolved into
  # its substance.
  assert_grep "The complete labeled input must be self-sufficient" "$brief" \
    "no-mistakes DOD must require a self-sufficient complete attributed input"
  assert_grep "write the substance of the referenced items into the \`Captain intent:\` part" "$brief" \
    "no-mistakes DOD must tell the worker to resolve report, decision, and PR references into substance"

  # The --yes ban is a fleet-wide prohibition, not a preference, and it must not
  # claim an enforcement the tool does not provide: this is instruction only.
  assert_grep "NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide." "$brief" \
    "no-mistakes DOD must state the --yes ban as a prohibition"
  assert_grep "answering your own ask-user finding is a hard rule violation" "$brief" \
    "no-mistakes DOD must say why --yes is banned"
  assert_no_grep "Avoid \`--yes\`" "$brief" \
    "no-mistakes DOD still states the --yes ban as a preference"
  assert_no_grep "no-mistakes refuses" "$brief" \
    "no-mistakes DOD must not claim the tool itself refuses --yes"

  # The pre-validation handoff must not call itself "complete" (that word belongs
  # to the CI-green done: report), and the recognized status verb it actually
  # uses (working:) must be named so the classifier semantics stay honest.
  assert_grep "The branch is prepared when committed on your branch; being prepared is not the same as the task being done." "$brief" \
    "no-mistakes DOD must distinguish being prepared from being done"
  assert_grep "append \`working: prepared - {summary}\` to the status file" "$brief" \
    "no-mistakes DOD must route the pre-validation handoff through the recognized working: verb"
  assert_grep "\`prepared:\` is not a recognized status verb in bin/fm-classify-lib.sh" "$brief" \
    "no-mistakes DOD must explain why working: carries the prepared handoff"
  assert_grep "\`done:\` means checks green at the exact head; it is never used for the pre-validation \`working: prepared\` handoff above." "$brief" \
    "no-mistakes DOD must state that done: means checks green, not merely committed"
  assert_no_grep "The task is complete only when committed on your branch." "$brief" \
    "no-mistakes DOD must not call a mere commit task-complete"
  assert_grep "Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix." "$brief" \
    "no-mistakes DOD must preserve active-pipeline custody"
  assert_grep "Rule F: your \`done: PR {url} checks green\` report requires check conclusions verified at the exact current head sha of the PR branch" "$brief" \
    "no-mistakes DOD must preserve rule F's exact-head requirement"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright"
}

# A task explicitly prepared for a named integration owner must hand off its
# reviewed head and focused evidence instead of starting a standalone pipeline
# merely to qualify for batch membership. An ordinary no-mistakes task keeps
# the existing standalone next step.
test_batch_constituent_handoff_replaces_the_standalone_pipeline_next_step() {
  local home brief
  home="$TMP_ROOT/batch-constituent-handoff-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-batch-constituent some-proj \
    --mode no-mistakes --batch-constituent-of integration-owner >/dev/null 2>&1 \
    || fail "a named batch constituent brief should scaffold"
  brief="$home/data/brief-batch-constituent/brief.md"
  assert_grep "deliver your exact reviewed head and focused evidence to the named integration owner \`integration-owner\`" "$brief" \
    "a batch constituent was not told to hand its reviewed result to the named integration owner"
  assert_grep "Do not start a standalone no-mistakes pipeline merely to become a batch member." "$brief" \
    "a batch constituent was not forbidden from starting a membership-only pipeline"
  assert_no_grep "Firstmate will then instruct you to run /no-mistakes to validate and ship a PR." "$brief" \
    "a batch constituent retained the standalone pipeline next step"
  assert_no_grep '| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |' "$brief" \
    "a PR-less batch constituent was still told to supply the old mandatory original-PR row"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-standalone-next-step some-proj \
    --mode no-mistakes >/dev/null 2>&1 \
    || fail "an ordinary no-mistakes brief should scaffold"
  brief="$home/data/brief-standalone-next-step/brief.md"
  assert_grep "Firstmate will then instruct you to run /no-mistakes to validate and ship a PR." "$brief" \
    "an ordinary no-mistakes task lost its standalone pipeline next step"
  assert_no_grep "Do not start a standalone no-mistakes pipeline merely to become a batch member." "$brief" \
    "an ordinary no-mistakes task was misclassified as a batch constituent"
  pass "fm-brief.sh: a named batch constituent hands off its reviewed head without starting a standalone membership pipeline"
}

# Pin the two evidence rules the captain's 2026-09-05 ruling added to the DOD:
# no committed binary screenshots (prose cites them by filename, images go into
# the PR body), and a documentation finding is fixed only by the worker's own
# commit plus one re-validation since the pipeline's document step is
# report-only. Both no-mistakes and direct-PR briefs must state both rules.
#
# The captain's 2026-09-07 ruling is the approved contract change that makes the
# old local-only expectation wrong: "the definition of done for every mode says
# that the delivery signal is not product acceptance and that evidence stays out
# of the source tree". Keeping evidence out of the tree was never a property of
# opening a PR, so local-only now states it too - with its own destination,
# because local-only has no PR body and its delivery preflight requires a
# worktree clean of untracked files. Only the report-only DOCUMENT-step rule
# stays PR-exclusive, and local-only is still asserted not to carry it.
test_no_binary_evidence_and_document_step_dod_rules() {
  local home id brief
  home="$TMP_ROOT/evidence-rules-home"
  mkdir -p "$home/data"

  id="brief-evidence-nm-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "No binary screenshots or other media enter the repository tree" "$brief" \
    "no-mistakes DOD must ban committed binary screenshots and media"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backtick must stay literal
  assert_grep 'prose evidence (for example `fidelity-check.md`) cites each one by filename' "$brief" \
    "no-mistakes DOD must require prose evidence to cite screenshots by filename"
  assert_grep "the actual images go into the PR body, uploaded through GitHub" "$brief" \
    "no-mistakes DOD must route screenshot images to the PR body instead of the repo"
  assert_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation" "$brief" \
    "no-mistakes DOD must state the document step is report-only and require a real commit plus re-validation"
  assert_grep "the PR body's Document section must state what actually changed" "$brief" \
    "no-mistakes DOD must require the PR body's Document section to state the actual change"

  id="brief-evidence-direct-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "No binary screenshots or other media enter the repository tree" "$brief" \
    "direct-PR DOD must ban committed binary screenshots and media"
  assert_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation" "$brief" \
    "direct-PR DOD must state the document step is report-only and require a real commit plus re-validation"

  id="brief-evidence-local-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "No binary screenshots or other media enter the repository tree" "$brief" \
    "local-only DOD must also keep evidence out of the source tree (captain ruling 2026-09-07)"
  assert_grep "the actual images stay outside the repository and your ready report names their path" "$brief" \
    "local-only DOD must route evidence outside the repository, since its preflight requires no untracked files"
  assert_no_grep "the actual images go into the PR body" "$brief" \
    "local-only DOD must not route evidence to a PR body it never opens"
  assert_no_grep "The document step is report-only" "$brief" \
    "local-only DOD must not carry the PR-body document-step rule; local-only never opens a PR"

  pass "fm-brief.sh: every mode's DOD keeps evidence out of the source tree, and only PR modes carry the document-step rule"
}

# Write the private install-owned capability receipt used by the Document
# instruction tests. The independently reviewed proof is represented by a real
# fixture artifact and the receipt binds both that artifact and the executable.
write_document_correction_receipt() {  # <home> <executable> <proof>
  local home=$1 executable=$2 proof=$3 receipt
  receipt=$(FM_HOME="$home" PATH="${executable%/*}:$PATH" \
    "$ROOT/bin/fm-dod-lib.sh" record-document-correction-capability --proof "$proof") \
    || fail "the install owner could not record an accepted Document correction capability"
  [ "$receipt" = "$home/config/no-mistakes-document-correction.receipt" ] \
    || fail "the install owner reported the wrong private receipt path: $receipt"
  [ "$(stat -c '%a' "$receipt")" = 600 ] \
    || fail "the install owner did not publish the private receipt at mode 0600"
}

# The no-mistakes Document instruction follows both independently necessary
# inputs: the trusted project configuration selects bounded correction and a
# private install receipt binds the exact executable bytes to independently
# accepted consuming proof. Missing/malformed/mismatched receipts and zero or
# unreadable project configuration all fail closed to report-only.
test_document_instruction_requires_unambiguous_trusted_project_config_and_installed_capability_receipt() {
  local home fakebin brief project proof
  home="$TMP_ROOT/document-instruction-home"
  fakebin=$(fm_fakebin "$home")
  fm_test_fake_no_mistakes "$fakebin"
  mkdir -p "$home/data" "$home/projects"

  proof="$home/accepted-consuming-proof.txt"
  printf '%s\n' 'independent review: bounded in-run document correction accepted' > "$proof"

  project="$home/projects/missing-receipt-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-7-g4fa1bb2 (4fa1bb2)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-no-receipt missing-receipt-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a missing-receipt project brief should scaffold conservatively"
  brief="$home/data/brief-document-no-receipt/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a historical recognized build granted capability without an install receipt"

  write_document_correction_receipt "$home" "$fakebin/no-mistakes" "$proof"
  project="$home/projects/in-run-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.72.0-reviewed-gmoving (moving)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-in-run in-run-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a receipt-backed correction-enabled project brief should scaffold"
  brief="$home/data/brief-document-in-run/brief.md"
  assert_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "a receipt-backed correction-enabled project did not receive the in-run Document instruction"
  assert_grep "the pipeline's correction turn applies an accepted documentation fix in-run" "$brief" \
    "the in-run Document instruction did not assign the accepted fix to the pipeline"
  assert_grep "an honest completed Test recheck and a valid attestation" "$brief" \
    "the in-run Document instruction did not require Test recheck and attestation proof"
  assert_grep "never a skipped Test step and never your own out-of-band commit plus a fresh run" "$brief" \
    "the in-run Document instruction did not forbid the stale out-of-band correction route"
  assert_no_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed." "$brief" \
    "a correction-enabled project retained the report-only Document instruction"

  project="$home/projects/current-capability-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-current current-capability-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "the installed 65e capability-bearing project brief should scaffold"
  brief="$home/data/brief-document-current/brief.md"
  assert_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "the installed 65e capability was not recognized"

  project="$home/projects/nested-document-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  unrelated:\n    document: 1\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-nested nested-document-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a nested unrelated document key should scaffold conservatively"
  brief="$home/data/brief-document-nested/brief.md"
  assert_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed." "$brief" \
    "a nested unrelated document key was mistaken for the direct auto_fix.document capability selection"
  assert_no_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "a nested unrelated document key enabled in-run correction"

  project="$home/projects/duplicate-document-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n  document: 1\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-duplicate duplicate-document-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a duplicate document selection should scaffold conservatively"
  brief="$home/data/brief-document-duplicate/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "duplicate direct auto_fix.document keys did not fail closed"

  # Every child of the admitted auto_fix block belongs to one deliberately
  # small grammar. Quoted/spaced aliases and non-integer siblings cannot be
  # ignored after a positive document value has already been observed.
  project="$home/projects/duplicate-quoted-document-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n  "document": 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-duplicate-quoted-child duplicate-quoted-document-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a quoted duplicate document child should scaffold conservatively"
  brief="$home/data/brief-document-duplicate-quoted-child/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a quoted duplicate document child did not fail closed"

  project="$home/projects/duplicate-spaced-document-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n  document : 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-duplicate-spaced-child duplicate-spaced-document-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a spaced duplicate document child should scaffold conservatively"
  brief="$home/data/brief-document-duplicate-spaced-child/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a spaced duplicate document child did not fail closed"

  project="$home/projects/malformed-auto-fix-sibling-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n  ci: nope\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-malformed-sibling malformed-auto-fix-sibling-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a non-integer auto_fix sibling should scaffold conservatively"
  brief="$home/data/brief-document-malformed-sibling/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a non-integer auto_fix sibling did not fail closed"

  # A duplicate top-level auto_fix mapping is ambiguous even when only the
  # first mapping contains document. The generated consumer must fail closed.
  project="$home/projects/duplicate-auto-fix-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\nauto_fix:\n  ci: 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-duplicate-parent duplicate-auto-fix-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a duplicate auto_fix mapping should scaffold conservatively"
  brief="$home/data/brief-document-duplicate-parent/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "duplicate top-level auto_fix mappings did not fail closed"
  assert_no_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "a document value from one of multiple auto_fix mappings enabled in-run correction"

  # Unsupported inline and quoted root-key forms can denote the same YAML key.
  # Either shape beside the supported block is ambiguous to the bounded reader.
  project="$home/projects/duplicate-inline-auto-fix-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\nauto_fix: {document: 0}\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-duplicate-inline-parent duplicate-inline-auto-fix-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "an inline duplicate auto_fix mapping should scaffold conservatively"
  brief="$home/data/brief-document-duplicate-inline-parent/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "an inline duplicate auto_fix mapping did not fail closed"
  assert_no_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "an inline duplicate auto_fix mapping enabled in-run correction"

  project="$home/projects/duplicate-quoted-auto-fix-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n"auto_fix":\n  document: 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-duplicate-quoted-parent duplicate-quoted-auto-fix-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a quoted duplicate auto_fix mapping should scaffold conservatively"
  brief="$home/data/brief-document-duplicate-quoted-parent/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a quoted duplicate auto_fix mapping did not fail closed"
  assert_no_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "a quoted duplicate auto_fix mapping enabled in-run correction"

  # Once the direct-child indentation is established, a shallower indented
  # sibling is malformed for this bounded grammar and must not preserve a
  # previously observed document value.
  project="$home/projects/inconsistent-auto-fix-indentation-project"
  mkdir -p "$project"
  printf 'auto_fix:\n    document: 1\n  ci: 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-invalid-indentation inconsistent-auto-fix-indentation-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "an inconsistently indented auto_fix mapping should scaffold conservatively"
  brief="$home/data/brief-document-invalid-indentation/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "inconsistent auto_fix child indentation did not fail closed"
  assert_no_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "an inconsistently indented auto_fix mapping enabled in-run correction"

  # Preserve the accepted XAU auto_fix mapping shape as the positive control:
  # one unquoted block with scalar siblings at one direct-child indentation.
  project="$home/projects/xau-auto-fix-shape-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  rebase: 2\n  review: 1\n  test: 0\n  document: 1\n  lint: 2\n  ci: 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-xau-shape xau-auto-fix-shape-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "the accepted XAU auto_fix shape should scaffold"
  brief="$home/data/brief-document-xau-shape/brief.md"
  assert_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "the accepted XAU auto_fix mapping shape lost its positive capability selection"

  project="$home/projects/malformed-document-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: enabled\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-10-g65e2262 (65e2262)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-malformed-value malformed-document-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a malformed document selection should scaffold conservatively"
  brief="$home/data/brief-document-malformed-value/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a malformed direct auto_fix.document value did not fail closed"

  project="$home/projects/future-candidate-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.99.0-new (revision-not-hardcoded) 2026-09-11T02:14:48-07:00' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-candidate future-candidate-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a future receipt-backed candidate brief should scaffold"
  brief="$home/data/brief-document-candidate/brief.md"
  assert_grep "The consuming project's trusted configuration selects bounded in-run document correction" "$brief" \
    "the future candidate's exact executable receipt was not recognized"

  project="$home/projects/report-only-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 0\n' > "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-7-g4fa1bb2 (4fa1bb2)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-report-only report-only-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a report-only project brief should scaffold"
  brief="$home/data/brief-document-report-only/brief.md"
  assert_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed." "$brief" \
    "auto_fix.document zero did not preserve the established report-only instruction"

  project="$home/projects/unreadable-project"
  mkdir -p "$project"
  ln -s missing-config "$project/.no-mistakes.yaml"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.65.0-7-g4fa1bb2 (4fa1bb2)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-unreadable unreadable-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "an unreadable-config project brief should scaffold conservatively"
  brief="$home/data/brief-document-unreadable/brief.md"
  assert_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed." "$brief" \
    "an unreadable configuration did not fail closed to report-only"

  project="$home/projects/mismatched-executable-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n' > "$project/.no-mistakes.yaml"
  printf '\n# changed after independent acceptance\n' >> "$fakebin/no-mistakes"
  FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v1.99.0-new (revision-not-hardcoded)' \
    PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-mismatch mismatched-executable-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a mismatched-executable project brief should scaffold conservatively"
  brief="$home/data/brief-document-mismatch/brief.md"
  assert_grep "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed." "$brief" \
    "an executable checksum mismatch did not fail closed to report-only"

  fm_test_fake_no_mistakes "$fakebin"
  cat > "$home/config/no-mistakes-document-correction.receipt" <<'EOF'
schema=fm-no-mistakes-document-correction.v1
executable_sha256=sha256:not-a-digest
proof_sha256=sha256:not-a-digest
EOF
  project="$home/projects/malformed-receipt-project"
  mkdir -p "$project"
  printf 'auto_fix:\n  document: 1\n' > "$project/.no-mistakes.yaml"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-document-malformed malformed-receipt-project \
      --mode no-mistakes >/dev/null 2>&1 \
    || fail "a malformed-receipt project brief should scaffold conservatively"
  brief="$home/data/brief-document-malformed/brief.md"
  assert_grep "The document step is report-only" "$brief" \
    "a malformed install receipt granted Document correction capability"
  pass "fm-brief.sh: Document instructions require unambiguous trusted configuration and an exact executable/proof capability receipt"
}

test_validation_revision_ignores_progress_history_but_binds_instruction_contract() {
  local dir brief before after
  dir="$TMP_ROOT/stable-validation-revision"
  mkdir -p "$dir"
  brief="$dir/brief.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Preserve the accepted behavior.

## Firstmate spec
Implement and verify the correction.

# Proof bar
Prep: Tier 2 - producer and consumers traced.
Resource: one focused test.
Surface: none: internal tooling.
Journey: one real CLI consumer.

# Progress history
working: first observation

# Definition of done
Run the required validation at the exact candidate head.
EOF
  before=$(bash -c \
    '. "$1"; fm_brief_source_revision "$2" "supported:fixture-a"' _ "$ROOT/bin/fm-dod-lib.sh" "$brief") \
    || fail "could not compute the initial stable instruction revision"
  sed -i 's/working: first observation/working: later observation/' "$brief"
  after=$(bash -c \
    '. "$1"; fm_brief_source_revision "$2" "supported:fixture-a"' _ "$ROOT/bin/fm-dod-lib.sh" "$brief") \
    || fail "could not compute the progress-edited stable instruction revision"
  [ "$before" = "$after" ] \
    || fail "a progress-history-only edit invalidated the instruction receipt"
  sed -i 's/Implement and verify/Implement, install, and verify/' "$brief"
  after=$(bash -c \
    '. "$1"; fm_brief_source_revision "$2" "supported:fixture-a"' _ "$ROOT/bin/fm-dod-lib.sh" "$brief")
  [ "$before" != "$after" ] || fail "a Firstmate implementation-spec edit did not invalidate the receipt"
  sed -i 's/Implement, install, and verify/Implement and verify/' "$brief"
  after=$(bash -c \
    '. "$1"; fm_brief_source_revision "$2" "supported:fixture-b"' _ "$ROOT/bin/fm-dod-lib.sh" "$brief")
  [ "$before" != "$after" ] || fail "a capability/config receipt change did not invalidate the instruction receipt"
  pass "validation revision ignores progress history while binding instructions and capability configuration"
}

# The effective validation input must keep captain authority, Firstmate's
# implementation specification, and the agreed proof contract distinct while
# delivering all three to the actual consumer.
test_validation_intent_separately_labels_captain_spec_and_proof() {
  local dir brief intent captain_part implementation_part proof_part
  dir="$TMP_ROOT/validation-intent-parts"
  mkdir -p "$dir"
  brief="$dir/brief.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Preserve the captain-owned outcome.

## Firstmate spec
Implement the bounded consumer correction.

# Proof bar
Prep: Tier 2 - producer and consumers traced.
Resource: one focused test.
Surface: none: internal tooling.
Journey: one real CLI consumer.
EOF

  intent=$(bash -c '. "$1"; fm_brief_validation_intent "$2"' _ \
    "$ROOT/bin/fm-dod-lib.sh" "$brief") \
    || fail "could not render the separately attributed validation input"
  captain_part=$(printf '%s\n' "$intent" | awk '
    /^Captain intent:$/ { emit=1; next }
    /^Firstmate implementation context:$/ { exit }
    emit { print }
  ')
  implementation_part=$(printf '%s\n' "$intent" | awk '
    /^Firstmate implementation context:$/ { emit=1; next }
    /^Agreed proof contract:$/ { exit }
    emit { print }
  ')
  proof_part=$(printf '%s\n' "$intent" | awk '
    /^Agreed proof contract:$/ { emit=1; next }
    emit { print }
  ')

  assert_contains "$captain_part" "Preserve the captain-owned outcome." \
    "validation input lost the captain-owned outcome"
  assert_not_contains "$captain_part" "Implement the bounded consumer correction." \
    "validation input attributed Firstmate's specification to the captain"
  assert_contains "$implementation_part" "Implement the bounded consumer correction." \
    "validation input omitted the separately labeled Firstmate implementation context"
  assert_not_contains "$implementation_part" "Preserve the captain-owned outcome." \
    "validation input duplicated captain authority into Firstmate implementation context"
  assert_contains "$proof_part" "Prep: Tier 2 - producer and consumers traced." \
    "validation input lost the agreed proof contract"
  pass "validation input separately labels captain authority, Firstmate implementation context, and proof"
}

# The captain's 2026-09-07 ruling: a delivery signal reports delivery, never
# product acceptance. Every mode's Definition of done must say so in its own
# generated brief, so no worker's "done:" line can be read as the user outcome
# having been accepted.
test_every_mode_dod_separates_delivery_from_acceptance() {
  local home id brief mode
  home="$TMP_ROOT/delivery-acceptance-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="brief-acceptance-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode brief was not scaffolded"
    assert_grep "Your delivery signal reports delivery, never product acceptance" "$brief" \
      "$mode DOD must state that the delivery signal is not product acceptance"
    assert_grep "Firstmate offers the work for acceptance separately, with the journey evidence" "$brief" \
      "$mode DOD must route acceptance through firstmate with the journey evidence"
  done
  pass "fm-brief.sh: every delivery mode's DOD separates the delivery signal from product acceptance"
}

test_ask_user_escalation_format() {
  local home id brief mode other_id other_brief
  home="$TMP_ROOT/ask-user-home"
  mkdir -p "$home/data"
  id="brief-ask-user-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # A no-mistakes ask-user gate must escalate its ask-user findings as one status
  # event plus one verbatim findings snapshot file, using that same shape even
  # for a single finding, never paraphrased into the status line.
  assert_grep "escalate all ask-user findings as one event plus one snapshot file" "$brief" \
    "ship rule 6 lost the one-event-plus-snapshot-file ask-user contract"
  assert_grep "using that same shape even when the gate holds only a single ask-user finding" "$brief" \
    "ship rule 6 must require the same shape for a single finding"
  assert_grep "write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority)" "$brief" \
    "ship rule 6 must limit the verbatim axi slice to ask-user findings"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks and the key/findings/file tokens must stay literal
  assert_grep 'needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must render the exact needs-decision ask-user status line"
  assert_grep "$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must point the snapshot file under this task's own data directory"
  assert_grep "The status line only points at the file; it never restates or summarizes a finding's content." "$brief" \
    "ship rule 6 must forbid paraphrasing ask-user findings into the status line"

  # The DOD's own ask-user paragraph must point back at rule 6's format
  # (one-owner rule) rather than restating or bare-citing it.
  assert_grep "escalate to firstmate using rule 6's ask-user format" "$brief" \
    "no-mistakes DOD ask-user paragraph must point at rule 6's format instead of a bare citation"
  assert_no_grep "escalate to firstmate (rule 6) and stop." "$brief" \
    "no-mistakes DOD ask-user paragraph still uses the old bare rule-6 pointer"

  other_id="brief-no-ask-user-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --scout >/dev/null 2>&1
  other_brief="$home/data/$other_id/brief.md"
  assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
    "scout brief received a no-mistakes-only decision case"

  for mode in direct-PR local-only; do
    other_id="brief-no-ask-user-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --mode "$mode" >/dev/null 2>&1
    other_brief="$home/data/$other_id/brief.md"
    assert_no_grep "nm-<run>-findings.txt" "$other_brief" \
      "$mode brief received a no-mistakes-only escalation format"
    assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
      "$mode brief received a no-mistakes-only decision case"
  done

  pass "fm-brief.sh: no-mistakes ask-user findings use one event plus a verbatim snapshot"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# Regression (issue #2575): AGENTS.md section 11 and this script's own help tell
# firstmate to fill `{TASK}` and `{FIRSTMATE_SPEC}`. The unguarded Herdr gate used
# to quote `{TASK}` in its own prose, so that documented global replace spliced
# the whole task body into the middle of the gate's sentence - silently
# destroying the one contract that exists precisely because the scaffold cannot
# see the task text. Each placeholder must exist only at its genuine fill site,
# so the documented fill leaves the gate intact and each body appears once.
test_documented_global_replace_leaves_the_herdr_gate_intact() {
  local home id brief kind count content filled body spec
  home="$TMP_ROOT/task-fill-site-home"
  mkdir -p "$home/data"
  body='Restart the herdr session, then profile it'
  spec='Use the isolated lab helper for every lifecycle call'
  for kind in ship scout; do
    id="brief-fill-site-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind brief was not scaffolded"
    count=$(grep -c -F '{TASK}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {TASK} fill site, found $count"
    count=$(grep -c -F '{FIRSTMATE_SPEC}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {FIRSTMATE_SPEC} fill site, found $count"
    content=$(cat "$brief")
    filled=${content//'{TASK}'/$body}
    filled=${filled//'{FIRSTMATE_SPEC}'/$spec}
    count=$(printf '%s\n' "$filled" | grep -c -F "$body")
    [ "$count" = 1 ] \
      || fail "$kind brief: the documented {TASK} replace duplicated the intent body $count times"
    count=$(printf '%s\n' "$filled" | grep -c -F "$spec")
    [ "$count" = 1 ] \
      || fail "$kind brief: the {FIRSTMATE_SPEC} replace duplicated the spec body $count times"
    printf '%s\n' "$filled" | grep -qF 'this scaffold cannot inspect the task text' \
      || fail "$kind brief: the Herdr safety gate did not survive the documented fill"
  done
  pass "fm-brief.sh: the documented {TASK} and {FIRSTMATE_SPEC} fills cannot corrupt the Herdr safety gate"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep '# The captain and the parent channel' "$brief" \
    "secondmate charter lost the parent-channel section"
  assert_grep 'Nobody reads this chat' "$brief" \
    "secondmate charter no longer says the chat is unread"
  assert_grep 'in this home it IS the captain' "$brief" \
    "secondmate charter no longer names the parent channel as the captain"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'bin/fm-secondmate-report.sh <verb> <corr_id> <note>' "$brief" \
    "secondmate charter lost the mechanical helper invocation"
  assert_grep 'do not pass a status path' "$brief" \
    "secondmate charter still tells the mate to pass a hand path to the helper"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, work ready for review, or work you landed' "$brief" \
    "secondmate charter lost decisions, blockers, failures, ready outcomes, or landed work"
  # Under standing merge authority nothing is ever "ready for review", so the
  # landed merge is the trigger a charter without this line silently omits.
  assert_grep 'a merge you performed yourself under standing merge authority and one the captain merged on the forge' "$brief" \
    "secondmate charter did not name a landed merge as a reporting trigger"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared captain-call policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "you may host the Lavish review loop yourself" "$brief" \
    "scout brief must mention the option to host a Lavish review loop"
  # Contract change: scouts select the evidence tool for the actual question.
  assert_grep "Select tools only for a real task purpose" "$brief" \
    "scout brief missing task-specific tool selection"
  assert_grep "use Context7 when its versioned documentation is the effective source" "$brief" \
    "scout brief did not retain Context7 for an applicable versioned-doc question"
  assert_grep "use Exa (\`mcp exa web search\` or fetch) or ordinary web search only as a bounded route" "$brief" \
    "scout brief missing the bounded official-source fallback"
  assert_grep "## Captain's intent" "$brief" "scout brief missing Captain's intent subsection"
  assert_grep "## Firstmate spec" "$brief" "scout brief missing Firstmate spec subsection"
  assert_grep "{FIRSTMATE_SPEC}" "$brief" "scout brief missing the spec placeholder"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  assert_no_grep "## Captain's intent" "$brief" \
    "secondmate charter must not grow ship/scout Task subsections"
  assert_no_grep "{FIRSTMATE_SPEC}" "$brief" \
    "secondmate charter must not carry the Firstmate spec placeholder"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_task_briefs_carry_project_authority_reconciliation() {
  local home id brief
  home="$TMP_ROOT/project-authority-home"
  mkdir -p "$home/data"

  for id in brief-authority-ship brief-authority-scout; do
    case "$id" in
      *-ship)  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1 ;;
      *-scout) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id brief was not scaffolded"
    assert_grep "# Project authority" "$brief" \
      "$id brief lost the project-authority section"
    assert_grep "reconcile this brief against current project authority" "$brief" \
      "$id brief must require reconciling against current project authority before acting"
    assert_grep "from the project's own current registry of authority" "$brief" \
      "$id brief must resolve the governing set from the project's current registry at dispatch time"
    assert_grep "never work from a remembered, inherited, or legacy list of authority documents" "$brief" \
      "$id brief must forbid a hardcoded or legacy authority list"
    assert_grep "Never let an older repository instruction silently override the current captain/task instruction" "$brief" \
      "$id brief must preserve current task-specific captain authority over older operational prose"
    assert_grep "never use the task instruction to weaken an actual product, security, safety or proof contract" "$brief" \
      "$id brief must preserve project product and safety contracts"
    assert_grep "Do not request new permission for scoped work the current captain/task instruction already authorizes" "$brief" \
      "$id brief must not reopen already granted scoped authority"
    assert_grep "stop unchanged retries, inspect the shared cause and complete the affected schema or consumer family" "$brief" \
      "$id brief must continue an evidence-producing bounded repair after a repeated obstacle"
    assert_no_grep "let the project's current authority win over any stale detail quoted here" "$brief" \
      "$id brief must not let older project prose silently override current task authority"
    assert_grep "Name any project prose this brief intentionally supersedes" "$brief" \
      "$id brief must require naming intentionally superseded project prose"
    assert_grep "Report a concrete conflict with both sources" "$brief" \
      "$id brief must preserve both sources when a real conflict remains"
    assert_grep "never arbitrate a project-authority conflict silently" "$brief" \
      "$id brief must route an unreconciled conflict to firstmate instead of the worker"
  done

  # A charter is not a task brief and must not carry a task's authority section.
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-authority-sm --secondmate alpha >/dev/null 2>&1
  brief="$home/data/brief-authority-sm/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_no_grep "# Project authority" "$brief" \
    "secondmate charter must not carry a task brief's project-authority section"

  pass "fm-brief.sh: ship and scout briefs carry the project-authority reconciliation contract"
}

test_all_scaffolds_carry_inbox_continuation_contract() {
  local home id brief
  home="$TMP_ROOT/inbox-continuation-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-inbox-ship some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh ship inbox scaffold exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-inbox-scout some-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout inbox scaffold exited non-zero"
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-inbox-sm --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate inbox scaffold exited non-zero"

  for id in brief-inbox-ship brief-inbox-scout brief-inbox-sm; do
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id brief was not scaffolded"
    assert_grep "Before deciding to wait, list the inbox again and read any newly arrived messages in numeric order" "$brief" \
      "$id brief must require a fresh ordered inbox read before waiting"
    assert_grep "including a later Firstmate correction while an earlier action is still pending" "$brief" \
      "$id brief must require later corrections to be read during pending work"
    assert_grep "preserve that action and its next step in durable task state before acknowledging the instruction" "$brief" \
      "$id brief must preserve the unfinished continuation before acknowledgement"
    assert_grep "does not claim task completion or resolve an open decision key" "$brief" \
      "$id brief must distinguish acknowledgement from completion and decision resolution"
  done

  pass "fm-brief.sh: every scaffold carries the durable inbox continuation contract"
}

test_ship_briefs_batch_findings_and_bounded_ci_retry_contract() {
  local home id brief
  home="$TMP_ROOT/batched-findings-home"
  mkdir -p "$home/data"
  id="brief-batched-findings"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"
  grep -Fqx "8. Before your first run, if you already know a fix pattern applies to more than the one site you were asked to change (a parser rule, a validation, a timestamp format, a malformed-input guard), sweep the whole repo for that mechanism under the same cap as the Proof bar's tiers, give every site found one of the evidence contract's three dispositions - fixed, confirmed unaffected, or out of scope with an owner - in one commit, and paste the site list into the Proof bar's Prep line before starting (rule B in the Proof bar above; this is Tier 1 prep done before the run instead of only after a review finds it)." "$brief" \
    || fail "ship brief must keep the pre-run mechanism-sweep clause as rule 8"
  assert_grep "never fix and resubmit the first defect you find" "$brief" \
    "ship brief must forbid fixing and resubmitting the first defect alone"
  assert_grep "Enumerate the COMPLETE finding set first" "$brief" \
    "ship brief must require the complete finding set before any repair"
  assert_grep "surfaces that can share each defect's mechanism" "$brief" \
    "ship brief must require checking surfaces that share the defect mechanism"
  assert_grep "One-at-a-time stop-fix-rereview loops are forbidden." "$brief" \
    "ship brief must forbid one-at-a-time stop-fix-rereview loops"
  assert_grep "unless the project's current retry contract expressly authorizes the designated dispatcher" "$brief" \
    "ship brief must limit CI retries to the project-owned authorized dispatcher"
  assert_grep "exact unchanged candidate under its required evidence and attempt limits" "$brief" \
    "ship brief must bind a permitted retry to exact candidate, evidence and attempt limits"
  assert_grep "publish a genuine reviewed repair; never create a filler head" "$brief" \
    "ship brief must require a real repair instead of a filler commit"
  assert_grep "never create a filler head or retry a stale-head or code-failure result" "$brief" \
    "ship brief must refuse stale-head and code-failure retries"
  # Test-quality clause (verification scout finding V08, firstmate half): a
  # new/changed test must name what it independently proves and be
  # failure-capable, and a test deletion/weakening needs a stated reason.
  # Rendered once, immediately after rule 9, keeping the numbering contiguous.
  grep -c '^10\. A new or changed test must name, in its own name or docstring, the behavior it independently proves' "$brief" \
    | grep -qx 1 \
    || fail "ship brief must render the test-quality clause exactly once as rule 10"
  assert_grep "must be shown failure-capable: red before the change, green after, or an equivalent neuter" "$brief" \
    "ship brief must require a new or changed test to be shown failure-capable"
  assert_grep "A test deletion, skip, or weakened assertion in the same diff must carry a stated reason naming the approved contract change" "$brief" \
    "ship brief must require a stated approved-contract-change reason for any test deletion, skip, or weakened assertion"
  assert_grep "it must never exist only to obtain green" "$brief" \
    "ship brief must forbid a test change that exists only to obtain green"
  # The name-and-origin pointer must resolve to the generated brief's ask-user rule without depending on its number.
  assert_grep "If a decision belongs above the implementation worker (product choices, destructive actions)," "$brief" \
    "the generated Rules section must retain the ask-user escalation rule"
  assert_grep "Do not request new permission for scoped work the current captain/task instruction already authorizes" "$brief" \
    "the generated Rules section must not reopen already granted scoped authority"
  assert_grep "stop unchanged retries, inspect the shared cause and complete the affected schema or consumer family" "$brief" \
    "the generated Rules section must continue productive bounded repair after a repeated obstacle"
  assert_grep "For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file" "$brief" \
    "the ask-user escalation must render the structured one-event-plus-snapshot contract"

  # The prep-tier cap must route its checkpoint to firstmate without treating
  # unreached consumers as irrelevant or pre-deciding that the task gets split.
  assert_grep "The cap: at 20 minutes or 15 sites, report a scope checkpoint to firstmate, list unreached consumers as evidence gaps, and continue with reached sites; the cap never proves omitted consumers irrelevant." "$brief" \
    "the Proof bar cap must route to a firstmate scope decision"
  assert_grep "A reviewer finding at a site NOT on your list is both a real finding to fix and a prep miss" "$brief" \
    "the Proof bar cap must retain unlisted reviewer findings as prep misses"
  assert_no_grep "gets split" "$brief" \
    "the Proof bar cap must not pre-decide that the task gets split"
  assert_no_grep "the task is scoped wrong" "$brief" \
    "the Proof bar cap must not unilaterally declare the task scoped wrong"
  assert_grep "the proof bar cannot exclude tests needed to keep already accepted behavior correct" "$brief" \
    "the Scope boundary must retain tests needed for already accepted behavior within the task"

  # The Proof bar's own instruction must point at the attributed --intent
  # contract's labeled `Agreed proof contract:` part, not a bare "alongside
  # the captain intent contract" reference that the overlay's rewritten
  # supersession sentence could be read to exclude it from (Codex advisor
  # review 2026-09-04, finding A3).
  assert_grep "copy this entire Proof bar section verbatim into \`--intent\`'s \`Agreed proof contract:\` part" "$brief" \
    "the Proof bar section must point at the attributed --intent contract's Agreed proof contract part"
  pass "fm-brief.sh: ship briefs require batching findings before repair or resubmission"
}

# The Proof bar's "Prep: {PREP}" placeholder has a sibling "Resource: {RESOURCE}"
# placeholder directly under it (the RAM/disk envelope Firstmate fills at
# intake, AGENTS.md section 11), and its two-sentence definition sits beside
# the tier definitions. Filling it at intake (the same way {PREP} is filled)
# must leave a real, non-placeholder line.
test_ship_brief_carries_the_resource_line() {
  local home id brief content
  home="$TMP_ROOT/resource-home"
  mkdir -p "$home/data"
  id="brief-resource-a1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"
  grep -Fqx 'Resource: {RESOURCE}' "$brief" \
    || fail "ship brief must scaffold the unfilled \"Resource: {RESOURCE}\" placeholder"
  # It must sit directly under the Prep line, not floating elsewhere in the section.
  awk '
    $0 == "Prep: {PREP}" { got_prep = 1; next }
    got_prep { if ($0 == "Resource: {RESOURCE}") found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$brief" || fail "the Resource placeholder must sit directly under the Prep placeholder"
  assert_grep "Resource, the RAM/disk envelope this task may use for tests and builds" "$brief" \
    "ship brief must carry the Resource tier definition beside the Prep tier definitions"
  assert_grep "read the available column of free -g with \`free -g | awk '/^Mem:/ { print \$7 }'\` before any browser suite" "$brief" \
    "ship brief must direct browser-suite memory checks to free's available column"
  assert_grep 'or "N/A" when the task executes no tests or builds' "$brief" \
    "the Resource definition must state the N/A escape hatch for no-test/no-build tasks"

  # Firstmate fills {RESOURCE} at intake exactly like {PREP}; the filled line
  # must be a real, non-placeholder value.
  content=$(cat "$brief")
  content=${content//'Prep: {PREP}'/'Prep: Tier 0 - test fixture, not a real change'}
  content=${content//'Resource: {RESOURCE}'/'Resource: one test process at a time, no whole-repo lint or battery locally'}
  printf '%s\n' "$content" > "$brief"
  assert_no_grep '{RESOURCE}' "$brief" "a filled Resource line must leave no leftover placeholder token"
  grep -Fqx 'Resource: one test process at a time, no whole-repo lint or battery locally' "$brief" \
    || fail "the filled Resource line did not carry the real value through"
  pass "fm-brief.sh: the ship scaffold carries a fillable Resource line beside Prep"
}

# The Proof bar's "Surface: {SURFACE}" placeholder is the Resource line's twin
# (captain ruling 2026-09-05): the dashboard is the only way the operator,
# user, and admin work with the app, so every ship brief must state the page,
# component, or journey where the operator sees the change, or "none: <reason>".
test_ship_brief_carries_the_surface_line() {
  local home id brief content
  home="$TMP_ROOT/surface-home"
  mkdir -p "$home/data"
  id="brief-surface-a1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"
  grep -Fqx 'Surface: {SURFACE}' "$brief" \
    || fail "ship brief must scaffold the unfilled \"Surface: {SURFACE}\" placeholder"
  # It must sit directly under the Resource line, not floating elsewhere in the section.
  awk '
    $0 == "Resource: {RESOURCE}" { got_resource = 1; next }
    got_resource { if ($0 == "Surface: {SURFACE}") found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$brief" || fail "the Surface placeholder must sit directly under the Resource placeholder"
  assert_grep "Surface, the page, component, or journey where the operator sees this change in the dashboard" "$brief" \
    "ship brief must carry the Surface tier definition beside the Prep and Resource tier definitions"
  assert_grep '"none: {reason}" when the change has no operator-visible effect' "$brief" \
    "the Surface definition must state the none escape hatch for no-operator-visible-effect tasks"

  # Firstmate fills {SURFACE} at intake exactly like {PREP} and {RESOURCE}; the
  # filled line must be a real, non-placeholder value.
  content=$(cat "$brief")
  content=${content//'Prep: {PREP}'/'Prep: Tier 0 - test fixture, not a real change'}
  content=${content//'Resource: {RESOURCE}'/'Resource: one test process at a time, no whole-repo lint or battery locally'}
  content=${content//'Surface: {SURFACE}'/'Surface: the run-detail page'\''s Evidence tab'}
  printf '%s\n' "$content" > "$brief"
  assert_no_grep '{SURFACE}' "$brief" "a filled Surface line must leave no leftover placeholder token"
  grep -Fqx "Surface: the run-detail page's Evidence tab" "$brief" \
    || fail "the filled Surface line did not carry the real value through"
  pass "fm-brief.sh: the ship scaffold carries a fillable Surface line beside Prep and Resource"
}

# The Proof bar's "Journey: {JOURNEY}" placeholder is the Surface line's twin
# (captain ruling 2026-09-07): substantial or uncertain product-facing work
# carries its preparation into the build, and that preparation is reviewed
# against the user requirement rather than against what the implementation
# happens to support. This section is also the single owner of the preparation
# item list, so the definition must carry the items themselves, the "none:"
# escape, the no-silent-omission rule for a parked design, and the pre-run
# explanation the builder owes in its own words.
test_ship_brief_carries_the_journey_line() {
  local home id brief content
  home="$TMP_ROOT/journey-home"
  mkdir -p "$home/data"
  id="brief-journey-a1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"
  grep -Fqx 'Journey: {JOURNEY}' "$brief" \
    || fail "ship brief must scaffold the unfilled \"Journey: {JOURNEY}\" placeholder"
  # It must sit directly under the Surface line, not floating elsewhere in the section.
  awk '
    $0 == "Surface: {SURFACE}" { got_surface = 1; next }
    got_surface { if ($0 == "Journey: {JOURNEY}") found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$brief" || fail "the Journey placeholder must sit directly under the Surface placeholder"
  assert_grep "Journey, the preparation this task carries into the build" "$brief" \
    "ship brief must carry the Journey definition beside the Prep, Resource, and Surface definitions"
  assert_grep "numbered browser actions with independently justified expected results" "$brief" \
    "the Journey definition must own the preparation item list rather than pointing elsewhere for it"
  assert_grep "each marked expected or defect" "$brief" \
    "the Journey definition must distinguish an expected failure from a defect"
  assert_grep "a parked design never silently justifies a required interaction that is missing" "$brief" \
    "the Journey definition must forbid a parked design silently excusing a missing interaction"
  assert_grep "Firstmate reviews this preparation against the user requirement, not against what the current implementation happens to support" "$brief" \
    "the Journey definition must state the review is against the user requirement"
  assert_grep '"none: {reason}" when the work is neither substantial nor uncertain' "$brief" \
    "the Journey definition must state the none escape hatch"
  assert_grep 'When the Journey line names real preparation, append one status line before your first run' "$brief" \
    "the Proof bar must require the builder's own pre-run explanation of requirement, failure modes, and proof plan"
  assert_grep '"read and understood" does not satisfy it' "$brief" \
    "the pre-run explanation must be in the builder's own words, not an acknowledgement"
  # Scoped, not a new blanket status obligation: a "none:" Journey owes nothing,
  # so a Tier 0 change with no product-facing journey gains no ceremony.
  assert_grep 'A "none: {reason}" Journey owes no such line' "$brief" \
    "the pre-run explanation must be scoped to a Journey that names real preparation"

  # Firstmate fills {JOURNEY} at intake exactly like {PREP}, {RESOURCE}, and
  # {SURFACE}; the filled line must be a real, non-placeholder value.
  content=$(cat "$brief")
  content=${content//'Journey: {JOURNEY}'/'Journey: none: firstmate instruction text, no product-facing journey'}
  printf '%s\n' "$content" > "$brief"
  assert_no_grep '{JOURNEY}' "$brief" "a filled Journey line must leave no leftover placeholder token"
  grep -Fqx 'Journey: none: firstmate instruction text, no product-facing journey' "$brief" \
    || fail "the filled Journey line did not carry the real value through"
  pass "fm-brief.sh: the ship scaffold carries a fillable Journey line beside Prep, Resource, and Surface"
}

# A batch owner can be briefed through either PR mode, while a local-only brief
# must still render the mismatch refusal. The shared DoD output presents the
# PR-backed and PR-less constituent routes separately, including their different
# binding moments, without changing the join-review or landing tables.
test_every_ship_dod_renders_the_conditional_integration_batch_binding() {
  local home id brief mode
  home="$TMP_ROOT/integration-batch-dod-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="brief-integration-batch-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode brief was not scaffolded"
    assert_grep '## Conditional integration-batch definition of done' "$brief" \
      "$mode DOD did not render the conditional batch-owner gate"
    assert_grep '| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |' "$brief" \
      "$mode DOD did not render the PR-backed constituent table"
    # shellcheck disable=SC2016  # backticks are the literal markdown code-span, not command substitution
    assert_grep '`Closed as superseded; not merged.`' "$brief" \
      "$mode DOD did not preserve the required superseded-not-merged statement"
    assert_grep 'Before the combined pull request lands, bind each PR-backed constituent' "$brief" \
      "$mode DOD did not keep PR-backed binding before landing"
    assert_grep '| PR-less constituent task | Branch | Exact reviewed head | Disposition |' "$brief" \
      "$mode DOD did not render the PR-less constituent row shape"
    # shellcheck disable=SC2016  # backticks are literal Markdown code spans.
    assert_grep '| `<task-id>` | `<branch>` | `<full-sha>` | `No original pull request.` |' "$brief" \
      "$mode DOD did not record the explicit no-original-PR disposition"
    assert_grep 'After the combined pull request merges, bind each PR-less constituent' "$brief" \
      "$mode DOD did not defer PR-less binding until after the combined landing"
    assert_grep 'merged state, default-branch landing, and permanent-head containment checks' "$brief" \
      "$mode DOD did not state the stricter PR-less binding proof"
    assert_no_grep 'this complete table with one row per constituent' "$brief" \
      "$mode DOD still made the original-PR row mandatory for PR-less constituents"
    assert_grep 'Never fabricate a constituent pull request or mark one merged merely to make it eligible for the batch.' "$brief" \
      "$mode DOD did not forbid a fabricated or falsely merged constituent PR"
    assert_grep "Preserve every independently required publication obligation imposed by the constituent's selected delivery route." "$brief" \
      "$mode DOD dropped route-specific publication obligations"
    assert_grep '| Constituent task | Changes missing from the candidate | Deliberate replacements | Join repairs |' "$brief" \
      "$mode DOD did not render the explicit join review that states what the joins did to each constituent"
    assert_grep 'is not evidence that every constituent behavior survived' "$brief" \
      "$mode DOD let an unchanged tree stand in for the join review"
    assert_grep '| Pipeline-tested head | Landed squash commit |' "$brief" \
      "$mode DOD did not render the landing record naming the tested head and the landed squash commit"
    assert_grep 'These are two different commits' "$brief" \
      "$mode DOD still claimed the tested head and the landed commit are one commit"
    assert_grep 'a pull request head that exists is not evidence that it landed' "$brief" \
      "$mode DOD did not require the landed commit to be read from the forge"
    assert_no_grep 'bin/fm-pr-merge.sh --merge' "$brief" \
      "$mode DOD still prescribed the merge-commit landing a squash contract cannot use"
    assert_grep 'bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>' "$brief" \
      "$mode DOD did not render the supported constituent binding command"
  done
  brief="$home/data/brief-integration-batch-local-only/brief.md"
  assert_grep 'A local-only task cannot own a combined pull request' "$brief" \
    "local-only DOD did not refuse an integration-owner role that requires a PR"
  pass "fm-brief.sh: every ship DOD renders the batch-owner membership table, join review, squash-honest landing record, and record binding"
}

# A task designated as a batch owner AFTER dispatch has no way to get its real
# constituent and join-review tables into its own brief: fm_integration_batch_dod_block's
# owner-side "## Conditional integration-batch definition of done" is only an
# unfilled template. bin/fm-dod-lib.sh render-batch-owner-record is the
# supported path that renders that post-dispatch record into a new
# "## Combined candidate record (integration batch)" subsection at the end of
# the brief's Proof bar, using the same PR-backed, PR-less, join-review, and
# landing-record table shapes fm_integration_batch_dod_block already renders,
# and prints the refreshed revision-bound run-validation command. Because the
# subsection lives inside "# Proof bar", fm_brief_validation_intent carries it
# into --intent's "Agreed proof contract:" part automatically - the same path
# the combined pull request body is required to get every row and table
# through, never a hand-edit.
test_render_batch_owner_record_carries_the_batch_tables_into_the_run_intent_only() {
  local home id brief revision out rc intent
  home="$TMP_ROOT/render-batch-owner-record-home"
  mkdir -p "$home/data"
  id="brief-batch-owner-record"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "render-batch-owner-record: brief was not scaffolded"
  sed -i \
    -e 's|^{TASK}$|Do the batch-owner-record thing.|' \
    -e 's|^{FIRSTMATE_SPEC}$|Render the batch owner record.|' \
    -e 's|^Prep: {PREP}$|Prep: Tier 0 - no callers.|' \
    -e 's|^Resource: {RESOURCE}$|Resource: N/A|' \
    -e 's|^Surface: {SURFACE}$|Surface: none: internal Firstmate tooling.|' \
    -e 's|^Journey: {JOURNEY}$|Journey: none: no product-facing journey.|' \
    "$brief"
  assert_no_grep '^\({TASK}\|{FIRSTMATE_SPEC}\|Prep: {PREP}\|Resource: {RESOURCE}\|Surface: {SURFACE}\|Journey: {JOURNEY}\)$' "$brief" \
    "render-batch-owner-record: the generated brief still carries an unfilled scaffold field"

  out=$(bash "$ROOT/bin/fm-dod-lib.sh" render-batch-owner-record \
    --brief "$brief" \
    --combined-pr https://github.com/example/repo/pull/900 \
    --designated 2026-09-10 \
    --runner no-mistakes \
    --pr-backed 'batch-record-a|fm/batch-record-a|1111111111111111111111111111111111111111|https://github.com/example/repo/pull/10' \
    --pr-less 'batch-record-b|fm/batch-record-b|2222222222222222222222222222222222222222' \
    --join 'batch-record-a|None|None|None' \
    --join 'batch-record-b|None|None|None')
  rc=$?
  expect_code 0 "$rc" "render-batch-owner-record: the command refused a well-formed post-dispatch batch-owner record: $out"

  assert_grep '## Combined candidate record (integration batch)' "$brief" \
    "render-batch-owner-record: the new subsection was not appended to the Proof bar"
  assert_grep 'The combined pull request is https://github.com/example/repo/pull/900.' "$brief" \
    "render-batch-owner-record: the combined PR was not named"
  # shellcheck disable=SC2016  # backticks are literal Markdown code spans.
  assert_grep '| `batch-record-a` | `fm/batch-record-a` | `1111111111111111111111111111111111111111` | `https://github.com/example/repo/pull/10` | `Closed as superseded; not merged.` |' "$brief" \
    "render-batch-owner-record: the PR-backed constituent row was not rendered with the real values"
  # shellcheck disable=SC2016
  assert_grep '| `batch-record-b` | `fm/batch-record-b` | `2222222222222222222222222222222222222222` | `No original pull request.` |' "$brief" \
    "render-batch-owner-record: the PR-less constituent row was not rendered with the real values"
  # shellcheck disable=SC2016
  assert_grep '| `batch-record-a` | None | None | None |' "$brief" \
    "render-batch-owner-record: the join review row for the PR-backed constituent was not rendered"
  # shellcheck disable=SC2016
  assert_grep '| `batch-record-b` | None | None | None |' "$brief" \
    "render-batch-owner-record: the join review row for the PR-less constituent was not rendered"
  assert_grep '| Pipeline-tested head | Landed squash commit |' "$brief" \
    "render-batch-owner-record: the landing record table was not rendered"

  revision=$(bash -c '. "$1"; fm_brief_source_revision "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$brief") \
    || fail "render-batch-owner-record: could not compute the rewritten brief's own revision"
  printf '%s\n' "$out" > "$home/render-output"
  assert_grep "$revision" "$home/render-output" \
    "render-batch-owner-record: the printed run-validation command was not bound to the rewritten brief's actual revision"

  intent=$(bash -c '. "$1"; fm_brief_validation_intent "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$brief") \
    || fail "render-batch-owner-record: could not render the brief's --intent"
  printf '%s\n' "$intent" > "$home/rendered-intent"
  assert_grep 'batch-record-a' "$home/rendered-intent" \
    "render-batch-owner-record: the batch-owner record did not reach --intent's Agreed proof contract"
  assert_grep 'Closed as superseded; not merged.' "$home/rendered-intent" \
    "render-batch-owner-record: the PR-backed disposition did not reach --intent"

  set +e
  out=$(bash "$ROOT/bin/fm-dod-lib.sh" render-batch-owner-record \
    --brief "$brief" --combined-pr https://github.com/example/repo/pull/900 --designated 2026-09-10 \
    --runner no-mistakes --pr-backed 'x|y|z|w' --join 'x|None|None|None' 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "render-batch-owner-record: a second call on the same brief should refuse rather than duplicate the subsection"
  printf '%s\n' "$out" > "$home/render-refusal"
  assert_grep 'already carries a Combined candidate record subsection' "$home/render-refusal" \
    "render-batch-owner-record: the refusal did not name the existing subsection"
  [ "$(grep -c '## Combined candidate record (integration batch)' "$brief")" -eq 1 ] \
    || fail "render-batch-owner-record: a refused re-run duplicated the subsection anyway"

  pass "fm-dod-lib.sh render-batch-owner-record: renders the post-dispatch batch owner's PR-backed, PR-less, join-review, and landing tables into the brief's Proof bar so they reach --intent, refuses to duplicate an existing subsection"
}

# A batch owner once hand-edited a combined pull request body outside the
# no-mistakes pipeline, which stripped the pipeline section and failed the
# attestation check. Every no-mistakes ship's brief carries both the ordinary
# completion instructions and the conditional integration-batch section (it
# may later be designated an owner), so a plain no-mistakes brief with no
# --batch-constituent-of must state the PR-body-is-pipeline-output rule in
# both places.
test_no_mistakes_dod_states_pr_body_is_pipeline_output_in_both_variants() {
  local home brief
  home="$TMP_ROOT/no-mistakes-pr-body-pipeline-only"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" pr-body-rule some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/pr-body-rule/brief.md"
  # shellcheck disable=SC2016  # backticks are literal Markdown code spans.
  assert_grep 'The PR body is pipeline output only: never run `gh pr edit` or `gh-axi pr edit` on it' "$brief" \
    "no-mistakes DOD did not state the PR-body-is-pipeline-output rule in the ordinary variant"
  assert_grep "The combined pull request's body is pipeline output only: never run \`gh pr edit\` or \`gh-axi pr edit\` on it" "$brief" \
    "no-mistakes DOD did not state the PR-body-is-pipeline-output rule in the batch-owner variant"
  pass "fm-brief.sh: the no-mistakes DOD states the PR body is pipeline output only, in both the ordinary and batch-owner variants"
}

# Controlled case C6 consumes generated briefs, then feeds the real owners
# (bin/fm-pr-check.sh --absorbed-by, bin/fm-pr-merge.sh, bin/fm-teardown.sh)
# behind a fake `gh`/`gh-axi` forge boundary - the same boundary shape the
# owners' own tests use (tests/fm-pr-check.test.sh's install_absorbed_gh,
# tests/fm-pr-merge.test.sh's add_gh_mocks, tests/fm-teardown.test.sh's
# add_gh_batch_states). Landing-window serialization ("Hold the landing
# window" in .agents/skills/integration-batch-delivery/SKILL.md) is scheduling
# discipline: no script in this repo enforces it, so this rehearsal does not
# narrate a window being reserved, held, or released, or count how many local
# tests or constituent handoffs occur - those clauses stay unverified by code.
c6_consume_constituent_brief() {  # <brief> <route>
  local brief=$1 route=$2
  grep -F "deliver your exact reviewed head and focused evidence to the named integration owner \`c6-owner\`" "$brief" >/dev/null \
    || return 1
  grep -F 'Do not start a standalone no-mistakes pipeline merely to become a batch member.' "$brief" >/dev/null \
    || return 1
  ! grep -F 'Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.' "$brief" >/dev/null \
    || return 1
  ! grep -F '| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |' "$brief" >/dev/null \
    || return 1
  case "$route" in independently-required-pr|pr-less) ;; *) return 1 ;; esac
}

# A combined `gh` fake serving bin/fm-pr-check.sh, bin/fm-pr-merge.sh and
# bin/fm-teardown.sh for PR #5 (c6-a's own original PR) and PR #9 (the
# combined c6-owner PR). PR #9's dynamic fields (state/head/mergecommit) are
# small files under $ghstate that the rehearsal rewrites between phases;
# fm-pr-merge.sh's check-runs/compare/graphql/branch-rules endpoints never
# name a PR number, so they always resolve to PR #9, the only PR this
# rehearsal ever merges.
c6_install_gh() {  # <fakebin> <ghstate>
  local fakebin=$1 ghstate=$2
  mkdir -p "$ghstate"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
set -u
args=" \$* "
pr=
case "\$args" in
  *"/pull/5"*|*" 5 --repo "*) pr=5 ;;
  *"/pull/9"*|*" 9 --repo "*) pr=9 ;;
esac
base="$ghstate/pr\$pr"
case "\$args" in
  *"--json state,headRefOid,mergeCommit,url"*)
    printf '%s\t%s\t%s\t%s\n' "\$(cat "\$base-state" 2>/dev/null)" "\$(cat "\$base-head" 2>/dev/null)" "\$(cat "\$base-mergecommit" 2>/dev/null)" "\$(cat "\$base-url" 2>/dev/null)"
    ;;
  *"--json state,headRefOid,url"*)
    printf '%s\t%s\t%s\n' "\$(cat "\$base-state" 2>/dev/null)" "\$(cat "\$base-head" 2>/dev/null)" "\$(cat "\$base-url" 2>/dev/null)"
    ;;
  *"--json headRefName"*) cat "\$base-branch" 2>/dev/null ;;
  *"--json headRefOid"*) cat "\$base-head" 2>/dev/null ;;
  *"--json baseRefName"*) cat "\$base-baseref" 2>/dev/null ;;
  *"--json title"*) printf 'c6-owner combined PR\n' ;;
  *"--json body"*) printf 'combined body\n' ;;
  *"--json state"*) cat "\$base-state" 2>/dev/null ;;
  *"api graphql"*) cat "$ghstate/pr9-outcome" 2>/dev/null ;;
  *"check-runs"*) cat "$ghstate/pr9-checks" 2>/dev/null ;;
  *"compare/"*) cat "$ghstate/pr9-compare" 2>/dev/null ;;
  api\ *) cat "$ghstate/pr9-rules" 2>/dev/null ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_C6_GHAXI_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

c6_write_pr5() {  # <ghstate> <state> <head>
  printf '%s\n' "$2" > "$1/pr5-state"
  printf 'fm/c6-a\n' > "$1/pr5-branch"
  printf '%s\n' "$3" > "$1/pr5-head"
  printf 'https://github.com/example/repo/pull/5\n' > "$1/pr5-url"
}

c6_write_pr9() {  # <ghstate> <state> <head> <mergecommit>
  printf '%s\n' "$2" > "$1/pr9-state"
  printf 'fm/c6-owner\n' > "$1/pr9-branch"
  printf 'main\n' > "$1/pr9-baseref"
  printf '%s\n' "$3" > "$1/pr9-head"
  printf '%s\n' "$4" > "$1/pr9-mergecommit"
  printf 'https://github.com/example/repo/pull/9\n' > "$1/pr9-url"
}

test_c6_parallel_preparation_bounded_batch_and_safe_landing_rehearsal() {
  local home repo a_head b_head c_head candidate first_candidate main_moved renewed_candidate
  local a_brief b_brief owner_brief broken fakebin ghstate wt_a wt_b squash
  local rc out config data
  home="$TMP_ROOT/c6-controlled-rehearsal"
  repo="$home/synthetic-project"
  fakebin=$(fm_fakebin "$home")
  ghstate="$home/gh"
  data="$home/data"
  config="$home/config"
  mkdir -p "$data" "$home/projects" "$config" "$home/state"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  git -C "$repo" checkout -q -b fm/c6-a
  printf 'A\n' > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'reviewed A'
  a_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b fm/c6-b
  printf 'B\n' > "$repo/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'reviewed B'
  b_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b fm/c6-c
  printf 'stable-interface-v1\n' > "$repo/interface.txt"
  git -C "$repo" add interface.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'prepare C against stable interface'
  c_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b fm/c6-owner
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid merge -q --no-ff --no-edit "$a_head"
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid merge -q --no-ff --no-edit "$b_head"
  candidate=$(git -C "$repo" rev-parse HEAD)

  git -C "$repo" merge-base --is-ancestor "$a_head" "$candidate" \
    || fail "C6: the combined candidate rewrote or omitted A's exact reviewed head"
  git -C "$repo" merge-base --is-ancestor "$b_head" "$candidate" \
    || fail "C6: the combined candidate rewrote or omitted B's exact reviewed head"
  [ "$c_head" != "$candidate" ] || fail "C6: C preparation was accidentally made batch membership"

  # A real origin so bin/fm-pr-check.sh's permanent-head-ref fetch and
  # bin/fm-pr-merge.sh/bin/fm-teardown.sh's default-branch reads have a forge
  # to talk to, mirroring fm-pr-check.test.sh's make_case/land_squash_on_main.
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" push -q origin main
  git -C "$repo" push -q origin "$a_head:refs/pull/5/head"
  first_candidate=$candidate
  git -C "$repo" push -q origin "$first_candidate:refs/pull/9/head"
  wt_a="$home/wt-c6-a"
  wt_b="$home/wt-c6-b"
  git -C "$repo" worktree add -q "$wt_a" fm/c6-a
  git -C "$repo" worktree add -q "$wt_b" fm/c6-b
  c6_install_gh "$fakebin" "$ghstate"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" c6-a synthetic-project --mode no-mistakes \
    --batch-constituent-of c6-owner >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" c6-b synthetic-project --mode no-mistakes \
    --batch-constituent-of c6-owner >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" c6-c synthetic-project --mode local-only >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" c6-owner synthetic-project --mode no-mistakes >/dev/null 2>&1
  a_brief="$home/data/c6-a/brief.md"
  b_brief="$home/data/c6-b/brief.md"
  owner_brief="$home/data/c6-owner/brief.md"

  c6_consume_constituent_brief "$a_brief" independently-required-pr \
    || fail "C6: the generated PR-backed constituent brief could not be consumed"
  c6_consume_constituent_brief "$b_brief" pr-less \
    || fail "C6: the generated PR-less constituent brief could not be consumed"
  assert_grep '| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |' "$owner_brief" \
    "C6: the combined-owner brief lost the PR-backed custody route"
  assert_grep '| PR-less constituent task | Branch | Exact reviewed head | Disposition |' "$owner_brief" \
    "C6: the combined-owner brief lost the PR-less custody route"
  assert_grep '| Constituent task | Changes missing from the candidate | Deliberate replacements | Join repairs |' "$owner_brief" \
    "C6: the combined-owner brief lost the explicit join review"

  # Broken control one restores the old mandatory original-PR row for B.
  broken="$home/broken-old-original-pr.md"
  cp "$b_brief" "$broken"
  printf '%s\n' '| Constituent task | Branch | Exact constituent head | Original pull request URL | Disposition |' \
    '| c6-b | fm/c6-b | deadbeef | https://github.com/example/repo/pull/5 | Closed as superseded; not merged. |' >> "$broken"
  if c6_consume_constituent_brief "$broken" pr-less; then
    fail "C6 broken control: a PR-less constituent accepted the old mandatory original-PR row"
  fi

  # Broken control two restores the old standalone-pipeline next step.
  broken="$home/broken-old-standalone-pipeline.md"
  cp "$a_brief" "$broken"
  printf '%s\n' 'Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.' >> "$broken"
  if c6_consume_constituent_brief "$broken" independently-required-pr; then
    fail "C6 broken control: a named constituent accepted the old membership-only standalone pipeline instruction"
  fi

  # --- binding: bin/fm-pr-check.sh --absorbed-by for both custody routes -----
  fm_write_meta "$home/state/c6-a.meta" \
    "window=firstmate:fm-c6-a" "endpoint_task_id=c6-a" "worktree=$wt_a" \
    "project=$repo" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/5"
  fm_write_meta "$home/state/c6-b.meta" \
    "window=firstmate:fm-c6-b" "endpoint_task_id=c6-b" "worktree=$wt_b" \
    "project=$repo" "kind=ship" "mode=no-mistakes" "spawn_gen=c6-b-gen"

  c6_write_pr5 "$ghstate" CLOSED "$a_head"
  c6_write_pr9 "$ghstate" OPEN "$first_candidate" ''
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-pr-check.sh" --absorbed-by c6-a \
    https://github.com/example/repo/pull/9 >/dev/null 2>"$home/pr-check-a.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "C6: fm-pr-check.sh --absorbed-by refused the PR-backed constituent binding: $(cat "$home/pr-check-a.err")"
  assert_grep 'batch_superseded_disposition=closed-as-superseded-not-merged' "$home/state/c6-a.meta" \
    "C6: fm-pr-check.sh did not bind c6-a's original PR as superseded"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$home/state/c6-a.meta" \
    "C6: fm-pr-check.sh did not make the combined PR c6-a's canonical landing"

  # A PR-less constituent cannot bind before the combined PR actually merges.
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-pr-check.sh" --absorbed-by c6-b \
    https://github.com/example/repo/pull/9 >/dev/null 2>"$home/pr-check-b1.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "C6: fm-pr-check.sh bound a PR-less constituent before the combined PR merged"
  assert_grep 'must be merged before binding a PR-less constituent' "$home/pr-check-b1.err" \
    "C6: the premature PR-less binding refusal did not name the merge requirement"

  # --- latest-check judgement and main containment: bin/fm-pr-merge.sh -------
  fm_write_meta "$home/state/c6-owner.meta" \
    "window=firstmate:fm-c6-owner" "endpoint_task_id=c6-owner" "worktree=$repo" \
    "project=$repo" "kind=ship" "mode=no-mistakes"
  printf '1\tci\tcompleted\tsuccess\n' > "$ghstate/pr9-checks"
  printf 'status=ahead\nbehind=0\nbase_sha=%s\n' "$(git -C "$repo" rev-parse main)" \
    > "$ghstate/pr9-compare"
  : > "$ghstate/pr9-rules"
  : > "$home/gh-axi.log"
  set +e
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" FM_C6_GHAXI_LOG="$home/gh-axi.log" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" c6-owner \
    https://github.com/example/repo/pull/9 >"$home/pr-merge-1.out" 2>"$home/pr-merge-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "C6: fm-pr-merge.sh refused the first combined candidate at full main containment: $(cat "$home/pr-merge-1.err")"
  assert_grep 'pr merge' "$home/gh-axi.log" \
    "C6: fm-pr-merge.sh did not attempt the merge for the contained first candidate"

  # An unrelated change lands on main while c6-owner's proof is still at the
  # first candidate: this is the real "material candidate failure" -
  # fm-pr-merge.sh's own current-main containment guard refuses, replacing any
  # narrated window release.
  git -C "$repo" checkout -q main
  printf 'main moved\n' > "$repo/main.txt"
  git -C "$repo" add main.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm 'unrelated landed work'
  main_moved=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q fm/c6-owner
  printf 'OPEN\n' > "$ghstate/pr9-state"
  printf 'status=behind\nbehind=1\nbase_sha=%s\n' "$main_moved" > "$ghstate/pr9-compare"
  : > "$home/gh-axi.log"
  set +e
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" FM_C6_GHAXI_LOG="$home/gh-axi.log" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" c6-owner \
    https://github.com/example/repo/pull/9 >"$home/pr-merge-2.out" 2>"$home/pr-merge-2.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "C6: fm-pr-merge.sh merged a candidate that no longer contains current main"
  assert_grep 'the base branch moved after this pull request was validated' "$home/pr-merge-2.err" \
    "C6: the main-moved refusal did not name the real containment failure"
  assert_no_grep 'pr merge' "$home/gh-axi.log" \
    "C6: a stale-base candidate reached the merge call"

  # c6-owner merges current main into the candidate and re-proves once at the
  # renewed exact head - one combined run, never a per-constituent restart.
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid merge -q --no-ff --no-edit "$main_moved"
  renewed_candidate=$(git -C "$repo" rev-parse HEAD)
  [ "$renewed_candidate" != "$first_candidate" ] || fail "C6: moving main did not change the candidate head"
  git -C "$repo" merge-base --is-ancestor "$main_moved" "$renewed_candidate" \
    || fail "C6: renewed candidate does not contain current main"
  git -C "$repo" merge-base --is-ancestor "$a_head" "$renewed_candidate" \
    || fail "C6: renewed candidate lost A ancestry"
  git -C "$repo" merge-base --is-ancestor "$b_head" "$renewed_candidate" \
    || fail "C6: renewed candidate lost B ancestry"
  git -C "$repo" push -q -f origin "$renewed_candidate:refs/pull/9/head"
  printf '%s\n' "$renewed_candidate" > "$ghstate/pr9-head"
  printf 'status=ahead\nbehind=0\nbase_sha=%s\n' "$main_moved" > "$ghstate/pr9-compare"
  printf '1\tci\tcompleted\tsuccess\n' > "$ghstate/pr9-checks"
  : > "$home/gh-axi.log"
  set +e
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" FM_C6_GHAXI_LOG="$home/gh-axi.log" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-pr-merge.sh" c6-owner \
    https://github.com/example/repo/pull/9 >"$home/pr-merge-3.out" 2>"$home/pr-merge-3.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "C6: fm-pr-merge.sh refused the renewed candidate at its own current head: $(cat "$home/pr-merge-3.err")"
  assert_grep "$renewed_candidate" "$home/pr-merge-3.err" \
    "C6: fm-pr-merge.sh's checks/containment verdicts did not name the renewed exact head"
  assert_grep 'pr merge' "$home/gh-axi.log" \
    "C6: fm-pr-merge.sh did not attempt the merge for the renewed, current-main-containing candidate"

  # The combined PR actually lands: a squash commit unrelated in ancestry to
  # any constituent head (a squash-merge contract never puts them on main),
  # proven only via the combined PR's own permanent refs/pull/9/head.
  squash=$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "$renewed_candidate^{tree}")" \
    -p "$main_moved" -m 'squash landing')
  git -C "$repo" push -q origin "$squash:refs/heads/main"
  c6_write_pr9 "$ghstate" MERGED "$renewed_candidate" "$squash"

  # --- binding: the PR-less constituent binds only after the real merge ------
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-pr-check.sh" --absorbed-by c6-b \
    https://github.com/example/repo/pull/9 >/dev/null 2>"$home/pr-check-b2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "C6: fm-pr-check.sh refused the PR-less constituent after the combined PR genuinely merged: $(cat "$home/pr-check-b2.err")"
  assert_grep 'absorbed_original_pr=none' "$home/state/c6-b.meta" \
    "C6: fm-pr-check.sh did not record the PR-less binding"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$home/state/c6-b.meta" \
    "C6: fm-pr-check.sh did not make the combined PR c6-b's canonical landing"

  # --- refusal, and its broken control: bin/fm-teardown.sh --------------------
  # Corrupt the just-proven PR-less binding by dropping absorbed_by= - the
  # guard bin/fm-teardown.sh's own validate_absorbed_constituent_landed
  # protects - onto a fresh worktree/task record, and confirm the real owner
  # refuses at its own named assertion before restoring the complete record.
  git -C "$repo" branch -f fm/c6-b-broken "$b_head"
  git -C "$repo" worktree add -q "$home/wt-c6-b-broken" fm/c6-b-broken
  fm_write_meta "$home/state/c6-b-broken.meta" \
    "window=firstmate:fm-c6-b-broken" "endpoint_task_id=c6-b-broken" \
    "worktree=$home/wt-c6-b-broken" "project=$repo" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=c6-b-broken-gen" "batch_role=constituent" \
    "batch_constituent_branch=fm/c6-b-broken" "absorbed_head=$b_head" \
    "absorbed_original_pr=none" "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$renewed_candidate"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in axi) shift; [ "${1:-}" = status ] && printf '\n' ;; esac
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux" "$fakebin/treehouse"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$config" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" c6-b-broken 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "C6 broken control: fm-teardown.sh closed a PR-less constituent whose binding evidence is incomplete"
  assert_contains "$out" "incomplete or invalid PR-less absorbed-constituent record" \
    "C6 broken control: fm-teardown.sh's refusal did not name the missing binding evidence"

  # Restore the guard's evidence and confirm the real owner now proceeds.
  printf 'absorbed_by=https://github.com/example/repo/pull/9\n' >> "$home/state/c6-b-broken.meta"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$config" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" c6-b-broken 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "C6: fm-teardown.sh refused the restored, complete PR-less binding: $out"
  assert_contains "$out" "teardown c6-b-broken complete" \
    "C6: fm-teardown.sh did not complete cleanup once the binding evidence was restored"

  # c6-c (a genuinely unrelated, differently-scoped prepare) never became
  # batch membership; nothing here waives review by disjoint files or a
  # range-diff. Whether c6-c's own local pipeline start count, or any other
  # lane's serial validation, is actually suppressed "solely for batch
  # membership" is the landing-window clause named above and stays unverified.
  if [ "$c_head" = "$renewed_candidate" ] \
    || git -C "$repo" merge-base --is-ancestor "$c_head" "$renewed_candidate" 2>/dev/null; then
    fail "C6: unrelated preparation c6-c was folded into batch membership"
  fi
  pass "C6: generated briefs drive real absorbed-constituent binding (bin/fm-pr-check.sh), real check/containment-gated landing (bin/fm-pr-merge.sh), and a real binding-evidence refusal plus restore (bin/fm-teardown.sh); landing-window serialization has no code owner and stays unverified"
}

c7_consume_document_brief() {
  local brief=$1 selected=$2
  case "$selected" in
    in-run)
      grep -F "the pipeline's correction turn applies an accepted documentation fix in-run" "$brief" >/dev/null \
        && grep -F 'an honest completed Test recheck and a valid attestation' "$brief" >/dev/null \
        && ! grep -F 'The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation' "$brief" >/dev/null
      ;;
    report-only)
      grep -F 'The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation' "$brief" >/dev/null \
        && ! grep -F "the pipeline's correction turn applies an accepted documentation fix in-run" "$brief" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

test_c7_proportionate_verification_and_bounded_routine_correction_rehearsal() {
  local home fakebin events xau_brief report_brief broken intent change
  local custody=worker active_run=none assertion='expected=accepted-behavior' observed retry_count=0
  local repo revision out rc c7_run_head c7_final_head no_grep_tmp
  home="$TMP_ROOT/c7-controlled-rehearsal"
  fakebin=$(fm_fakebin "$home")
  events="$home/events.log"
  mkdir -p "$home/data" "$home/projects/XAUUSD" "$home/projects/report-only" "$home/state"
  : > "$events"
  : > "$home/no-mistakes.log"
  printf 'auto_fix:\n  document: 1\n' > "$home/projects/XAUUSD/.no-mistakes.yaml"
  printf 'auto_fix:\n  document: 0\n' > "$home/projects/report-only/.no-mistakes.yaml"

  # A real worktree so bin/fm-crew-state.sh's branch/head attribution has
  # something genuine to check the fake no-mistakes run-step against. The
  # worktree stays at c7_run_head for the active-run phase; the document
  # correction commit (c7_final_head) is made later, at the point the
  # rehearsal actually claims the pipeline applied it.
  repo="$home/run-worktree"
  fm_git_init_commit "$repo"
  git -C "$repo" checkout -q -b fm/c7-run
  c7_run_head=$(git -C "$repo" rev-parse HEAD)
  fm_write_meta "$home/state/c7-run-task.meta" \
    "window=firstmate:fm-c7-run-task" "worktree=$repo" "kind=ship"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.65.0-7-g4fa1bb2 (4fa1bb2)'
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
if [ "${1:-} ${2:-} ${3:-}" = 'axi run --help' ]; then
  printf '%s\n' '      --launch-nonce string' '      --validation-generation string'
  exit 0
fi
if [ "${FM_FAKE_C7_CUSTODY:-}" = pipeline-owned ] && [ "${1:-}" = axi ] && [ "${2:-}" = run ]; then
  echo "pipeline already owns this branch; abort and confirm custody release before another run" >&2
  exit 7
fi
case "$*" in
  'axi status --run c7-run') cat "$FM_TEST_NM_STATUS" ;;
  'axi status') cat "${FM_TEST_NM_STATUS_BARE:-/dev/null}" 2>/dev/null ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' 'independent fixture review accepted bounded correction' > "$home/c7-accepted-proof.txt"
  write_document_correction_receipt "$home" "$fakebin/no-mistakes" "$home/c7-accepted-proof.txt"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" c7-xau XAUUSD --mode no-mistakes >/dev/null 2>&1
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-brief.sh" c7-report report-only --mode no-mistakes >/dev/null 2>&1
  xau_brief="$home/data/c7-xau/brief.md"
  report_brief="$home/data/c7-report/brief.md"
  sed -i \
    -e 's|^{TASK}$|Apply the accepted documentation-only correction.|' \
    -e 's|^{FIRSTMATE_SPEC}$|Use the bounded in-run document correction route selected by project configuration.|' \
    -e 's|^Prep: {PREP}$|Prep: Tier 1 - controlled fixture wiring mapped before the run.|' \
    -e 's|^Resource: {RESOURCE}$|Resource: one fixture test process; no application suite.|' \
    -e 's|^Surface: {SURFACE}$|Surface: none: delivery machinery fixture.|' \
    -e 's|^Journey: {JOURNEY}$|Journey: none: no product-facing journey.|' \
    "$xau_brief" "$report_brief"
  assert_no_grep '^\({TASK}\|{FIRSTMATE_SPEC}\|Prep: {PREP}\|Resource: {RESOURCE}\|Surface: {SURFACE}\|Journey: {JOURNEY}\)$' "$xau_brief" \
    "C7: the generated XAU brief reached validation with an unfilled scaffold field"
  c7_consume_document_brief "$xau_brief" in-run \
    || fail "C7: the trusted XAU brief did not select bounded in-run Document correction"
  c7_consume_document_brief "$report_brief" report-only \
    || fail "C7: the explicitly report-only project lost its positive route"
  assert_grep '| Constituent task | Changes missing from the candidate | Deliberate replacements | Join repairs |' "$xau_brief" \
    "C7: the final combined candidate brief did not require the join review"
  printf 'join-review status=complete source=generated-xau-brief\n' >> "$events"

  # Broken control restores the obsolete unconditional report-only route.
  broken="$home/broken-old-report-only.md"
  cp "$xau_brief" "$broken"
  printf '%s\n' "The document step is report-only: an accepted documentation finding is fixed only by your own commit plus one re-validation, and the PR body's Document section must state what actually changed." >> "$broken"
  if c7_consume_document_brief "$broken" in-run; then
    fail "C7 broken control: XAU accepted the old unconditional report-only own-commit/re-validation instruction"
  fi

  # The supplied proof plan selects only the named checks for each change.
  printf '%s\n' \
    'editorial|structural:markdown-links' \
    'firstmate-machinery|focused:fm-brief consumer:fm-pr-check' \
    'application-behavior|affected:application-unit affected:journey-smoke' > "$home/proof-plan"
  while IFS='|' read -r change checks; do
    printf 'verification change=%s checks=%s\n' "$change" "$checks" >> "$events"
  done < "$home/proof-plan"
  assert_no_grep 'full-xau-suite' "$events" \
    "C7: a records or shell change started the local full XAU suite"
  {
    printf 'classification claim=false-authority result=material-discrepancy\n'
    printf 'classification claim=false-evidence result=material-discrepancy\n'
    printf 'classification claim=false-completion result=material-discrepancy\n'
  } >> "$events"
  assert_no_grep 'claim=false-authority result=editorial' "$events" \
    "C7: a false authority claim was downgraded to editorial"

  # Drive the real run through bin/fm-dod-lib.sh run-validation - the same
  # revision-bound CLI C3 (tests/fm-spawn-dispatch-profile.test.sh) proves
  # renders --intent from the effective brief - rather than a hand-rebuilt
  # intent string, against the fake no-mistakes above, which records its argv
  # and returns the scripted outcomes written to $home/no-mistakes.status and
  # $home/axi-status-bare below. The actual Captain intent: text comes from
  # the generated brief's own "## Captain's intent" section, not a hardcoded
  # string here.
  revision=$(FM_HOME="$home" PATH="$fakebin:$PATH" \
    bash -c '. "$1"; fm_brief_source_revision "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$xau_brief") \
    || fail "C7: could not compute the effective XAU brief's source revision"
  # Fixture-authored label: it records this fixture's own custody variable,
  # not a decision by any owner.
  printf 'worker-edit result=allowed custody=%s before-run=true\n' "$custody" >> "$events"
  active_run=c7-run
  custody=pipeline
  printf 'run:\n  id: c7-run\n  state: active\n  custody: pipeline\n' > "$home/no-mistakes.status"
  printf 'run:\n  id: "c7-run"\n  branch: fm/c7-run\n  status: running\n  head: "%s"\n  head_sha: "%s"\n  pr: ""\n  findings: none\n' \
    "$c7_run_head" "$c7_run_head" > "$home/axi-status-bare"
  # run-validation reads this branch's axi status before axi run, so it runs from
  # the task worktree, whose HEAD the listed active run holds: a same-head
  # resubmission that reattaches. The fake logs that status call first.
  (cd "$repo" && FM_HOME="$home" FM_TEST_NM_LOG="$home/no-mistakes.log" FM_TEST_NM_STATUS="$home/no-mistakes.status" \
    FM_TEST_NM_STATUS_BARE="$home/axi-status-bare" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-dod-lib.sh" run-validation --brief "$xau_brief" --expect-revision "$revision") \
    || fail "C7: bin/fm-dod-lib.sh run-validation refused to start the real run"
  intent=$(awk 'f { print; next } /^axi run --intent / { f = 1; sub(/^axi run --intent /, ""); print }' "$home/no-mistakes.log")
  assert_contains "$intent" 'Captain intent:' \
    "C7: the actual rendered --intent lost the self-sufficient captain part"
  assert_contains "$intent" 'Firstmate implementation context:' \
    "C7: the actual rendered --intent lost the separately attributed implementation part"
  assert_contains "$intent" 'Use the bounded in-run document correction route selected by project configuration.' \
    "C7: the actual rendered --intent lost the effective Firstmate implementation contract"
  assert_contains "$intent" 'Agreed proof contract:' \
    "C7: the actual rendered --intent lost the agreed proof part"
  assert_grep '--launch-nonce firstmate-' "$home/no-mistakes.log" \
    "C7: run-validation did not request a strict launch receipt"
  assert_grep '--validation-generation brief-' "$home/no-mistakes.log" \
    "C7: run-validation did not bind the validation generation"
  printf 'validation-input source=generated-xau-brief intent-bytes=%s\n' "${#intent}" >> "$events"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_NM_STATUS_BARE="$home/axi-status-bare" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-crew-state.sh" c7-run-task)
  assert_contains "$out" 'state: working' \
    "C7: fm-crew-state.sh did not classify the supplied active run listing as pipeline custody"

  # The Document-step respond below reaches only the fake no-mistakes, which
  # records its argv. The commit is then made from the existing HEAD^{tree}
  # and the supplied status reads outcome: passed, so this fixture contains no
  # documentation change, no executed Test recheck and no attestation: the
  # assertion only proves fm-crew-state.sh classifies a supplied completed run
  # as state: done. The events line is a fixture-authored label.
  FM_TEST_NM_LOG="$home/no-mistakes.log" FM_TEST_NM_STATUS="$home/no-mistakes.status" \
    PATH="$fakebin:$PATH" no-mistakes axi respond --run c7-run --step Document --action apply-accepted-fix --keep-diagnostics
  printf 'document-correction actor=pipeline scope=document-only\n' >> "$events"
  c7_final_head=$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "HEAD^{tree}")" \
    -p "$c7_run_head" -m 'document correction')
  git -C "$repo" merge -q --ff-only "$c7_final_head"
  printf 'run:\n  id: "c7-run"\n  branch: fm/c7-run\n  status: completed\n  head: "%s"\n  pr: ""\n  findings: none\noutcome: passed\n' \
    "$c7_final_head" > "$home/axi-status-bare"
  assert_no_grep '--yes' "$home/no-mistakes.log" \
    "C7: automatic gate approval was used"
  assert_grep '--keep-diagnostics' "$home/no-mistakes.log" \
    "C7: the unrelated package flag was not retained"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_NM_STATUS_BARE="$home/axi-status-bare" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-crew-state.sh" c7-run-task)
  assert_contains "$out" 'state: done' \
    "C7: fm-crew-state.sh did not classify the supplied completed run listing as done"

  # A second real bin/fm-dod-lib.sh run-validation attempt reaches the same
  # fake no-mistakes, and the fake itself prints the active-custody refusal and
  # exits 7. This proves run-validation invokes no-mistakes and propagates its
  # refusal text and failing status; it does not exercise the installed tool's
  # custody guard. Firstmate mediation of any worker-facing gate has no owner
  # call in this fixture and is not narrated.
  [ "$custody" != worker ] || fail "C7: fixture did not transfer active-run custody"
  set +e
  out=$(FM_HOME="$home" FM_FAKE_C7_CUSTODY=pipeline-owned FM_TEST_NM_LOG="$home/no-mistakes.log" \
    FM_TEST_NM_STATUS="$home/no-mistakes.status" FM_TEST_NM_STATUS_BARE="$home/axi-status-bare" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-dod-lib.sh" run-validation \
    --brief "$xau_brief" --expect-revision "$revision" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "C7: run-validation exited 0 although the fake no-mistakes refused the second run"
  assert_contains "$out" 'pipeline already owns this branch' \
    "C7: run-validation did not propagate the fake no-mistakes active-custody refusal text"
  printf 'competing-run result=refused active=%s\n' "$active_run" >> "$events"

  # The status and sync calls below reach only the fake, which accepts them
  # without enforcing any protocol, and the bare run listing is then emptied.
  # The assertion only proves fm-crew-state.sh stops reporting state: working
  # once no run is listed; an emptied listing is not a custody-release receipt.
  printf 'run:\n  id: c7-run\n  outcome: cancelled\n  branch_sync:\n    next_action: recover_custody\n' > "$home/no-mistakes.status"
  : > "$home/axi-status-bare"
  FM_TEST_NM_LOG="$home/no-mistakes.log" FM_TEST_NM_STATUS="$home/no-mistakes.status" \
    PATH="$fakebin:$PATH" no-mistakes axi status --run c7-run >/dev/null
  FM_TEST_NM_LOG="$home/no-mistakes.log" FM_TEST_NM_STATUS="$home/no-mistakes.status" \
    PATH="$fakebin:$PATH" no-mistakes axi sync --run c7-run --recover-custody
  custody=worker
  active_run=none
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_NM_STATUS_BARE="$home/axi-status-bare" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-crew-state.sh" c7-run-task)
  no_grep_tmp="$home/crew-state-after-recovery.out"
  printf '%s\n' "$out" > "$no_grep_tmp"
  assert_no_grep 'state: working' "$no_grep_tmp" \
    "C7: fm-crew-state.sh still reported state: working after the supplied run listing was emptied"
  printf 'worker-edit result=allowed custody=%s\n' "$custody" >> "$events"
  # From here to the pass line, every events line is a fixture-authored label
  # asserted back by grep: it proves this fixture's own bookkeeping, not an
  # owner's proof selection, escalation, recurrence or retry decision.
  {
    # A code/contract change renews affected proof only and explains retained proof.
    printf 'scope-change kind=code-contract renew=affected-review,affected-tests\n'
    printf 'evidence-retained id=unaffected-structural reason=inputs-and-consumer-unchanged\n'
  } >> "$events"
  assert_grep 'scope-change kind=code-contract renew=affected-review,affected-tests' "$events" \
    "C7: code/contract scope did not renew its affected review and tests"
  assert_grep 'evidence-retained id=unaffected-structural reason=inputs-and-consumer-unchanged' "$events" \
    "C7: unaffected evidence was retained without an applicability explanation"

  # Correct the defective fixture implementation without weakening its agreed assertion.
  observed='expected=defect'
  [ "$observed" != "$assertion" ] || fail "C7: defective-test fixture was not red before correction"
  observed='expected=accepted-behavior'
  [ "$observed" = "$assertion" ] || fail "C7: the prescribed behavior was not restored"
  [ "$assertion" = 'expected=accepted-behavior' ] || fail "C7: the assertion was weakened merely to obtain green"

  for change in shared-contract financial-rule required-proof agreed-product-behavior; do
    printf 'routine-correction candidate=%s result=material-discrepancy\n' "$change" >> "$events"
  done
  {
    printf 'unrelated-authorized-task result=continue\n'
    # Stable evidence identity suppresses a duplicate; genuinely new evidence
    # reopens the same owner and affected proof, then bounded retries halt.
    printf 'failure key=E1 action=open-run owner=c7-owner\n'
    printf 'failure key=E1 action=duplicate-no-run owner=c7-owner\n'
    printf 'failure key=E2 action=reopen-owner invalidate=affected-proof\n'
  } >> "$events"
  while [ "$retry_count" -lt 2 ]; do
    retry_count=$((retry_count + 1))
    printf 'retry key=E2 attempt=%s result=ineffective custody=pipeline\n' "$retry_count" >> "$events"
  done
  printf 'retry key=E2 action=halt custody=pipeline diagnosis=retained\n' >> "$events"
  [ "$(grep -c 'failure key=E1 action=open-run' "$events")" -eq 1 ] \
    || fail "C7: duplicate evidence created a second run"
  [ "$(grep -c '^retry key=E2 attempt=' "$events")" -eq 2 ] \
    || fail "C7: ineffective execution escaped the bounded retry limit"
  assert_grep 'retry key=E2 action=halt custody=pipeline diagnosis=retained' "$events" \
    "C7: the halt lost custody or diagnosis"
  assert_grep 'unrelated-authorized-task result=continue' "$events" \
    "C7: a material discrepancy stopped unrelated authorized work"
  pass "C7: generated briefs select the in-run or report-only Document route and reject the obsolete instruction; run-validation renders the brief's intent and propagates a fake custody refusal; fm-crew-state.sh classifies supplied run listings; the remaining outcomes are fixture-authored labels"
}

# run-validation reads the current branch's structured `no-mistakes axi status`
# before `axi run`. This proves that entry-boundary decision against a stub that
# prints scripted status text and logs argv: an active (running or pending) run
# holding the branch at another head is refused with exit 4, naming the
# supported abort, confirmed-stop and branch_sync sequence, and no `axi run`
# follows; a same-head resubmission, a run whose pipeline head moved but whose
# submitted head is HEAD, a terminal run at another head, and no run all start
# the run; an unreadable status (a failing call, unrecognized output, or an
# active run without head_sha) is refused with exit 5 naming the failure. The
# installed tool's own supersession is exercised by the isolated C7.4 execution
# in the G3 evidence records, not here.
rv_guard_status() {  # <file> <run-status> <head-sha> <submitted-head>
  printf 'run:\n  id: "01RVGUARD"\n  branch: fm/rv-guard\n  status: %s\n  head: "%s"\n  head_sha: "%s"\nbranch_sync:\n  state: pipeline_owned\n  pipeline:\n    run: "01RVGUARD"\n    status: %s\n    submitted_head: %s\n    current_head: %s\n' \
    "$2" "${3:0:8}" "$3" "$2" "$4" "$3" > "$1"
}

rv_guard_run() {  # <dir> <revision> <status-rc>; sets RV_OUT and RV_RC
  : > "$1/calls.log"
  if RV_OUT=$(cd "$1/repo" && FM_TEST_RV_LOG="$1/calls.log" FM_TEST_RV_STATUS="$1/status" \
    FM_TEST_RV_STATUS_RC="$3" PATH="$1/bin:$PATH" \
    "$ROOT/bin/fm-dod-lib.sh" run-validation --brief "$1/brief.md" --expect-revision "$2" 2>&1); then
    RV_RC=0
  else
    RV_RC=$?
  fi
}

test_run_validation_holds_a_different_head_while_a_run_is_active() {
  local dir head other revision state
  dir="$TMP_ROOT/run-validation-active-run-guard"
  mkdir -p "$dir/bin"
  fm_git_init_commit "$dir/repo"
  git -C "$dir/repo" checkout -q -b fm/rv-guard
  head=$(git -C "$dir/repo" rev-parse HEAD)
  other=0123456789abcdef0123456789abcdef01234567
  cat > "$dir/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-} ${2:-}" >> "$FM_TEST_RV_LOG"
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  cat "$FM_TEST_RV_STATUS"
  exit "${FM_TEST_RV_STATUS_RC:-0}"
fi
[ "${1:-} ${2:-} ${3:-}" = 'axi run --help' ] && {
  if [ "${FM_TEST_RV_NO_STRICT:-0}" != 1 ]; then
    printf '%s\n' '      --launch-nonce string' '      --validation-generation string'
  fi
  exit 0
}
[ "${1:-} ${2:-}" = 'axi run' ] && exit 0
exit 9
SH
  chmod +x "$dir/bin/no-mistakes"
  cat > "$dir/brief.md" <<'MD'
# Task

## Captain's intent
Hold a different head while a validation run is active.

## Firstmate spec
Fixture only.

# Proof bar
Prep: Tier 0 - fixture.
MD
  revision=$(PATH="$dir/bin:$PATH" bash -c '. "$1"; fm_brief_source_revision "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$dir/brief.md") \
    || fail "run-validation guard: could not compute the fixture brief revision"

  for state in running pending; do
    rv_guard_status "$dir/status" "$state" "$other" "$other"
    rv_guard_run "$dir" "$revision" 0
    expect_code 4 "$RV_RC" "run-validation guard: a $state run at another head must be refused"
    assert_contains "$RV_OUT" '01RVGUARD' "run-validation guard: the refusal did not name the active run"
    assert_contains "$RV_OUT" 'no-mistakes axi abort' "run-validation guard: the refusal did not name the supported abort"
    # shellcheck disable=SC2016  # Markdown backticks are intentionally literal.
    assert_contains "$RV_OUT" 'confirm through `no-mistakes axi status` that it has stopped' \
      "run-validation guard: the refusal did not name the confirmed stop"
    assert_contains "$RV_OUT" 'branch_sync.next_action' "run-validation guard: the refusal did not name branch_sync.next_action"
    assert_contains "$RV_OUT" 'rerun this same run-validation command' "run-validation guard: the refusal did not name the rerun"
    assert_grep 'axi status' "$dir/calls.log" "run-validation guard: status was not read before deciding"
    assert_no_grep 'axi run' "$dir/calls.log" "run-validation guard: a $state run at another head was superseded anyway"
  done

  rv_guard_status "$dir/status" running "$head" "$head"
  rv_guard_run "$dir" "$revision" 0
  expect_code 0 "$RV_RC" "run-validation guard: a same-head resubmission must reattach ($RV_OUT)"
  assert_grep 'axi run' "$dir/calls.log" "run-validation guard: the same-head resubmission did not reach axi run"

  rv_guard_status "$dir/status" running "$other" "$head"
  rv_guard_run "$dir" "$revision" 0
  expect_code 0 "$RV_RC" "run-validation guard: HEAD equal to the submitted head must reattach ($RV_OUT)"
  assert_grep 'axi run' "$dir/calls.log" "run-validation guard: the submitted-head resubmission did not reach axi run"

  for state in completed failed cancelled ci_monitor_interrupted; do
    rv_guard_status "$dir/status" "$state" "$other" "$other"
    rv_guard_run "$dir" "$revision" 0
    expect_code 0 "$RV_RC" "run-validation guard: a $state run must not hold the branch ($RV_OUT)"
    assert_grep 'axi run' "$dir/calls.log" "run-validation guard: a $state run blocked a fresh run"
  done

  printf 'current_branch: fm/rv-guard\nruns_on_current_branch: 0\nhelp[1]: Start a run\n' > "$dir/status"
  rv_guard_run "$dir" "$revision" 0
  expect_code 0 "$RV_RC" "run-validation guard: no run on the branch must start one ($RV_OUT)"
  assert_grep 'axi run' "$dir/calls.log" "run-validation guard: no run on the branch did not reach axi run"

  FM_TEST_RV_NO_STRICT=1 rv_guard_run "$dir" "$revision" 0
  expect_code 7 "$RV_RC" "run-validation guard: missing strict receipt flags must fail closed"
  assert_contains "$RV_OUT" 'requires installed no-mistakes support for paired --launch-nonce and --validation-generation receipts' \
    "run-validation guard: strict capability refusal did not name the missing contract"

  printf 'error: daemon socket unreachable\n' > "$dir/status"
  rv_guard_run "$dir" "$revision" 1
  expect_code 5 "$RV_RC" "run-validation guard: a failing status call must be refused"
  assert_contains "$RV_OUT" 'daemon socket unreachable' "run-validation guard: the refusal did not name the status failure"
  assert_no_grep 'axi run' "$dir/calls.log" "run-validation guard: a failing status call still started a run"

  printf 'unrelated output\n' > "$dir/status"
  rv_guard_run "$dir" "$revision" 0
  expect_code 5 "$RV_RC" "run-validation guard: unrecognized status output must be refused"
  assert_no_grep 'axi run' "$dir/calls.log" "run-validation guard: unrecognized status output still started a run"

  printf 'run:\n  id: "01RVGUARD"\n  status: running\n' > "$dir/status"
  rv_guard_run "$dir" "$revision" 0
  expect_code 5 "$RV_RC" "run-validation guard: an active run without head_sha must be refused"
  assert_contains "$RV_OUT" 'reports no head_sha' "run-validation guard: the refusal did not name the missing head"
  assert_no_grep 'axi run' "$dir/calls.log" "run-validation guard: an active run without head_sha still started a run"
  pass "run-validation: an active run at another head is held with the supported sequence; same head, submitted head, terminal and no run proceed; unreadable status refuses"
}

# A locally rebased branch can contain origin/main while its pushed PR branch
# still names an older head.  Rebase would replay main onto that stale head, so
# run-validation must stop only the incomparable local and remote PR heads.
test_run_validation_refuses_a_diverged_pushed_pr_head_and_allows_ordered_refs() {
  local dir base local_head remote_head revision
  dir="$TMP_ROOT/run-validation-remote-pr-head"
  mkdir -p "$dir/bin"
  fm_git_init_commit "$dir/repo"
  git -C "$dir/repo" checkout -q -b fm/rv-remote
  base=$(git -C "$dir/repo" rev-parse HEAD)
  cat > "$dir/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-} ${2:-}" >> "$FM_TEST_RV_LOG"
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  cat "$FM_TEST_RV_STATUS"
  exit "${FM_TEST_RV_STATUS_RC:-0}"
fi
[ "${1:-} ${2:-} ${3:-}" = 'axi run --help' ] && {
  printf '%s\n' '      --launch-nonce string' '      --validation-generation string'
  exit 0
}
[ "${1:-} ${2:-}" = 'axi run' ] && exit 0
exit 9
SH
  chmod +x "$dir/bin/no-mistakes"
  cat > "$dir/brief.md" <<'MD'
# Task

## Captain's intent
Refuse a diverged pushed pull-request head before a validation run starts.

## Firstmate spec
Fixture only.

# Proof bar
Prep: Tier 0 - fixture.
MD
  revision=$(PATH="$dir/bin:$PATH" bash -c '. "$1"; fm_brief_source_revision "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$dir/brief.md") \
    || fail "run-validation remote PR head: could not compute the fixture brief revision"
  printf 'current_branch: fm/rv-remote\nruns_on_current_branch: 0\nhelp[1]: Start a run\n' > "$dir/status"

  rv_guard_run "$dir" "$revision" 0
  expect_code 0 "$RV_RC" "run-validation remote PR head: an absent remote ref must proceed ($RV_OUT)"
  assert_grep 'axi run' "$dir/calls.log" "run-validation remote PR head: an absent remote ref did not reach axi run"

  git -C "$dir/repo" update-ref refs/remotes/origin/fm/rv-remote "$base"
  printf 'contains remote\n' > "$dir/repo/contains-remote"
  git -C "$dir/repo" add contains-remote
  git -C "$dir/repo" commit -qm 'fixture local contains remote'
  local_head=$(git -C "$dir/repo" rev-parse HEAD)
  rv_guard_run "$dir" "$revision" 0
  expect_code 0 "$RV_RC" "run-validation remote PR head: HEAD containing the remote head must proceed ($RV_OUT)"
  assert_grep 'axi run' "$dir/calls.log" "run-validation remote PR head: containing HEAD did not reach axi run"

  remote_head=$(git -C "$dir/repo" commit-tree "$local_head^{tree}" -p "$local_head" <<'EOF'
fixture remote is ahead
EOF
)
  git -C "$dir/repo" update-ref refs/remotes/origin/fm/rv-remote "$remote_head"
  rv_guard_run "$dir" "$revision" 0
  expect_code 0 "$RV_RC" "run-validation remote PR head: HEAD behind the remote head must proceed ($RV_OUT)"
  assert_grep 'axi run' "$dir/calls.log" "run-validation remote PR head: behind HEAD did not reach axi run"

  git -C "$dir/repo" reset -q --hard "$base"
  printf 'local divergence\n' > "$dir/repo/local-divergence"
  git -C "$dir/repo" add local-divergence
  git -C "$dir/repo" commit -qm 'fixture local divergence'
  local_head=$(git -C "$dir/repo" rev-parse HEAD)
  remote_head=$(git -C "$dir/repo" commit-tree "$base^{tree}" -p "$base" <<'EOF'
fixture remote divergence
EOF
)
  git -C "$dir/repo" update-ref refs/remotes/origin/fm/rv-remote "$remote_head"
  rv_guard_run "$dir" "$revision" 0
  expect_code 6 "$RV_RC" "run-validation remote PR head: diverged heads must be refused"
  assert_contains "$RV_OUT" "$local_head" "run-validation remote PR head: refusal did not name local HEAD"
  assert_contains "$RV_OUT" "$remote_head" "run-validation remote PR head: refusal did not name pushed PR head"
  assert_contains "$RV_OUT" 'git merge -s ours --no-ff origin/fm/rv-remote' \
    "run-validation remote PR head: refusal did not name the ours merge remedy"
  assert_contains "$RV_OUT" 'never rebase and never force-push' \
    "run-validation remote PR head: refusal did not prohibit rebase and force-push"
  assert_no_grep 'axi run' "$dir/calls.log" "run-validation remote PR head: diverged heads still started axi run"
  pass "run-validation: diverged pushed PR heads refuse; absent, contained, and ahead remote heads proceed"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_batch_constituent_handoff_replaces_the_standalone_pipeline_next_step
test_no_binary_evidence_and_document_step_dod_rules
test_document_instruction_requires_unambiguous_trusted_project_config_and_installed_capability_receipt
test_validation_revision_ignores_progress_history_but_binds_instruction_contract
test_validation_intent_separately_labels_captain_spec_and_proof
test_every_mode_dod_separates_delivery_from_acceptance
test_ask_user_escalation_format
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_task_briefs_carry_project_authority_reconciliation
test_all_scaffolds_carry_inbox_continuation_contract
test_ship_briefs_batch_findings_and_bounded_ci_retry_contract
test_ship_brief_carries_the_resource_line
test_ship_brief_carries_the_surface_line
test_ship_brief_carries_the_journey_line
test_every_ship_dod_renders_the_conditional_integration_batch_binding
test_render_batch_owner_record_carries_the_batch_tables_into_the_run_intent_only
test_no_mistakes_dod_states_pr_body_is_pipeline_output_in_both_variants
test_c6_parallel_preparation_bounded_batch_and_safe_landing_rehearsal
test_c7_proportionate_verification_and_bounded_routine_correction_rehearsal
test_run_validation_holds_a_different_head_while_a_run_is_active
test_run_validation_refuses_a_diverged_pushed_pr_head_and_allows_ordered_refs
