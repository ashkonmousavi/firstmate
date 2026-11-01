#!/usr/bin/env bash
# Default-on live guard for the worker account pin's sign-in check
# (bin/fm-worker-account-lib.sh) against every installed runner it supports.
#
# The check's verdict comes from vendor output - the exit status of
# `claude auth status`, the JSON of `pi auth check`, and the table of
# `pi --list-models` - so a fake can only restate the assumption written into
# it. This guard asks the REAL installed runners about synthetic account roots
# that need no login and no network: a Claude root whose settings name an
# apiKeyHelper, a Pi root holding a stored API key, and Pi roots whose only
# provider comes from an extension. Each refusal first proves the divergence
# it depends on: the same runner, with a credential variable left in its
# environment, answers signed in, so the refusal is the check's own cleared
# environment at work rather than a root the runner could never accept.
#
# It submits no prompt and spends no tokens, so the shared live gate runs it by
# default wherever a runner is installed. Run it after every Claude or Pi
# upgrade and before trusting the "Worker account pin sign-in check" entry in
# docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WORKER_ACCOUNT_LIVE_E2E jq perl python3
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account-live)
# A throwaway HOME keeps the operator's own logins, Anthropic profiles, and Pi
# settings out of every answer.
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR PI_CODING_AGENT_DIR ANTHROPIC_API_KEY OPENAI_API_KEY FM_LIVE_EXT_KEY
CHECKED=

