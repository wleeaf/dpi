#!/bin/bash
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${DPI_CONFIG:-/etc/dpi/dpi.conf}
STATE=/var/run/dpi-macos
ANCHOR=com.apple/dpi
ENGINE_PID=
ENGINE="$BASE/bin/tpws"
[[ -x "$ENGINE" ]] || ENGINE="$BASE/macos/bin/tpws"
fail() { echo "Error: $*" >&2; exit 1; }

load_config() {
    PROFILE=discord STRATEGY=default
    local line key value
    [[ -f "$CONFIG" ]] || fail "Missing settings: $CONFIG"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*([a-z]+)[[:space:]]*$ ]] || fail "Invalid setting: $line"
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        case "$key:$value" in
            PROFILE:discord|PROFILE:all|STRATEGY:default|STRATEGY:split|VOICE:yes|VOICE:no) printf -v "$key" '%s' "$value" ;;
            *) fail "Unsupported setting: $key=$value" ;;
        esac
    done < "$CONFIG"
}
build_args() {
    # Bash 3.2 ships with macOS and treats empty arrays as unset with -u.
    ARGS=(--user=root --enable-pf --port=988 --bind-addr=127.0.0.1 --bind-iface6=lo0 --bind-linklocal=force --filter-tcp=80)
    [[ "$PROFILE" != discord ]] || ARGS+=("--hostlist=$BASE/profiles/discord.txt")
    ARGS+=(--split-pos=method+2 --new --filter-tcp=443)
    [[ "$PROFILE" != discord ]] || ARGS+=("--hostlist=$BASE/profiles/discord.txt")
    ARGS+=("--split-pos=1,midsld")
    [[ "$STRATEGY" != default ]] || ARGS+=(--tlsrec=sni)
}
rules() {
    cat <<'EOF'
rdr pass on lo0 inet proto tcp from !127.0.0.0/8 to !127.0.0.0/8 port {80,443} -> 127.0.0.1 port 988
rdr pass on lo0 inet6 proto tcp from !::1 to !::1 port {80,443} -> fe80::1 port 988
pass out quick route-to (lo0 127.0.0.1) inet proto tcp from !127.0.0.0/8 to !127.0.0.0/8 port {80,443} user { >root }
pass out quick route-to (lo0 fe80::1) inet6 proto tcp from !::1 to !::1 port {80,443} user { >root }
EOF
}
hooks_present() {
    pfctl -s nat 2>/dev/null | /usr/bin/grep -Fq 'rdr-anchor "com.apple/*"' &&
        pfctl -s rules 2>/dev/null | /usr/bin/grep -Fq 'anchor "com.apple/*"'
}
prepare_pf() {
    hooks_present && return
    # Only initialize an empty PF ruleset from Apple's stock configuration.
    # Custom/live firewall rules are never replaced to obtain our hooks.
    [[ -z $(pfctl -s rules 2>/dev/null) && -z $(pfctl -s nat 2>/dev/null) ]] || fail "PF lacks Apple's wildcard anchors. See docs/MACOS.md for custom firewalls."
    local content line
    content=$(/usr/bin/sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /etc/pf.conf)
    while IFS= read -r line; do
        case "$line" in
            'scrub-anchor "com.apple/*"'|'nat-anchor "com.apple/*"'|'rdr-anchor "com.apple/*"'|'dummynet-anchor "com.apple/*"'|'anchor "com.apple/*"'|'load anchor "com.apple" from "/etc/pf.anchors/com.apple"') ;;
            *) fail "Custom /etc/pf.conf detected. See docs/MACOS.md for PF hooks." ;;
        esac
    done <<< "$content"
    pfctl -nf /etc/pf.conf
    pfctl -f /etc/pf.conf
    hooks_present || fail "Apple PF anchors are unavailable."
}
cleanup() {
    rm -f "$STATE/ready"
    if [[ -f "$STATE/owned" ]]; then
        pfctl -a "$ANCHOR" -F rules || return 1
        pfctl -a "$ANCHOR" -F nat || return 1
        rm -f "$STATE/owned"
    fi
    if [[ -n "$ENGINE_PID" ]]; then
        kill "$ENGINE_PID" 2>/dev/null || true
        wait "$ENGINE_PID" 2>/dev/null || true
    fi
    if [[ -f "$STATE/token" ]]; then
        local token
        token=$(cat "$STATE/token")
        [[ "$token" =~ ^[0-9]+$ ]] || fail "Invalid PF reference token."
        pfctl -X "$token" || return 1
        rm -f "$STATE/token"
    fi
}
run() {
    [[ $EUID == 0 ]] || fail "Run as administrator."
    umask 077
    mkdir -p "$STATE"
    chmod 755 "$STATE"
    load_config; build_args
    "$ENGINE" --dry-run "${ARGS[@]}"
    prepare_pf
    [[ ! -f "$STATE/owned" && ! -f "$STATE/token" ]] || cleanup
    [[ -z $(pfctl -a "$ANCHOR" -s rules 2>/dev/null) && -z $(pfctl -a "$ANCHOR" -s nat 2>/dev/null) ]] || fail "The DPI PF anchor is already in use by another installation."
    /sbin/ifconfig lo0 | /usr/bin/grep -q 'inet6 fe80::1%lo0 ' || fail "Missing IPv6 loopback address fe80::1%lo0. See docs/MACOS.md."
    trap cleanup EXIT
    trap 'exit 0' TERM INT
    # Root can bind the privileged port and access macOS DIOCNATLOOK.
    # Start the listener before redirecting traffic into it.
    "$ENGINE" "${ARGS[@]}" &
    ENGINE_PID=$!
    local ready=no attempt
    for ((attempt=0; attempt<50; attempt++)); do
        kill -0 "$ENGINE_PID" 2>/dev/null || fail "TCP proxy exited during startup."
        if /usr/bin/nc -z -w 1 127.0.0.1 988; then ready=yes; break; fi
        sleep 0.1
    done
    [[ "$ready" == yes ]] || fail "TCP proxy did not become ready."
    rules > "$STATE/rules"
    pfctl -a "$ANCHOR" -nf "$STATE/rules"
    touch "$STATE/owned"
    pfctl -a "$ANCHOR" -f "$STATE/rules"
    if ! pfctl -s info 2>/dev/null | /usr/bin/grep -q '^Status: Enabled'; then
        local enabled token
        enabled=$(pfctl -E 2>&1)
        token=$(printf '%s\n' "$enabled" | /usr/bin/sed -n 's/^Token : \([0-9][0-9]*\)$/\1/p')
        [[ "$token" =~ ^[0-9]+$ ]] || fail "PF did not return an enable token: $enabled"
        printf '%s\n' "$token" > "$STATE/token"
    fi
    touch "$STATE/ready"
    echo 'DPI connected. Restart Discord to open new connections.'
    while kill -0 "$ENGINE_PID" 2>/dev/null; do
        sleep 1
        hooks_present || fail "Another tool replaced the PF hooks. Disconnecting DPI."
    done
    fail "TCP proxy stopped; removing traffic redirection."
}
case "${1:-}" in
    check|args) load_config; build_args; if [[ "$1" == check ]]; then "$ENGINE" --dry-run "${ARGS[@]}"; else printf '%s\n' "${ARGS[@]}"; fi ;;
    rules) rules ;;
    run) run ;;
    cleanup) [[ $EUID == 0 ]] || fail 'Run as administrator.'; cleanup ;;
    *) fail 'Usage: runtime.sh {check|args|rules|run|cleanup}' ;;
esac
