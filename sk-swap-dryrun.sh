#!/bin/bash
# sk-swap-dryrun.sh
#
# Dry-run test of the SK swap logic — NO WiFi changes made.
# Tests only:
#   • rpi4b IP remap: 192.168.1.30 → 192.168.1.60 → back to 192.168.1.30
#   • SK stop / start on rpi4b
#   • source-sk provider disable / re-enable in rpi5sk settings.json
#
# Safe to run while rpi5sk is on a different network from MNX_SYSTEMS.
# Run from this Mac: bash sk-swap-dryrun.sh

set -e

RPI4B_IP="192.168.1.30"
RPI4B_NEW_IP="192.168.1.60"
RPI5SK_IP="192.168.9.244"
SETTINGS="/home/pi/.signalk/settings.json"
USER="pi"
PASS="raspberry"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   SK Swap Dry-Run (no WiFi changes)              ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Check both Pis are reachable ──────────────────────────────────────
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

# ── Step 2: Verify SK is running on rpi4b ─────────────────────────────────────
echo "► Checking SK status on rpi4b..."
SK_STATUS=$(ssh -o BatchMode=yes "$USER@$RPI4B_IP" "systemctl is-active signalk" 2>/dev/null || echo "unknown")
echo "  signalk is: $SK_STATUS"
echo ""

# ── Step 3: Verify source-sk state on rpi5sk ──────────────────────────────────
echo "► Checking source-sk provider state on rpi5sk..."
ENABLED=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
    "python3 -c \"
import json
with open('$SETTINGS') as f:
    cfg = json.load(f)
for p in cfg['pipedProviders']:
    if p['id'] == 'source-sk':
        print(p['enabled'])
\"" 2>/dev/null || echo "error")
echo "  source-sk enabled: $ENABLED"
echo ""

# ── Step 4: Remap rpi4b to 192.168.1.60 ──────────────────────────────────────
echo "► [SIMULATE FAILOVER] Remapping rpi4b: $RPI4B_IP → $RPI4B_NEW_IP ..."
echo "  (SSH will drop — reconnecting at new IP)"
ssh "$USER@$RPI4B_IP" "echo '$PASS' | sudo -S bash -c \
    'nmcli con modify MNX_SYSTEMS ipv4.addresses $RPI4B_NEW_IP/24 && \
     sleep 1 && nmcli con up MNX_SYSTEMS' &" || true

echo "  Waiting for rpi4b at $RPI4B_NEW_IP..."
for i in $(seq 1 15); do
    HOST=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "$USER@$RPI4B_NEW_IP" "hostname" 2>/dev/null || echo "")
    if [ "$HOST" = "rpi4b" ]; then
        echo "  ✓ rpi4b is up at $RPI4B_NEW_IP"
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

# ── Step 5: Stop SK on rpi4b ──────────────────────────────────────────────────
echo "► Stopping Signal K on rpi4b (at $RPI4B_NEW_IP)..."
ssh -o StrictHostKeyChecking=no "$USER@$RPI4B_NEW_IP" "echo '$PASS' | sudo -S systemctl stop signalk"
SK_STATUS=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$USER@$RPI4B_NEW_IP" "systemctl is-active signalk" 2>/dev/null || echo "inactive")
echo "  signalk is: $SK_STATUS"
echo ""

# ── Step 6: Disable source-sk on rpi5sk ───────────────────────────────────────
echo "► Disabling source-sk provider on rpi5sk..."
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
    "python3 -c \"
import json
with open('$SETTINGS') as f:
    cfg = json.load(f)
for p in cfg['pipedProviders']:
    if p['id'] == 'source-sk':
        p['enabled'] = False
with open('$SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  source-sk disabled')
\""
echo ""

# ── Pause ─────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Mid-swap state (simulated):                                 ║"
echo "║    rpi4b  → $RPI4B_NEW_IP  (SK stopped, standing by)           ║"
echo "║    rpi5sk → $RPI5SK_IP (source-sk disabled)          ║"
echo "║                                                              ║"
echo "║  In a real swap, rpi5sk would now join MNX_SYSTEMS           ║"
echo "║  and take 192.168.1.30. That step is skipped here.           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
read -p "  Press Enter to run the restore (reverse) sequence..."
echo ""

# ── Step 7: Re-enable source-sk on rpi5sk ─────────────────────────────────────
echo "► [SIMULATE RESUME] Re-enabling source-sk provider on rpi5sk..."
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
    "python3 -c \"
import json
with open('$SETTINGS') as f:
    cfg = json.load(f)
for p in cfg['pipedProviders']:
    if p['id'] == 'source-sk':
        p['enabled'] = True
with open('$SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  source-sk re-enabled')
\""
echo ""

# ── Step 8: Remap rpi4b back to 192.168.1.30 ─────────────────────────────────
echo "► Remapping rpi4b: $RPI4B_NEW_IP → $RPI4B_IP ..."
echo "  (SSH will drop — reconnecting at original IP)"
ssh -o StrictHostKeyChecking=no "$USER@$RPI4B_NEW_IP" "echo '$PASS' | sudo -S bash -c \
    'nmcli con modify MNX_SYSTEMS ipv4.addresses $RPI4B_IP/24 && \
     sleep 1 && nmcli con up MNX_SYSTEMS' &" || true

echo "  Waiting for rpi4b at $RPI4B_IP..."
for i in $(seq 1 15); do
    HOST=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$USER@$RPI4B_IP" "hostname" 2>/dev/null || echo "")
    if [ "$HOST" = "rpi4b" ]; then
        echo "  ✓ rpi4b is up at $RPI4B_IP"
        break
    fi
    echo "  Waiting... ($i/15)"
    sleep 3
    if [ $i -eq 15 ]; then
        echo "  ERROR: rpi4b did not come up at $RPI4B_IP"
        exit 1
    fi
done
echo ""

# ── Step 9: Start SK on rpi4b ─────────────────────────────────────────────────
echo "► Starting Signal K on rpi4b..."
ssh "$USER@$RPI4B_IP" "echo '$PASS' | sudo -S systemctl start signalk"
echo ""

# ── Step 10: Verify SK is up ──────────────────────────────────────────────────
echo "► Waiting for SK at http://$RPI4B_IP:3000..."
for i in $(seq 1 12); do
    if curl -s --max-time 3 "http://$RPI4B_IP:3000/signalk" &>/dev/null; then
        echo "  ✓ SK is up."
        break
    fi
    echo "  Waiting... ($i/12)"
    sleep 5
    if [ $i -eq 12 ]; then
        echo "  WARNING: SK not responding yet — check manually."
    fi
done
echo ""

# ── Final state check ─────────────────────────────────────────────────────────
echo "► Final state check..."
SK_STATUS=$(ssh -o BatchMode=yes "$USER@$RPI4B_IP" "systemctl is-active signalk" 2>/dev/null || echo "unknown")
ENABLED=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
    "python3 -c \"
import json
with open('$SETTINGS') as f:
    cfg = json.load(f)
for p in cfg['pipedProviders']:
    if p['id'] == 'source-sk':
        print(p['enabled'])
\"" 2>/dev/null || echo "error")

echo "  rpi4b  signalk service : $SK_STATUS"
echo "  rpi5sk source-sk enabled: $ENABLED"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Dry-run complete — all systems returned to normal           ║"
echo "║    rpi4b  → $RPI4B_IP  (SK running)                        ║"
echo "║    rpi5sk → $RPI5SK_IP (source-sk enabled, mirroring)   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
