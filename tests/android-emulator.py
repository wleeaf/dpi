#!/usr/bin/env python3
"""Test the APK through a real VPN using an independently installed probe app."""
import http.server
import os
from pathlib import Path
import re
import socket
import subprocess
import threading
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ADB = os.environ.get("ADB", "adb")
PACKAGE = "io.github.wleeaf.dpi"


def adb(*args):
    result = subprocess.run([ADB, *args], text=True, capture_output=True, timeout=90, check=True)
    return result.stdout


def settings():
    return ET.fromstring(adb("shell", "run-as", PACKAGE, "cat", "shared_prefs/dpi.xml"))


def state():
    try:
        node = settings().find("string[@name='state']")
        return node.text if node is not None else ""
    except (subprocess.CalledProcessError, ET.ParseError):
        return ""


def click(text):
    adb("shell", "uiautomator", "dump", "/sdcard/dpi-ui.xml")
    xml = ET.fromstring(adb("shell", "cat", "/sdcard/dpi-ui.xml"))
    for node in xml.iter("node"):
        if node.get("text", "").casefold().startswith(text.casefold()):
            x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.attrib["bounds"]))
            adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
            return
    raise RuntimeError(f"Could not find control: {text}")


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/dpi-smoke":
            self.send_error(404)
            return
        payload = b"dpi-smoke-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def main():
    paths = ["app/build/outputs/apk/debug/app-debug.apk", "probe/build/outputs/apk/debug/probe-debug.apk", "probe/build/outputs/apk/androidTest/debug/probe-debug-androidTest.apk"]
    for path in paths:
        adb("install", "-r", str(ROOT / "android" / path))
    adb("shell", "pm", "clear", PACKAGE)
    adb("shell", "appops", "set", PACKAGE, "ACTIVATE_VPN", "allow")
    adb("shell", "pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS")
    http_fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    threading.Thread(target=http_fixture.serve_forever, daemon=True).start()

    def echo():
        while True:
            try:
                payload, sender = udp.recvfrom(65535)
                udp.sendto(payload, sender)
            except OSError:
                return

    threading.Thread(target=echo, daemon=True).start()
    try:
        adb("shell", "am", "start", "-n", PACKAGE + "/.MainActivity")
        time.sleep(2)
        click("All apps")
        click("Connect")
        for _ in range(30):
            current = state()
            if current.startswith("Connected"):
                break
            if "failed" in current.lower():
                raise RuntimeError(current)
            time.sleep(1)
        else:
            raise RuntimeError("VPN did not connect: " + state())
        output = adb("shell", "am", "instrument", "-w", "-e", "tcpPort", str(http_fixture.server_port), "-e", "udpPort", str(udp.getsockname()[1]), "io.github.wleeaf.dpi.probe.test/io.github.wleeaf.dpi.probe.SmokeRunner")
        if "DPI_SMOKE_PASSED" not in output:
            raise RuntimeError(output)
        time.sleep(2)
        counters = settings()
        sent = int(counters.find("long[@name='txPackets']").attrib["value"])
        received = int(counters.find("long[@name='rxPackets']").attrib["value"])
        if sent < 1 or received < 1:
            raise RuntimeError("Probe did not traverse the native VPN adapter")
        print(output.strip())
        print(f"Native VPN packet counters: sent={sent}, received={received}")
        adb("shell", "am", "start", "-n", PACKAGE + "/.MainActivity")
        time.sleep(1)
        click("Disconnect")
        for _ in range(10):
            if state() == "Disconnected":
                print("VPN disconnected cleanly")
                break
            time.sleep(1)
        else:
            raise RuntimeError("VPN did not disconnect")
    finally:
        http_fixture.shutdown()
        udp.close()
        adb("shell", "am", "force-stop", PACKAGE)


if __name__ == "__main__":
    main()
