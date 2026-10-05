#!/usr/bin/env python3
"""Upload your persistent Android signing identity to GitHub Actions secrets."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub OWNER/REPO whose Android signing secrets will be set")
    default = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "dpi/android/signing.json"
    parser.add_argument("--config", type=Path, default=Path(os.environ.get("DPI_ANDROID_SIGNING_CONFIG", default)))
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+", args.repo):
        parser.error("Use a GitHub OWNER/REPO")
    if not args.config.exists():
        raise SystemExit("Create a signing key first: python3 scripts/create-android-signing-key.py")
    config = json.loads(args.config.read_text())
    key = Path(config["keystore"])
    password = config["store_password"]
    alias = config["key_alias"]
    if not key.is_file() or not password or not alias:
        raise SystemExit("The private signing config is incomplete")
    values = {
        "DPI_ANDROID_KEYSTORE_BASE64": base64.b64encode(key.read_bytes()).decode("ascii"),
        "DPI_ANDROID_STORE_PASSWORD": password,
        "DPI_ANDROID_KEY_ALIAS": alias,
        "DPI_ANDROID_KEY_PASSWORD": config.get("key_password", password),
    }
    try:
        subprocess.run(["gh", "auth", "status", "--hostname", "github.com"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name, value in values.items():
            # Private values go through stdin, never command arguments or output.
            subprocess.run(["gh", "secret", "set", name, "--repo", args.repo], input=value, text=True, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        raise SystemExit("Install GitHub CLI and run gh auth login first") from None
    except subprocess.CalledProcessError:
        raise SystemExit("Could not configure secrets. Check gh authentication and repository admin access.") from None
    print(f"Configured Android release signing for {args.repo}. Keep the local key backed up.")


if __name__ == "__main__":
    main()
