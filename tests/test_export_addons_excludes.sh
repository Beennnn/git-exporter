#!/usr/bin/env bash
#
# Integration test for export_addons: user excludes matching addons/*
# must be honored. Same shape as the esphome (#7) and lovelace (#9)
# tests.

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src"
echo 'name: Foo Addon' > "$TMP/src/68413af6_foo.yaml"
echo 'name: Bar Addon' > "$TMP/src/b67bc1f9_bar.yaml"
echo 'repos: []' > "$TMP/src/repositories.yaml"

mkdir -p "$TMP/dest"

addons_exclude_args=""
EXCLUDES=$'addons/68413af6_foo.yaml\nlovelace/x.yaml'
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    case "$ex" in
        addons/*) addons_exclude_args+="--exclude=${ex#addons/} " ;;
    esac
done <<<"$EXCLUDES"

[[ "$addons_exclude_args" == *"--exclude=68413af6_foo.yaml"* ]] || { echo "FAIL: prefix strip"; exit 1; }
[[ "$addons_exclude_args" == *"lovelace"* ]] && { echo "FAIL: lovelace/* leaked"; exit 1; }

# shellcheck disable=SC2086
rsync -archive --compress --delete --checksum --prune-empty-dirs -q \
     $addons_exclude_args "$TMP/src/" "$TMP/dest/"

[ ! -f "$TMP/dest/68413af6_foo.yaml" ] || { echo "FAIL: excluded file copied"; exit 1; }
[ -f "$TMP/dest/b67bc1f9_bar.yaml" ]   || { echo "FAIL: kept file missing"; exit 1; }
[ -f "$TMP/dest/repositories.yaml" ]   || { echo "FAIL: repositories.yaml missing"; exit 1; }

echo "PASS"
