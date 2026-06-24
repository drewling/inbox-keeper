#!/usr/bin/env python3
"""Roll the user's action signals into a readable learning/learned.md.

Reads learning/signals.jsonl (see lib/learning.py), nets out undone dismissals,
and asks Haiku to distil two short sections:
  - Archive-by-default patterns  (what the user keeps setting aside, so the
    keep-bar can stop surfacing similar mail)
  - Draft voice notes            (how the user edits the system's drafts)

The result is written to learning/learned.md, which the keep-bar and draft
prompts include. It is plain markdown the user can read and edit; this never
rewrites keep-policy.md. With too few signals it writes nothing.

Usage: learn.py [--min 4]
"""
import argparse, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import learning  # noqa: E402

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

PROMPT = (
    "You maintain a short 'learned preferences' note for an email keeper that decides "
    "which threads still need the user. Below are real signals from the user's own actions. "
    "Write concise markdown with exactly these two sections (omit a section if it has no data):\n\n"
    "## Archive by default\n"
    "Generalised patterns of mail the user sets aside without replying (sender types, topics, "
    "notification kinds). Each bullet should help judge NEW mail, not just restate one example.\n\n"
    "## Draft voice\n"
    "How the user edits drafts: tone, length, sign-off, phrasing. Only if draft-edit signals exist.\n\n"
    "Be specific but general enough to apply to unseen mail. Max 10 bullets total. No preamble.\n\n"
    "SIGNALS:\n"
)

HEADER = (
    "# Learned from your actions\n\n"
    "> Auto-generated from what you set aside and how you edit drafts. The keeper reads "
    "this alongside your keep-policy. Edit or delete anything that's wrong; it won't be "
    "silently overwritten without new signals.\n\n"
)


def _active_overrides(signals):
    undone = {s.get("thread_id") for s in signals if s.get("type") == "keep_override_undo"}
    return [s for s in signals
            if s.get("type") == "keep_override" and s.get("thread_id") not in undone]


def build(min_signals):
    signals = learning.recent(800)
    overrides = _active_overrides(signals)
    edits = [s for s in signals if s.get("type") == "draft_edit"]
    if len(overrides) + len(edits) < min_signals:
        return None, len(overrides), len(edits)

    lines = []
    for s in overrides[-60:]:
        lines.append(f"- ARCHIVED w/o reply: from {s.get('sender','?')} "
                     f"<{s.get('sender_email','')}> | subject: {s.get('subject','')}")
    for s in edits[-40:]:
        lines.append(f"- DRAFT EDITED: orig=\"{(s.get('original_snippet') or '')[:160]}\" "
                     f"final=\"{(s.get('final') or '')[:200]}\"")

    try:
        r = subprocess.run([CLAUDE, "-p", PROMPT + "\n".join(lines), "--model", "haiku"],
                           capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        return None, len(overrides), len(edits)
    if r.returncode != 0 or not r.stdout.strip():
        return None, len(overrides), len(edits)
    return HEADER + r.stdout.strip() + "\n", len(overrides), len(edits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=int, default=4,
                    help="minimum signals before writing a rollup")
    a = ap.parse_args()
    text, n_over, n_edit = build(a.min)
    if text is None:
        print(f"learn: not enough signals yet ({n_over} archives, {n_edit} edits); "
              f"need >= {a.min}. learned.md unchanged.")
        return
    os.makedirs(learning.LEARN_DIR, exist_ok=True)
    tmp = learning.LEARNED + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, learning.LEARNED)
    print(f"learn: updated {learning.LEARNED} from {n_over} archives + {n_edit} edits.")


if __name__ == "__main__":
    main()
