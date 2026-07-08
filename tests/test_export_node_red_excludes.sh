#!/usr/bin/env bash
set -euo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src"
echo '[]' > "$TMP/src/flows.json"
echo 'module.exports={}' > "$TMP/src/settings.js"

mkdir -p "$TMP/dest"

node_red_exclude_args=""
EXCLUDES=$'node-red/flows.json\nother/x.yaml'
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    case "$ex" in
        node-red/*) node_red_exclude_args+="--exclude=${ex#node-red/} " ;;
    esac
done <<<"$EXCLUDES"

[[ "$node_red_exclude_args" == *"--exclude=flows.json"* ]] || { echo "FAIL: flows.json not in exclude args"; exit 1; }
[[ "$node_red_exclude_args" == *"other"* ]] && { echo "FAIL: other/* leaked"; exit 1; }

# shellcheck disable=SC2086
rsync -archive --compress --delete --checksum --prune-empty-dirs -q \
      $node_red_exclude_args \
      --exclude='flows_cred.json' --exclude='*.backup' --include='flows.json' --include='settings.js' --exclude='*' \
    "$TMP/src/" "$TMP/dest/"

[ ! -f "$TMP/dest/flows.json" ] || { echo "FAIL: excluded flows.json copied"; exit 1; }
[ -f "$TMP/dest/settings.js" ]  || { echo "FAIL: settings.js missing"; exit 1; }
echo "PASS"
