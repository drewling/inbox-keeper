#!/usr/bin/env python3
"""Final aggressive pass: keep ONLY genuine open loops that need the account owner's attention.

Thread-level. The core signal for "already dealt with" is who sent the LAST message:
- last message is from the owner -> they already responded; ball is in their court -> ARCHIVE.
- Owner never engaged + sender is cold/no-history -> not a real loop -> ARCHIVE.
- last message is from a real person the owner has corresponded with, with an open ask -> Haiku decides.

Always KEPT regardless: live payment problems, legal/disputes, explicit deadlines.
Reversible (dated recovery label). Dry-run by default.

Usage: review_open_loops.py <config_dir> <account_label> [--execute] [--chunk 50]
"""
import argparse, json, os, subprocess, sys
from email.utils import parseaddr

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import inbox_zero as iz       # noqa: E402
import thin_protected as tp   # noqa: E402
import draftutil as du        # noqa: E402
import learning               # noqa: E402

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

_CATEGORIES_PATH = os.path.join(ROOT, "categories.json")
_LABEL_HISTORY_PATH = os.path.join(ROOT, "app", "category_label_history.json")


def _load_label_history():
    """Return the persisted set of category label names (past + present)."""
    try:
        if os.path.exists(_LABEL_HISTORY_PATH):
            with open(_LABEL_HISTORY_PATH) as f:
                data = json.load(f)
            return set(data.get("labels", []))
    except Exception:
        pass
    return set()


def _add_to_label_history(names):
    """Union names into the persisted label history file. Non-fatal."""
    try:
        existing = _load_label_history()
        merged = existing | set(names)
        tmp = _LABEL_HISTORY_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"labels": sorted(merged)}, f, ensure_ascii=False, indent=2)
        os.replace(tmp, _LABEL_HISTORY_PATH)
    except Exception:
        pass

_DEFAULT_CATEGORIES = [
    {"name": "Needs reply",      "description": "Someone is waiting on a direct response from me.", "emoji": "✉️"},
    {"name": "Waiting on others","description": "I'm blocked on someone else; tracking, no action yet.", "emoji": "⏳"},
    {"name": "To schedule",      "description": "Needs a meeting, call, or calendar action.",       "emoji": "📅"},
    {"name": "Read later",       "description": "Worth reading but not urgent or action-bearing.",  "emoji": "🔖"},
    {"name": "Action required",  "description": "A task or deadline I personally need to handle.",  "emoji": "⚡"},
]


def _categories():
    """Return the categories list from categories.json, or built-in defaults."""
    try:
        if os.path.exists(_CATEGORIES_PATH):
            with open(_CATEGORIES_PATH) as f:
                data = json.load(f)
            cats = data.get("categories", [])
            if cats:
                return cats
    except Exception:
        pass
    return _DEFAULT_CATEGORIES


def _category_label_name(cat):
    """Compose the Gmail label name for a category: '<emoji> <name>'."""
    return f"{cat['emoji']} {cat['name']}"

# Candidate set: inbox minus starred/Action and (optionally) recent mail. Unlike the
# blunt inbox_zero sweep, we do NOT pattern-exclude high-stakes mail here — the LLM
# reviewer reads each thread and keeps genuine sign/pay/legal/deadline items itself,
# so excluding them would only leave settled (already-signed/paid) mail stuck in inbox.
def _candidate_q(grace_days):
    keep = '-is:starred -label:"⚡ Action"'
    if grace_days and grace_days > 0:
        keep += f" -newer_than:{grace_days}d"
    return f"in:inbox {keep}"

