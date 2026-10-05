#!/bin/bash
# Restricted to disposable CI runners: installs a package and uses real PF.
set -euo pipefail
[[ ${CI:-} == true && $(uname -s) == Darwin ]] || { echo 'Use a disposable macOS CI runner.' >&2; exit 1; }
PACKAGE=${1:?Pass a Mac release package}
WORK=$(mktemp -d)
cleanup() {
    if [[ -x /opt/dpi/dpi ]]; then sudo /opt/dpi/dpi uninstall || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
sudo pfctl -a com.apple/dpi-ci-unrelated -f - <<'EOF'
pass out inet proto tcp to port 65530
EOF
before=$(sudo pfctl -a com.apple/dpi-ci-unrelated -s rules 2>/dev/null)
sudo /usr/sbin/installer -pkg "$PACKAGE" -target /
[[ $(/opt/dpi/dpi status) == 'DPI connected' ]]
sudo /opt/dpi/dpi configure all default
# The CI user (not root) must traverse the real transparent PF proxy.
curl --ipv4 --http1.1 --noproxy '*' --max-time 30 --fail https://github.com/robots.txt > "$WORK/response"
grep -qi 'user-agent' "$WORK/response"
counters=$(sudo pfctl -a com.apple/dpi -vvsr)
printf '%s\n' "$counters" > "$WORK/pf-counters"
cat "$WORK/pf-counters"
grep -Eq 'Packets: [1-9][0-9]*' "$WORK/pf-counters"
sudo /opt/dpi/dpi configure discord split
sudo /usr/sbin/installer -pkg "$PACKAGE" -target /
grep -q '^STRATEGY=split$' /etc/dpi/dpi.conf
[[ $(/opt/dpi/dpi status) == 'DPI connected' ]]
sudo /opt/dpi/dpi disable
[[ $(/opt/dpi/dpi status) == 'DPI disconnected' ]]
[[ -z $(sudo pfctl -a com.apple/dpi -s rules 2>/dev/null) ]]
[[ -z $(sudo pfctl -a com.apple/dpi -s nat 2>/dev/null) ]]
sudo /opt/dpi/dpi start
[[ $(/opt/dpi/dpi status) == 'DPI connected' ]]
sudo /opt/dpi/dpi uninstall
[[ ! -e /opt/dpi && ! -e /Applications/DPI.app && -f /etc/dpi/dpi.conf ]]
[[ "$before" == "$(sudo pfctl -a com.apple/dpi-ci-unrelated -s rules 2>/dev/null)" ]]
sudo pfctl -a com.apple/dpi-ci-unrelated -F rules
echo 'macOS native install, PF routing, upgrade, settings preservation, disable, restart and uninstall passed.'
