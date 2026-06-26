#!/usr/bin/env python3
"""Runnable check for keeper_server._seed_bundled_client — first-run seeding of the
bundled OAuth client into ~/.config/gws, without ever clobbering a user's own client.
Run: python3 lib/tests/test_seed_client.py"""
import os, sys, json, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import keeper_server as ks   # noqa: E402

orig_home, orig_root = os.environ.get("HOME"), ks.ROOT
try:
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as home:
        ks.ROOT = root
        os.environ["HOME"] = home
        gws = os.path.join(home, ".config", "gws", "client_secret.json")

        # 1. No bundled client present → no-op (never creates an empty dst).
        ks._seed_bundled_client()
        assert not os.path.exists(gws), "must not create dst when no bundled client"

        # 2. Bundled client present, user has none → seeds it (mode 600).
        with open(os.path.join(root, "client_secret.json"), "w") as f:
            f.write('{"installed":{"client_id":"BUNDLED"}}')
        ks._seed_bundled_client()
        assert os.path.isfile(gws), "must seed when bundled present and user has none"
        assert oct(os.stat(gws).st_mode)[-3:] == "600", "seeded client must be 0600"
        assert json.load(open(gws))["installed"]["client_id"] == "BUNDLED"

        # 3. User already has a client → never clobber it.
        with open(gws, "w") as f:
            f.write('{"installed":{"client_id":"USER_OWN"}}')
        ks._seed_bundled_client()
        assert json.load(open(gws))["installed"]["client_id"] == "USER_OWN", \
            "must never overwrite the user's existing client"
    print("seed_client OK")
finally:
    ks.ROOT = orig_root
    if orig_home is not None:
        os.environ["HOME"] = orig_home