# Fallback if the user hasn't written a keep-policy.md (owner-neutral).
DEFAULT_POLICY = (
    "Keep a thread only if it genuinely needs the user to act now: a real person awaiting their reply "
    "or decision; an unanswered direct question or request to them; a live payment PROBLEM; a legal or "
    "dispute matter; or an explicit deadline with a consequence.\n"
    "Archive everything else (reversibly): cold outreach, sales, pitches and prospecting even from "
    "named senders the user has never replied to; receipts, invoices, statements, confirmations, "
    "notifications, alerts, digests, newsletters, marketing, social, surveys, calendar RSVPs, meeting "
    "summaries, past security alerts; and any thread whose last message was from the user (already "
    "handled). When unsure, keep personal, family, legal, and payment-problem mail."
)

KEEP_POLICY_PATH = os.path.join(os.path.dirname(HERE), "keep-policy.md")


def _policy_text():
    """The user's keep-policy.md (authoritative), or the owner-neutral default."""
    try:
        if os.path.exists(KEEP_POLICY_PATH):
            t = open(KEEP_POLICY_PATH).read().strip()
            if t:
                return t
    except Exception:
        pass
    return DEFAULT_POLICY


# {policy} is filled from keep-policy.md at call time.
# {categories_section} is filled from categories.json at call time.
PROMPT_HEAD = (
    "You are tidying the user's inbox. For EACH numbered thread decide \"keep\" or \"archive\". "
    "Keep only what genuinely needs the user to act now; bias hard toward archive (everything archived "
    "is reversible, so when in doubt about noise, archive it). Each line gives: last_sender, "
    "last_from_owner (did the USER send the most recent message), replied_before (has the user ever "
    "written to this sender), subject, snippet.\n\n"
    "THE USER'S KEEP POLICY (authoritative -- follow it exactly):\n{policy}\n\n"
    "Hard rules regardless of the above: if last_from_owner=YES the user already replied, so archive "
    "(nothing left to do). Personal, family, legal, and live-payment-problem mail are kept even if "
    "unsure.\n\n"
    "{categories_section}"
    'Output ONLY a JSON object mapping each number to an object {{"decision":"keep"|"archive","category":<name>|null}}. '
    "category must be one of the category names above (for kept threads) or null. No prose.\n\nTHREADS:\n"
)

_REPLIED = {}


def _replied_before(cfg, email):
    email = (email or "").lower()
    if not email:
        return False
    if email in _REPLIED:
        return _REPLIED[email]
    try:
        d = iz.gws(cfg, ["gmail", "users", "messages", "list", "--params",
                         json.dumps({"userId": "me", "q": f"from:me to:{email}", "maxResults": 1})])
        v = bool(d.get("messages"))
    except Exception:
        v = True
    _REPLIED[email] = v
    return v


def _thread_ids(cfg, grace_days):
    ids, tok = [], None
    cq = _candidate_q(grace_days)
    while True:
        p = {"userId": "me", "q": cq, "maxResults": 500}
        if tok:
            p["pageToken"] = tok
        d = iz.gws(cfg, ["gmail", "users", "threads", "list", "--params", json.dumps(p)])
        ids += [t["id"] for t in d.get("threads", []) or []]
        tok = d.get("nextPageToken")
        if not tok:
            break
    return ids


def _thread_info(cfg, tid, me):
    t = iz.gws(cfg, ["gmail", "users", "threads", "get", "--params",
                     json.dumps({"userId": "me", "id": tid, "format": "metadata",
                                 "metadataHeaders": ["From", "Subject"]})])
    msgs = t.get("messages", []) or []
    if not msgs:
        return None
    last = msgs[-1]
    h = {x["name"].lower(): x["value"] for x in last.get("payload", {}).get("headers", [])}
    last_from = h.get("from", "")
    subject = h.get("subject", "(no subject)")
    snippet = (last.get("snippet", "") or "")[:160]
    last_email = (parseaddr(last_from)[1] or "").lower()
    last_from_owner = bool(me and me.lower() in last_from.lower())
    return {"id": tid, "ids": [m["id"] for m in msgs], "last_from": last_from,
            "last_email": last_email, "last_from_owner": last_from_owner,
            "subject": subject, "snippet": snippet}


