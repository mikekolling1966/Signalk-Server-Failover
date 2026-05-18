#!/bin/bash
# Run with: sudo sk-resume-backup.sh
# Returns this machine (rpi5sk) to backup/replica mode.
# Re-enables the source-sk WebSocket pull and removes the boat WiFi connection.
set -e

SETTINGS="/home/pi/.signalk/settings.json"
CONN_NAME="boat-failover"

echo "=== SK Resume: returning to backup mode ==="

echo "► Re-enabling source-sk WebSocket pull..."
python3 -c "
import json
with open('$SETTINGS') as f:
    cfg = json.load(f)
for p in cfg['pipedProviders']:
    if p['id'] == 'source-sk':
        p['enabled'] = True
with open('$SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
print('  source-sk re-enabled')
"

echo "► Removing boat WiFi connection..."
nmcli con delete "$CONN_NAME" 2>/dev/null && echo "  boat-failover connection removed" || echo "  (not found, skipping)"

echo "► Restarting Signal K..."
systemctl restart signalk

echo ""
echo "Backup mode restored — pulling live data from 192.168.1.30"
