#!/bin/bash
# sk-swap-to-primary.sh
#
# Restores SK roles:
#   rpi5sk 192.168.1.30 → resumes backup mode, returns to home WiFi
#   rpi4b  192.168.1.60 → remapped back to 192.168.1.30, SK started
#
# Run from this Mac: bash sk-swap-to-primary.sh
# Prerequisite: sk-swap-to-backup.sh must have been run first.

set -e

RPI4B_TEMP_IP="192.168.1.60"
RPI4B_NORMAL_IP="192.168.1.30"
BOAT_IP="192.168.1.30"          # rpi5sk will be here after swap
USER="pi"
PASS="raspberry"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   SK Swap: rpi4b → Primary               ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: Verify rpi5sk is at 192.168.1.30 ──────────────────────────────
echo "► Checking who is at $BOAT_IP..."
CURRENT_HOST=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER@$BOAT_IP" "hostname" 2>/dev/null || echo "unreachable")

if [ "$CURRENT_HOST" = "unreachable" ]; then
    echo "  ERROR: Nothing reachable at $BOAT_IP — is rpi5sk running as primary?"
    exit 1
fi
echo "  Found: $CURRENT_HOST at $BOAT_IP"

if [ "$CURRENT_HOST" != "rpi5sk" ]; then
    echo "  WARNING: Expected rpi5sk but found $CURRENT_HOST."
    read -p "  Continue anyway? [y/N] " CONFIRM
    [ "$CONFIRM" = "y" ] || exit 1
fi
echo ""

# ── Step 2: Check rpi4b is reachable at temp IP ────────────────────────────
echo "► Checking rpi4b at $RPI4B_TEMP_IP..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER@$RPI4B_TEMP_IP" "hostname" &>/dev/null; then
    echo "  ERROR: Cannot reach rpi4b at $RPI4B_TEMP_IP"
    echo "  Was sk-swap-to-backup.sh run? Is rpi4b powered on?"
    exit 1
fi
echo "  rpi4b is at $RPI4B_TEMP_IP — OK"
echo ""

# ── Step 3: Return rpi5sk to backup mode ──────────────────────────────────
echo "► Returning rpi5sk to backup mode..."
echo "  (SSH to $BOAT_IP will drop as rpi5sk leaves MNX_SYSTEMS)"
ssh "$USER@$BOAT_IP" "echo '$PASS' | sudo -S sk-resume-backup.sh" || true
echo ""

# ── Step 4: Remap rpi4b back to 192.168.1.30 ──────────────────────────────
echo "► Remapping rpi4b: $RPI4B_TEMP_IP → $RPI4B_NORMAL_IP ..."
echo "  (SSH will drop — reconnecting at new IP)"
ssh -o ConnectTimeout=10 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$USER@$RPI4B_TEMP_IP" "echo '$PASS' | sudo -S bash -c \
    'nmcli con modify MNX_SYSTEMS ipv4.addresses $RPI4B_NORMAL_IP/24 && \
     sleep 1 && nmcli con up MNX_SYSTEMS > /dev/null 2>&1 &' && sleep 2" || true

echo "  Waiting for rpi4b at $RPI4B_NORMAL_IP..."
for i in $(seq 1 15); do
    HOST=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "$USER@$RPI4B_NORMAL_IP" "hostname" 2>/dev/null || echo "")
    if [ "$HOST" = "rpi4b" ]; then
        echo "  rpi4b is up at $RPI4B_NORMAL_IP"
        break
    fi
    echo "  Waiting... ($i/15)"
    sleep 3
    if [ $i -eq 15 ]; then
        echo "  ERROR: rpi4b did not come up at $RPI4B_NORMAL_IP"
        exit 1
    fi
done
echo ""

# ── Step 5: Start SK on rpi4b ──────────────────────────────────────────────
echo "► Starting Signal K on rpi4b..."
ssh -o StrictHostKeyChecking=no "$USER@$RPI4B_NORMAL_IP" \
    "echo '$PASS' | sudo -S bash -c 'systemctl start signalk.socket 2>/dev/null; systemctl start signalk'"
echo ""

# ── Step 6: Verify ────────────────────────────────────────────────────────
echo "► Waiting for SK at http://$RPI4B_NORMAL_IP:3000..."
for i in $(seq 1 12); do
    if curl -s --max-time 3 "http://$RPI4B_NORMAL_IP:3000/signalk" &>/dev/null; then
        echo "  SK is up."
        break
    fi
    echo "  Waiting... ($i/12)"
    sleep 5
    if [ $i -eq 12 ]; then
        echo "  WARNING: SK not responding yet — check manually."
    fi
done
echo ""

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Swap complete                                       ║"
echo "║  rpi4b  → primary SK at http://192.168.1.30:3000    ║"
echo "║  rpi5sk → backup, mirroring rpi4b                   ║"
echo "╚══════════════════════════════════════════════════════╝"
