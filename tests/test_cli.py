"""End-to-end tests of the cdswap binary against a fake Claude data folder.
They never touch the real app: CDSWAP_CLAUDE_DIR / CDSWAP_HOME point at a
temp folder and CDSWAP_NO_APP=1 skips quitting and launching Claude.

Run: swift build && python3 tests/test_cli.py
"""

import json
import os
import time
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CDSWAP = os.environ.get("CDSWAP_BIN", os.path.join(ROOT, ".build", "debug", "cdswap"))
A = "aaaaaaaa-0000-0000-0000-000000000001"
B = "bbbbbbbb-0000-0000-0000-000000000002"
ORG1 = "11111111-0000-0000-0000-000000000001"
ORG2 = "22222222-0000-0000-0000-000000000002"


class Fake:
    def __init__(self, root):
        self.claude = os.path.join(root, "Claude")
        self.home = os.path.join(root, "store")
        os.makedirs(self.claude)
        self.write_config({"darkMode": "dark", "locale": "en-GB"})

    def env(self):
        return dict(os.environ, CDSWAP_CLAUDE_DIR=self.claude, CDSWAP_HOME=self.home,
                    CDSWAP_NO_APP="1")

    def run(self, *args, ok=True):
        r = subprocess.run([CDSWAP] + list(args), env=self.env(),
                           capture_output=True, text=True)
        if ok and r.returncode != 0:
            raise AssertionError("cdswap %s failed:\n%s%s" % (args, r.stdout, r.stderr))
        return r

    def path(self, *parts):
        return os.path.join(self.claude, *parts)

    def config(self):
        with open(self.path("config.json")) as f:
            return json.load(f)

    def write_config(self, data):
        with open(self.path("config.json"), "w") as f:
            json.dump(data, f)

    def sign_in(self, account):
        """Do what the app does on sign-in: cookies, web storage, tokens."""
        for name in ("Cookies",):
            if os.path.exists(self.path(name)):
                os.remove(self.path(name))
        db = sqlite3.connect(self.path("Cookies"))
        db.execute("create table cookies (host text, name text, value text)")
        db.execute("insert into cookies values ('.claude.ai', 'sessionKey', ?)", (account,))
        db.commit()
        db.close()
        os.makedirs(self.path("Local Storage", "leveldb"), exist_ok=True)
        with open(self.path("Local Storage", "leveldb", "000001.log"), "w") as f:
            f.write("user=" + account)
        config = self.config()
        config.update({"oauth:tokenCache": "tok-" + account,
                       "oauth:tokenCacheV2": "v2-" + account,
                       "lastKnownAccountUuid": account})
        self.write_config(config)

    def signed_in_as(self):
        if not os.path.exists(self.path("Cookies")):
            return None
        db = sqlite3.connect(self.path("Cookies"))
        value = db.execute("select value from cookies where name='sessionKey'").fetchone()[0]
        db.close()
        with open(self.path("Local Storage", "leveldb", "000001.log")) as f:
            assert f.read() == "user=" + value
        c = self.config()
        assert c["lastKnownAccountUuid"] == value
        assert c["oauth:tokenCache"] == "tok-" + value
        return value

    def usage_sample(self, org, fh=None, sd=None, minutes_ago=0):
        """Append a sample the way Claude does while it runs."""
        path = self.path("plan-usage-history.json")
        data = {"version": 2, "samples": []}
        if os.path.exists(path):
            with open(path) as fh_:
                data = json.load(fh_)
        u = {}
        if fh is not None:
            u["fh"] = fh
        if sd is not None:
            u["sd"] = sd
        t = int((time.time() - minutes_ago * 60) * 1000) + len(data["samples"])
        data["samples"].append({"t": t, "org": org, "u": u})
        with open(path, "w") as out:
            json.dump(data, out)

    def session(self, account, org, sid, activity, root="claude-code-sessions"):
        folder = self.path(root, account, org)
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "local_%s.json" % sid), "w") as f:
            json.dump({"sessionId": sid, "lastActivityAt": activity, "title": sid}, f)


class SwapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fake(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_full_cycle(self):
        f = self.f
        f.sign_in(A)
        f.session(A, ORG1, "a1", 100)
        f.run("add", "work@example.com")
        self.assertIn("work@example.com", f.run("list", "--names").stdout)

        # Sign out to add a second account; the first stays saved.
        f.run("new")
        self.assertIsNone(f.signed_in_as())
        self.assertNotIn("lastKnownAccountUuid", f.config())
        self.assertEqual(f.config()["darkMode"], "dark")  # other settings untouched

        # The app signs in B and files B's sessions under B's own folder.
        f.sign_in(B)
        f.session(B, ORG2, "b1", 200)
        self.assertEqual(f.run("status", "--name").stdout.strip(), "unsaved:" + B)
        f.run("add", "personal")

        # B refreshes its tokens before switching away; the switch keeps them.
        c = f.config()
        c["oauth:tokenCache"] = "tok-" + B
        c["oauth:tokenCacheV2"] = "v2-fresh"
        f.write_config(c)

        f.run("switch", "work@example.com")
        self.assertEqual(f.signed_in_as(), A)
        self.assertEqual(f.config()["locale"], "en-GB")

        # Sessions are shared: every account/org folder shows a1 and b1.
        for acct in (A, B):
            for org in (ORG1, ORG2):
                folder = f.path("claude-code-sessions", acct, org)
                self.assertEqual(sorted(os.listdir(folder)),
                                 ["local_a1.json", "local_b1.json"], (acct, org))

        # Rotating with no name goes to the next account, fresh tokens intact.
        f.run("switch")
        self.assertEqual(f.signed_in_as(), B)
        self.assertEqual(f.config()["oauth:tokenCacheV2"], "v2-fresh")

        # Undo returns to the sign-in from before the last switch.
        f.run("undo")
        self.assertEqual(f.signed_in_as(), A)

    def test_share_conflicts_keep_newest(self):
        f = self.f
        f.sign_in(A)
        f.session(A, ORG1, "s1", 100)
        f.session(A, ORG1, "only-a", 100)
        f.session(B, ORG1, "s1", 500)      # same session, newer on B
        f.session(B, ORG1, "only-b", 100)
        f.run("share", "--dry-run")
        self.assertFalse(os.path.islink(f.path("claude-code-sessions", B, ORG1)))
        out = f.run("share").stdout
        self.assertIn("· 1 conflicts", out)
        a = f.path("claude-code-sessions", A, ORG1)
        b = f.path("claude-code-sessions", B, ORG1)
        self.assertEqual(os.path.realpath(a), os.path.realpath(b))
        with open(os.path.join(a, "local_s1.json")) as fh:
            self.assertEqual(json.load(fh)["lastActivityAt"], 500)
        self.assertEqual(sorted(os.listdir(a)),
                         ["local_only-a.json", "local_only-b.json", "local_s1.json"])
        # Running it again is a no-op.
        self.assertIn("linked 0 folders", f.run("share").stdout)

    def test_scheduled_tasks_are_merged_not_dropped(self):
        f = self.f
        f.sign_in(A)
        f.session(A, ORG1, "s", 1)
        f.session(B, ORG1, "t", 1)
        def write(account, data):
            with open(f.path("claude-code-sessions", account, ORG1, "scheduled-tasks.json"), "w") as fh:
                json.dump(data, fh)
        write(A, {"scheduledTasks": [{"id": "r1", "enabled": True}, {"id": "r2"}],
                  "recordedSkips": {"r1": [{"at": 1}]}, "flag": True})
        write(B, {"scheduledTasks": [], "recordedSkips": {}, "flag": True})  # newer, empty
        with open(f.path("claude-code-sessions", A, ORG1, "archived-sessions.idx"), "w") as fh:
            json.dump({"v": 1, "archived": ["local_x"]}, fh)
        with open(f.path("claude-code-sessions", B, ORG1, "archived-sessions.idx"), "w") as fh:
            json.dump({"v": 1, "archived": ["local_y"]}, fh)
        self.assertIn("· 2 merged", f.run("share").stdout)
        folder = f.path("claude-code-sessions", B, ORG1)
        with open(os.path.join(folder, "scheduled-tasks.json")) as fh:
            tasks = json.load(fh)
        self.assertEqual([t["id"] for t in tasks["scheduledTasks"]], ["r1", "r2"])
        self.assertEqual(tasks["recordedSkips"], {"r1": [{"at": 1}]})
        with open(os.path.join(folder, "archived-sessions.idx")) as fh:
            self.assertEqual(sorted(json.load(fh)["archived"]), ["local_x", "local_y"])

    def test_link_to_outside_folder_is_never_emptied(self):
        """Regression (2026-11-01): a session folder linked to a folder
        outside Claude's data (here: the real data of a cloned setup) had
        all its files deleted as "duplicates" by sharing."""
        f = self.f
        f.sign_in(A)
        outside = os.path.join(self.tmp.name, "elsewhere", "sessions")
        os.makedirs(outside)
        for sid, t in (("one", 1), ("two", 2)):
            with open(os.path.join(outside, "local_%s.json" % sid), "w") as fh:
                json.dump({"sessionId": sid, "lastActivityAt": t}, fh)
        with open(os.path.join(outside, "local_mine.json"), "w") as fh:
            json.dump({"sessionId": "mine", "lastActivityAt": 9}, fh)
        before = {n: open(os.path.join(outside, n)).read() for n in os.listdir(outside)}
        # Our own store already has an identical "one" and an older "mine".
        f.session(A, ORG1, "one", 1)
        f.session(A, ORG1, "mine", 1)
        with open(f.path("claude-code-sessions", A, ORG1, "local_one.json"), "w") as fh:
            fh.write(before["local_one.json"])
        os.makedirs(f.path("claude-code-sessions", B))
        os.symlink(outside, f.path("claude-code-sessions", B, ORG1))
        f.run("share")
        after = {n: open(os.path.join(outside, n)).read() for n in os.listdir(outside)}
        self.assertEqual(before, after)  # untouched, byte for byte
        store = f.path("claude-code-sessions", A, ORG1)
        self.assertEqual(sorted(os.listdir(store)),
                         ["local_mine.json", "local_one.json", "local_two.json"])
        with open(os.path.join(store, "local_mine.json")) as fh:
            self.assertEqual(json.load(fh)["lastActivityAt"], 9)  # newer copy wins
        self.assertEqual(os.path.realpath(f.path("claude-code-sessions", B, ORG1)),
                         os.path.realpath(store))

    def test_existing_symlink_layout_is_respected(self):
        """The layout already on disk: B's org folders link to A's store."""
        f = self.f
        f.sign_in(A)
        f.session(A, ORG1, "x", 1)
        os.makedirs(f.path("claude-code-sessions", B))
        os.symlink(f.path("claude-code-sessions", A, ORG1),
                   f.path("claude-code-sessions", B, ORG1))
        out = f.run("share").stdout
        self.assertIn("linked 0 folders", out)
        self.assertEqual(os.listdir(f.path("claude-code-sessions", A, ORG1)), ["local_x.json"])
        self.assertTrue(os.path.isdir(f.path("claude-code-sessions", A, ORG1)))
        self.assertFalse(os.path.islink(f.path("claude-code-sessions", A, ORG1)))

    def test_after_switch_hook(self):
        f = self.f
        marker = os.path.join(self.tmp.name, "hook-ran")
        f.sign_in(A)
        f.run("add", "one")
        f.run("new")
        f.sign_in(B)
        f.run("add", "two")
        f.run("hook", 'echo "$CDSWAP_ACCOUNT" >> %s' % marker)
        f.run("switch", "one")
        f.run("hook", "exit 3")
        out = f.run("switch", "two").stdout  # a failing hook doesn't undo the switch
        self.assertIn("exited with 3", out)
        self.assertEqual(f.signed_in_as(), B)
        with open(marker) as fh:
            self.assertEqual(fh.read().split(), [A])
        f.run("hook", "--clear")
        self.assertIn("No after-switch hook", f.run("hook").stdout)

    def two_accounts(self):
        f = self.f
        f.sign_in(A)
        f.usage_sample(ORG1, fh=10, sd=20)
        f.run("add", "work")
        f.run("new")
        f.sign_in(B)
        f.usage_sample(ORG2, fh=5, sd=5)
        f.run("add", "home")
        f.run("switch", "work")
        return f

    def test_usage_is_credited_to_the_signed_in_account(self):
        f = self.two_accounts()
        rows = {r["name"]: r for r in json.loads(f.run("list", "--json").stdout)}
        self.assertEqual((rows["work"]["fiveHour"], rows["work"]["sevenDay"]), (10, 20))
        self.assertEqual((rows["home"]["fiveHour"], rows["home"]["sevenDay"]), (5, 5))
        self.assertTrue(rows["work"]["active"])

    def test_auto_switch_at_threshold(self):
        f = self.two_accounts()
        self.assertIn("Staying: work is at 20%", f.run("auto", "--once").stdout)
        f.usage_sample(ORG1, fh=96, sd=40)
        out = f.run("auto", "--dry-run").stdout
        self.assertIn("work reached 96%; switching to home", out)
        self.assertEqual(f.signed_in_as(), A)  # dry run changes nothing
        f.run("auto", "--once")
        self.assertEqual(f.signed_in_as(), B)
        # Right after a switch, a limited reading never bounces it back.
        f.usage_sample(ORG2, fh=100)
        self.assertIn("less than 10 minutes", f.run("auto", "--once").stdout)
        self.assertEqual(f.signed_in_as(), B)

    def test_auto_threshold_setting(self):
        f = self.two_accounts()
        f.run("config", "threshold", "80")
        f.usage_sample(ORG1, sd=85)
        self.assertIn("switching to home", f.run("auto", "--dry-run").stdout)

    def test_stale_reading_never_triggers(self):
        f = self.f
        f.sign_in(A)
        f.usage_sample(ORG1, sd=99, minutes_ago=45)  # Claude stopped sampling
        f.run("add", "work")
        f.run("new")
        f.sign_in(B)
        f.run("add", "home")
        f.run("switch", "work")
        self.assertIn("no recent usage reading", f.run("auto", "--once").stdout)

    def test_all_accounts_limited(self):
        f = self.two_accounts()
        f.run("switch", "home")
        f.usage_sample(ORG2, fh=100)
        f.run("switch", "work")
        f.usage_sample(ORG1, sd=100)
        out = f.run("auto", "--once").stdout
        self.assertIn("Every saved account is at its limit", out)
        self.assertEqual(f.signed_in_as(), A)

    def test_guards(self):
        f = self.f
        r = f.run("switch", "nobody", ok=False)
        self.assertNotEqual(r.returncode, 0)
        r = f.run("add", "x", ok=False)  # not signed in
        self.assertIn("not signed in", r.stderr)
        f.sign_in(A)
        r = f.run("add", "bad name!", ok=False)
        self.assertNotEqual(r.returncode, 0)
        f.run("add", "one")
        f.run("rename", "one", "two")
        self.assertEqual(f.run("list", "--names").stdout.split(), ["two"])
        self.assertEqual(f.run("status", "--name").stdout.strip(), "two")
        self.assertIn("Already on", f.run("switch", "two").stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
