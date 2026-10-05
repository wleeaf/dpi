#!/usr/bin/env python3
"""Fetch the signed upstream WinDivert runtime with a pinned archive checksum."""
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

VERSION = "2.2.2"
SHA256 = "63cb41763bb4b20f600b6de04e991a9c2be73279e317d4d82f237b150c5f3f15"
SOURCE_SHA256 = "65ec79c9e6afa99f648a3f4d1f6db794640b40d0b65bd438770ea503ee14ecb7"
ROOT = Path(__file__).resolve().parents[1] / "windows"


def main():
    url = f"https://github.com/basil00/WinDivert/releases/download/v{VERSION}/WinDivert-{VERSION}-A.zip"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("WinDivert archive checksum mismatch")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for source, target in {
            "x64/WinDivert.dll": "bin/WinDivert.dll",
            "x64/WinDivert64.sys": "bin/WinDivert64.sys",
            "LICENSE": "third-party/WinDivert-LICENSE.txt",
        }.items():
            path = ROOT / target
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.read(f"WinDivert-{VERSION}-A/{source}"))
    source_url = f"https://codeload.github.com/basil00/WinDivert/zip/refs/tags/v{VERSION}"
    with urllib.request.urlopen(source_url, timeout=60) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise SystemExit("WinDivert source checksum mismatch")
    source_path = ROOT / f"third-party/sources/WinDivert-{VERSION}-source.zip"
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_bytes(source)
    print(f"Fetched verified WinDivert {VERSION} x64")


if __name__ == "__main__":
    main()
