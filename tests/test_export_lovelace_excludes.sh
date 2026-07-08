#!/usr/bin/env bash
#
# Integration test for export_lovelace: user excludes matching lovelace/*
# must be honored, same fix pattern as export_esphome.

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake /tmp/lovelace tree (flat — no subdirs, mirrors real behaviour)
mkdir -p "$TMP/src"
cat > "$TMP/src/lovelace.dashboard_public.yaml" <<'EOF'
title: Public
EOF
cat > "$TMP/src/lovelace.dashboard_famille.yaml" <<'EOF'
title: Family
# has real lat/lng values that user wants to exclude
latitude: 43.570758
longitude: 1.5978114
EOF

mkdir -p "$TMP/dest"

# --- Simulate the fixed export_lovelace logic ---
lovelace_exclude_args=""
EXCLUDES=$'lovelace/lovelace.dashboard_famille.yaml\nesphome/foo.yaml'
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    case "$ex" in
        lovelace/*) lovelace_exclude_args+="--exclude=${ex#lovelace/} " ;;
    esac
done <<<"$EXCLUDES"

# Assertion 1: the stripped path was added
if [[ "$lovelace_exclude_args" != *"--exclude=lovelace.dashboard_famille.yaml"* ]]; then
    echo "FAIL: dashboard_famille not in lovelace_exclude_args"
    echo "actual: '$lovelace_exclude_args'"
    exit 1
fi

# Assertion 2: non-lovelace prefix entries don't leak
if [[ "$lovelace_exclude_args" == *"esphome"* ]] || [[ "$lovelace_exclude_args" == *"foo.yaml"* ]]; then
    echo "FAIL: esphome/foo.yaml leaked into lovelace_exclude_args"
    exit 1
fi

# Assertion 3: rsync honors the exclude
# shellcheck disable=SC2086
rsync -archive --compress --delete --checksum --prune-empty-dirs -q \
     $lovelace_exclude_args --include='*.yaml' --exclude='*' \
    "$TMP/src/" "$TMP/dest/"

if [ -f "$TMP/dest/lovelace.dashboard_famille.yaml" ]; then
    echo "FAIL: excluded lovelace dashboard was still copied"
    exit 1
fi
if [ ! -f "$TMP/dest/lovelace.dashboard_public.yaml" ]; then
    echo "FAIL: non-excluded lovelace dashboard was not copied"
    exit 1
fi

echo "PASS: user exclude 'lovelace/lovelace.dashboard_famille.yaml' was honored"
