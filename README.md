# rpi5sk — Boat Network, SignalK & Remote Access

Scripts and documentation for the boat's shore network, SignalK servers, Tailscale remote access, and router setup.

---

## Current Network State (updated 2026-05-29)

> **Note:** rpi5sk is now the **permanent primary** SignalK server. It took over rpi4b's IP (.30). The failover scripts below are retained but rpi4b may be decommissioned.

| Device | Hostname | IP | Role |
|--------|----------|----|------|
| Teltonika RUT200 | — | 192.168.1.1 | Router/AP — 4G + WiFi (MNX_SYSTEMS) |
| rpi5sk | rpi5sk | 192.168.1.30 | **PRIMARY** SignalK + TidalPlan (:8081) |
| Home Assistant | — | 192.168.1.40 | HA + MQTT broker + Tailscale backup subnet router |
| Pi Zero 2W | rpi02wtailscale | 192.168.1.165 | Tailscale subnet router only |
| rpi5b (DeskPi) | rpi5b | 192.168.1.211 | OpenCPN + DashboardSK display |
| Halmet | — | 192.168.1.227 | ESP32 reading engine gauges → SK |
| EW10_COMPASS | — | 192.168.1.155 | Elfin WiFi-serial bridge → compass |
| EW10_GARMIN | — | 192.168.1.184 | Elfin WiFi-serial bridge → Garmin |
| EW11_AIS | — | 192.168.1.248 | Elfin WiFi-serial bridge → AIS |
| EW11_WIND | — | 192.168.1.142 | Elfin WiFi-serial bridge → wind |

### SSH Access

| Device | Local | Remote (via Tailscale) |
|--------|-------|----------------------|
| rpi5sk | `ssh pi@192.168.1.30` | `ssh pi@100.75.173.122` |
| Router | `ssh root@192.168.1.1` | `ssh -J pi@100.75.173.122 root@192.168.1.1` |
| Pi Zero | `ssh pi@192.168.1.165` | `ssh pi@100.114.4.35` |

All Pi passwords: `raspberry`. Router password: `Br00mCr0wn??`

---

## What Went Wrong — 48 Hours of Debugging (2026-05-28/29)

### Problem: Months of Intermittent WiFi Outages

All WiFi clients (Elfins, Pi Zero, Halmet, rpi5sk) were dropping every few minutes for ~20 seconds. Elfins don't auto-reconnect after a drop, requiring manual reboots each time. This had been ongoing for months and was initially attributed to the router's location, hardware failure, or a firmware update.

### Root Cause: ACS (Automatic Channel Selection)

The Teltonika RUT200 wireless config had `option channel 'auto'`, which enables ACS — Automatic Channel Selection. ACS intentionally kills the AP while it scans all channels to find the least congested one, then restarts the AP on the chosen channel. This takes ~20 seconds and drops every client.

Evidence from the router's `hostapd.log` (extracted from the troubleshoot archive):

```
[315s] CTRL-EVENT-TERMINATING
[315s] AP-DISABLED
[318s] ACS started
[338s] ACS-COMPLETED freq=2447 channel=8
[338s] AP-ENABLED
```

This was happening repeatedly, on a cycle driven by ACS. Not hardware failure. Not firmware. One misconfigured line.

**Why Teltonika defaults to `auto`:** The RUT200 is designed for fleet vehicles — ACS makes sense when driving between locations. It's the wrong default for a fixed marine installation.

### Fix

```bash
ssh root@192.168.1.1   # password: Br00mCr0wn??
uci set wireless.radio0.channel='6'
uci commit wireless
wifi
```

Fixed on channel 6. Zero AP-DISABLED events in the first overnight test.

**If you get interference from neighbours on ch6 at a marina** (only 3 non-overlapping 2.4GHz channels: 1, 6, 11):
```bash
uci set wireless.radio0.channel='1'   # or 11
uci commit wireless
wifi
```

---

## Tailscale Remote Access Setup

Tailscale provides remote access to the boat's 192.168.1.x network from anywhere.

### Architecture

| Device | Tailscale IP | Role |
|--------|-------------|------|
| raspberrypi-zero | 100.114.4.35 | **PRIMARY** subnet router for 192.168.1.0/24 |
| homeassistant-boat | — | **BACKUP** subnet router for 192.168.1.0/24 |
| rpi5sk | 100.75.173.122 | SSH only — NO subnet routing |
| Mac | 100.74.41.121 | Client |

### Pi Zero — Primary Subnet Router

```bash
tailscale up --accept-routes --advertise-routes=192.168.1.0/24 --accept-dns=false --hostname=raspberrypi-zero --ssh
```

