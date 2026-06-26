#!/usr/bin/env python3
"""Self-check: gws pretty-prints getProfile JSON across multiple lines and exits 0
even on API errors. _gws must (a) parse multi-line success JSON, (b) raise the
error body instead of silently returning an empty email. The old single-line
scan in keeper_server failed both. Run: python3 test_fix_profile_email.py"""
import json, types, draftutil as du

PRETTY_OK = """Using keyring backend: file
{
  "emailAddress": "alex@example.com",
  "messagesTotal": 12345,
  "threadsTotal": 6789
}
"""

PRETTY_ERR = """Using keyring backend: file
{
  "error": {
    "code": 403,
    "message": "Gmail API has not been used in project 123 before or it is disabled.",
    "reason": "accessNotConfigured"
  }
}
"""


def _fake_run(out, code=0):
    def run(*a, **k):
        return types.SimpleNamespace(returncode=code, stdout=out, stderr="")
    return run


def main():
    orig = du.subprocess.run
    try:
        # (a) multi-line success parses to the email
        du.subprocess.run = _fake_run(PRETTY_OK)
        assert du._profile_email("/cfg") == "alex@example.com"

        # (b) error body (exit 0!) is raised, not swallowed into an empty email
        du.subprocess.run = _fake_run(PRETTY_ERR)
        try:
            du._profile_email("/cfg")
            assert False, "expected error body to raise"
        except RuntimeError as e:
            assert "Gmail API has not been used" in str(e), str(e)
    finally:
        du.subprocess.run = orig
    print("ok: multi-line profile parse + error passthrough")


if __name__ == "__main__":
    main()
