#!/usr/bin/env python3
"""Fetch the pinned, checksum-verified upstream Android networking library."""
import hashlib
from pathlib import Path
import urllib.request

VERSION = "2.18.0"
SHA256 = "15ec8ed121663b562c99caa5bb602d1009f24e5b09e733438b81988f12feaaab"
DESTINATION = Path(__file__).resolve().parents[1] / "android/app/libs/hev-socks5-tunnel.aar"


def main():
    if DESTINATION.exists() and hashlib.sha256(DESTINATION.read_bytes()).hexdigest() == SHA256:
        print("Android tunnel library verified")
        return
    url = f"https://github.com/heiher/hev-socks5-tunnel/releases/download/{VERSION}/hev-socks5-tunnel.aar"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("Android tunnel library checksum mismatch")
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    DESTINATION.write_bytes(data)
    print(f"Fetched verified hev-socks5-tunnel {VERSION}")


if __name__ == "__main__":
    main()
