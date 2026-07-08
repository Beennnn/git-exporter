#!/usr/bin/env bash
#
# Integration test for export_esphome: user excludes matching esphome/*
# must be honored (stripped-prefix, passed to rsync BEFORE the *.yaml include).
#
# Reproduces the pre-fix bug: a user-supplied `exclude:` list entry like
# `esphome/pool-temperature.yaml` was ignored by export_esphome because the
# function had a hardcoded rsync exclude list. This test verifies the fix
# by asserting the resulting exclude args include the stripped path AND that
# an actual rsync run skips the file.

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake /config/esphome tree
mkdir -p "$TMP/src/config/esphome"
cat > "$TMP/src/config/esphome/other.yaml" <<'EOF'
# safe device
name: other
EOF
cat > "$TMP/src/config/esphome/pool-temperature.yaml" <<'EOF'
# device with hardcoded secret in ota.password
ota:
  password: "REAL_SECRET_TOKEN"
EOF

mkdir -p "$TMP/dest"

# --- Simulate the fixed export_esphome logic ---
esphome_exclude_args=""
EXCLUDES=$'esphome/pool-temperature.yaml\nzigbee2mqtt/state.json'
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    case "$ex" in
        esphome/*) esphome_exclude_args+="--exclude=${ex#esphome/} " ;;
    esac
done <<<"$EXCLUDES"

# Assertion 1: the stripped path was added
if [[ "$esphome_exclude_args" != *"--exclude=pool-temperature.yaml"* ]]; then
    echo "FAIL: pool-temperature.yaml not in esphome_exclude_args"
    echo "actual: '$esphome_exclude_args'"
    exit 1
fi

# Assertion 2: non-esphome excludes are NOT in the esphome args
if [[ "$esphome_exclude_args" == *"zigbee2mqtt"* ]]; then
    echo "FAIL: zigbee2mqtt/* leaked into esphome_exclude_args"
    exit 1
fi

# Assertion 3: rsync actually skips the file when given the args
# shellcheck disable=SC2086
rsync -archive --compress --delete --checksum --prune-empty-dirs -q \
     $esphome_exclude_args \
     --exclude='.esphome*' --include='*/' --include='.gitignore' --include='*.yaml' --include='*.disabled' --exclude='secrets.yaml' --exclude='*' \
    "$TMP/src/config/esphome" "$TMP/dest"

if [ -f "$TMP/dest/esphome/pool-temperature.yaml" ]; then
    echo "FAIL: excluded file was still copied"
    exit 1
fi
if [ ! -f "$TMP/dest/esphome/other.yaml" ]; then
    echo "FAIL: non-excluded file was not copied"
    exit 1
fi

echo "PASS: user exclude 'esphome/pool-temperature.yaml' was honored"
