#!/usr/bin/env python3
"""Build a signed Android release APK using environment or a private local config."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else "dev"
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", version):
        raise SystemExit("Invalid version")
    environment = dict(os.environ)
    if not environment.get("DPI_ANDROID_KEYSTORE"):
        default = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "dpi/android/signing.json"
        config = Path(environment.get("DPI_ANDROID_SIGNING_CONFIG", default))
        if not config.exists():
            raise SystemExit("Create a signing key first: python3 scripts/create-android-signing-key.py")
        values = json.loads(config.read_text())
        environment.update(DPI_ANDROID_KEYSTORE=values["keystore"], DPI_ANDROID_STORE_PASSWORD=values["store_password"], DPI_ANDROID_KEY_ALIAS=values["key_alias"])
    if not environment.get("DPI_ANDROID_STORE_PASSWORD"):
        raise SystemExit("DPI_ANDROID_STORE_PASSWORD is required")
    environment.setdefault("DPI_VERSION_NAME", version)
    subprocess.run([sys.executable, str(ROOT / "scripts/fetch-android-tunnel.py")], check=True)
    wrapper = "gradlew.bat" if os.name == "nt" else "./gradlew"
    subprocess.run([wrapper, "--no-daemon", ":app:assembleRelease", ":app:lintRelease"], cwd=ROOT / "android", env=environment, check=True)
    source = ROOT / "android/app/build/outputs/apk/release/app-release.apk"
    if not source.exists():
        raise SystemExit("Signed release APK was not produced")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    target = dist / f"dpi-{version}-android.apk"
    shutil.copy2(source, target)
    target.with_name(target.name + ".sha256").write_text(f"{hashlib.sha256(target.read_bytes()).hexdigest()}  {target.name}\n")
    print(f"Created {target}")


if __name__ == "__main__":
    main()
