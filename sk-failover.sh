#!/bin/bash
# Run with: sudo sk-failover.sh
# Promotes this machine (rpi5sk) to primary SK.
# Connects to MNX_SYSTEMS with static IP 192.168.1.30 and restarts Signal K.
set -e

SETTINGS="/home/pi/.signalk/settings.json"
BOAT_SSID="MNX_SYSTEMS"
BOAT_PSK="broomcrown37??"
BOAT_IP="192.168.1.30/24"
BOAT_GW="192.168.1.1"
CONN_NAME="boat-failover"

echo "=== SK Failover: promoting this machine to primary ==="

echo "► Disabling source-sk WebSocket pull..."
python3 -c "
import json
with open('$SETTINGS') as f:
    cfg = json.load(f)
for p in cfg['pipedProviders']:
    if p['id'] == 'source-sk':
        p['enabled'] = False
with open('$SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  source-sk disabled')
"

echo "► Setting up WiFi connection to $BOAT_SSID with static IP..."
nmcli con delete "$CONN_NAME" 2>/dev/null || true

nmcli con add type wifi \
    con-name "$CONN_NAME" \
    ssid "$BOAT_SSID" \
    -- \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$BOAT_PSK" \
    ipv4.method manual \
    ipv4.addresses "$BOAT_IP" \
    ipv4.gateway "$BOAT_GW" \
    ipv4.dns "8.8.8.8 $BOAT_GW"

nmcli con up "$CONN_NAME"
echo "  Connected to $BOAT_SSID as 192.168.1.30"

echo "► Restarting Signal K..."
systemctl restart signalk

echo ""
echo "Failover complete — this machine is now primary SK"
echo "  http://192.168.1.30:3000"
echo ""
echo "When original is restored: run  sudo sk-resume-backup.sh"