codex_live_cases() {
  local version empty stored out config email
  version=$(codex --version 2>/dev/null | head -1)
  empty="$TMP_ROOT/codex-empty"
  stored="$TMP_ROOT/codex-stored"
  config="$TMP_ROOT/codex-config"
  mkdir -p "$empty/rules" "$stored/rules" "$config"
  printf 'cli_auth_credentials_store="file"\n' > "$empty/config.toml"
  cp "$empty/config.toml" "$stored/config.toml"
  : > "$empty/AGENTS.md"
  : > "$stored/AGENTS.md"
  printf 'prefix_rule(pattern=["echo"], decision="allow")\n' > "$empty/rules/default.rules"
  cp "$empty/rules/default.rules" "$stored/rules/default.rules"
  # Synthetic cached API auth proves the vendor's local-status contract only.
  # No request is sent and no real credential or account directory is touched.
  printf '{"OPENAI_API_KEY":"sk-fm-live-synthetic"}\n' > "$stored/auth.json"
  printf '%s\n' "$empty" > "$config/codex-accounts"
  if out=$(OPENAI_API_KEY=sk-fm-live-ambient fm_worker_account_select codex "$config" '' codex 2>&1); then
    fail "codex $version: accepted an empty folder under ambient credentials"
  fi
  assert_not_contains "$out" 'sk-fm-live-' "codex $version leaked vendor status diagnostics"
  printf '%s\n' "$stored" > "$config/codex-accounts"
  # Avoid any network: this fake quota tool leaves room unmeasured while the
  # installed Codex alone decides whether the synthetic cache is signed in.
  mkdir -p "$TMP_ROOT/quota-bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/quota-bin/quota-axi"
  chmod +x "$TMP_ROOT/quota-bin/quota-axi"
  out=$(PATH="$TMP_ROOT/quota-bin:$PATH" fm_worker_account_select codex "$config" '' codex 2>&1) ||
    fail "codex $version: refused a synthetic file-backed local login: $out"
  assert_equals "$stored" "${out%%$'\t'*}" "codex $version selected a different root"
  pass "codex $version: file-backed local status accepts a synthetic cache, refuses an empty root and suppresses diagnostics"
  for email in same-account@example.invalid other-account@example.invalid; do
    python3 - "$TMP_ROOT" "$email" <<'PY'
import base64, datetime, json, os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
for i, email in enumerate(("same-account@example.invalid", sys.argv[2])):
    folder = root / f"codex-identity-{i}"
    folder.mkdir(exist_ok=True)
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    token = encode({"alg": "none"}) + "." + encode({"email": email,
        "https://api.openai.com/auth": {"chatgpt_account_id": "fm-live-synthetic-account",
                                         "chatgpt_plan_type": "pro"}}) + "."
    (folder / "auth.json").write_text(json.dumps({"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
        "tokens": {"id_token": token, "access_token": f"fm-live-synthetic-access-{i}",
                   "refresh_token": f"fm-live-synthetic-refresh-{i}", "account_id": "fm-live-synthetic-account"},
        "last_refresh": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")}))
    stamp = time.time() - i
    os.utime(folder / "auth.json", (stamp, stamp))
(root / "codex-config" / "codex-accounts").write_text(
    "".join(str(root / f"codex-identity-{i}") + "\n" for i in range(2)))
PY
    if out=$(python3 "$ROOT/bin/fm-codex-accounts.py" guard --config "$config/codex-accounts" 2>&1); then
      [ "$email" != same-account@example.invalid ] || fail "codex $version: duplicate runner identities passed the guard"
      assert_equals '' "$out" "codex $version: healthy identity guard must remain silent"
    else
      [ "$email" = same-account@example.invalid ] || fail "codex $version: distinct runner identities refused: $out"
      assert_contains "$out" 'duplicate Codex account' "codex $version: account/read identity contract changed"
    fi
    assert_not_contains "$out" 'example.invalid' "codex $version leaked an account identity"
    assert_not_contains "$out" 'fm-live-synthetic' "codex $version leaked synthetic credentials"
  done
  pass "codex $version: account/read compares synthetic ChatGPT identities without refresh or credential output"
  CHECKED="$CHECKED codex"
}

claude_live_cases() {
  local version empty helper
  version=$(claude --version 2>/dev/null | head -1)
  empty="$TMP_ROOT/claude-empty"
  helper="$TMP_ROOT/claude-helper"
  mkdir -p "$empty" "$helper"
  printf '{"apiKeyHelper":"echo sk-ant-fm-live-synthetic"}\n' > "$helper/settings.json"

  env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR="$empty" ANTHROPIC_API_KEY=sk-ant-fm-live-synthetic \
    claude auth status >/dev/null 2>&1 </dev/null ||
    fail "claude $version: an environment API key no longer answers claude auth status for an empty root, so the refusal below proves nothing"
  if ANTHROPIC_API_KEY=sk-ant-fm-live-synthetic fm_worker_account_check claude "$empty" "$empty" claude 2>/dev/null; then
    fail "claude $version: the pin check accepted an empty root because a credential variable in the caller answered for it"
  fi
  fm_worker_account_check claude "$helper" "$helper" claude ||
    fail "claude $version: the pin check refused a root whose apiKeyHelper signs it in"
  pass "claude $version: the pin check accepts a signed-in root and refuses an empty one despite an ambient API key"
  CHECKED="$CHECKED claude"
}

# write_ext_provider <root> <api-key-expression>
write_ext_provider() {
  mkdir -p "$1/extensions"
  cat > "$1/extensions/fm-live-provider.ts" <<TS
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.registerProvider("fm-live-ext", {
    baseUrl: "http://127.0.0.1:9/v1",
    apiKey: "$2",
    api: "openai-completions",
    models: [{ id: "fm-ext-model", name: "fm-ext-model", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 4096 }],
  });
}
TS
}

pi_live_cases() {
  local exe=$1 version empty stored ext unset_ext out
  version=$("$exe" --version 2>/dev/null | head -1)
  empty="$TMP_ROOT/$exe-empty"
  stored="$TMP_ROOT/$exe-stored"
  ext="$TMP_ROOT/$exe-ext"
  unset_ext="$TMP_ROOT/$exe-ext-unset"
  mkdir -p "$empty" "$stored"
  printf '{"openai":{"type":"api_key","key":"sk-fm-live-synthetic"}}\n' > "$stored/auth.json"
  chmod 600 "$stored/auth.json"
  write_ext_provider "$ext" sk-fm-live-synthetic
  # shellcheck disable=SC2016  # Pi expands this key reference itself.
  write_ext_provider "$unset_ext" '$FM_LIVE_EXT_KEY'

  out=$(env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$empty" OPENAI_API_KEY=sk-fm-live-synthetic \
    "$exe" auth check --provider openai --json --no-refresh 2>/dev/null </dev/null)
  [ "$(printf '%s\n' "$out" | jq -r '.status' 2>/dev/null)" = ready ] ||
    fail "$exe $version: an environment API key no longer answers pi auth check for an empty root ($out), so the refusal below proves nothing"
  if OPENAI_API_KEY=sk-fm-live-synthetic fm_worker_account_check "$exe" "$empty" "$empty" "$exe" openai 2>/dev/null; then
    fail "$exe $version: the pin check accepted an empty root because a credential variable in the caller answered for it"
  fi
  fm_worker_account_check "$exe" "$stored" "$stored" "$exe" openai ||
    fail "$exe $version: the pin check refused a root holding a stored API key for its provider"

  out=$(env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$ext" \
    "$exe" auth check --provider fm-live-ext --json --no-refresh 2>/dev/null </dev/null)
  [ "$(printf '%s\n' "$out" | jq -r '.reason' 2>/dev/null)" = provider_not_found ] ||
    fail "$exe $version: pi auth check now sees extension providers ($out), so the model-listing fallback is no longer exercised; revisit bin/fm-worker-account-lib.sh"
  fm_worker_account_check "$exe" "$ext" "$ext" "$exe" fm-live-ext ||
    fail "$exe $version: the pin check refused an extension provider its root lists models for"
  out=$(env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$unset_ext" FM_LIVE_EXT_KEY=sk-fm-live-synthetic \
    "$exe" --list-models fm-live-ext 2>/dev/null </dev/null)
  printf '%s\n' "$out" | awk 'NR > 1 && $1 == "fm-live-ext" { found = 1 } END { exit !found }' ||
    fail "$exe $version: an environment key no longer makes the extension provider listable, so the refusal below proves nothing"
  if FM_LIVE_EXT_KEY=sk-fm-live-synthetic fm_worker_account_check "$exe" "$unset_ext" "$unset_ext" "$exe" fm-live-ext 2>/dev/null; then
    fail "$exe $version: the model-listing fallback accepted an extension provider only a caller variable authenticates"
  fi
  pass "$exe $version: the pin check reads auth check and the model listing, and refuses what only an ambient credential signs in"
  CHECKED="$CHECKED $exe"
}

for runner in claude pi pi-signed codex; do
  if ! command -v "$runner" >/dev/null 2>&1; then
    printf 'skip-runner: %s is not installed, so its pin check was not exercised\n' "$runner"
    continue
  fi
  case "$runner" in
    claude) claude_live_cases ;;
    codex) codex_live_cases ;;
    *) pi_live_cases "$runner" ;;
  esac
done

if [ -z "$CHECKED" ]; then
  if [ "${FM_WORKER_ACCOUNT_LIVE_E2E:-${FM_LIVE:-}}" = 1 ]; then
    fail "the worker account live guard was requested but no supported runner (claude, pi, pi-signed, codex) is installed"
  fi
  echo "skip: live: no supported runner (claude, pi, pi-signed, codex) installed"
  exit 0
fi
echo "# worker account live guard checked:$CHECKED"
