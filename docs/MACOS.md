# macOS

Supports **macOS 15+**, on Intel and Apple Silicon. One universal download works on both. No Homebrew, Rosetta, remote server, or developer tools are needed to use a release.

Download `dpi-vX.Y.Z-macos-universal.pkg` from [Releases](https://github.com/wleeaf/dpi/releases/latest), open it, and follow the installer. It installs **DPI** in Applications and starts the bypass at boot. Restart Discord after installation.

**These Mac downloads are not Developer ID signed or notarized yet.** If macOS blocks the package or app, open **System Settings → Privacy & Security → Open Anyway** for that download, then retry. Only approve the download you obtained from this repository. Gatekeeper settings are not changed by DPI.

If you prefer a terminal, extract `dpi-vX.Y.Z-macos-universal.tar.gz`, open a terminal in the extracted folder, and run:

```sh
sudo ./dpi install
```

`macos/Install.command` runs the same installer and opens the controls. Allow the administrator prompt when asked.

## Controls and configuration

Open **DPI** in Applications. Choose **Connect / apply settings**, select Discord or all websites and the default or alternate strategy, then allow the administrator prompt. **Disconnect** stops the current connection; **Disable startup** also prevents startup at boot. Connect enables startup again. Closing the controls leaves the bypass running.

The default strategy splits TCP writes and the first TLS record. The alternate strategy uses TCP splitting alone. macOS cannot use Linux/Windows fake packet techniques: **UDP voice and QUIC remain unchanged**, so Discord calls may still fail on some ISPs. The `VOICE` setting is accepted for compatibility and has no effect on Mac. A connected indicator is not proof of success on your network.

Settings live in `/etc/dpi/dpi.conf`. Updates preserve them. Commands:

```sh
dpi status
sudo dpi configure discord split
sudo dpi restart
sudo dpi stop
sudo dpi disable
sudo dpi enable
sudo dpi doctor
dpi logs
sudo dpi uninstall
```

Uninstall preserves settings. DNS is unchanged; configure an encrypted resolver separately if Discord domains fail to resolve. Root-owned outgoing connections bypass DPI to prevent proxy loops.

## Firewall behavior

DPI uses the existing `com.apple/*` PF wildcard hooks and owns only the `com.apple/dpi` child anchor. It never edits `/etc/pf.conf` or flushes the main ruleset. When the live ruleset is empty, it loads only a verified stock Apple `/etc/pf.conf` to initialize those hooks. Custom configurations without those hooks are refused.

For a custom firewall, your administrator can provide the following hooks in the correct NAT/filter order, retaining their existing rules, then load that configuration themselves:

```pf
rdr-anchor "com.apple/*"
anchor "com.apple/*"
```

Do not enable Internet Sharing or another PF rules manager while DPI is connected; they may replace PF rules. If hooks disappear, DPI removes its redirection and reports the error in `/var/log/dpi.log`. The supervisor also clears redirection when the proxy exits. A PF enable reference is released on disconnect only if DPI enabled PF itself.

IPv6 uses the standard `fe80::1%lo0` loopback address. DPI refuses to connect when that address is absent; it does not disable IPv6 or modify sysctls. For a customized loopback interface, restore its standard IPv6 configuration before connecting.

The transparent proxy uses macOS's undocumented PF destination lookup inherited from upstream zapret. CI checks it on macOS 15 and 26, but future macOS versions can change that interface. VPNs and custom firewalls can also affect routing.

## Building

Install Xcode Command Line Tools and run:

```sh
bash scripts/build-macos.sh
bash scripts/package-macos.sh dev
python3 tests/macos-network.py
```

The engine links only macOS SDK libraries. Builds use ad hoc code signing for executable integrity, which does not establish a Developer ID identity or notarization. Native CI installs the package, tests forwarding, upgrades, configuration preservation, service startup, and uninstall on disposable runners. Do not run the service test on a personal Mac.
