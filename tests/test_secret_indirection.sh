#!/usr/bin/env bash
#
# Tests for the `secret://<key>` indirection that keeps credentials out of the add-on
# options (see DOCS.md § "Keeping secrets out of the add-on options").
#
# Why this exists. Supervisor stores add-on options in clear text and returns them in
# clear text to any API call — the `password:` schema type only masks the UI field. On
# 2026-08-16 a single read of the options copied the GitHub PAT into a transcript and
# it had to be revoked. This add-on holds two such secrets: the git password and the
# Anthropic API key, the latter billed per use.
#
# Five properties are locked here, each one expensive to get wrong:
#
#   1. BACKWARD COMPATIBILITY — a value without the prefix is returned untouched, so
#      existing installs keep working and options can be switched one at a time.
#   2. NO LEAK — the resolved value reaches stdout (the return channel) and nowhere
#      else, not even in an error message. Otherwise the leak just moved.
#   3. ERRORS NAME THE KEY — without it, a typo in the key name and a revoked token
#      produce the same unreadable 401.
#   4. THE PREFIX IS `secret://`, NOT `!secret` — Supervisor supports `!secret` natively
#      but RESOLVES it before answering the API: measured 2026-08-16, an option using
#      `!secret` still comes back in clear text from `ha apps info --raw-json`, so it
#      does NOT close the leak. `secret://` means nothing to Supervisor, which passes it
#      through untouched — that is what keeps the API down to the key name.
#   5. PARSING HOLDS — quotes, end-of-line comments, indented keys. A mis-split value
#      is a silently wrong credential, i.e. a failure diagnosed on the wrong side.
#   5. THE TWO CALL SITES DIFFER ON PURPOSE — no git password means no push, so that
#      one fails the run; the AI commit message is opt-in and contractually degrades
#      to the static message, so a broken indirection there must not abort the export.
#
# The real function is extracted from run.sh and driven with a fake bashio: no
# Supervisor needed. Run with: bash tests/test_secret_indirection.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SH="${RUN_SH_UNDER_TEST:-$ROOT/git-exporter/root/run.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail=0
ok()    { printf '  ✅ %s\n' "$1"; }
ko()    { printf '  ❌ %s\n' "$1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (expected «${3}», got «${2}»)"; fi; }

# --- the real function, extracted from run.sh -------------------------------
sed -n '/^resolve_secret() {/,/^}/p' "$RUN_SH" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { printf '❌ resolve_secret not found in %s\n' "$RUN_SH"; exit 1; }

# --- fake bashio. Logs go to STDERR so they cannot stick to the secret returned on
# STDOUT — that is exactly what test group 3 checks, and the harness must not fake it.
bashio::log.error() { printf 'ERROR: %s\n' "$*" >&2; }
bashio::exit.nok()  { bashio::log.error "$@"; exit 1; }

SECRETS_FILE="$T/secrets.yaml"
# shellcheck disable=SC1091
. "$T/fn.sh"

cat > "$SECRETS_FILE" <<'EOF'
# leading comment
github_pat_exporter: github_pat_11ABCDEF_bare
quoted_double: "github_pat_11ABCDEF_double"
quoted_single: 'github_pat_11ABCDEF_single'
with_comment: github_pat_11ABCDEF_cmt  # expires 2026-11-14
hash_glued: token#inner
with_colon: https://example.test/path
padded:      github_pat_11ABCDEF_pad
anthropic_api_key: sk-ant-api03-FAKEKEYFORTESTS
empty:
nested:
  inner: indented_value
EOF

# 1. Backward compatibility — no prefix, no change.
check "bare value returned unchanged" \
  "$(resolve_secret 'github_pat_literal' 'repository.password')" 'github_pat_literal'
check "empty value returned unchanged" \
  "$(resolve_secret '' 'repository.password')" ''
check "'!secretfoo' is NOT an indirection (prefix is '!secret' + space)" \
  "$(resolve_secret '!secretfoo' 'repository.password')" '!secretfoo'
check "'secret:/foo' is NOT an indirection (prefix is 'secret://')" \
  "$(resolve_secret 'secret:/foo' 'repository.password')" 'secret:/foo'

# 2. Nominal resolution and parsing variants.
check "plain key (secret://)" "$(resolve_secret 'secret://github_pat_exporter' 'p')" 'github_pat_11ABCDEF_bare'
check "'!secret' still accepted as a net" \
  "$(resolve_secret '!secret github_pat_exporter' 'p')" 'github_pat_11ABCDEF_bare'
