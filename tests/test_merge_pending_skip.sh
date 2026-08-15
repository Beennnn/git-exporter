#!/usr/bin/env bash
#
# Tests for merge_is_pending() — the second half of the anti-race guard. It covers
# the chain link deploy_is_pending() cannot see: a change merged into the review
# branch (`main`) but not yet fast-forwarded onto the deploy branch, which leaves
# `/config` legitimately stale while the deployed-SHA marker still matches.
# Blind spot hit for real on 2026-08-15 (see docs/design/deploy-snapshot-race.md
# in the consumer repo ha-vallesvilles-family).
#
#   1. guard OFF                       -> not pending
#   2. merged_branch unset             -> not pending (opt-in)
#   3. merged_branch == branch         -> not pending (nothing to compare)
#   4. steady, main == deploy branch   -> not pending
#   5. deploy branch ahead (capture)   -> not pending (Workflow B preserved)
#   6. main ahead, config differs      -> PENDING (the fix)
#   7. main ahead, same tree           -> not pending (merge commit absorbing a
#                                         capture PR must not freeze captures)
#   8. main ahead, diff outside subdir -> not pending (export-only trees never
#                                         travel git -> HA)
#   9. origin/main unknown             -> fail-safe: not pending
#
# Real git is used; no network, no curl. Requires git; skips cleanly without it.

set -euo pipefail

command -v git >/dev/null || { echo "SKIP: git not installed"; exit 0; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNSH="$ROOT/git-exporter/root/run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub bashio::config (per key) + bashio::log.* (no-ops) ------------------
bashio::config() {
  case "$1" in
    repository.skip_when_deploy_pending) printf '%s' "${CFG_ENABLED:-true}" ;;
    repository.merged_branch)            printf '%s' "${CFG_MERGED:-main}" ;;
    repository.deployed_subdir)          printf '%s' "${CFG_SUBDIR:-}" ;;
    *) printf '' ;;
  esac
}
bashio::log.info()    { :; }
bashio::log.warning() { :; }

# --- a repo with a config/ subtree and an export-only lovelace/ subtree ------
local_repository="$TMP/repo"
branch=live-snapshot
git init -q "$local_repository"
cd "$local_repository"
git config user.email t@t.t
git config user.name t

mkdir -p config lovelace
echo 'base' > config/sensor.yaml
echo 'base' > lovelace/dash.yaml
git add -A && git commit -qm base
BASE="$(git rev-parse HEAD)"

# a merged fix living only on the review branch (case 6)
echo 'unique_id: fixed' >> config/sensor.yaml
git commit -qam 'fix(rest): unique_id'
FIX="$(git rev-parse HEAD)"

# a live capture living only on the deploy branch (case 5)
git reset -q --hard "$BASE"
echo 'captured live' >> config/sensor.yaml
git commit -qam 'chore(snapshot): capture live'
CAPTURE="$(git rev-parse HEAD)"

# the merge commit that absorbs the capture PR into main: same tree as CAPTURE,
# different history (case 7)
MERGE="$(git commit-tree "$(git rev-parse "${CAPTURE}^{tree}")" -p "$BASE" -p "$CAPTURE" -m 'Merge capture PR')"

# a review-branch commit touching only the export-only tree (case 8)
git reset -q --hard "$BASE"
echo 'tweak' >> lovelace/dash.yaml
git commit -qam 'refactor(lovelace): tweak'
LOVELACE="$(git rev-parse HEAD)"

git reset -q --hard "$BASE"

set_refs() {  # $1 = origin/live-snapshot, $2 = origin/main
  git update-ref "refs/remotes/origin/${branch}" "$1"
  git update-ref refs/remotes/origin/main "$2"
}

# --- load the function under test -------------------------------------------
sed -n '/^function merge_is_pending {/,/^}/p' "$RUNSH" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract merge_is_pending from run.sh"; exit 1; }
# shellcheck disable=SC1091
source "$TMP/fn.sh"

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
# rc 0 = pending (skip snapshot) ; rc 1 = not pending (snapshot proceeds).
# Each case runs in a subshell so env vars never leak between assertions.

# 1. guard OFF -> not pending even with an undeployed merge
set_refs "$BASE" "$FIX"
( CFG_ENABLED=false; merge_is_pending ) && fail "1: OFF must not be pending"

# 2. merged_branch unset -> not pending (opt-in)
( CFG_MERGED=''; merge_is_pending ) && fail "2: unset merged_branch must not be pending"

# 3. merged_branch == branch -> not pending
( CFG_MERGED="$branch"; merge_is_pending ) && fail "3: same branch must not be pending"

# 4. steady state -> not pending
set_refs "$BASE" "$BASE"
( merge_is_pending ) && fail "4: main == deploy branch must not be pending"

# 5. deploy branch ahead (live capture awaiting its PR) -> not pending
set_refs "$CAPTURE" "$BASE"
( merge_is_pending ) && fail "5: capture ahead must not be pending (Workflow B)"

# 6. main ahead with a real config change -> PENDING
set_refs "$BASE" "$FIX"
( merge_is_pending ) || fail "6: undeployed merge must be pending"

# 6'. explicit deployed_subdir -> same verdict
( CFG_SUBDIR=config; merge_is_pending ) || fail "6': explicit subdir must be pending"

# 7. main ahead by a merge commit with an identical tree -> not pending
set_refs "$CAPTURE" "$MERGE"
( merge_is_pending ) && fail "7: same-tree merge commit must not freeze captures"

# 8. main ahead but only in an export-only tree -> not pending
set_refs "$BASE" "$LOVELACE"
( merge_is_pending ) && fail "8: export-only divergence must not be pending"

# 9. origin/main unknown -> fail-safe not pending
set_refs "$BASE" "$FIX"
git update-ref -d refs/remotes/origin/main
( merge_is_pending ) && fail "9: missing review branch must fail-safe"

echo "PASS"
