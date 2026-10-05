# DPI

Simple local DPI bypass for **Windows, Linux, macOS, and Android**, focused on Discord in Turkey. Desktop versions use [zapret](https://github.com/bol-van/zapret). Android uses a local VPN adapter and TCP/TLS splitting without root or a remote server.

Download your device's file from [Releases](https://github.com/wleeaf/dpi/releases/latest). Choose an attached ZIP, archive, or APK; GitHub's automatic source downloads do not contain built apps.

| Platform | Download | Setup |
| --- | --- | --- |
| Windows 10/11 · Intel/AMD x64 | `dpi-vX.Y.Z-windows-x86_64.zip` | Extract → run **Install.cmd** → accept the administrator prompt. |
| Linux · x86_64 or ARM64 | `dpi-vX.Y.Z-linux-ARCH.tar.gz` | Extract → run **`sudo ./dpi install`** in the extracted folder. |
| macOS 15+ · Intel or Apple Silicon | `dpi-vX.Y.Z-macos-universal.pkg` | Open the installer → open **DPI** in Applications. |
| Android 10+ · ARM or Intel | `dpi-vX.Y.Z-android.apk` | Install → open **DPI** → tap **Connect** → accept the VPN prompt. |

Restart Discord after connecting. These tools keep your normal IP address. A working bypass depends on your ISP; DNS poisoning and IP blocks may require other measures. The supplied presets have not been verified on every Turkish ISP.

## Windows

Run **Install.cmd** once. It installs the app, starts the bypass service, and enables startup with Windows. Open **DPI** from the Start menu to change traffic scope, strategy, voice handling, or startup behavior. Closing the window leaves the service running; **Disconnect** stops it.

There are only three settings: Discord or all websites, the default or alternate TCP strategy, and voice on/off. Start with the defaults; try `split` if the default strategy fails. Settings are saved in `%ProgramData%\DPI\dpi.conf`; updates preserve them. Run **Install.cmd** from a freshly extracted ZIP to update, or **Uninstall.cmd** from the ZIP to remove the app and retain settings.

Administrator PowerShell commands are available too:

```powershell
& "$env:ProgramFiles\DPI\dpi.ps1" -Command status
& "$env:ProgramFiles\DPI\dpi.ps1" -Command doctor
& "$env:ProgramFiles\DPI\dpi.ps1" -Command configure -Strategy split
& "$env:ProgramFiles\DPI\dpi.ps1" -Command stop
& "$env:ProgramFiles\DPI\dpi.ps1" -Command enable
& "$env:ProgramFiles\DPI\dpi.ps1" -Command disable
```

The ZIP includes the Cygwin runtime and signed WinDivert driver. Windows on ARM and 32-bit Windows are outside this release's scope. Stop and disable other zapret/winws installations first. If the driver fails to load, check `doctor` and Windows security logs; the installer does not change Windows security settings. DNS settings are preserved: configure encrypted DNS in Windows if Discord domains fail to resolve.

## Linux

Requires systemd, nftables/NFQUEUE, and glibc 2.35+ for release binaries, such as Ubuntu 22.04+, Debian 12+, or recent Fedora/Arch. The installer installs missing runtime dependencies through apt, dnf, or pacman and starts the service at boot.

```sh
sudo ./dpi install
dpi status
```

Edit `/etc/dpi/dpi.conf`, then run `sudo dpi restart`:

```ini
PROFILE=discord
STRATEGY=default
VOICE=yes
```

Use `PROFILE=all` for all websites, `STRATEGY=split` for the alternate TCP strategy, or `VOICE=no` to disable voice discovery processing. IPv4 and IPv6 are supported. Desktop voice handling targets Discord's discovery signature on UDP 50000–50099; other protocols or ports may need additional tuning.

```sh
dpi doctor              # Settings, service, DNS, and Discord HTTPS checks
dpi logs                # Service logs
sudo dpi disable        # Stop and disable startup at boot
sudo dpi enable         # Start and enable startup at boot
sudo dpi uninstall      # Remove the app; preserve settings
```

Updates use `sudo ./dpi install` from the new release and preserve settings. DNS is unchanged by default. On systems using systemd-resolved, `sudo dpi dns on` opts into Cloudflare DNS over TLS; `sudo dpi dns off` removes DPI's override. See [Linux setup and troubleshooting](docs/LINUX.md) for details, staging installs, DNS, firewall behavior, and migration from the old installation.

## macOS

Open the universal PKG installer and follow its prompts. It installs **DPI** in Applications and enables startup at boot. The controls let you connect, choose Discord or all websites, try the alternate TCP strategy, disconnect, or disable startup. Updates preserve `/etc/dpi/dpi.conf`. No Homebrew or Rosetta is required.

Mac downloads are **not Developer ID signed/notarized yet**. If macOS blocks a download, approve it through **System Settings → Privacy & Security → Open Anyway**. A terminal archive is also available: extract it and run `sudo ./dpi install`.

macOS uses TCP splitting and optional TLS record splitting. **UDP voice and QUIC remain unchanged**, so it cannot apply Linux/Windows fake UDP techniques. It preserves existing PF rules, owns one child anchor, and removes redirection on disconnect. DNS settings are unchanged. See [Mac setup and troubleshooting](docs/MACOS.md) for commands, custom firewalls, Internet Sharing limitations, and uninstall.

## Android

Install the APK and allow installation from your browser/file manager if Android asks. Open **DPI**, tap **Connect**, and accept Android's VPN permission. No root, terminal, server address, or Discord proxy configuration is needed. By default only the installed Discord app (`com.discord`) enters the local VPN. Select **All apps** for browsers or other apps.

- **TLS record splitting:** enabled by default. If connections fail, disconnect, turn it off, and reconnect to try TCP splitting alone.
- **Encrypted DNS (Cloudflare):** enabled by default for DNS queries entering the VPN. Turn it off if you need your own resolver behavior. Applications using their own encrypted resolver retain that resolver.
- **Disconnect:** available in the app and its notification. Android supports one active VPN at a time; another VPN or VPN-based firewall will conflict with DPI.

**Android has more limited bypass capabilities than desktop.** The app splits TCP writes and optionally TLS ClientHello records. It forwards UDP, including voice and QUIC, unchanged; it cannot apply zapret's fake UDP packet techniques without root. Discord login or voice may still fail on networks requiring those techniques. Do not treat a connected indicator as proof that Discord works on your ISP.

The VPN adapter connects to a proxy on the phone itself, then to each destination directly. HTTPS certificates use normal Android validation; the app does not decrypt your HTTPS traffic or log it. Cloudflare receives DNS queries when encrypted DNS is enabled. ICMP and router forwarding are outside this app's scope. If Android stops the app in the background, check its battery settings and reconnect; always-on/lockdown VPN mode is not supported.

Install subsequent release APKs over the existing app to preserve settings. Development/CI preview APKs use a separate debug signing key and cannot replace a signed release without uninstalling it first.

## Downloads and releases

Release downloads include `SHA256SUMS`. On Linux, place it beside your download and run:

```sh
sha256sum --ignore-missing --check SHA256SUMS
```

On Windows, use `Get-FileHash path-to-download.zip -Algorithm SHA256` and compare it with the corresponding entry.

[Build and maintainer instructions](docs/DEVELOPMENT.md) cover local builds, checks, and the one-time Android signing setup. Once Android signing secrets are configured, pushing a `vX.Y.Z` tag builds, tests, and publishes all four platforms. Manual workflow runs produce development artifacts without publishing. CI preview APKs are clearly named `android-preview.apk`.

## License and credits

[MIT](LICENSE). Desktop packet processing comes from **bol-van/zapret**. Android's native adapter is **[heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)**, with its MIT notice included in the app. Windows downloads include dependency notices and matching Cygwin/zlib sources. Preserved [upstream engine documentation](https://github.com/wleeaf/dpi/blob/master/docs/readme.en.md) covers advanced tuning and other platforms.
