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
#   6. marker eclipsed briefly   -> retry sees it: PENDING (or not, if it comes back
#                                   on the current head) — the 2026-08-16 hole
#   7. eclipse outlasts retries  -> fail-safe by default (real outage)
#   8. same, fail_closed ON      -> PENDING: the durable-outage arbitration (beennnn.8)
#   9. guard_status              -> every branch reports itself, so a skip is never silent
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
# FAKE_ECLIPSE=N : the marker is missing for the first N calls, then readable.
# Models the real failure mode — the entity vanishes while the deployer's pass
# reloads the helpers — rather than a steadily unreadable marker.
if [ -n "${FAKE_ECLIPSE:-}" ]; then
  # Default to 0 on a missing OR EMPTY counter file: an empty $n would make the
  # comparison below error out, the eclipse would never happen, and the test would
  # pass for the wrong reason (caught while writing case 7).
  n="$(cat "$FAKE_CALLS" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  echo $((n + 1)) > "$FAKE_CALLS"
  if [ "$n" -lt "$FAKE_ECLIPSE" ]; then printf '%s' ''; exit 0; fi
fi
case "${FAKE_STATE:-}" in
  "")      printf '%s' '' ;;                            # unreadable / empty body
  unknown) printf '%s' '{"state":"unknown"}' ;;
  *)       printf '%s' "{\"state\":\"${FAKE_STATE}\"}" ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export SUPERVISOR_TOKEN=dummy
export FAKE_CALLS="$TMP/calls"
# No real waiting between retries; the retry COUNT is what the assertions exercise.
export DEPLOYED_SHA_READ_DELAY=0

# --- stub bashio::config (per key) + bashio::log.* (no-ops) ------------------
bashio::config() {
  case "$1" in
    repository.skip_when_deploy_pending) printf '%s' "${CFG_ENABLED:-false}" ;;
    repository.deployed_sha_entity)      printf '%s' "${CFG_ENTITY:-}" ;;
    repository.fail_closed_when_marker_unreadable) printf '%s' "${CFG_FAIL_CLOSED:-false}" ;;
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

# 4. guard ON, marker unknown, fail_closed OFF -> fail-safe not pending
( export CFG_ENABLED=true FAKE_STATE=unknown; deploy_is_pending ) && fail "4: unknown marker must fail-safe"

# 4'. guard ON, marker empty/unreadable, fail_closed OFF -> fail-safe not pending
( export CFG_ENABLED=true FAKE_STATE=''; deploy_is_pending ) && fail "4': empty marker must fail-safe"

# 6. ÉCLIPSE — the marker is gone for the first 3 reads (the deployer's reload_all),
#    then comes back on the OLD sha: the retry must see it and PEND instead of
#    fail-safing into a capture that would revert the just-merged PR (2026-08-16, #226).
echo 0 > "$FAKE_CALLS"
( export CFG_ENABLED=true FAKE_ECLIPSE=3 FAKE_STATE=0000000000000000000000000000000000000000
  deploy_is_pending ) || fail "6: a transient eclipse must not fall through to fail-safe"

# 6'. Same eclipse, but the deployer finishes during the retries and publishes the
#     current head -> /config is up to date, capturing is correct.
echo 0 > "$FAKE_CALLS"
( export CFG_ENABLED=true FAKE_ECLIPSE=3 FAKE_STATE="$HEAD_SHA"
  deploy_is_pending ) && fail "6': eclipse resolving to head must not be pending"

# 7. The eclipse outlasts every retry (real outage: deployer dead, entity deleted,
#    API down) and fail_closed is OFF -> historical fail-safe is preserved.
echo 0 > "$FAKE_CALLS"
( export CFG_ENABLED=true FAKE_ECLIPSE=99 DEPLOYED_SHA_READ_ATTEMPTS=3 FAKE_STATE=deadbeef
  deploy_is_pending ) && fail "7: a lasting outage must fail-safe when fail_closed is off"

# 8. Same durable outage, fail_closed ON -> the guard ABSTAINS. This is the arbitration
#    of 2026-08-16: no more blind capture, hence no more silent revert. Only tenable
#    because the abstention is reported (case 9) instead of freezing capture in silence.
echo 0 > "$FAKE_CALLS"
( export CFG_ENABLED=true CFG_FAIL_CLOSED=true FAKE_ECLIPSE=99 DEPLOYED_SHA_READ_ATTEMPTS=3 FAKE_STATE=deadbeef
  deploy_is_pending ) || fail "8: a lasting outage must skip when fail_closed is on"

# 8'. fail_closed must NOT change the nominal branches: a readable marker equal to head
#     still means "nothing pending", otherwise the flag would freeze capture outright.
( export CFG_ENABLED=true CFG_FAIL_CLOSED=true FAKE_STATE="$HEAD_SHA"
  deploy_is_pending ) && fail "8': fail_closed must not skip when the marker is current"

# 9. guard_status — each outcome names itself, so the consumer alerts on a POSITIVE
#    state instead of inferring a freeze from silence (the two watchdogs that were
#    disabled for false positives, letting a 7-day outage through).
check_status() { # <expected> <label> ; runs in the caller's shell so guard_status survives
  [ "$guard_status" = "$1" ] || fail "9: $2 must report $1, got '${guard_status}'"
}

guard_status=OK
echo 0 > "$FAKE_CALLS"
export CFG_ENABLED=true CFG_FAIL_CLOSED=true FAKE_ECLIPSE=99 DEPLOYED_SHA_READ_ATTEMPTS=3 FAKE_STATE=deadbeef
deploy_is_pending || true
check_status MARKER_UNREADABLE "a durable outage (fail-closed)"

guard_status=OK
unset FAKE_ECLIPSE
export CFG_FAIL_CLOSED=false FAKE_STATE=unknown
deploy_is_pending || true
check_status MARKER_UNREADABLE "a durable outage (fail-safe, capture went ahead blind)"

guard_status=OK
export FAKE_STATE=0000000000000000000000000000000000000000
deploy_is_pending || true
check_status DEPLOY_PENDING "a pending deploy"

guard_status=OK
export FAKE_STATE="$HEAD_SHA"
deploy_is_pending || true
check_status OK "a marker already on head"
unset CFG_ENABLED CFG_FAIL_CLOSED FAKE_STATE

# 5. guard ON, no known remote head -> fail-safe not pending
git -C "$local_repository" update-ref -d "refs/remotes/origin/${branch}"
( export CFG_ENABLED=true FAKE_STATE=whatever; deploy_is_pending ) && fail "5: missing origin head must fail-safe"

echo "PASS"
