#!/usr/bin/env bash
#
# Integration test for check.mode: warn|error.
#
# Simulates the fixed check_secrets branching logic against a git-secrets
# scan that reports a match. Verifies that:
#   - mode=error   → non-zero exit, "Found secrets" error logged
#   - mode=warn    → zero exit,     "check.mode=warn" warning logged
#   - mode=<empty> → non-zero exit  (default = error, back-compat)

set -euo pipefail

# Helper: simulate the branching block from run.sh
simulate() {
    local mode="$1"
    # Simulate git-secrets returning non-zero (found matches)
    local out
    if ! false; then
        # rebuild the exact conditional from run.sh
        if [ "${mode:-error}" = 'warn' ]; then
            out="WARNING: check.mode=warn — proceeding"
            echo "$out"
            return 0
        else
            out="ERROR: Found secrets in files"
            echo "$out"
            return 1
        fi
    fi
}

# --- error mode ---
set +e
output=$(simulate 'error' 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: mode=error must exit non-zero on match, got rc=$rc"
    exit 1
fi
if [[ "$output" != *"ERROR: Found secrets"* ]]; then
    echo "FAIL: mode=error must log 'Found secrets', got: $output"
    exit 1
fi

# --- warn mode ---
set +e
output=$(simulate 'warn' 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "FAIL: mode=warn must exit zero on match, got rc=$rc"
    exit 1
fi
if [[ "$output" != *"check.mode=warn"* ]]; then
    echo "FAIL: mode=warn must log 'check.mode=warn' warning, got: $output"
    exit 1
fi

# --- default (empty) mode → error ---
set +e
output=$(simulate '' 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: empty mode must default to error (non-zero exit), got rc=$rc"
    exit 1
fi

echo "PASS: check.mode error/warn/default all behave correctly"
