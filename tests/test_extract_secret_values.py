"""Unit tests for utils/extract_secret_values.py"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).parent.parent / "git-exporter" / "root" / "utils" / "extract_secret_values.py"


def _run(content: str) -> list[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        fh.write(content)
        path = fh.name
    result = subprocess.run(
        [sys.executable, str(SCRIPT), path],
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def test_skips_boolean_numeric_and_short():
    out = _run(
        "port: 8123\n"
        "enabled: true\n"
        "short: abc\n"
        "latitude: 43.6108\n"
    )
    assert out == []


def test_keeps_long_alnum_values_and_regex_escapes():
    out = _run(
        'api_key: "abc123DEF456ghi789"\n'
        'password: "Str0ng!Pa$$w0rd"\n'
    )
    assert "abc123DEF456ghi789" in out
    # $ must be escaped so grep-secrets doesn't treat it as end-of-line
    assert r"Str0ng!Pa\$\$w0rd" in out


def test_skips_comments_and_blank_lines():
    out = _run("# a comment\n\n\ngithub_token: ghp_ThisIsFakeXXXXXXXXXXXXX\n")
    assert out == ["ghp_ThisIsFakeXXXXXXXXXXXXX"]


def test_missing_file_is_noop():
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "/nonexistent/secrets.yaml"],
        check=True,
        capture_output=True,
        text=True,
    )
    assert result.stdout == ""
