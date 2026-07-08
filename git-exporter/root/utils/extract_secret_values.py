#!/usr/bin/env python3
"""Extract leaf values from secrets.yaml as safe git-secrets patterns.

Reads /config/secrets.yaml (or the path passed as argv[1]) line-by-line
and prints one regex-escaped pattern per line to stdout, suitable for
feeding to `git secrets --add-provider`.

Skips values that would cause massive false-positive rates:
  - empty values, YAML anchors/aliases, comments
  - booleans (true/false/yes/no/on/off/null/~)
  - purely numeric values (int or float)
  - values shorter than MIN_LENGTH characters (default 8)

Regex-escapes the value before printing so metacharacters like '.' and
'/' don't behave as wildcards downstream.

This replaces the historical one-line sed provider whose bugs were:
  1. `s/\\s//g` deleted the letter 's' from every value (POSIX sed
     treats `\\s` as a literal 's', not as `[[:space:]]`).
  2. Values were emitted unescaped, so `43.6108` became a regex where
     `.` matched any char.
  3. No length / type filter, so `port: 8123` blocked every config that
     mentioned the default HA port.
"""
from __future__ import annotations

import re
import sys

MIN_LENGTH = 8
BOOL_LIKE = {"true", "false", "yes", "no", "on", "off", "null", "~", ""}
NUMERIC_RE = re.compile(r"[-+]?\d+(\.\d+)?([eE][-+]?\d+)?")


def _leaf_value(line: str) -> str | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("&"):
        return None
    if ":" not in stripped:
        return None
    value = stripped.split(":", 1)[1].strip()
    if not value:
        return None
    # strip inline comment
    if " #" in value:
        value = value.split(" #", 1)[0].rstrip()
    # strip surrounding quotes
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("\"", "'"):
        value = value[1:-1]
    if value.lower() in BOOL_LIKE:
        return None
    if NUMERIC_RE.fullmatch(value):
        return None
    if len(value) < MIN_LENGTH:
        return None
    return value


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/config/secrets.yaml"
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                value = _leaf_value(raw.rstrip("\n"))
                if value is not None:
                    print(re.escape(value))
    except FileNotFoundError:
        # No secrets.yaml → nothing to protect against, silent no-op.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
