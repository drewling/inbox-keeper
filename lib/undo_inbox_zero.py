#!/usr/bin/env python3
"""Undo an inbox_zero sweep: move everything tagged with the recovery label back to
the inbox. Restores INBOX on every message carrying the label, in batches.

When called without --recovery-label, restores ALL messages tagged with any label
whose name starts with "🗄️ Auto-Archived" (covering all dated sweep labels such as
"🗄️ Auto-Archived 2026-06-23"). Pass --recovery-label to target exactly one label.

Usage: undo_inbox_zero.py <config_dir> [--recovery-label "🗄️ Auto-Archived 2026-06-23"] [--execute]
Default is DRY-RUN (reports how many would be restored).
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import draftutil as du  # noqa: E402
import inbox_zero as iz  # noqa: E402

_BASE_LABEL = "🗄️ Auto-Archived"


def _strip_keyring(text):
    return "\n".join(l for l in text.splitlines() if "keyring" not in l).strip()


def _messages_for_label(cfg, label_name, label_id):
    """Return list of message ids carrying *label_id*. Raises on failure."""
    msg_ids = []
    r = subprocess.run(["gws", "gmail", "users", "messages", "list", "--params",
                        json.dumps({"userId": "me", "q": f'label:"{label_name}"',
                                    "maxResults": 500}),
                        "--page-all", "--page-limit", "500"],
                       capture_output=True, text=True, env=du._env(cfg))
    if r.returncode != 0:
        err = _strip_keyring(r.stderr) or _strip_keyring(r.stdout) or "gws non-zero exit"
        raise RuntimeError(f"message list failed for {label_name!r}: {err}")

    for line in r.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{") or "keyring" in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if "error" in o:
            raise RuntimeError(
                f"API error listing {label_name!r}: {json.dumps(o['error'])}"
            )
        for m in o.get("messages", []) or ([o] if "id" in o else []):
            if m.get("id"):
                msg_ids.append(m["id"])
    return msg_ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config_dir")
    ap.add_argument("--recovery-label", default=None,
                    help="exact label to undo; default: all labels starting with "
                         f"'{_BASE_LABEL}'")
    ap.add_argument("--execute", action="store_true")
    a = ap.parse_args()
    cfg = a.config_dir

    # Fetch all labels once.
    labels_data = du._gws(cfg, ["gmail", "users", "labels", "list",
                                "--params", json.dumps({"userId": "me"})])
    all_labels = labels_data.get("labels", [])

    if a.recovery_label:
        # Exact match.
        target_labels = [(l["name"], l["id"])
                         for l in all_labels if l["name"] == a.recovery_label]
        if not target_labels:
            print(json.dumps({"error": f"label not found: {a.recovery_label}"}))
            return
    else:
        # Match all labels whose name starts with the base prefix.
        target_labels = [(l["name"], l["id"])
                         for l in all_labels if l["name"].startswith(_BASE_LABEL)]
        if not target_labels:
            print(json.dumps({"error": f"no labels found with prefix: {_BASE_LABEL!r}"}))
            return

    # Gather all message ids across matched labels.
    all_msg_ids = []
    for label_name, label_id in target_labels:
        msgs = _messages_for_label(cfg, label_name, label_id)
        all_msg_ids.extend(msgs)

    # Deduplicate (a message could carry multiple archive labels in theory).
    unique_msg_ids = list(dict.fromkeys(all_msg_ids))
    label_ids_to_remove = [lid for _, lid in target_labels]

    report = {
        "account": cfg,
        "labels_targeted": [name for name, _ in target_labels],
        "to_restore": len(unique_msg_ids),
        "executed": False,
    }
    if not a.execute:
        report["mode"] = "dry-run"
        print(json.dumps(report, ensure_ascii=False))
        return

    # Restore INBOX and remove all the recovery labels.
    iz._batch_modify(cfg, unique_msg_ids, add_ids=["INBOX"], remove_ids=label_ids_to_remove)
    report["executed"] = True
    report["mode"] = "execute"
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