Approve the route in the Tailscale admin console. The Pi Zero is physically adjacent to the router so signal is not an issue.

### rpi5sk — SSH Only

```bash
tailscale up --reset --ssh --accept-dns=false --hostname=rpi5sk
```

> ⚠️ **CRITICAL — NEVER add `--advertise-routes` to rpi5sk.**
>
> Adding subnet routing to rpi5sk causes Tailscale to insert `192.168.1.0/24 dev tailscale0` into routing table 52. IP rule `5270: from all lookup 52` runs **before** the main routing table, so SK's replies to Elfins (192.168.1.x) get routed via tailscale0 instead of wlan0 — breaking all instrument connectivity. This was confirmed by hours of painful debugging.

### HA — Backup Subnet Router

Configured via HA Tailscale addon:
```yaml
local_subnets:
  - 192.168.1.0/24
userspace_networking: true
snat_subnet_routes: true
accept_dns: false
```

`userspace_networking: true` means HA's Tailscale doesn't touch the kernel routing table — safe for all HA services. Approve the route in the admin console.

### Mac Client

```bash
sudo tailscale up --accept-routes --reset
```

Use SSH or HTTP to test connectivity — ICMP (ping) is unreliable through subnet routing.

---

## Router Syslog Forwarding

The router streams syslog to rpi5sk via UDP 514. Logs are saved to `/var/log/router.log` and rotated daily for 14 days.

### Check for WiFi crashes

```bash
ssh pi@100.75.173.122 'grep -E "AP-DISABLED|ACS|CTRL-EVENT-TERMINATING" /var/log/router.log'
```

No output = no crashes. Any `AP-DISABLED` lines with a following `ACS started` = ACS crash (should not happen now channel is fixed).

### Router UCI log config (already applied)

```bash
uci set log.remote=remote_logger
uci set log.remote.log_ip='192.168.1.30'
uci set log.remote.log_port='514'
uci set log.remote.log_proto='udp'
uci set log.remote.log_remote='1'
uci commit log
```

---

## Monitoring on rpi5sk

| Log | Content |
|-----|---------|
| `/var/log/router.log` | Router syslog — WiFi events, DHCP, SSH logins |
| `/var/log/halmet_watchdog.log` | Halmet (engine gauges ESP32) connectivity |
| `/var/log/sk-watchdog.log` | SignalK watchdog |

---

## Pending / Future Work

- **GL.iNet MT3000 repeater** — on order. Will act as dedicated WiFi AP bridged off Teltonika LAN port, letting Teltonika handle 4G only. Will eliminate any remaining WiFi concerns.
- **Halmet on Shelly 1 Gen4** — for remote power cycle via HA if Halmet hangs (same pattern as Kvaser).
- **Change default passwords** — Pi Zero and rpi5sk both still using `raspberry`.

---

## SignalK Failover Scripts

Scripts for swapping SignalK primary/backup roles (retained from original setup).

### Scripts

| Script | Purpose |
|--------|---------|
| `sk-swap-to-backup.sh` | Promote rpi5sk to primary SK |
| `sk-swap-to-primary.sh` | Restore rpi4b to primary SK |
| `sk-swap-dryrun.sh` | Test swap logic without touching WiFi |
| `sk-sync-flows.sh` | Sync Node-RED flows from rpi4b to rpi5sk |

### Prerequisites

```bash
brew install hudochenkov/sshpass/sshpass
```

### Promote rpi5sk to Primary

```bash
bash sk-swap-to-backup.sh
```

1. Remaps rpi4b: `192.168.1.30` → `192.168.1.60`
2. Stops SignalK on rpi4b
3. Syncs Node-RED flows to rpi5sk
4. Connects rpi5sk to MNX_SYSTEMS as `192.168.1.30`, starts SK

### Restore rpi4b to Primary

```bash
bash sk-swap-to-primary.sh
```

1. Runs `sk-resume-backup.sh` on rpi5sk
2. Remaps rpi4b: `192.168.1.60` → `192.168.1.30`
3. Starts SignalK on rpi4b

### Troubleshooting — Stuck Mid-Swap

**Reset rpi4b to `.30`:**
```bash
echo 'raspberry' | sudo -S bash -c \
  'nmcli con modify MNX_SYSTEMS ipv4.addresses 192.168.1.30/24 && nmcli con up MNX_SYSTEMS'
```

**Reset rpi5sk to backup:**
```bash
sshpass -p 'raspberry' ssh pi@192.168.1.10 "sudo sk-resume-backup.sh"
```

**Check SK status:**
```bash
ssh pi@192.168.1.30 "sudo systemctl status signalk --no-pager"
ssh pi@192.168.1.30 "sudo journalctl -u signalk -n 30 --no-pager"
```
