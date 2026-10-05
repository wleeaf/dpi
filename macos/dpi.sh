#!/bin/bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=/opt/dpi
CONFIG=/etc/dpi/dpi.conf
LABEL=io.github.wleeaf.dpi
PLIST=/Library/LaunchDaemons/io.github.wleeaf.dpi.plist
fail() { echo "Error: $*" >&2; exit 1; }
root_required() { [[ $EUID == 0 ]] || fail 'Run this command with sudo.'; }
installed() { [[ -x "$TARGET/bin/tpws" && -f "$CONFIG" ]] || fail 'Install DPI first.'; }
owned_service() {
    if [[ -e "$PLIST" ]]; then
        if [[ ! -f "$TARGET/packaging/$LABEL.plist" ]] || ! cmp -s "$PLIST" "$TARGET/packaging/$LABEL.plist"; then
            fail 'The DPI launchd service was changed or belongs to another installation.'
        fi
    elif launchctl print "system/$LABEL" >/dev/null 2>&1; then
        fail 'A different service already uses the DPI launchd label.'
    fi
}
stop() {
    root_required; owned_service
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then launchctl bootout "system/$LABEL"; fi
    [[ ! -x "$TARGET/macos/runtime.sh" ]] || "$TARGET/macos/runtime.sh" cleanup
}
start() {
    root_required; installed; owned_service
    DPI_CONFIG="$CONFIG" "$TARGET/macos/runtime.sh" check
    stop
    launchctl enable "system/$LABEL"
    launchctl bootstrap system "$PLIST"
    local attempt
    for ((attempt=0; attempt<50; attempt++)); do
        if [[ -f /var/run/dpi-macos/ready ]] && /usr/bin/nc -z -w 1 127.0.0.1 988; then
            echo 'DPI connected. Restart Discord.'; return
        fi
        sleep 0.2
    done
    tail -n 15 /var/log/dpi.log 2>/dev/null || true
    stop
    fail 'DPI could not start. Run sudo dpi doctor.'
}
install_dpi() {
    root_required
    local package=no no_start=no option
    for option in "$@"; do
        case "$option" in --package) package=yes ;; --no-start) no_start=yes ;; *) fail "Unknown option: $option" ;; esac
    done
    if [[ "$package" == yes ]]; then [[ "$BASE" == "$TARGET" ]] || fail 'Package setup must run from /opt/dpi.';
    else [[ "$BASE" != "$TARGET" ]] || fail 'Update from a newly extracted download.'; fi
    owned_service
    [[ ! -e /Library/LaunchDaemons/zapret.plist ]] || fail 'Uninstall the existing zapret launchd service first.'
    local selected="$CONFIG"
    [[ -f "$selected" ]] || selected="$BASE/macos/dpi.conf.example"
    DPI_CONFIG="$selected" "$BASE/macos/runtime.sh" check
    stop
    if [[ "$package" == no ]]; then
        [[ ! -e /Applications/DPI.app || -x "$TARGET/bin/tpws" ]] || fail 'An unrelated /Applications/DPI.app already exists.'
        install -d -m 755 "$TARGET/bin" "$TARGET/macos" "$TARGET/profiles" "$TARGET/packaging" "$TARGET/docs"
        install -m 755 "$BASE/bin/tpws" "$TARGET/bin/"
        install -m 755 "$BASE/dpi" "$TARGET/"
        install -m 755 "$BASE/macos/dpi.sh" "$BASE/macos/runtime.sh" "$TARGET/macos/"
        install -m 644 "$BASE/macos/dpi.conf.example" "$TARGET/macos/"
        install -m 644 "$BASE/profiles/discord.txt" "$TARGET/profiles/"
        install -m 644 "$BASE/packaging/$LABEL.plist" "$TARGET/packaging/"
        install -m 644 "$BASE/README.md" "$BASE/LICENSE" "$TARGET/"
        install -m 644 "$BASE/docs/MACOS.md" "$BASE/docs/DEVELOPMENT.md" "$TARGET/docs/"
        rm -rf /Applications/DPI.app
        /usr/bin/ditto "$BASE/DPI.app" /Applications/DPI.app
    fi
    chown -R root:wheel "$TARGET" /Applications/DPI.app
    chmod -R go-w "$TARGET" /Applications/DPI.app
    install -d -m 755 /etc/dpi /usr/local/bin
    [[ -e "$CONFIG" ]] || install -m 644 "$TARGET/macos/dpi.conf.example" "$CONFIG"
    install -m 644 "$TARGET/packaging/$LABEL.plist" "$PLIST"
    chown root:wheel "$PLIST" "$CONFIG"
    chmod 644 "$CONFIG"
    ln -sfn "$TARGET/dpi" /usr/local/bin/dpi
    [[ "$no_start" == yes ]] || start
    echo 'Installed. Open DPI from Applications. Settings: /etc/dpi/dpi.conf'
}
case "${1:-help}" in
    install) shift; install_dpi "$@" ;;
    start|restart|enable) start ;;
    stop) stop ;;
    disable) stop; launchctl disable "system/$LABEL" ;;
    configure)
        root_required; installed
        [[ $# == 3 ]] || fail 'Usage: sudo dpi configure {discord|all} {default|split}'
        case "$2:$3" in discord:default|discord:split|all:default|all:split) ;; *) fail 'Invalid settings.' ;; esac
        printf 'PROFILE=%s\nSTRATEGY=%s\nVOICE=no\n' "$2" "$3" > "$CONFIG"
        start ;;
    status)
        if [[ -f /var/run/dpi-macos/ready ]] && /usr/bin/nc -z -w 1 127.0.0.1 988; then echo 'DPI connected'; else echo 'DPI disconnected'; fi ;;
    logs) tail -n 60 /var/log/dpi.log ;;
    doctor)
        installed
        DPI_CONFIG="$CONFIG" "$TARGET/macos/runtime.sh" check
        launchctl print "system/$LABEL" || true
        echo 'DNS:'; /usr/bin/dscacheutil -q host -a name discord.com
        echo 'PF rules (administrator required):'; pfctl -a com.apple/dpi -s rules || true
        echo 'Recent startup messages:'; tail -n 15 /var/log/dpi.log 2>/dev/null || true ;;
    uninstall)
        root_required; installed; stop
        launchctl disable "system/$LABEL"
        rm -f "$PLIST"
        [[ $(readlink /usr/local/bin/dpi) != "$TARGET/dpi" ]] || rm /usr/local/bin/dpi
        rm -rf "$TARGET" /Applications/DPI.app
        echo 'DPI removed. Settings are preserved in /etc/dpi/dpi.conf.' ;;
    *) echo 'Usage: sudo dpi {install|start|restart|stop|enable|disable|configure|status|doctor|logs|uninstall}' ;;
esac
