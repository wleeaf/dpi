#!/usr/bin/env python3
"""Bundle matching dependency sources and notices for the Windows distribution."""
import hashlib
import io
import lzma
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
import urllib.request

MIRROR = "https://mirrors.kernel.org/sourceware/cygwin/"
ROOT = Path(__file__).resolve().parents[1] / "windows/third-party"


def fetch(path):
    with urllib.request.urlopen(MIRROR + path, timeout=60) as response:
        return response.read()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: fetch-cygwin-sources.py C:/cygwin/etc/setup/installed.db")
    installed = Path(sys.argv[1]).read_text()
    metadata = lzma.decompress(fetch("x86_64/setup.xz")).decode()
    ROOT.mkdir(parents=True, exist_ok=True)
    sources = ROOT / "sources"
    sources.mkdir(exist_ok=True)
    notices = ["Windows dependency notices", "", "WinDivert: https://github.com/basil00/WinDivert (see WinDivert-LICENSE.txt).",
               "Cygwin: https://cygwin.com/licensing.html (LGPLv3+ with linking exception).",
               "Unmodified matching Cygwin and zlib source packages are included in sources/.",
               "The Cygwin source archive includes its complete licenses and linking exception.",
               "GCC runtime: GPLv3 with GCC Runtime Library Exception 3.1.",
               "https://gcc.gnu.org/onlinedocs/libstdc++/manual/license.html", ""]
    for package in ("cygwin", "zlib-devel"):
        match = re.search(r"^" + re.escape(package) + r"\s+(\S+)", installed, re.M)
        if not match:
            raise SystemExit(f"{package} is not installed")
        binary = match[1]
        version = re.sub(r"(?:-x86_64)?\.tar\.(?:xz|zst|bz2|gz)$", "", binary.removeprefix(package + "-"))
        section = metadata.split("@ " + package + "\n", 1)[1].split("\n@ ", 1)[0]
        blocks = re.split(r"\n\[(?:prev|test)\]\n", section)
        record = next((b for b in blocks if re.search(r"^version: " + re.escape(version) + r"$", b, re.M)), None)
        if record is None:
            raise SystemExit(f"Matching source for {package} {version} is unavailable")
        source = re.search(r"^source: (\S+) (\d+) ([0-9a-f]{128})$", record, re.M)
        if not source:
            raise SystemExit(f"No source metadata for {package}")
        data = fetch(source[1])
        if len(data) != int(source[2]) or hashlib.sha512(data).hexdigest() != source[3]:
            raise SystemExit(f"Source checksum mismatch for {package}")
        name = PurePosixPath(source[1]).name
        (sources / name).write_bytes(data)
        notices.append(f"{package} {version}: {name}; SHA512 {source[3]}")
        if package == "cygwin":
            # Cygwin's packaging tar contains a nested upstream source tar.
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                member = next(m for m in archive.getmembers() if m.isfile() and m.name.endswith(".tar.bz2"))
                upstream = archive.extractfile(member).read()
            with tarfile.open(fileobj=io.BytesIO(upstream)) as archive:
                for source_name, target_name in {
                    "newlib-cygwin/COPYING": "GPL-3.0.txt",
                    "newlib-cygwin/COPYING.LIB": "LGPL-3.0.txt",
                    "newlib-cygwin/COPYING.NEWLIB": "Newlib-COPYING.txt",
                    "newlib-cygwin/winsup/CYGWIN_LICENSE": "Cygwin-LICENSE.txt",
                }.items():
                    (ROOT / target_name).write_bytes(archive.extractfile(source_name).read())
        print(f"Bundled verified {package} {version} source")
    (ROOT / "NOTICE.txt").write_text("\n".join(notices) + "\n")
    with urllib.request.urlopen("https://raw.githubusercontent.com/gcc-mirror/gcc/master/COPYING.RUNTIME", timeout=60) as response:
        (ROOT / "GCC-Runtime-Exception.txt").write_bytes(response.read())


if __name__ == "__main__":
    main()
