#!/usr/bin/env bash
#
# Tests for the final commit/push/report block of run.sh — the part that decides
# whether a pass ENDS well. The regression it locks down: `git commit` exits
# non-zero when nothing is staged, and `set -e` turned that nominal "config
# didn't move" case into a dead run (no push, no compte-rendu, add-on `error`).
#
#   1. nothing staged      -> pass completes, reports, no new commit
#   2. a change staged     -> commit + push, origin receives it
#   3. commit stuck local  -> pushed on the next pass even with nothing staged
#   4. dry_run             -> neither commit nor push
#   5. virgin repository   -> no push attempted, pass still completes
#
# The block is extracted from run.sh verbatim and run under `set -e`, so a
# regression to an unguarded `git commit` fails case 1 exactly as it did in prod.
# Real git is used; curl (the compte-rendu POST) is stubbed via a PATH shim.
# Requires jq + git; skips cleanly without them.

set -euo pipefail

command -v jq  >/dev/null || { echo "SKIP: jq not installed";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not installed"; exit 0; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNSH="$ROOT/git-exporter/root/run.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub curl: record the published status, always succeed ------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# The payload is the last -d argument; keep it so the test can assert the report.
prev=''
for arg in "$@"; do
  [ "$prev" = '-d' ] && printf '%s\n' "$arg" >> "$FAKE_POSTS"
  prev="$arg"
done
exit 0
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export SUPERVISOR_TOKEN=dummy
export FAKE_POSTS="$TMP/posts"

# --- extract the code under test: publish_status + everything from the
#     dry_run branch to the end of the script (commit, push, report, finish) --
sed -n '/^function publish_status {/,/^}/p'                 "$RUNSH" >  "$TMP/tail.sh"
sed -n "/^if \[ \"\$(bashio::config 'dry_run')\"/,\$p"      "$RUNSH" >> "$TMP/tail.sh"
grep -q 'git commit'       "$TMP/tail.sh" || { echo "FAIL: could not extract the commit block from run.sh"; exit 1; }
grep -q 'Exporter finished' "$TMP/tail.sh" || { echo "FAIL: extracted block is missing the final log line"; exit 1; }

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# --- run the extracted block against $1 (a repo), with $2 as dry_run --------
# `set -e` is ON inside, exactly as in run.sh (line 2): that is what turned a
# non-zero `git commit` into a killed pass.
#
# The result lands in $PASS_RC / $PASS_OUT instead of being tested with `||` at
# the call site, and that is NOT cosmetic: bash suppresses errexit inside any
# command that is part of a `||` list, and the suppression PROPAGATES into
# subshells. Written as `out="$(run_pass …)" || fail`, the `set -e` below is
# ignored, the killed pass runs to the end anyway, and the test passes against
# the very bug it exists to catch (verified against the pre-fix run.sh).
run_pass() {
  local repo="$1" dry="${2:-false}"
  set +e
  PASS_OUT="$(_run_pass_inner "$repo" "$dry")"
  PASS_RC=$?
  set -e
}

_run_pass_inner() {
  local repo="$1" dry="$2"
  (
    set -e
    cd "$repo"
    # Read by the sourced block, not by this file — hence the SC2034 waiver.
    # shellcheck disable=SC2034
    local_repository="$repo"
    # shellcheck disable=SC2034
    branch=main
    # shellcheck disable=SC2034
    pull_before_push=true
    # shellcheck disable=SC2034
    guard_status=OK
    bashio::config() {
      case "$1" in
        dry_run)                             printf '%s' "$dry" ;;
        repository.commit_message)           printf '%s' 'Home Assistant Config Export' ;;
        repository.commit_message_api_key)   printf '' ;;
        repository.status_entity)            printf '' ;;
        *)                                   printf '' ;;
      esac
    }
    bashio::log.info()    { printf 'INFO: %s\n' "$1"; }
    bashio::log.warning() { printf 'WARN: %s\n' "$1"; }
    # shellcheck disable=SC1090
    source "$TMP/tail.sh"
  )
}

