# Build and release

The repository keeps upstream zapret engines and advanced tools, while easy setup lives in `dpi`, `scripts/`, `windows/`, and `android/`. Shared Discord domains live in `profiles/discord.txt`. Generated binaries, downloads, local settings, keys, and `dist/` are ignored.

## Linux

On Debian/Ubuntu:

```sh
sudo apt-get install build-essential zlib1g-dev libcap-dev libnetfilter-queue-dev libmnl-dev
make -C nfq
bash scripts/package.sh dev
```

On Fedora, install `gcc`, `make`, `zlib-ng-compat-devel`, `libcap-devel`, `libnetfilter_queue-devel`, and `libmnl-devel`. Local builds use your system's glibc. Official archives use Ubuntu 22.04 for x86_64 and ARM64. The native ARM64 Actions runner requires a public repository or your own suitable runner.

Checks:

```sh
shellcheck dpi scripts/*.sh tests/*.sh enable.sh disable.sh nft-start.sh nft-stop.sh
python3 -m unittest discover -s tests -v
sudo unshare --net bash tests/firewall.sh
```

The firewall test runs in an isolated network namespace. `DESTDIR=/absolute/staging/path ./dpi install` stages files without changing host services, DNS, or dependencies.

## Windows

Use Windows x64 and Cygwin with `gcc-core`, `make`, and `zlib-devel`. In a Cygwin shell:

```sh
bash scripts/build-windows.sh
```

This builds winws with service name `DpiBypass`, preserving the upstream name for other builds. In Windows PowerShell with Python 3.10+ available:

```powershell
python scripts/fetch-windivert.py
python scripts/fetch-cygwin-sources.py C:/cygwin/etc/setup/installed.db
./tests/windows-core.ps1
./scripts/package-windows.ps1 -Version dev
```

The driver archive is checksum pinned. Matching Cygwin/zlib sources are checked against mirror metadata and included in the ZIP. The resulting `dist/dpi-dev-windows-x86_64.zip` includes all required runtime files; users do not install Cygwin separately. The native service smoke test is restricted to disposable CI runners because it installs and removes a real Windows service.

## Android

Requires JDK 17+, Python 3.10+, Android SDK platform 36 and build tools 35.0.0. The checked-in Gradle 8.13 wrapper verifies its distribution checksum. Point `ANDROID_HOME` at your SDK or create ignored `android/local.properties` with `sdk.dir=/absolute/path/to/sdk`.

```sh
python3 scripts/fetch-android-tunnel.py
bash tests/android-core.sh
cd android
./gradlew --no-daemon :app:assembleDebug :app:lintDebug
```

The checksum-pinned hev-socks5-tunnel AAR supplies four ABIs: arm64-v8a, armeabi-v7a, x86, and x86_64, with minimum Android 10. No NDK is required. The app uses an Android VPN adapter, a bounded loopback SOCKS5 TCP/UDP relay, and protected upstream sockets. Discord mode includes only `com.discord`; all-apps mode excludes the VPN app itself. UDP forwarding has no fake packet desynchronization. DNS over HTTPS uses Cloudflare with normal certificate validation.

The Java relay tests exercise real TCP/UDP sockets, IPv6, actual TLS handshakes through both splitting strategies, partial ClientHello reads, DNS interception, and half-close behavior. To test native VPN routing on an Android emulator:

```sh
cd android
./gradlew :app:assembleDebug :probe:assembleDebug :probe:assembleDebugAndroidTest
cd ..
python3 tests/android-emulator.py
```

The test installs a probe in a separate app UID so traffic traverses the VPN. It grants VPN consent only in the emulator, drives the production Connect UI, checks TCP/UDP and native packet counters, and disconnects. Use `ADB` and `ANDROID_SERIAL` if needed. The test clears the emulator app's settings before running. The `probe` module is never included in release APKs.

### Persistent signing key

Create a private signing key once:

```sh
python3 scripts/create-android-signing-key.py
python3 scripts/build-android.py dev
```

The default key and private config live outside the repository in `$XDG_DATA_HOME/dpi/android/` or `~/.local/share/dpi/android/`. **Back up both files securely.** Losing or replacing the key prevents existing users from installing updates over your APK. The helper reuses an existing key. `DPI_ANDROID_SIGNING_CONFIG` can select another private config.

For another signing setup, supply `DPI_ANDROID_KEYSTORE`, `DPI_ANDROID_STORE_PASSWORD`, `DPI_ANDROID_KEY_ALIAS` (default `dpi`), and optionally `DPI_ANDROID_KEY_PASSWORD` (defaults to store password). `DPI_VERSION_NAME` and a monotonically increasing `DPI_VERSION_CODE` customize Android versions. The signed APK and checksum are copied into `dist/`.

### GitHub release signing

With GitHub CLI installed and authenticated (`gh auth login`), run this once to set the repository's signing secrets using your local key:

```sh
python3 scripts/configure-android-ci.py --repo wleeaf/dpi
```

This command writes the four Actions signing secrets to the named repository. It requires repository admin access and sends private values through stdin without printing them. To use another private signing config, add `--config /path/to/signing.json`. You can also add secrets through GitHub's **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `DPI_ANDROID_KEYSTORE_BASE64` | Base64 encoding of your persistent `.jks` file. |
| `DPI_ANDROID_STORE_PASSWORD` | Store password from the private signing config. |
| `DPI_ANDROID_KEY_ALIAS` | Key alias, normally `dpi`. |
| `DPI_ANDROID_KEY_PASSWORD` | Optional; only needed if different from the store password. |

Use the same key for local releases and Actions releases. Never commit keys, passwords, or the private config. Tagged builds fail if signing is missing; they do not publish an incompatible debug APK. Branch/PR and manual builds produce a clearly named debug preview APK without secrets. Actions uses its release workflow run number as `versionCode`; keep version codes increasing if building releases elsewhere.

## Publish

Enable Actions and configure Android signing before tagging:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The release workflow builds native Linux x86_64/ARM64 archives, a Windows x64 ZIP, and a signed universal Android APK. It validates Linux install/firewall behavior, Windows presets and native service lifecycle, and Android relay/lint/emulator routing before publishing with combined `SHA256SUMS`. A hyphen in the tag marks a prerelease. Manual workflow runs create downloadable development artifacts without creating a release.

These checks validate packaging and networking behavior, not success against an ISP's DPI appliance. Before calling a strategy verified, test Discord login, text, calls, DNS, and IPv4/IPv6 on the target network. Windows live behavior also needs a successful Windows CI run; Android real-device behavior needs device testing beyond the emulator.
