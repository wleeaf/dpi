"""Exercise the native Mac engine with real HTTP and TLS through SOCKS5."""
import http.server
import itertools
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "macos/bin/tpws"
if not ENGINE.exists():
    ENGINE = ROOT / "bin/tpws"  # Extracted release archive.


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"dpi-macos-relay-ok")

    def log_message(self, *_):
        pass


def tunnel(proxy_port, destination_port):
    stream = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
    stream.sendall(b"\x05\x01\x00")
    assert stream.recv(2) == b"\x05\x00", "SOCKS negotiation failed"
    stream.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + destination_port.to_bytes(2, "big"))
    response = b""
    while len(response) < 10:
        chunk = stream.recv(10 - len(response))
        assert chunk, "SOCKS connection closed"
        response += chunk
    assert response[:2] == b"\x05\x00", f"SOCKS connect failed: {response!r}"
    return stream


def request(stream):
    with stream:
        stream.sendall(b"GET / HTTP/1.1\r\nHost: discord.com\r\nConnection: close\r\n\r\n")
        response = b""
        while chunk := stream.recv(4096):
            response += chunk
    assert b"200 OK" in response and response.endswith(b"dpi-macos-relay-ok"), response


def main():
    with tempfile.TemporaryDirectory(prefix="dpi-mac-network-") as tmp:
        work = Path(tmp)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=discord.com", "-addext", "subjectAltName=DNS:discord.com",
                        "-keyout", str(work / "key.pem"), "-out", str(work / "cert.pem")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        secure = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(work / "cert.pem", work / "key.pem")
        secure.socket = server_context.wrap_socket(secure.socket, server_side=True)
        for server in (plain, secure):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        context = ssl.create_default_context(cafile=str(work / "cert.pem"))
        try:
            for strategy in ("default", "split"):
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", 0))
                    port = probe.getsockname()[1]
                args = [str(ENGINE), "--socks", f"--port={port}", "--bind-addr=127.0.0.1",
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
                        request(tunnel(port, plain.server_port))
                        request(context.wrap_socket(tunnel(port, secure.server_port), server_hostname="discord.com"))
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
        finally:
            for server in (plain, secure):
                server.shutdown()
                server.server_close()
    print("macOS HTTP, TLS, SOCKS forwarding and production presets passed.")


if __name__ == "__main__":
    main()