# --- a repo with an origin that can actually be pushed to -------------------
new_repo() { # <name> -> prints the worktree path
  local name="$1"
  git init -q --bare "$TMP/$name.git"
  git init -q -b main "$TMP/$name"
  git -C "$TMP/$name" config user.email t@t.t
  git -C "$TMP/$name" config user.name t
  git -C "$TMP/$name" remote add origin "$TMP/$name.git"
  printf '%s' "$TMP/$name"
}

# 1. NOTHING STAGED — the regression. The pass must complete: report published,
#    final log line reached, and no empty commit invented to dodge the problem.
repo="$(new_repo nochange)"
printf 'first\n' > "$repo/f.yaml"
git -C "$repo" add . && git -C "$repo" commit -qm seed
git -C "$repo" push -q origin main
before="$(git -C "$repo" rev-parse HEAD)"
: > "$FAKE_POSTS"
run_pass "$repo"
[ "$PASS_RC" -eq 0 ] || fail "1: a pass with nothing to commit must not fail"
grep -q 'Exporter finished' <<<"$PASS_OUT" || fail "1: the pass must reach 'Exporter finished'"
grep -q 'ha_exporter_last_result' "$FAKE_POSTS" || fail "1: the compte-rendu must be published"
grep -qE '"value": *"OK"' "$FAKE_POSTS" || fail "1: an unchanged config is a healthy pass (OK)"
[ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail "1: nothing staged must not create a commit"

# 2. A CHANGE STAGED — the nominal path still commits and pushes.
printf 'second\n' > "$repo/f.yaml"
: > "$FAKE_POSTS"
run_pass "$repo"
[ "$PASS_RC" -eq 0 ] || fail "2: a pass with a change must succeed"
[ "$(git -C "$repo" rev-parse HEAD)" != "$before" ] || fail "2: a staged change must be committed"
[ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$TMP/nochange.git" rev-parse main)" ] \
  || fail "2: the commit must reach origin"

# 3. COMMIT STUCK LOCALLY (previous push failed: dead token, DNS) and nothing new
#    to commit. The push is unconditional precisely so the orphan leaves now,
#    instead of waiting for the next config change to be noticed.
repo="$(new_repo stuck)"
printf 'a\n' > "$repo/f.yaml"
git -C "$repo" add . && git -C "$repo" commit -qm seed
git -C "$repo" push -q origin main
printf 'b\n' > "$repo/f.yaml"
git -C "$repo" add . && git -C "$repo" commit -qm 'not pushed'   # the failed push
stuck="$(git -C "$repo" rev-parse HEAD)"
[ "$stuck" != "$(git -C "$TMP/stuck.git" rev-parse main)" ] || fail "3: setup — origin must be behind"
run_pass "$repo"
[ "$PASS_RC" -eq 0 ] || fail "3: a catch-up pass must succeed"
[ "$(git -C "$TMP/stuck.git" rev-parse main)" = "$stuck" ] || fail "3: the stuck commit must be pushed"

# 4. DRY RUN — untouched by the fix: neither commit nor push.
repo="$(new_repo dry)"
printf 'a\n' > "$repo/f.yaml"
git -C "$repo" add . && git -C "$repo" commit -qm seed
before="$(git -C "$repo" rev-parse HEAD)"
printf 'b\n' > "$repo/f.yaml"
run_pass "$repo" true
[ "$PASS_RC" -eq 0 ] || fail "4: dry_run must succeed"
[ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail "4: dry_run must not commit"
if git -C "$TMP/dry.git" rev-parse main >/dev/null 2>&1; then fail "4: dry_run must not push"; fi

# 5. VIRGIN REPOSITORY (first run, nothing exported yet) — there is no ref to
#    push, so pushing would die on 'src refspec main does not match any'. The
#    pass must end cleanly instead, and still report.
repo="$(new_repo virgin)"
: > "$FAKE_POSTS"
run_pass "$repo"
[ "$PASS_RC" -eq 0 ] || fail "5: a virgin repository must not fail the pass"
grep -q 'Exporter finished' <<<"$PASS_OUT" || fail "5: the pass must reach 'Exporter finished'"
grep -q 'ha_exporter_last_result' "$FAKE_POSTS" || fail "5: the compte-rendu must be published"

echo "PASS"
