# sk-connectivity-watchdog — WiFi & Signal K Monitoring

Runs every minute on **rpi5sk** (192.168.1.30) and **DeskPi** (192.168.1.211).  
Detects WiFi drops, attempts automatic reconnection, and captures a full diagnostic
snapshot at the moment of failure so post-incident analysis is possible.

---

## What It Monitors

| Check | rpi5sk | DeskPi |
|-------|--------|--------|
| WiFi association (`MNX_SYSTEMS`) | ✓ | ✓ |
| Auto-reconnect on drop | ✓ | ✓ |
| Signal K service (`signalk.service`) | ✓ | — |
| Network reachability (router ping) | ✓ | — |
| SK port 3000 reachable | — | ✓ |

---

## Log Locations

| Source | How to read |
|--------|-------------|
| `/var/log/sk-watchdog.log` | Plain text, survives reboots, auto-trimmed at 500 KB |
| `journalctl -t sk-watchdog` | Filterable by time, also survives reboots (persistent journal enabled) |

Both logs receive the same entries. The file log is easier to `grep`; journalctl is
better for time-bounded queries after an incident.

---

## Log Format

### Normal (heartbeat every 5 minutes — all OK)
```
2026-05-27 08:00:01 | STATUS: wifi=ok sk_svc=ok net=ok(192.168.1.1) ip=192.168.1.30
```

### WiFi drop — recovered automatically
```
2026-05-27 08:07:01 | WIFI_DOWN: MNX_SYSTEMS not active — reconnecting
2026-05-27 08:07:03 | WIFI_RESTORED: MNX_SYSTEMS reconnected
2026-05-27 08:07:03 | STATUS: wifi=ok sk_svc=ok net=ok(192.168.1.1) ip=192.168.1.30
2026-05-27 08:07:03 | ── DIAG:kernel(journal) ──────────────────────────
2026-05-27 08:07:03 | brcmfmac: brcmf_link_down: disconnected
2026-05-27 08:07:03 | wlan0: deauthenticated from aa:bb:cc:dd:ee:ff
2026-05-27 08:07:03 | ────────────────────────────────────────────
2026-05-27 08:07:03 | ── DIAG:ping-router(192.168.1.1) ──────────────────
2026-05-27 08:07:03 | 2 packets transmitted, 2 received, 0% packet loss
2026-05-27 08:07:03 | ────────────────────────────────────────────
```

### WiFi drop — router unreachable (full network outage)
```
2026-05-27 08:07:01 | WIFI_DOWN: MNX_SYSTEMS not active — reconnecting
2026-05-27 08:07:04 | WIFI_FAILED: Error: Connection activation failed
2026-05-27 08:07:04 | STATUS: wifi=DOWN sk_svc=ok net=DOWN(192.168.1.1) ip=
2026-05-27 08:07:04 | ── DIAG:ping-router(192.168.1.1) ──────────────────
2026-05-27 08:07:04 | 2 packets transmitted, 0 received, 100% packet loss
```

### SK service down (rpi5sk only)
```
2026-05-27 08:07:01 | SK_SVC_DOWN: signalk not running — attempting restart
2026-05-27 08:07:01 | STATUS: wifi=ok sk_svc=DOWN net=ok(192.168.1.1) ip=192.168.1.30
```

---

## Diagnostic Snapshot

On any failure the watchdog immediately captures:

| Block | Content | What it answers |
|-------|---------|-----------------|
| `DIAG:kernel(journal)` | Kernel WiFi events from last 120s | Did the driver log a deauth/disconnect? |
| `DIAG:nmcli-dev` | Interface state table | Which interfaces are up/down/connecting? |
| `DIAG:iw-link` | Current WiFi association details | Signal strength, AP MAC, bitrate |
| `DIAG:ping-router` | 2-ping result to 192.168.1.1 | Is the whole network gone, or just this Pi? |
| `DIAG:ping-sk` | 2-ping result to SK host | Is the SK server reachable at IP level? |

The router ping is the key diagnostic: if it fails, the entire WiFi network is down.
If it succeeds but WiFi association is lost, the problem is local to that Pi.

---

## Post-Incident Queries

```bash
# Everything that went wrong since yesterday
ssh pi@192.168.1.30 "grep -E 'DOWN|FAILED|RESTORED' /var/log/sk-watchdog.log"

# Full incident detail including diagnostic snapshots
ssh pi@192.168.1.30 "grep -A 30 'WIFI_DOWN\|SK_PORT_DOWN' /var/log/sk-watchdog.log | tail -80"

# Time-bounded query via journalctl
ssh pi@192.168.1.30 "journalctl -t sk-watchdog --since '2026-05-27 06:00:00' --until '2026-05-27 07:00:00' --no-pager"

# Same on DeskPi
ssh mike@192.168.1.211 "journalctl -t sk-watchdog --since 'today' --no-pager"
```

