"""Mac configuration and PF ownership checks without changing host networking."""
import itertools
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MacTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dpi mac test ")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.config = self.work / "dpi.conf"
        self.config.write_text("PROFILE=discord\nSTRATEGY=default\nVOICE=no\n")
        self.env = dict(os.environ, DPI_CONFIG=str(self.config))

    def runtime(self, command, script=None):
        return subprocess.run(["bash", str(script or ROOT / "macos/runtime.sh"), command],
                              env=self.env, text=True, capture_output=True)

    def test_presets_limit_hosts_and_do_not_claim_udp_bypass(self):
        for profile, strategy in itertools.product(("discord", "all"), ("default", "split")):
            self.config.write_text(f"PROFILE={profile}\nSTRATEGY={strategy}\nVOICE=yes\n")
            result = self.runtime("args")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("--hostlist="), 2 if profile == "discord" else 0)
            self.assertEqual("--tlsrec=sni" in result.stdout, strategy == "default")
            self.assertNotIn("--filter-udp", result.stdout)
            self.assertNotIn("--socks", result.stdout)
            self.assertEqual(self.runtime("settings").stdout, f"{profile}:{strategy}\n")

    def test_injected_and_invalid_settings_are_rejected(self):
        for setting in ("PROFILE=$(touch BAD)", "PROFILE=unknown", "OTHER=yes", "VOICE=true", "profile=all"):
            self.config.write_text(setting)
            self.assertNotEqual(self.runtime("args").returncode, 0)

    def test_rules_support_both_families_and_exempt_root(self):
        result = self.runtime("rules")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inet6", result.stdout)
        self.assertIn("user { >root }", result.stdout)
        self.assertNotIn("udp", result.stdout)

    def test_cleanup_only_flushes_owned_child_anchor_and_releases_own_token(self):
        script = self.work / "runtime.sh"
        state = self.work / "state"
        state.mkdir()
        source = (ROOT / "macos/runtime.sh").read_text().replace("STATE=/var/run/dpi-macos", f'STATE="{state}"')
        # Fixture bypasses only the privilege check; all PF calls are mocked.
        source = source.replace("[[ $EUID == 0 ]]", "[[ 1 == 1 ]]")
        script.write_text(source)
        calls = self.work / "calls"
        pf = self.work / "pfctl"
        pf.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$MOCK_CALLS"\n')
        pf.chmod(0o755)
        self.env.update(PATH=str(self.work) + os.pathsep + self.env["PATH"], MOCK_CALLS=str(calls))
        self.assertEqual(self.runtime("cleanup", script).returncode, 0)
        self.assertFalse(calls.exists())
        (state / "owned").touch()
        (state / "token").write_text("123456\n")
        result = self.runtime("cleanup", script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.read_text().splitlines(), ["-a com.apple/dpi -F rules", "-a com.apple/dpi -F nat", "-X 123456"])
        self.assertFalse((state / "owned").exists())
        self.assertFalse((state / "token").exists())
