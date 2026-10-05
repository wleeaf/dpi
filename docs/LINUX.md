# Linux setup

## Install

Requires **Linux with systemd**, nftables/NFQUEUE support, and **glibc 2.35 or newer** for release binaries (Ubuntu 22.04+, Debian 12+, and recent Fedora/Arch). This setup processes traffic from this computer; it does not configure router forwarding or OpenWrt.

1. Open [Releases](https://github.com/wleeaf/dpi/releases/latest).
2. Download `dpi-vX.Y.Z-linux-x86_64.tar.gz` for Intel/AMD, or `dpi-vX.Y.Z-linux-arm64.tar.gz` for ARM64. Check with `uname -m` if unsure. Choose an attached release archive; GitHub's automatic source archives do not contain binaries.
3. Extract it, open a terminal inside the extracted folder, and run:

   ```sh
   sudo ./dpi install
   ```

The installer installs missing runtime dependencies through apt, dnf, or pacman, starts the service, and enables it at boot. Restart Discord after installation. For other package managers, install `nftables`, `libnetfilter_queue`, `libnfnetlink`, `libmnl`, and `zlib` first.

To verify your download, place `SHA256SUMS` beside the archive and run `sha256sum --ignore-missing --check SHA256SUMS` before extracting. To install without starting or enabling the service, use `sudo ./dpi install --no-start`.

## Configure

Edit **`/etc/dpi/dpi.conf`**, then run `sudo dpi restart`:

```ini
PROFILE=discord
STRATEGY=default
VOICE=yes
```

| Setting | Choices | Meaning |
| --- | --- | --- |
| `PROFILE` | `discord`, `all` | Apply HTTP/HTTPS and QUIC strategies to Discord domains, or to all domains. |
| `STRATEGY` | `default`, `split` | Start with `default`. Try `split` if your ISP rejects the default TCP strategy. |
| `VOICE` | `yes`, `no` | Process Discord voice discovery packets on UDP ports 50000–50099. |

Both IPv4 and IPv6 are handled. Discord subdomains are included automatically. Voice detection uses the packet signature rather than a domain list. Other UDP voice protocols or ports may need an ISP-specific strategy.

The nftables output rules send TCP 80/443, UDP 443, and selected voice discovery packets to nfqws; the Discord domain list limits which web connections it modifies. This means other web traffic still passes through the queue. Packets marked by nfqws are excluded to prevent loops. Queue 20000 and mark `0x40000000` are reserved by this setup.

The settings file accepts plain `KEY=VALUE` lines and comments. Shell commands and unknown settings are rejected.

## Everyday commands

```sh
dpi status             # Service status
dpi logs               # Recent service logs
dpi doctor             # Settings, service, DNS, and Discord HTTPS checks
sudo dpi stop          # Stop now; keep the boot setting
sudo dpi start         # Start again
sudo dpi disable       # Stop and turn off startup at boot
sudo dpi enable        # Start and turn on startup at boot
sudo dpi uninstall     # Remove the app; keep /etc/dpi for reinstallation
```

Updates use the same installation command from a freshly extracted release. Existing `/etc/dpi/dpi.conf` settings are preserved.

## DNS

The default installation preserves your DNS settings. If Discord domains fail to resolve, configure encrypted DNS in your network settings. On systems with an **active systemd-resolved** service, you can use:

```sh
sudo dpi dns on         # Cloudflare DNS over TLS
resolvectl status       # Review resolver settings and per-interface DNS
sudo dpi dns off        # Remove only dpi's DNS override
```

You can also opt in during installation with `sudo ./dpi install --dns`. DNS over TLS requires access to TCP port 853. Your applications must use systemd-resolved for this override to take effect; check `/etc/resolv.conf` and your network manager's resolver settings. It can affect private/VPN DNS, so review `resolvectl status` on those networks.

The DNS override persists when you stop or disable the bypass service. `dns off` or `uninstall` removes it. The command refuses to overwrite an existing file or remove one you edited.

## Troubleshooting and migration

- **Old installation:** if `zapret` is active or enabled, first run `sudo systemctl disable --now zapret`. The installer checks this to avoid two bypass services running together. You can keep `/opt/zapret` while evaluating the new setup.
- **Old DNS settings:** the previous `enable.sh` wrote `/etc/systemd/resolved.conf.d/dot.conf`. Review that file when migrating. The new setup does not delete it or the libraries previously copied into `/usr/lib64`.
- **Website fails:** run `dpi doctor`, check DNS, try `STRATEGY=split`, then restart the service and Discord. An HTTP response confirms HTTPS reachability; it does not prove login or voice works.
- **Voice fails:** check `VOICE=yes`, test without other bypass/VPN tools, and inspect `dpi logs`. The supplied preset is a starting point, not a verified strategy for every Turkish ISP.
- **Service fails:** run `dpi logs`. Missing NFQUEUE kernel support, a firewall reload, or a conflicting queue/table can prevent startup. After your firewall manager reloads rules, run `sudo dpi restart`.
- **Need more tuning or another platform:** the upstream engines and advanced installers remain available. See the preserved [English engine reference](https://github.com/wleeaf/dpi/blob/master/docs/readme.en.md), [Russian reference](https://github.com/wleeaf/dpi/blob/master/docs/readme.md), and `blockcheck.sh`. Advanced upstream installation uses `/opt/zapret` and its own configuration; stop `dpi` before using it.

Stopping the service removes only the `inet dpi` table. Rules use nftables' queue `bypass` option so traffic passes if no queue listener exists. This does not bypass a later firewall rule that drops the connection.