def _learned_preface():
    """Preferences distilled from the user's past actions (lib/learn.py)."""
    try:
        txt = learning.learned_text().strip()
    except Exception:
        txt = ""
    if not txt:
        return ""
    return ("PREFERENCES LEARNED FROM THE USER'S PAST ACTIONS (apply these when deciding; "
            "they refine but never override keeping genuine personal/legal/payment loops):\n"
            + txt + "\n\n")


def _classify(chunk):
    cats = _categories()
    cat_names = {c["name"] for c in cats}
    cat_lines = "\n".join(f'  - {c["name"]}: {c["description"]}' for c in cats)
    categories_section = (
        "CATEGORIES — for each KEPT thread, also pick the best-fit category name from this list:\n"
        + cat_lines + "\n\n"
    )

    lines = []
    for i, c in enumerate(chunk):
        lines.append(
            f'{i}. last_sender: {c["last_from"]} | last_from_owner: {"YES" if c["last_from_owner"] else "NO"}'
            f' | replied_before: {"YES" if c["replied_before"] else "NO"} | subject: {c["subject"]}'
            f' | snippet: {c["snippet"]}')
    prompt = (_learned_preface()
              + PROMPT_HEAD.format(policy=_policy_text(), categories_section=categories_section)
              + "\n".join(lines))
    try:
        r = subprocess.run([CLAUDE, "-p", prompt, "--model", "haiku"],
                           capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        return {}
    if r.returncode != 0:
        return {}
    txt = r.stdout
    s, e = txt.find("{"), txt.rfind("}")
    if s < 0 or e < 0:
        return {}
    try:
        raw = json.loads(txt[s:e + 1])
    except Exception:
        return {}

    # Normalize: accept both old bare-string form {"0":"keep"} and new object form
    # {"0":{"decision":"keep","category":"Needs reply"}}.
    normalized = {}
    for k, v in raw.items():
        if isinstance(v, str):
            # Old format: bare "keep"/"archive" string.
            normalized[k] = {"decision": v, "category": None}
        elif isinstance(v, dict):
            decision = v.get("decision", "keep")
            cat = v.get("category")
            if cat not in cat_names:
                cat = None
            normalized[k] = {"decision": decision, "category": cat}
        else:
            normalized[k] = {"decision": "keep", "category": None}
    return normalized


def apply_category(cfg, thread_id, category_name):
    """Apply a category label to a kept thread: add '<emoji> <name>', remove any other
    category labels from our set (current OR historical). Never touches non-category
    labels. Non-fatal on error.

    Args:
        cfg:           gws config_dir for the account.
        thread_id:     Gmail thread id.
        category_name: The category name string (must be in _categories()), or None to
                       only remove stale category labels without adding a new one.
    """
    cats = _categories()
    cat_label_names = {_category_label_name(c) for c in cats}
    # Union current names into persistent history so renamed labels are tracked.
    _add_to_label_history(cat_label_names)
    # The full set of labels we'll clean up = current ∪ historical.
    all_known_cat_labels = cat_label_names | _load_label_history()

    target_label = None
    if category_name:
        cat = next((c for c in cats if c["name"] == category_name), None)
        if cat:
            target_label = _category_label_name(cat)

    try:
        # Fetch current labels on this thread to find stale category labels to remove.
        t = iz.gws(cfg, ["gmail", "users", "threads", "get",
                         "--params", json.dumps({"userId": "me", "id": thread_id,
                                                 "format": "metadata",
                                                 "metadataHeaders": []})])
        thread_label_ids = set()
        for m in (t.get("messages") or []):
            thread_label_ids.update(m.get("labelIds") or [])

        # Resolve label ids -> names for our category labels only.
        label_data = iz.gws(cfg, ["gmail", "users", "labels", "list",
                                  "--params", json.dumps({"userId": "me"})])
        all_labels = label_data.get("labels", []) or []
        id_to_name = {l["id"]: l["name"] for l in all_labels}
        name_to_id = {l["name"]: l["id"] for l in all_labels}

        # Labels to remove: any current/historical category label on the thread
        # (excluding the new target, if any).
        remove_ids = [
            lid for lid in thread_label_ids
            if id_to_name.get(lid, "") in all_known_cat_labels
            and id_to_name.get(lid, "") != target_label
        ]

        if not target_label and not remove_ids:
            return  # nothing to do

        add_ids = []
        if target_label:
            # Ensure the target label exists in Gmail (create if missing).
            if target_label not in name_to_id:
                created = iz.gws(cfg, ["gmail", "users", "labels", "create",
                                       "--params", json.dumps({"userId": "me"}),
                                       "--json", json.dumps({"name": target_label,
                                                             "labelListVisibility": "labelShow",
                                                             "messageListVisibility": "show"})])
                add_ids = [created["id"]]
            else:
                add_ids = [name_to_id[target_label]]

        if add_ids or remove_ids:
            iz.gws(cfg, ["gmail", "users", "threads", "modify",
                         "--params", json.dumps({"userId": "me", "id": thread_id}),
                         "--json", json.dumps({"addLabelIds": add_ids,
                                               "removeLabelIds": remove_ids})],
                   allow_empty=True)
    except Exception:
        pass  # category labeling is additive; never block the keeper run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config_dir")
    ap.add_argument("account_label")
    ap.add_argument("--execute", action="store_true")
    ap.add_argument("--chunk", type=int, default=50)
    ap.add_argument("--grace-days", type=int, default=2,
                    help="protect mail newer than N days from review (0 = review everything)")
    a = ap.parse_args()

    try:
        me = du._profile_email(a.config_dir)
    except Exception:
        me = a.account_label

    tids = _thread_ids(a.config_dir, a.grace_days)
    infos = []
    for tid in tids:
        info = _thread_info(a.config_dir, tid, me)
        if info:
            info["replied_before"] = _replied_before(a.config_dir, info["last_email"])
            infos.append(info)

    archive_msg_ids, kept, keep_s = [], 0, []
    # Deterministic fast-path: last message from the owner -> dealt with -> archive.
    to_judge = []
    for c in infos:
        if c["last_from_owner"]:
            archive_msg_ids += c["ids"]
        else:
            to_judge.append(c)

    for i in range(0, len(to_judge), a.chunk):
        chunk = to_judge[i:i + a.chunk]
        verdict = _classify(chunk)
        for j, c in enumerate(chunk):
            # _classify always returns normalized dicts; fall back to keep on missing key.
            v = verdict.get(str(j), {"decision": "keep", "category": None})
            decision = v.get("decision", "keep") if isinstance(v, dict) else v
            category = v.get("category") if isinstance(v, dict) else None
            if decision == "archive":
                archive_msg_ids += c["ids"]
            else:
                kept += 1
                if len(keep_s) < 25:
                    keep_s.append({"from": c["last_from"], "subject": c["subject"],
                                   "category": category})
                # Apply category label when executing; non-fatal if it fails.
                if a.execute and category:
                    apply_category(a.config_dir, c["id"], category)

    result = {"account": a.account_label, "threads": len(infos),
              "dealt_with_last_from_owner": sum(1 for c in infos if c["last_from_owner"]),
              "to_archive_threads": len(infos) - kept, "to_keep_threads": kept,
              "mode": "execute" if a.execute else "dry-run", "keep_sample": keep_s}

    if a.execute and archive_msg_ids:
        lab = iz._dated_label(iz._BASE_LABEL)
        lid = iz._ensure_label(a.config_dir, lab)
        result["archived_messages"] = iz._batch_modify(a.config_dir, archive_msg_ids,
                                                        add_ids=[lid], remove_ids=["INBOX"])
        result["recovery_label"] = lab

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
