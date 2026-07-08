"""Test the placeholder allow-list regexes added to check_secrets.

git-secrets treats each `--add -a <pattern>` as a PCRE regex that, when
matched anywhere on a line, marks that line as safe (bypasses prohibited
pattern matches on the same line). We test each regex against a set of
should-match and should-NOT-match cases using Python's `re` module,
which is functionally equivalent to PCRE for these patterns.
"""
from __future__ import annotations

import re

import pytest

# The 6 allow-list patterns, kept in lock-step with run.sh check_secrets.
# If you change one there, change it here too.
PATTERNS = {
    "redacted": r"REDACTED_[A-Z0-9_]+",
    "change_me": r"CHANGE_?ME(_[A-Z0-9_]+)?",
    "your_here": r"YOUR_[A-Z0-9_]+_HERE",
    "placeholder": r"PLACEHOLDER_[A-Z0-9_]+",
    "angle": r"<[A-Z][A-Z0-9_]*>",
    "jinja": r"\{\{\s*[a-zA-Z_][a-zA-Z0-9_.]*\s*\}\}",
}


@pytest.mark.parametrize(
    "pattern_key,line",
    [
        ("redacted", "password: REDACTED_TISSEO_KEY"),
        ("redacted", "token: REDACTED_ABC123"),
        ("change_me", "api_key: CHANGE_ME"),
        ("change_me", "api_key: CHANGEME"),
        ("change_me", "api_key: CHANGE_ME_LATER"),
        ("your_here", "password: YOUR_PASSWORD_HERE"),
        ("your_here", "token: YOUR_TISSEO_API_KEY_HERE"),
        ("placeholder", "password: PLACEHOLDER_VALUE"),
        ("placeholder", "token: PLACEHOLDER_123"),
        ("angle", "password: <PASSWORD>"),
        ("angle", "api_key: <TISSEO_API_KEY>"),
        ("jinja", "password: {{ password }}"),
        ("jinja", "password: {{password}}"),
        ("jinja", "password: {{ secrets.tisseo_api_key }}"),
    ],
)
def test_placeholder_matches(pattern_key: str, line: str) -> None:
    assert re.search(PATTERNS[pattern_key], line) is not None


@pytest.mark.parametrize(
    "pattern_key,line",
    [
        # case-sensitive: lowercase variants should NOT allow
        ("redacted", "password: redacted_lowercase"),
        ("change_me", "api_key: change_me"),
        ("placeholder", "password: placeholder_value"),
        ("angle", "password: <password>"),
        # structural requirements
        ("redacted", "password: REDACTED"),           # no suffix
        ("your_here", "password: YOUR_HERE"),         # no infix
        ("angle", "password: <a>"),                   # single lowercase char
        ("jinja", "password: {{}}"),                  # empty
    ],
)
def test_placeholder_non_matches(pattern_key: str, line: str) -> None:
    assert re.search(PATTERNS[pattern_key], line) is None


REAL_CREDENTIALS = [
    "password: 58ed6c97-1a77-4a86-863b-6bc8bf360676",
    "api_key: sk-proj-abc123XYZ456",
    "token: ghp_ThisIsExactlyLikeAGitHubPAT",
    "password: hunter2",
    "password: p@ssw0rd!",
    'password: "oopeez6aedahMeuk6cai6equaepeeroh3pi8"',
]


@pytest.mark.parametrize("cred_line", REAL_CREDENTIALS)
@pytest.mark.parametrize("pattern_key", list(PATTERNS.keys()))
def test_real_credentials_dont_match_any_allow_pattern(
    pattern_key: str, cred_line: str
) -> None:
    """Guard: real-looking credentials must not be accidentally allow-listed."""
    assert re.search(PATTERNS[pattern_key], cred_line) is None
