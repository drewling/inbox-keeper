#!/usr/bin/env python3
"""Parallel missed-items sweep across all authenticated accounts, then email one
"⏰ You may have missed" digest to the primary account (the first in accounts.json).

Runs lib/catchup.py for each authenticated account concurrently (each does its own
Haiku filtering), aggregates the important missed items, and sends a single digest.

Usage: missed_sweep.py [lookback_days]   (default 14)
"""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import config  # noqa: E402

PY = config.PYTHON_BIN
ACCOUNTS = config.ACCOUNTS_FILE


def _primary_account():
    """Return (email, config_dir) for the first account (digest sender)."""
    acct = config.primary_account()
    return acct["email"], acct["config_dir"]


def _env(config_dir):
    e = dict(os.environ)
    e["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = config_dir
    e["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
    return e


def authenticated(config_dir):
    try:
        r = subprocess.run(["gws", "gmail", "users", "getProfile", "--params",
                            json.dumps({"userId": "me"})],
                           capture_output=True, text=True, env=_env(config_dir), timeout=30)
        line = "\n".join(l for l in r.stdout.splitlines() if "keyring" not in l)
        return bool(json.loads(line).get("emailAddress")) if line.strip() else False
    except Exception:
        return False


def run_catchup(acct, lookback):
    cfg, email = acct["config_dir"], acct["email"]
    if not authenticated(cfg):
        return {"account": email, "missed": [], "skipped": "not authenticated"}
    try:
        r = subprocess.run([PY, os.path.join(HERE, "catchup.py"), cfg, email, str(lookback)],
                           capture_output=True, text=True, timeout=600)
        line = [l for l in r.stdout.splitlines() if l.strip().startswith("{")]
        out = json.loads(line[-1]) if line else {"account": email, "missed": []}
        # Annotate each missed item with account routing info for Slack post-missed.
        for m in out.get("missed", []):
            m["account_config_dir"] = cfg
            m["account_label"] = email
        return out
    except Exception as e:
        return {"account": email, "missed": [], "error": str(e)}


def main():
    lookback = sys.argv[1] if len(sys.argv) > 1 else "14"
    with open(ACCOUNTS) as f:
        data = json.load(f)
    accounts = data.get("accounts", []) if isinstance(data, dict) else data

    with ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(lambda a: run_catchup(a, lookback), accounts))

    total = sum(len(r.get("missed", [])) for r in results)

    # Collect accounts that could not be evaluated (skipped or errored).
    error_accounts = []
    for r in results:
        acct = r.get("account", "?")
        if r.get("skipped"):
            error_accounts.append(f"⚠️ {acct}: {r['skipped']}")
        elif r.get("error"):
            error_accounts.append(f"⚠️ {acct}: {r['error']}")

    # Write a flat list for the Slack "post-missed" command (always, even if empty).
    flat = [m for r in results for m in r.get("missed", [])]
    missed_path = config.MISSED_PATH
    os.makedirs(os.path.dirname(missed_path), exist_ok=True)
    with open(missed_path, "w") as f:
        json.dump(flat, f, ensure_ascii=False, indent=2)

    if total == 0:
        print(json.dumps({
            "missed_total": 0,
            "sent": False,
            "errors": error_accounts,
        }))
        return

    lines = ["You may have missed these — older un-replied emails still worth a look.\n"]
    for r in results:
        missed = r.get("missed", [])
        if not missed:
            continue
        lines.append(f"### {r['account']}")
        for m in missed:
            age = m.get("age_days")
            age_s = f"{age}d ago" if age is not None else ""
            lines.append(f"• {m.get('from','')} — {m.get('subject','')} {('('+age_s+') ' if age_s else '')}— {m.get('why','')}")
        lines.append("")

    if error_accounts:
        lines.append("\n---")
        for e in error_accounts:
            lines.append(e)
    body = "\n".join(lines)

    digest_to, digest_config = _primary_account()
    subj = "⏰ You may have missed — catch-up sweep"
    send_result = subprocess.run(
        ["gws", "gmail", "+send", "--to", digest_to, "--subject", subj, "--body", body],
        env=_env(digest_config), capture_output=True, text=True, timeout=60,
    )
    sent = send_result.returncode == 0
    print(json.dumps({
        "missed_total": total,
        "sent": sent,
        "errors": error_accounts,
    }))


if __name__ == "__main__":
    main()
