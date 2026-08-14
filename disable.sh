#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo ./disable.sh)"
    exit 1
fi

echo "==> Stopping zapret DPI bypass..."
systemctl disable zapret 2>/dev/null || true
systemctl stop zapret 2>/dev/null || true

# Clean up nftables if any rules remained
nft delete table inet zapret 2>/dev/null || true

echo "==> Restoring default DNS..."
rm -f /etc/systemd/resolved.conf.d/dot.conf
systemctl restart systemd-resolved

echo "==> Done. Everything restored to default."
