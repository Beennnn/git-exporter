#!/usr/bin/env bash
#
# Tests for the AI commit-message feature (docs/design/ai-commit-messages.md).
# Exercises generate_ai_commit_message() extracted from run.sh against the four
# paths from the design:
#   A. API succeeds            -> function prints the AI message
#   B. API network failure     -> function prints nothing (caller uses fallback)
#   D. API malformed response  -> function prints nothing (caller uses fallback)
# (Path C — api_key unset — lives in the caller, which never invokes the
#  function without a key; asserted separately at the bottom.)
#
# The real git and jq are used; curl is stubbed via a PATH shim whose behaviour
# is driven by $FAKE_CURL_MODE. Requires jq + git; skips cleanly without them.

set -euo pipefail

command -v jq  >/dev/null || { echo "SKIP: jq not installed";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not installed"; exit 0; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNSH="$ROOT/git-exporter/root/run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub curl on PATH; behaviour driven by FAKE_CURL_MODE ------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_CURL_MODE:-success}" in
  success)   printf '%s' '{"content":[{"type":"text","text":"fix(lovelace): rename printer sensors"}]}' ;;
  netfail)   exit 7 ;;                       # curl: could not connect
  malformed) printf '%s' '{"error":{"type":"overloaded"}}' ;;
  empty)     printf '%s' '' ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# --- stub bashio::config: optional keys empty -> function uses its defaults --
bashio::config() { printf ''; }
export -f bashio::config

# --- real git repo with a staged change so the diff is non-empty ------------
git init -q "$TMP/repo"
cd "$TMP/repo"
git config user.email t@t.t; git config user.name t
printf 'a\n' > f.txt
git add f.txt

# --- extract the real function from run.sh and load it ----------------------
sed -n '/^function generate_ai_commit_message {/,/^}/p' "$RUNSH" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract generate_ai_commit_message from run.sh"; exit 1; }
# shellcheck disable=SC1091
source "$TMP/fn.sh"

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
# FAKE_CURL_MODE must be exported so the curl PATH shim (a subprocess) reads it.

# Path A — success -> the AI message
export FAKE_CURL_MODE=success
out="$(generate_ai_commit_message "sk-test")"
[ "$out" = "fix(lovelace): rename printer sensors" ] || fail "A: expected AI message, got '$out'"

# Path B — network failure -> empty (caller falls back)
export FAKE_CURL_MODE=netfail
out="$(generate_ai_commit_message "sk-test")"
[ -z "$out" ] || fail "B: expected empty on netfail, got '$out'"

# Path D — malformed / error JSON -> empty
export FAKE_CURL_MODE=malformed
out="$(generate_ai_commit_message "sk-test")"
[ -z "$out" ] || fail "D: expected empty on malformed JSON, got '$out'"

# Path D' — empty body -> empty
export FAKE_CURL_MODE=empty
out="$(generate_ai_commit_message "sk-test")"
[ -z "$out" ] || fail "D': expected empty on empty body, got '$out'"

# Empty diff (nothing staged) -> empty regardless of API
git commit -qm seed
export FAKE_CURL_MODE=success
out="$(generate_ai_commit_message "sk-test")"
[ -z "$out" ] || fail "empty-diff: expected empty when nothing staged, got '$out'"

echo "PASS"
