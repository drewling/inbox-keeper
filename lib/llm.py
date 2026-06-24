#!/usr/bin/env python3
"""LLM provider abstraction for zero.

Single real backend today: the claude CLI. A second provider (Codex, Hermes,
etc.) would add an entry to KNOWN_PROVIDERS and its run_prompt translation.

# ponytail: single real backend (claude CLI); multi-provider routing lands when a 2nd real CLI exists
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SETTINGS_PATH = os.path.join(ROOT, "app", "settings.json")

# Each entry: name (settings key), label (display), bin (default binary name),
# and the model-alias map used when translating generic aliases to provider-specific names.
KNOWN_PROVIDERS = [
    {
        "name": "claude",
        "label": "Claude (Anthropic)",
        "bin": "claude",
        "bin_env": "CLAUDE_BIN",   # env var that overrides the binary path
        "wired": True,             # the only provider zero can actually drive today
        "model_map": {             # generic alias -> provider flag value
            "haiku": "haiku",
            "sonnet": "sonnet",
            "opus": "opus",
        },
    },
    {
        "name": "codex",
        "label": "Codex (OpenAI)",
        "bin": "codex",
        "bin_env": "CODEX_BIN",
        "wired": False,            # listed for the roadmap; invocation not implemented yet
        "model_map": {
            "haiku": "gpt-4o-mini",
            "sonnet": "gpt-4o",
            "opus": "o1",
        },
    },
    {
        "name": "hermes",
        "label": "Hermes (local)",
        "bin": "hermes",
        "bin_env": "HERMES_BIN",
        "wired": False,            # listed for the roadmap; invocation not implemented yet
        "model_map": {
            "haiku": "hermes-3-llama-3.1-8b",
            "sonnet": "hermes-3-llama-3.1-70b",
            "opus": "hermes-3-llama-3.1-70b",
        },
    },
]

# Index by name for O(1) lookup.
_BY_NAME = {p["name"]: p for p in KNOWN_PROVIDERS}


def _active_provider_name():
    """Read the active provider from settings (default 'claude'). Never throws."""
    try:
        if os.path.isfile(SETTINGS_PATH):
            with open(SETTINGS_PATH) as f:
                return json.load(f).get("provider", "claude")
    except Exception:
        pass
    return "claude"


def _bin_for(provider):
    """Resolve the binary path for a provider entry, honoring env override."""
    return os.environ.get(provider["bin_env"], provider["bin"])


def _version(binary):
    """Run `<binary> --version`, return stripped stdout, or None on failure."""
    try:
        r = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=5)
        out = (r.stdout or r.stderr or "").strip().splitlines()
        return out[0].strip() if out else None
    except Exception:
        return None


def detect_providers():
    """Return a list of provider status dicts.

    Shape: [{name, label, available: bool, version: str|None, active: bool}]
    """
    active = _active_provider_name()
    result = []
    for p in KNOWN_PROVIDERS:
        binary = _bin_for(p)
        # Only providers zero can actually drive count as available — otherwise a
        # stray same-named binary on PATH would let a user select a backend that
        # silently fails every call. Codex/Hermes show as "not detected" until wired.
        available = bool(p.get("wired")) and shutil.which(binary) is not None
        result.append({
            "name": p["name"],
            "label": p["label"],
            "available": available,
            "version": _version(binary) if available else None,
            "active": p["name"] == active,
        })
    return result


def run_prompt(prompt, model="haiku", timeout=120):
    """Run a prompt through the active provider's CLI.

    Returns (stdout_text: str, ok: bool).
    Reads the active provider at call time (not import time).
    """
    active_name = _active_provider_name()
    provider = _BY_NAME.get(active_name) or _BY_NAME["claude"]
    # Defense in depth: if settings somehow names a provider we can't actually
    # drive, fall back to claude rather than invoking a CLI with the wrong syntax
    # and silently breaking every triage/draft call.
    if not provider.get("wired"):
        provider = _BY_NAME["claude"]
    binary = _bin_for(provider)
    model_arg = provider["model_map"].get(model, model)
    cmd = [binary, "-p", prompt, "--model", model_arg]

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ("", False)
    except Exception:
        return ("", False)
    if r.returncode != 0:
        return ("", False)
    return (r.stdout, True)
