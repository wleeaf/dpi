import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class SigningUploadTests(unittest.TestCase):
    def test_secrets_use_stdin_and_never_appear_in_arguments_or_output(self):
        script = Path(__file__).resolve().parents[1] / "scripts/configure-android-ci.py"
        spec = importlib.util.spec_from_file_location("configure_signing", script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            key = root / "key.jks"
            key.write_bytes(b"fixture-keystore")
            config = root / "signing.json"
            config.write_text(json.dumps({"keystore": str(key), "store_password": "private-fixture-password", "key_alias": "dpi"}))
            output = io.StringIO()
            with patch("sys.argv", [str(script), "--repo", "owner/repository", "--config", str(config)]), \
                    patch.object(module.subprocess, "run") as run, contextlib.redirect_stdout(output):
                module.main()
            self.assertEqual(run.call_count, 5)
            uploads = run.call_args_list[1:]
            for call in uploads:
                self.assertEqual(call.args[0][:3], ["gh", "secret", "set"])
                self.assertEqual(call.args[0][-2:], ["--repo", "owner/repository"])
                self.assertIn("input", call.kwargs)
                self.assertNotIn("private-fixture-password", " ".join(call.args[0]))
            self.assertNotIn("private-fixture-password", output.getvalue())
            self.assertEqual(uploads[1].kwargs["input"], "private-fixture-password")
            self.assertEqual(uploads[3].kwargs["input"], "private-fixture-password")


if __name__ == "__main__":
    unittest.main()