check "double quotes strip" "$(resolve_secret 'secret://quoted_double' 'p')"       'github_pat_11ABCDEF_double'
check "single quotes strip" "$(resolve_secret 'secret://quoted_single' 'p')"       'github_pat_11ABCDEF_single'
check "end-of-line comment dropped" \
  "$(resolve_secret 'secret://with_comment' 'p')" 'github_pat_11ABCDEF_cmt'
check "'#' glued to the text kept (YAML needs a space before a comment)" \
  "$(resolve_secret 'secret://hash_glued' 'p')" 'token#inner'
check "value containing ':' kept whole" \
  "$(resolve_secret 'secret://with_colon' 'p')" 'https://example.test/path'
check "padding around the value stripped" \
  "$(resolve_secret 'secret://padded' 'p')" 'github_pat_11ABCDEF_pad'
check "padding around the KEY name tolerated" \
  "$(resolve_secret 'secret://  github_pat_exporter  ' 'p')" 'github_pat_11ABCDEF_bare'
check "anthropic key resolves too" \
  "$(resolve_secret 'secret://anthropic_api_key' 'repository.commit_message_api_key')" 'sk-ant-api03-FAKEKEYFORTESTS'

# 3. The secret goes to stdout (the return channel) and nowhere else.
out="$(resolve_secret 'secret://github_pat_exporter' 'repository.password' 2>"$T/err")"
check "resolution is silent: nothing on stderr" "$(wc -c <"$T/err" | tr -d ' ')" '0'
check "value actually returned"                 "$out" 'github_pat_11ABCDEF_bare'

# 4. Failures: non-zero exit, message naming the key, never the value.
expect_fail() { # expect_fail LABEL VALUE NEEDLE
  local label="$1" value="$2" needle="$3" rc=0
  ( resolve_secret "$value" 'repository.password' ) >"$T/out" 2>"$T/err" || rc=$?
  if [ "$rc" -eq 0 ]; then ko "$label (should have failed)"; return; fi
  if ! grep -qF -- "$needle" "$T/err"; then
    ko "$label (message does not name «${needle}»: $(tr -d '\n' <"$T/err"))"; return
  fi
  if grep -qF -- 'github_pat_11ABCDEF' "$T/err" "$T/out"; then
    ko "$label (the secret leaked into the output)"; return
  fi
  ok "$label"
}

expect_fail "missing key → message names the key"      'secret://not_in_the_file' 'not_in_the_file'
expect_fail "key present but empty → explicit failure" 'secret://empty'          'empty'
expect_fail "indirection with no key name → explicit failure" 'secret://'          'secret://<key>'
expect_fail "indented key ignored (flat mapping expected)"  'secret://inner'     'inner'

SECRETS_FILE="$T/missing.yaml"
expect_fail "missing secrets.yaml → message names the file AND the key" \
  'secret://github_pat_exporter' 'github_pat_exporter'
SECRETS_FILE="$T/secrets.yaml"

# 5. The two call sites in run.sh, and their deliberate asymmetry.
if grep -qF "resolve_secret \"\$(bashio::config 'repository.password')\"" "$RUN_SH"; then
  ok "run.sh resolves repository.password through resolve_secret"
else
  ko "run.sh does not call resolve_secret on repository.password"
fi

# The AI key call site is evaluated verbatim from run.sh: a broken indirection must
# leave the export running with an empty key (static commit message), not abort it.
callsite="$(grep -F 'ai_api_key="$(resolve_secret' "$RUN_SH" || true)"
if [ -z "$callsite" ]; then
  ko "run.sh does not call resolve_secret on repository.commit_message_api_key"
else
  rc=0
  # The redirect belongs INSIDE the substitution: on an assignment it is applied after
  # the substitution has already run, so the error would land on the terminal instead.
  got="$( (
    set -e
    bashio::config() { printf '%s' 'secret://not_in_the_file'; }
    eval "$callsite"
    printf '%s' "${ai_api_key}"
  ) 2>"$T/err" )" || rc=$?
  check "broken AI-key indirection does not abort the export" "$rc" '0'
  check "…and leaves the key empty, so the static message is used" "$got" ''
  if grep -qF 'not_in_the_file' "$T/err"; then
    ok "…while still logging which key is missing"
  else
    ko "…but says nothing about the missing key"
  fi

  rc=0
  got="$(
    set -e
    bashio::config() { printf '%s' 'secret://anthropic_api_key'; }
    eval "$callsite"
    printf '%s' "${ai_api_key}"
  )" || rc=$?
  check "a valid AI-key indirection resolves at the call site" "$got" 'sk-ant-api03-FAKEKEYFORTESTS'
fi

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo '✅ all tests pass' || echo '❌ failures above')"
exit "$fail"
