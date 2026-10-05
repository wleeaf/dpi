#!/usr/bin/env bash
set -euo pipefail

DPI_BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DPI_CONFIG=${DPI_CONFIG:-/etc/dpi/dpi.conf}
NFQWS="$DPI_BASE/bin/nfqws"
QUEUE=20000
MARK=0x40000000
DPI_STATE=${DPI_STATE:-/run/dpi}

fail() { echo "Error: $*" >&2; exit 1; }

load_config() {
    PROFILE=discord STRATEGY=default VOICE=yes
    local line key value
    [[ -f "$DPI_CONFIG" ]] || fail "Missing $DPI_CONFIG. Run sudo ./dpi install first."
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*([a-z]+)[[:space:]]*$ ]] || fail "Invalid setting in $DPI_CONFIG: $line"
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        case "$key:$value" in
            PROFILE:discord|PROFILE:all|STRATEGY:default|STRATEGY:split|VOICE:yes|VOICE:no)
                printf -v "$key" '%s' "$value" ;;
            *) fail "Unsupported setting: $key=$value" ;;
        esac
    done < "$DPI_CONFIG"
}

build_args() {
    local -a hosts=()
    [[ "$PROFILE" != discord ]] || hosts=("--hostlist=$DPI_BASE/profiles/discord.txt")
    ARGS=("--qnum=$QUEUE" "--dpi-desync-fwmark=$MARK")
    if [[ "$STRATEGY" == default ]]; then
        ARGS+=(--filter-tcp=80 "${hosts[@]}" "--dpi-desync=fake,multisplit"
            --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig --dpi-desync-cutoff=n9
            --new --filter-tcp=443 "${hosts[@]}" "--dpi-desync=fake,multidisorder"
            "--dpi-desync-split-pos=1,midsld" "--dpi-desync-fooling=badseq,md5sig"
            "--dpi-desync-fake-tls=$DPI_BASE/files/fake/tls_clienthello_www_google_com.bin"
            --dpi-desync-cutoff=n9)
    else
        ARGS+=(--filter-tcp=80 "${hosts[@]}" --dpi-desync=multisplit
            --dpi-desync-split-pos=method+2 --dpi-desync-cutoff=n9
            --new --filter-tcp=443 "${hosts[@]}" --dpi-desync=multisplit
            "--dpi-desync-split-pos=1,midsld" --dpi-desync-cutoff=n9)
    fi
    ARGS+=(--new --filter-udp=443 "${hosts[@]}" --dpi-desync=fake --dpi-desync-repeats=6
        "--dpi-desync-fake-quic=$DPI_BASE/files/fake/quic_initial_www_google_com.bin"
        --dpi-desync-cutoff=n9)
    if [[ "$VOICE" == yes ]]; then
        ARGS+=(--new --filter-udp=50000-50099 --filter-l7=discord
            --dpi-desync=fake --dpi-desync-repeats=2
            "--dpi-desync-fake-discord=$DPI_BASE/files/fake/discord-ip-discovery-with-port.bin"
            --dpi-desync-cutoff=n9)
    fi
}

check_args() {
    # nfqws otherwise drops root to UID 2147483647 even during a dry-run.
    # Keep the current UID for validation (including temporary install paths).
    local -a identity=()
    [[ $EUID != 0 ]] || identity=(--uid=0:0)
    "$NFQWS" --dry-run "${identity[@]}" "${ARGS[@]}"
}

firewall_rules() {
    # Only this computer's outgoing connections. Never flush another table.
    cat <<EOF
table inet dpi {
    chain output {
        type filter hook output priority mangle; policy accept;
        oifname "lo" return
        meta mark & $MARK != 0 return
        ct direction reply return
        tcp dport { 80, 443 } queue num $QUEUE bypass
        udp dport 443 queue num $QUEUE bypass
EOF
    if [[ "$VOICE" == yes ]]; then
        # Discord IP discovery uses an 8-byte UDP header + 74-byte payload.
        echo "        udp dport 50000-50099 udp length 82 queue num $QUEUE bypass"
    fi
    printf '    }\n}\n'
}

case "${1:-}" in
    check|args|rules|start|firewall-start)
        load_config
        build_args
        case "$1" in
            check) check_args ;;
            args) printf '%s\n' "${ARGS[@]}" ;;
            rules) firewall_rules ;;
            start) exec "$NFQWS" --user=nobody "${ARGS[@]}" ;;
            firewall-start)
                # Validate before redirecting any traffic.
                check_args
                nft list table inet dpi >/dev/null 2>&1 && fail "inet dpi table already exists; run sudo dpi stop first."
                mkdir -p "$DPI_STATE"
                firewall_rules | nft -f -
                touch "$DPI_STATE/firewall-owned"
                ;;
        esac
        ;;
    firewall-stop)
        # ExecStopPost also runs after a failed ExecStartPre. Only remove a
        # table successfully created by this service, not a conflicting table.
        if [[ -f "$DPI_STATE/firewall-owned" ]] && nft list table inet dpi >/dev/null 2>&1; then
            nft delete table inet dpi
        fi
        rm -f -- "$DPI_STATE/firewall-owned"
        ;;
    *) fail "Usage: runtime.sh {check|args|rules|start|firewall-start|firewall-stop}" ;;
esac
