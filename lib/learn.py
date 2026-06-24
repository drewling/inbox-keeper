#!/usr/bin/env python3
"""Roll the user's action signals into a readable learning/learned.md.

Reads learning/signals.jsonl (see lib/learning.py), nets out undone dismissals,
and asks Haiku to distil one short section:
  - Draft voice notes  (how the user edits the system's drafts)

A second short "Keep more like this" section is written from restore signals
(keeper-archived threads the user explicitly undid) — these are genuine
corrections, not routine triage.

Archive-by-default patterns are intentionally excluded: the user sets mail
aside because there's nothing to action, not to teach a rule. Generating
"archive LinkedIn by default" from routine triage filled learned.md with noise.

The result is written to learning/learned.md. It is plain markdown the user
can read and edit. With too few signals it writes nothing.

Usage: learn.py [--min 2]
"""
import argparse, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import learning  # noqa: E402

import llm as _llm  # noqa: E402

# Only voice edits feed the LLM rollup now.
VOICE_PROMPT = (
    "You maintain a short 'learned preferences' note for an email keeper. "
    "Below are real signals from edits the user made to AI-drafted replies. "
    "Write concise markdown with exactly this section (omit if no data):\n\n"
    "## Draft voice\n"
    "How the user edits drafts: tone, length, sign-off, phrasing preferences. "
    "Each bullet should apply to future drafts, not just restate one example.\n\n"
    "Max 8 bullets. No preamble.\n\n"
    "SIGNALS:\n"
)

HEADER = (
    "# Learned from your actions\n\n"
    "> Auto-generated from draft edits you made and threads you restored. "
    "The keeper reads this alongside your keep-policy. "
    "Edit or delete anything that's wrong.\n\n"
)


def _normalize(text):
    """Strip markdown bullet markers, lowercase, collapse whitespace — used for
    reject matching so a regenerated-but-equivalent bullet still hits."""
    t = re.sub(r"^[\s\-\*•]+", "", text.strip())
    return re.sub(r"\s+", " ", t).lower().strip()


def _rejected_norms():
    """Set of normalised texts from learning/rejected.jsonl."""
    path = os.path.join(learning.LEARN_DIR, "rejected.jsonl")
    if not os.path.exists(path):
        return set()
    out = set()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = __import__("json").loads(line)
                out.add(rec.get("norm", ""))
            except Exception:
                pass
    out.discard("")
    return out


def _filter_rejected(text, rejected_norms):
    """Remove any bullet from text whose normalised form is in rejected_norms."""
    if not rejected_norms:
        return text
    lines = text.splitlines()
    kept = []
    for line in lines:
        norm = _normalize(line)
        if norm and norm in rejected_norms:
            continue  # drop this bullet
        kept.append(line)
    return "\n".join(kept)


def _active_restores(signals):
    """Signals where the user explicitly un-archived a keeper-archived thread."""
    return [s for s in signals if s.get("type") == "keep_override_undo"]


def _build_restore_section(restores):
    """Short 'Keep more like this' section derived from explicit restores."""
    if not restores:
        return ""
    bullets = []
    for s in restores[-20:]:
        sender = s.get("sender", "")
        email = s.get("sender_email", "")
        subj = s.get("subject", "")
        parts = []
        if sender or email:
            parts.append(f"from {sender or email}")
        if subj:
            parts.append(f"subject: {subj}")
        if parts:
            bullets.append("- Keep: " + " | ".join(parts))
    if not bullets:
        return ""
    return "## Keep more like this\n" + "\n".join(bullets) + "\n\n"


def build(min_signals):
    import json as _json
    signals = learning.recent(800)
    edits = [s for s in signals if s.get("type") == "draft_edit"]
    restores = _active_restores(signals)
    # Need at least one of the high-signal types to write anything.
    if len(edits) + len(restores) < min_signals:
        return None, len(restores), len(edits)

    rejected = _rejected_norms()
    sections = []

    # Restore section: written from raw signals, no LLM needed.
    restore_section = _build_restore_section(restores)
    if restore_section:
        filtered = _filter_rejected(restore_section, rejected)
        if filtered.strip():
            sections.append(filtered.strip())

    # Voice section: LLM rollup from draft_edit signals only.
    if edits:
        lines = []
        for s in edits[-40:]:
            lines.append(
                f"- DRAFT EDITED: orig=\"{(s.get('original_snippet') or '')[:160]}\" "
                f"final=\"{(s.get('final') or '')[:200]}\""
            )
        voice_raw, voice_ok = _llm.run_prompt(VOICE_PROMPT + "\n".join(lines),
                                               model="haiku", timeout=150)
        if voice_ok and voice_raw.strip():
            voice_text = _filter_rejected(voice_raw.strip(), rejected)
            if voice_text.strip():
                sections.append(voice_text.strip())

    if not sections:
        return None, len(restores), len(edits)

    return HEADER + "\n\n".join(sections) + "\n", len(restores), len(edits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=int, default=2,
                    help="minimum high-signal events before writing a rollup")
    a = ap.parse_args()
    text, n_restore, n_edit = build(a.min)
    if text is None:
        print(f"learn: not enough signals yet ({n_restore} restores, {n_edit} edits); "
              f"need >= {a.min}. learned.md unchanged.")
        return
    os.makedirs(learning.LEARN_DIR, exist_ok=True)
    tmp = learning.LEARNED + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, learning.LEARNED)
    print(f"learn: updated {learning.LEARNED} from {n_restore} restores + {n_edit} edits.")


if __name__ == "__main__":
    main()
