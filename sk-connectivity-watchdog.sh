#!/bin/bash
# sk-connectivity-watchdog.sh
#
# Checks WiFi and SK connectivity every minute.
# Logs to syslog (journalctl -t sk-watchdog) AND /var/log/sk-watchdog.log
#
# On any failure, captures a diagnostic snapshot:
#   - kernel WiFi messages (dmesg)
#   - interface state (nmcli/iw)
#   - router reachability (ping)
#   - SK host reachability (ping)
#
# Config via environment — set in crontab:
#   CHECK_LOCAL_SK=1   → also check local signalk service (SK servers only)
#   SK_HOST=...        → where to test port 3000 (default 192.168.1.30)
#
# Cron examples:
#   rpi5sk:  * * * * * CHECK_LOCAL_SK=1 SK_HOST=localhost /usr/local/bin/sk-connectivity-watchdog.sh
#   rpi4b:   * * * * * CHECK_LOCAL_SK=1 SK_HOST=192.168.1.30 /usr/local/bin/sk-connectivity-watchdog.sh
#   deskpi:  * * * * * SK_HOST=192.168.1.30 /usr/local/bin/sk-connectivity-watchdog.sh

CONN="MNX_SYSTEMS"
SK_HOST="${SK_HOST:-192.168.1.30}"
SK_PORT="3000"
ROUTER="192.168.1.1"
LOG_TAG="sk-watchdog"
LOG_FILE="/var/log/sk-watchdog.log"
CHECK_LOCAL_SK="${CHECK_LOCAL_SK:-0}"

# ── Logging ──────────────────────────────────────────────────────────────────
log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${ts} | ${msg}" >> "$LOG_FILE"
    logger -t "$LOG_TAG" "$msg"
}

# Multi-line diagnostic block — each line prefixed with timestamp + DIAG tag
log_diag() {
    local label="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${ts} | ── DIAG:${label} ──────────────────────────" >> "$LOG_FILE"
    while IFS= read -r line; do
        echo "${ts} | ${line}" >> "$LOG_FILE"
    done
    echo "${ts} | ────────────────────────────────────────────" >> "$LOG_FILE"
}

# ── Diagnostic snapshot (called on any failure) ───────────────────────────────
capture_diag() {
    # 1. Kernel WiFi messages from the last 120 seconds via journalctl
    #    (dmesg only catches boot messages; journalctl -k gives timestamped kernel log)
    journalctl -k --since "120 seconds ago" --no-pager 2>/dev/null | \
        grep -iE 'wlan|brcm|brcmfmac|rfkill|deauth|disassoc|disconnect|auth|assoc|wpa|802\.11' | \
        tail -20 | log_diag "kernel(journal)"

    # 2. Interface state
    nmcli dev status 2>/dev/null | log_diag "nmcli-dev"
    iw dev wlan0 link 2>/dev/null | log_diag "iw-link"

    # 3. Router reachability — is the problem the radio, or something else?
    ping -c 2 -W 2 "$ROUTER" 2>&1 | tail -3 | log_diag "ping-router(${ROUTER})"

    # 4. SK host reachability (skip if SK_HOST is localhost — use router ping instead)
    if [ "$SK_HOST" != "localhost" ] && [ "$SK_HOST" != "127.0.0.1" ]; then
        ping -c 2 -W 2 "$SK_HOST" 2>&1 | tail -3 | log_diag "ping-sk(${SK_HOST})"
    fi
}

# ── Rotate log if > 500KB (keep last 5000 lines) ─────────────────────────────
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")" -gt 512000 ]; then
    tail -5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# ── WiFi check ───────────────────────────────────────────────────────────────
WIFI_OK=0
DIAG_NEEDED=0
if nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -q "^${CONN}:activated"; then
    WIFI_OK=1
else
    DIAG_NEEDED=1
    log "WIFI_DOWN: ${CONN} not active — reconnecting"
    RESULT=$(sudo nmcli con up "$CONN" 2>&1)
    if [ $? -eq 0 ]; then
        log "WIFI_RESTORED: ${CONN} reconnected"
        WIFI_OK=1
    else
        log "WIFI_FAILED: ${RESULT}"
    fi
fi

# ── SK service check (SK servers only) ──────────────────────────────────────
SK_SVC_OK=1
if [ "$CHECK_LOCAL_SK" = "1" ]; then
    if systemctl is-active --quiet signalk 2>/dev/null; then
        SK_SVC_OK=1
    else
        SK_SVC_OK=0
        DIAG_NEEDED=1
        log "SK_SVC_DOWN: signalk not running — attempting restart"
        systemctl start signalk 2>&1 | head -1 | xargs -I{} log "SK_SVC_RESTART: {}" || true
    fi
fi

# ── SK port check ────────────────────────────────────────────────────────────
# On SK servers (CHECK_LOCAL_SK=1), SK_HOST is localhost — checking localhost:3000
# tells us nothing about network reachability, so check the router instead.
SK_PORT_OK=0
SK_CHECK_HOST="$SK_HOST"
if [ "$SK_HOST" = "localhost" ] || [ "$SK_HOST" = "127.0.0.1" ]; then
    SK_CHECK_HOST="$ROUTER"
    if ping -c 1 -W 3 "$ROUTER" >/dev/null 2>&1; then
        SK_PORT_OK=1
    else
        DIAG_NEEDED=1
        log "ROUTER_UNREACHABLE: cannot ping ${ROUTER} — network is down"
    fi
else
    if bash -c "echo >/dev/tcp/${SK_HOST}/${SK_PORT}" 2>/dev/null; then
        SK_PORT_OK=1
    else
        DIAG_NEEDED=1
        log "SK_PORT_DOWN: cannot reach ${SK_HOST}:${SK_PORT}"
    fi
fi

# ── Status summary (every 5 min or on any issue) ─────────────────────────────
WIFI_STR=$( [ $WIFI_OK    -eq 1 ] && echo "ok"   || echo "DOWN" )
SVC_STR=$(  [ $SK_SVC_OK  -eq 1 ] && echo "ok"   || echo "DOWN" )
PORT_STR=$( [ $SK_PORT_OK -eq 1 ] && echo "ok"   || echo "DOWN" )
IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^169\.254\.' | head -1)
MINUTE=$(( 10#$(date +%M) % 5 ))

ANY_DOWN=0
[ $WIFI_OK    -eq 0 ] && ANY_DOWN=1
[ $SK_SVC_OK  -eq 0 ] && ANY_DOWN=1
[ $SK_PORT_OK -eq 0 ] && ANY_DOWN=1

if [ $ANY_DOWN -eq 1 ] || [ "$MINUTE" -eq 0 ]; then
    log "STATUS: wifi=${WIFI_STR} sk_svc=${SVC_STR} net=${PORT_STR}(${SK_CHECK_HOST}) ip=${IP}"
fi

# ── Diagnostic snapshot on any failure ───────────────────────────────────────
if [ "$DIAG_NEEDED" -eq 1 ]; then
    capture_diag
fi
