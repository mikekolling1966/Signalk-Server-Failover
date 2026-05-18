#!/bin/bash
# sk-swap-to-backup.sh
#
# Swaps SK roles:
#   rpi4b  192.168.1.30 → remapped to 192.168.1.60, SK stopped
#   rpi5sk 192.168.9.244 → takes 192.168.1.30 on MNX_SYSTEMS, SK primary
#
# Run from this Mac: bash sk-swap-to-backup.sh

set -e

RPI4B_IP="192.168.1.30"
RPI4B_NEW_IP="192.168.1.60"
RPI5SK_IP="192.168.9.244"
USER="pi"
PASS="raspberry"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   SK Swap: rpi5sk → Primary              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: Check both Pis are reachable ───────────────────────────────────
echo "► Checking connectivity..."

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER@$RPI4B_IP" "hostname" &>/dev/null; then
    echo "  ERROR: Cannot reach rpi4b at $RPI4B_IP"
    exit 1
fi
echo "  rpi4b  ($RPI4B_IP) — reachable"

if ! sshpass -p "$PASS" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" "hostname" &>/dev/null; then
    echo "  ERROR: Cannot reach rpi5sk at $RPI5SK_IP"
    exit 1
fi
echo "  rpi5sk ($RPI5SK_IP) — reachable"
echo ""

# ── Step 2: Remap rpi4b to 192.168.1.60 ───────────────────────────────────
echo "► Remapping rpi4b: 192.168.1.30 → $RPI4B_NEW_IP ..."
echo "  (SSH will drop — reconnecting at new IP)"
ssh "$USER@$RPI4B_IP" "echo '$PASS' | sudo -S bash -c \
    'nmcli con modify MNX_SYSTEMS ipv4.addresses $RPI4B_NEW_IP/24 && \
     sleep 1 && nmcli con up MNX_SYSTEMS' &" || true

echo "  Waiting for rpi4b at $RPI4B_NEW_IP..."
for i in $(seq 1 15); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "$USER@$RPI4B_NEW_IP" "hostname" &>/dev/null; then
        echo "  rpi4b is up at $RPI4B_NEW_IP"
        break
    fi
    echo "  Waiting... ($i/15)"
    sleep 3
    if [ $i -eq 15 ]; then
        echo "  ERROR: rpi4b did not come up at $RPI4B_NEW_IP"
        exit 1
    fi
done
echo ""

# ── Step 3: Stop SK on rpi4b ───────────────────────────────────────────────
echo "► Stopping Signal K on rpi4b (service + socket)..."
ssh -o StrictHostKeyChecking=no "$USER@$RPI4B_NEW_IP" \
    "echo '$PASS' | sudo -S bash -c 'systemctl stop signalk.socket 2>/dev/null; systemctl stop signalk'"
echo "  Done."
echo ""

# ── Step 4: Promote rpi5sk to primary ─────────────────────────────────────
echo "► Promoting rpi5sk to primary (connecting to MNX_SYSTEMS as 192.168.1.30)..."
echo "  (SSH to $RPI5SK_IP will drop as WiFi switches)"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
    "echo '$PASS' | sudo -S sk-failover.sh" || true
echo ""

# ── Step 5: Wait for SK at 192.168.1.30 ────────────────────────────────────
echo "► Waiting for SK at http://192.168.1.30:3000..."
for i in $(seq 1 15); do
    if curl -s --max-time 3 "http://192.168.1.30:3000/signalk" &>/dev/null; then
        echo "  SK is up."
        break
    fi
    echo "  Waiting... ($i/15)"
    sleep 5
    if [ $i -eq 15 ]; then
        echo "  WARNING: SK not responding yet — check manually."
    fi
done
echo ""

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Swap complete                                       ║"
echo "║  rpi5sk → primary SK at http://192.168.1.30:3000    ║"
echo "║  rpi4b  → standing by at 192.168.1.60 (SK stopped)  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "To restore: bash sk-swap-to-primary.sh"
