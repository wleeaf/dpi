#!/usr/bin/env python3
"""Create a persistent local release identity without printing private material."""
import json
import os
from pathlib import Path
import secrets
import subprocess


def main():
    directory = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "dpi/android"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    config = directory / "signing.json"
    if config.exists():
        print(f"Existing signing identity: {config}")
        return
    key = directory / "release.jks"
    if key.exists():
        raise SystemExit(f"Existing key without configuration at {key}; preserve it and configure signing manually.")
    password = secrets.token_urlsafe(32)
    environment = dict(os.environ, DPI_SIGNING_PASSWORD=password)
    subprocess.run([
        "keytool", "-genkeypair", "-alias", "dpi", "-keyalg", "RSA", "-keysize", "3072",
        "-storetype", "PKCS12", "-keystore", str(key), "-storepass:env", "DPI_SIGNING_PASSWORD",
        "-keypass:env", "DPI_SIGNING_PASSWORD", "-dname", "CN=DPI release", "-validity", "10000", "-noprompt",
    ], env=environment, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        json.dump({"keystore": str(key), "store_password": password, "key_alias": "dpi"}, output)
    print(f"Created persistent signing identity: {config}")
    print("Back up this private directory; Android updates must use the same signing key.")


if __name__ == "__main__":
    main()
