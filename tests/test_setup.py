"""Exercise release installation without modifying host services or networking."""
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
ENGINE = REPO / "nfq/nfqws"


class SetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ENGINE.is_file():
            raise RuntimeError("Build the engine first: make -C nfq")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dpi test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = self.root / "release"
        self.release.mkdir()
        for name in ["dpi", "dpi.conf.example", "README.md", "LICENSE", "enable.sh", "disable.sh"]:
            shutil.copy2(REPO / name, self.release / name)
        for name in ["scripts", "packaging", "profiles", "files/fake"]:
            shutil.copytree(REPO / name, self.release / name)
        (self.release / "docs").mkdir()
        for name in ["LINUX.md", "MACOS.md", "DEVELOPMENT.md"]:
            shutil.copy2(REPO / "docs" / name, self.release / "docs" / name)
        (self.release / "bin").mkdir()
        shutil.copy2(ENGINE, self.release / "bin/nfqws")
        self.config = self.root / "settings.conf"
        self.config.write_text((REPO / "dpi.conf.example").read_text())
        self.state = self.root / "state"
        self.env = dict(os.environ, DPI_CONFIG=str(self.config), DPI_STATE=str(self.state))

    def run_command(self, *args, ok=True, env=None):
        result = subprocess.run(args, env=env or self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def runtime(self, command, **kwargs):
        return self.run_command(str(self.release / "scripts/runtime.sh"), command, **kwargs)

    def test_every_profile_validates_with_real_engine(self):
        for profile, strategy, voice in itertools.product(["discord", "all"], ["default", "split"], ["yes", "no"]):
            with self.subTest(profile=profile, strategy=strategy, voice=voice):
                self.config.write_text(f"PROFILE={profile}\nSTRATEGY={strategy}\nVOICE={voice}\n")
                self.runtime("check")

    def test_config_rejects_commands_unknown_keys_and_invalid_values(self):
        sentinel = self.root / "executed"
        for setting in [f"PROFILE=$(touch '{sentinel}')", "OTHER=yes", "VOICE=true", "STRATEGY=missing", "PROFILE='discord'", "PROFILE=all;echo bad"]:
            with self.subTest(setting=setting):
                self.config.write_text(setting + "\n")
                self.runtime("check", ok=False)
                self.assertFalse(sentinel.exists())

    def test_config_handles_comments_whitespace_and_no_final_newline(self):
        self.config.write_text(" # comment\r\n PROFILE = all # note\nSTRATEGY=split\nVOICE=no")
        result = self.runtime("args")
        self.assertNotIn("--hostlist=", result.stdout)
        self.assertNotIn("--filter-l7=discord", result.stdout)

    def test_missing_config_fails(self):
        self.config.unlink()
        self.runtime("check", ok=False)

    def test_discord_hosts_are_applied_to_each_web_protocol(self):
        args = self.runtime("args").stdout.splitlines()
        self.assertEqual(sum(arg.startswith("--hostlist=") for arg in args), 3)
        self.assertIn("--filter-l7=discord", args)
        self.assertNotIn("--daemon", args)

    def test_voice_disabled_removes_queue_rule(self):
        self.config.write_text("VOICE=no\n")
        self.assertNotIn("50000-50099", self.runtime("rules").stdout)

    def mock_commands(self):
        """Create isolated service/firewall doubles with observable state."""
        commands = self.root / "commands"
        commands.mkdir()
        mock_state = self.root / "mock.json"
        mock_state.write_text(json.dumps({"calls": [], "table": False, "active": False, "enabled": False}))
        mock = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_file = Path(os.environ["MOCK_STATE"])
state = json.loads(state_file.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
state["calls"].append([name, *args])
code = 0
if name == "id":
    print(0)
elif name == "nft":
    if args[:2] == ["list", "table"]:
        code = 0 if state["table"] else 1
    elif args == ["-f", "-"]:
        state["rules"] = sys.stdin.read()
        state["table"] = True
    elif args[:2] == ["delete", "table"]:
        state["table"] = False
elif name == "systemctl":
    action = args[0]
    service = args[-1]
    if action in ["is-active", "is-enabled"]:
        if service == "zapret.service":
            code = 0 if os.environ.get("MOCK_LEGACY") == "yes" else 1
        elif service == "systemd-resolved":
            code = 0
        else:
            code = 0 if state["active" if action == "is-active" else "enabled"] else 1
    elif action == "enable":
        state["enabled"] = True
    elif action == "disable":
        state["enabled"] = False
        if "--now" in args: state["active"] = False
    elif action == "restart" and service == "dpi.service":
        state["active"] = True
    elif action == "stop":
        state["active"] = False
state_file.write_text(json.dumps(state))
sys.exit(code)
'''
        for name in ["id", "nft", "systemctl"]:
            path = commands / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env.update(PATH=str(commands) + os.pathsep + os.environ["PATH"], MOCK_STATE=str(mock_state))
        return mock_state

    def test_failed_start_does_not_remove_conflicting_firewall_table(self):
        state_file = self.mock_commands()
        state = json.loads(state_file.read_text())
        state["table"] = True
        state_file.write_text(json.dumps(state))
        self.runtime("firewall-start", ok=False)
        self.runtime("firewall-stop")
        self.assertTrue(json.loads(state_file.read_text())["table"])

    def test_owned_firewall_is_removed_even_when_config_becomes_invalid(self):
        state_file = self.mock_commands()
        self.runtime("firewall-start")
        self.assertTrue(json.loads(state_file.read_text())["table"])
        self.config.write_text("INVALID=setting\n")
        self.runtime("firewall-stop")
        self.assertFalse(json.loads(state_file.read_text())["table"])

    def test_validation_failure_does_not_create_firewall(self):
        state_file = self.mock_commands()
        self.config.write_text("PROFILE=invalid\n")
        self.runtime("firewall-start", ok=False)
        self.assertEqual(json.loads(state_file.read_text())["calls"], [])

    def sandbox_cli(self):
        # Relocate fixed production paths in this test copy, leaving the host alone.
        host = self.root / "host"
        for name in ["run/systemd/system", "etc/systemd/system", "usr/local/bin"]:
            (host / name).mkdir(parents=True)
        cli = self.release / "dpi"
        body = cli.read_text()
        for path in ["/opt/dpi", "/etc/dpi", "/etc/systemd/system", "/etc/systemd/resolved.conf.d", "/usr/local/bin", "/run/systemd/system"]:
            body = body.replace(path, str(host) + path)
        cli.write_text(body)
        self.config = host / "etc/dpi/dpi.conf"
        self.env["DPI_CONFIG"] = str(self.config)
        self.env.pop("DESTDIR", None)
        return host

    def test_install_update_disable_dns_and_uninstall(self):
        state_file = self.mock_commands()
        host = self.sandbox_cli()
        cli = str(self.release / "dpi")
        self.run_command(cli, "install")
        self.assertTrue((host / "opt/dpi/bin/nfqws").exists())
        self.assertTrue((host / "usr/local/bin/dpi").is_symlink())
        state = json.loads(state_file.read_text())
        self.assertTrue(state["active"])
        self.assertTrue(state["enabled"])
        self.config.write_text("PROFILE=all\nSTRATEGY=split\nVOICE=no\n")
        self.run_command(cli, "install")
        self.assertIn("PROFILE=all", self.config.read_text())
        self.run_command(cli, "disable")
        state = json.loads(state_file.read_text())
        self.assertFalse(state["active"])
        self.assertFalse(state["enabled"])
        self.run_command(cli, "dns", "on")
        dns = host / "etc/systemd/resolved.conf.d/90-dpi.conf"
        self.assertIn("DNSOverTLS=yes", dns.read_text())
        self.run_command(cli, "dns", "off")
        self.assertFalse(dns.exists())
        self.run_command(cli, "uninstall")
        self.assertFalse((host / "opt/dpi").exists())
        self.assertTrue(self.config.exists())

    def test_bad_upgrade_config_preserves_active_install(self):
        state_file = self.mock_commands()
        host = self.sandbox_cli()
        cli = str(self.release / "dpi")
        self.run_command(cli, "install")
        binary = (host / "opt/dpi/bin/nfqws").read_bytes()
        self.config.write_text("STRATEGY=invalid\n")
        self.run_command(cli, "install", ok=False)
        self.assertEqual((host / "opt/dpi/bin/nfqws").read_bytes(), binary)
        self.assertTrue(json.loads(state_file.read_text())["active"])

    def test_legacy_service_blocks_install_without_writing_files(self):
        self.mock_commands()
        host = self.sandbox_cli()
        self.env["MOCK_LEGACY"] = "yes"
        result = self.run_command(str(self.release / "dpi"), "install", ok=False)
        self.assertIn("Existing zapret service detected", result.stderr)
        self.assertFalse((host / "opt/dpi").exists())

    def test_edited_dns_override_is_preserved(self):
        self.mock_commands()
        host = self.sandbox_cli()
        cli = str(self.release / "dpi")
        self.run_command(cli, "install", "--no-start")
        dns = host / "etc/systemd/resolved.conf.d/90-dpi.conf"
        dns.parent.mkdir(parents=True)
        dns.write_text("[Resolve]\nDNS=192.0.2.1\n")
        for args in [("dns", "on"), ("dns", "off"), ("uninstall",)]:
            self.run_command(cli, *args, ok=False)
        self.assertEqual(dns.read_text(), "[Resolve]\nDNS=192.0.2.1\n")

    def test_staged_install_preserves_settings_and_never_calls_services(self):
        state_file = self.mock_commands()
        stage = self.root / "stage"
        self.env["DESTDIR"] = str(stage)
        cli = str(self.release / "dpi")
        self.run_command(cli, "install")
        config = stage / "etc/dpi/dpi.conf"
        config.write_text("PROFILE=all\n")
        self.run_command(cli, "install")
        self.assertEqual(config.read_text(), "PROFILE=all\n")
        self.assertEqual(json.loads(state_file.read_text())["calls"], [])

    def test_invalid_staging_paths_are_rejected_before_install(self):
        self.mock_commands()
        for directory in ["relative", "/", "//", "/tmp/.."]:
            with self.subTest(directory=directory):
                self.env["DESTDIR"] = directory
                result = self.run_command(str(self.release / "dpi"), "install", ok=False)
                self.assertIn("DESTDIR", result.stderr)

    def test_package_can_be_installed_without_source_tree(self):
        self.env["DPI_DIST"] = str(self.root / "package artifacts")
        self.run_command("bash", str(REPO / "scripts/package.sh"), "test")
        arch = "arm64" if os.uname().machine in ["aarch64", "arm64"] else "x86_64"
        archive = Path(self.env["DPI_DIST"]) / f"dpi-test-linux-{arch}.tar.gz"
        with tarfile.open(archive) as tar:
            members = tar.getnames()
            self.assertFalse(any("binaries/my" in name or "/.git" in name for name in members))
            tar.extractall(self.root / "extracted", filter="data") if hasattr(tarfile, "data_filter") else tar.extractall(self.root / "extracted")
        package = self.root / "extracted" / archive.name.removesuffix(".tar.gz")
        self.env["DESTDIR"] = str(self.root / "package install")
        self.run_command(str(package / "dpi"), "install")
        installed = Path(self.env["DESTDIR"]) / "opt/dpi"
        self.env["DPI_CONFIG"] = str(Path(self.env["DESTDIR"]) / "etc/dpi/dpi.conf")
        self.run_command(str(installed / "scripts/runtime.sh"), "check")


if __name__ == "__main__":
    unittest.main()