---

## Known Failure Modes & Root Causes

### 1. Engine alternator RF interference
**Symptom:** WiFi drops for all devices simultaneously (phone, Mac, DeskPi) when engines are running.  
**Cause:** Alternator generates broadband RF noise via 12V wiring, corrupts the router's WiFi radio.  
**Log signature:** `WIFI_DOWN` + `ping-router: 100% packet loss` (entire network gone).  
**Fix:**
- Ferrite choke on router 12V power lead (preventive)
- Router Ping/Wget Reboot rule (self-recovery in ~10 min if radio locks up)

### 2. WiFi power management (brcmfmac driver)
**Symptom:** Brief WiFi drops without engine running, usually recovers within one minute.  
**Cause:** The Broadcom WiFi driver (`brcmfmac`) on Raspberry Pi enables power save mode by
default (`brcmf_cfg80211_set_power_mgmt: power save enabled`). The chip periodically drops
association to save power and doesn't always cleanly re-associate.  
**Log signature:** `WIFI_DOWN` + `ping-router: 0% packet loss` (router is fine, only the Pi dropped off).  
**Fix applied:** Power save disabled permanently on both rpi5sk and DeskPi:
```
/etc/NetworkManager/conf.d/wifi-power-save-off.conf
  [connection]
  wifi.powersave = 2
```

### 3. Power save glitch triggering router reboot
**Symptom:** All devices lose WiFi briefly even though engines are not running.  
**Cause:** rpi5sk drops WiFi for ~10 seconds (power save, see above). During that window the
router's Ping/Wget Reboot rule fires two consecutive ping failures against 192.168.1.30 and
reboots the entire router — turning a 10-second Pi blip into a full network outage.  
**Fix applied:**
- WiFi power save disabled on rpi5sk (removes the trigger)
- Router ping check for 192.168.1.30: increase packet count to 5 failures before reboot
  *(System → Reboot → Ping/Wget Reboot → 192.168.1.30 rule → Packet Count = 5)*

---

## Crontab Entries

**rpi5sk** (`crontab -l` as `pi`):
```
* * * * * CHECK_LOCAL_SK=1 SK_HOST=localhost /usr/local/bin/sk-connectivity-watchdog.sh
```

**DeskPi** (`crontab -l` as `mike`):
```
* * * * * SK_HOST=192.168.1.30 /usr/local/bin/sk-connectivity-watchdog.sh
```

---

## Installation

The script is deployed to `/usr/local/bin/sk-connectivity-watchdog.sh` on both machines.
To re-deploy from this repo (run from Mac):

```bash
sshpass -p 'raspberry' scp sk-connectivity-watchdog.sh pi@192.168.1.30:/tmp/ && \
sshpass -p 'raspberry' ssh pi@192.168.1.30 "echo 'raspberry' | sudo -S cp /tmp/sk-connectivity-watchdog.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/sk-connectivity-watchdog.sh"

sshpass -p 'password' scp sk-connectivity-watchdog.sh mike@192.168.1.211:/tmp/ && \
sshpass -p 'password' ssh mike@192.168.1.211 "echo 'password' | sudo -S cp /tmp/sk-connectivity-watchdog.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/sk-connectivity-watchdog.sh"
```

### Dependencies on each Pi
- `nmcli` (NetworkManager) — WiFi check and reconnect
- `iw` — WiFi link detail
- `journalctl` — kernel log capture (persistent journal must be enabled)
- `sudo nmcli con up` without password — granted via `/etc/sudoers.d/sk-watchdog-nmcli`

### Persistent journal (required for kernel diag capture)
```bash
# Verify it's set on each Pi
grep Storage /etc/systemd/journald.conf
# Should show: Storage=persistent
```

---

## Router Auto-Reboot Configuration (Teltonika RUT200)

**System → Reboot → Ping/Wget Reboot:**

| Host | Interval | Timeout | Packet Count | Purpose |
|------|----------|---------|--------------|---------|
| 8.8.8.8 | 60 min | 5 sec | 2 | Internet uplink dead |
| 192.168.1.30 | 5 min | 10 sec | 5 | SK server unreachable |

The 192.168.1.30 rule provides a safety net if rpi5sk goes fully offline (not just a WiFi
blip). Packet Count 5 means the server must be unreachable for 25+ minutes before a reboot
is triggered — enough to distinguish a real outage from transient interference.
