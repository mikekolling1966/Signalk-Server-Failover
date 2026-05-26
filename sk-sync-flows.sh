#!/bin/bash
# sk-sync-flows.sh
#
# Copies the latest Node-RED flows from rpi4b to rpi5sk.
# Run this any time after editing flows on rpi4b to keep the backup current.
#
# Run from this Mac: bash sk-sync-flows.sh

RPI4B_IP="192.168.1.30"
RPI5SK_IP="192.168.1.10"
USER="pi"
PASS="raspberry"
RED_DIR="/home/pi/.signalk/red"

echo ""
echo "► Syncing Node-RED flows: rpi4b → rpi5sk..."

# Pull from rpi4b
scp "$USER@$RPI4B_IP:$RED_DIR/flows_rpi4b.json" /tmp/flows_rpi4b.json
scp "$USER@$RPI4B_IP:$RED_DIR/flows_rpi4b_cred.json" /tmp/flows_rpi4b_cred.json 2>/dev/null || true

# Check they differ
SRC=$(md5 -q /tmp/flows_rpi4b.json 2>/dev/null || md5sum /tmp/flows_rpi4b.json | cut -d' ' -f1)
DST=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
    "md5sum $RED_DIR/flows_rpi4b.json 2>/dev/null | cut -d' ' -f1" || echo "missing")

if [ "$SRC" = "$DST" ]; then
    echo "  Already up to date — no changes."
else
    # Push to rpi5sk
    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
        /tmp/flows_rpi4b.json "$USER@$RPI5SK_IP:$RED_DIR/flows_rpi4b.json"
    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
        /tmp/flows_rpi4b_cred.json "$USER@$RPI5SK_IP:$RED_DIR/flows_rpi4b_cred.json" 2>/dev/null || true

    echo "  Flows updated. Reloading Node-RED on rpi5sk..."
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$RPI5SK_IP" \
        "sudo systemctl restart signalk"
    echo "  Done."
fi

echo ""
