"""Exercise the native Mac engine with real HTTP and TLS through SOCKS5."""
import itertools
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "macos/bin/tpws"
if not ENGINE.exists():
    ENGINE = ROOT / "bin/tpws"  # Extracted release archive.


def tunnel(proxy_port, destination_port):
    stream = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
    stream.sendall(b"\x05\x01\x00")
    assert stream.recv(2) == b"\x05\x00", "SOCKS negotiation failed"
    host = b"github.com"
    stream.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + destination_port.to_bytes(2, "big"))
    response = b""
    while len(response) < 10:
        chunk = stream.recv(10 - len(response))
        assert chunk, "SOCKS connection closed"
        response += chunk
    assert response[:2] == b"\x05\x00", f"SOCKS connect failed: {response!r}"
    return stream


def request(stream, secure=False):
    with stream:
        stream.sendall(b"GET /robots.txt HTTP/1.1\r\nHost: github.com\r\nConnection: close\r\n\r\n")
        response = b""
        while chunk := stream.recv(4096):
            response += chunk
    if secure:
        assert b"200 OK" in response and b"user-agent" in response.lower(), response[:500]
    else:
        assert b"301" in response and b"https://github.com/robots.txt" in response, response[:500]


def main():
    with tempfile.TemporaryDirectory(prefix="dpi-mac-network-") as tmp:
        work = Path(tmp)
        # Upstream intentionally refuses SOCKS targets on local interfaces.
        # Exercise public HTTP/TLS with normal certificate verification.
        context = ssl.create_default_context()
        for strategy in ("default", "split"):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            args = [str(ENGINE), "--debug=2", "--socks", f"--port={port}", "--bind-addr=127.0.0.1",
                    "--split-pos=method+2,1,midsld"]
            if os.geteuid() == 0:
                args.append("--user=root")
            if strategy == "default":
                args.append("--tlsrec=sni")
            with (work / "engine.log").open("wb") as log:
                process = subprocess.Popen(args, stdout=log, stderr=log)
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise AssertionError((work / "engine.log").read_text())
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.1)
                    request(tunnel(port, 80))
                    request(context.wrap_socket(tunnel(port, 443), server_hostname="github.com"), secure=True)
                except Exception:
                    print("Engine exit status:", process.poll())
                    print((work / "engine.log").read_text()[-18000:])
                    raise
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        runtime = ROOT / "macos/runtime.sh"
        for profile, strategy in itertools.product(("discord", "all"), ("default", "split")):
            config = work / "dpi.conf"
            config.write_text(f"PROFILE={profile}\nSTRATEGY={strategy}\nVOICE=no\n")
            # Dry-run the actual production transparent-mode presets.
            # It needs root on macOS to open /dev/pf.
            subprocess.run(["sudo", "env", f"DPI_CONFIG={config}", "/bin/bash", str(runtime), "check"], check=True)
    print("macOS HTTP, TLS, SOCKS forwarding and production presets passed.")


if __name__ == "__main__":
    main()
