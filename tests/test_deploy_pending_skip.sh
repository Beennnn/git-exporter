#!/usr/bin/env bash
#
# Tests for deploy_is_pending() — the skip-when-deploy-pending guard that removes
# the exporter/deployer race (docs/design/deploy-snapshot-race.md, consumer repo
# ha-vallesvilles-family). The function is extracted from run.sh and driven against
# every branch of the guard:
#   1. guard OFF                 -> never pending (snapshot proceeds)
#   2. head == deployed          -> not pending (config already deployed)
#   3. head != deployed          -> PENDING (skip: a merged change isn't on /config yet)
#   4. marker unknown/empty      -> fail-safe: not pending (Workflow B preserved)
#   5. no known remote head      -> fail-safe: not pending
#
# Real git + jq are used; curl is stubbed via a PATH shim driven by $FAKE_STATE.
# Requires jq + git; skips cleanly without them.

set -euo pipefail

command -v jq  >/dev/null || { echo "SKIP: jq not installed";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not installed"; exit 0; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNSH="$ROOT/git-exporter/root/run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub curl on PATH: emits the HA state JSON per FAKE_STATE ---------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_STATE:-}" in
  "")      printf '%s' '' ;;                            # unreadable / empty body
  unknown) printf '%s' '{"state":"unknown"}' ;;
  *)       printf '%s' "{\"state\":\"${FAKE_STATE}\"}" ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export SUPERVISOR_TOKEN=dummy

# --- stub bashio::config (per key) + bashio::log.* (no-ops) ------------------
bashio::config() {
  case "$1" in
    repository.skip_when_deploy_pending) printf '%s' "${CFG_ENABLED:-false}" ;;
    repository.deployed_sha_entity)      printf '%s' "${CFG_ENTITY:-}" ;;
    *) printf '' ;;
  esac
}
bashio::log.info()    { :; }
bashio::log.warning() { :; }
export -f bashio::config bashio::log.info bashio::log.warning

# --- git repo with origin/main pointing at a known sha ----------------------
git init -q "$TMP/repo"
( cd "$TMP/repo"; git config user.email t@t.t; git config user.name t; git commit -qm seed --allow-empty )
local_repository="$TMP/repo"
branch=main
HEAD_SHA="$(git -C "$local_repository" rev-parse HEAD)"
git -C "$local_repository" update-ref "refs/remotes/origin/${branch}" "$HEAD_SHA"

# --- load the function under test -------------------------------------------
sed -n '/^function deploy_is_pending {/,/^}/p' "$RUNSH" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract deploy_is_pending from run.sh"; exit 1; }
# shellcheck disable=SC1091
source "$TMP/fn.sh"

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
# rc 0 = pending (skip snapshot) ; rc 1 = not pending (snapshot proceeds).
# Each case runs in a subshell so env vars never leak between assertions.

# 1. guard OFF -> not pending even if the marker differs
( export CFG_ENABLED=false FAKE_STATE=deadbeef; deploy_is_pending ) && fail "1: OFF must not be pending"

# 2. guard ON, head == deployed -> not pending (already deployed)
( export CFG_ENABLED=true FAKE_STATE="$HEAD_SHA"; deploy_is_pending ) && fail "2: head==deployed must not be pending"

# 3. guard ON, head != deployed -> PENDING (skip)
( export CFG_ENABLED=true FAKE_STATE=0000000000000000000000000000000000000000; deploy_is_pending ) || fail "3: head!=deployed must be pending"

# 4. guard ON, marker unknown -> fail-safe not pending
( export CFG_ENABLED=true FAKE_STATE=unknown; deploy_is_pending ) && fail "4: unknown marker must fail-safe"

# 4'. guard ON, marker empty/unreadable -> fail-safe not pending
( export CFG_ENABLED=true FAKE_STATE=''; deploy_is_pending ) && fail "4': empty marker must fail-safe"

# 5. guard ON, no known remote head -> fail-safe not pending
git -C "$local_repository" update-ref -d "refs/remotes/origin/${branch}"
( export CFG_ENABLED=true FAKE_STATE=whatever; deploy_is_pending ) && fail "5: missing origin head must fail-safe"

echo "PASS"
