#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo ./enable.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZAPRET_DIR="/opt/zapret"

echo "==> Syncing zapret files and dependencies..."
mkdir -p "$ZAPRET_DIR/binaries/my" "$ZAPRET_DIR/nfq" "$ZAPRET_DIR/tpws" "$ZAPRET_DIR/ip2net" "$ZAPRET_DIR/mdig" "$ZAPRET_DIR/files/fake"

# Copy library dependencies if present
if [ -f "$SCRIPT_DIR/binaries/my/libnetfilter_queue.so.1" ]; then
    cp -af "$SCRIPT_DIR/binaries/my/libnetfilter_queue"* "$ZAPRET_DIR/binaries/my/" 2>/dev/null || true
    if [ ! -f /usr/lib64/libnetfilter_queue.so.1 ]; then
        cp -af "$SCRIPT_DIR/binaries/my/libnetfilter_queue"* /usr/lib64/ 2>/dev/null || true
        ldconfig 2>/dev/null || true
    fi
fi

# Copy binaries
cp -af "$SCRIPT_DIR/binaries/my/"* "$ZAPRET_DIR/binaries/my/" 2>/dev/null || true
chmod 755 "$ZAPRET_DIR/binaries/my/"* 2>/dev/null || true

# Fix symlinks
ln -sfn ../binaries/my/nfqws "$ZAPRET_DIR/nfq/nfqws"
ln -sfn ../binaries/my/tpws "$ZAPRET_DIR/tpws/tpws"
ln -sfn ../binaries/my/ip2net "$ZAPRET_DIR/ip2net/ip2net"
ln -sfn ../binaries/my/mdig "$ZAPRET_DIR/mdig/mdig"

# Copy fake payload definitions
if [ -d "$SCRIPT_DIR/files/fake" ]; then
    cp -af "$SCRIPT_DIR/files/fake/"* "$ZAPRET_DIR/files/fake/" 2>/dev/null || true
fi

# Copy config
cp -f "$SCRIPT_DIR/config" "$ZAPRET_DIR/config"
chmod 644 "$ZAPRET_DIR/config"

echo "==> Enabling DNS over TLS..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dot.conf << 'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
FallbackDNS=9.9.9.9#dns.quad9.net
DNSOverTLS=yes
EOF
systemctl restart systemd-resolved

echo "==> Starting zapret DPI bypass service..."
systemctl enable zapret
systemctl restart zapret

echo "==> Verifying service status..."
sleep 1
if systemctl is-active --quiet zapret; then
    echo "==> zapret service is ACTIVE and running."
else
    echo "==> WARNING: zapret service is not active. Checking logs:"
    journalctl -u zapret -n 10 --no-pager
    exit 1
fi

echo "==> Testing connectivity..."
if curl -I https://discord.com --connect-timeout 4 -s -o /dev/null; then
    echo "==> Connection to Discord successful!"
else
    echo "==> Note: DNS/routes applied. If Discord app is open, try restarting it."
fi

echo "==> Done. DPI bypass enabled."
