#!/usr/bin/env bash
#
# Regression test for #5. A filename with a space must be passed as
# ONE argument to the scanner. Pre-fix the shell word-split the
# `$(find ...)` output and the scan received two garbage paths.

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/themes"
: > "$TMP/repo/themes/Liquid Glass.yaml"
: > "$TMP/repo/other.yaml"

# Simulate what the fixed check_secrets does — pipe the find output as
# separate args via -print0 | xargs -0. `printf %q\n` echoes what
# xargs will actually pass, one per line.
mapfile -t out < <(
    find "$TMP/repo" \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.disabled' \) -print0 \
        | xargs -0 -n1 printf '%s\n'
)

# Assertion: exactly 2 targets, and one of them is the space-in-name file
if [ "${#out[@]}" -ne 2 ]; then
    printf 'FAIL: expected 2 scan targets, got %d\n%s\n' "${#out[@]}" "$(printf '  %s\n' "${out[@]}")"
    exit 1
fi

found=0
for f in "${out[@]}"; do
    [[ "$f" == *"Liquid Glass.yaml" ]] && found=1
done
if [ "$found" -ne 1 ]; then
    printf 'FAIL: space-in-name file was word-split\ngot: %s\n' "$(printf '  %s\n' "${out[@]}")"
    exit 1
fi

echo "PASS"
