# rpi5sk — Signal K Failover Scripts

Scripts for cleanly swapping Signal K primary/backup roles between two Raspberry Pis.

---

## Network Layout

| Machine | Hostname | Normal IP | Normal Role |
|---------|----------|-----------|-------------|
| Primary | rpi4b | `192.168.1.30` | Signal K primary — all instruments |
| Backup | rpi5sk | `192.168.9.244` | Signal K replica — mirrors rpi4b live |

**During failover:**

| Machine | Hostname | Failover IP | Failover Role |
|---------|----------|-------------|---------------|
| Standby | rpi4b | `192.168.1.60` | SK stopped, standing by |
| Primary | rpi5sk | `192.168.1.30` | SK primary on MNX_SYSTEMS |

---

## How the Replication Works

In normal operation, rpi5sk runs Signal K in replica mode. It opens a WebSocket connection to rpi4b (`192.168.1.30:3000`) and pulls a live stream of all SK delta updates. These are written into rpi5sk's own SK store under the vessel's MMSI context, so rpi5sk has a real-time mirror of all instrument data.

If rpi4b goes offline, rpi5sk reconnects automatically once it comes back — no intervention needed.

**Node-RED** runs as the `signalk-node-red` plugin — it is embedded inside Signal K, not a separate service. It starts and stops automatically with SK on whichever Pi is currently primary. No extra steps are needed in the swap scripts.

---

## Prerequisites

- Both Pis powered on and reachable from this Mac
- Mac on a network with routes to both `192.168.1.x` and `192.168.9.x`  
  *(easiest when connected to MNX_SYSTEMS boat WiFi)*
- `sshpass` installed on Mac:
  ```bash
  brew install hudochenkov/sshpass/sshpass
  ```

---

## Scripts

### Mac-side (run these from your Mac)

| Script | Purpose |
|--------|---------|
| `sk-swap-to-backup.sh` | Promote rpi5sk to primary SK |
| `sk-swap-to-primary.sh` | Restore rpi4b to primary SK |
| `sk-swap-dryrun.sh` | Test swap logic without touching WiFi |

### Pi-side (deployed to `/usr/local/bin/` on rpi5sk)

| Script | Command | Purpose |
|--------|---------|---------|
| Failover | `sudo sk-failover.sh` | Connect rpi5sk to MNX_SYSTEMS as `192.168.1.30`, start SK as primary |
| Resume | `sudo sk-resume-backup.sh` | Return rpi5sk to home WiFi, resume replica mode |

---

## Promote rpi5sk to Primary

```bash
bash sk-swap-to-backup.sh
```

**What happens:**
1. Confirms both Pis are reachable
2. Remaps rpi4b: `192.168.1.30` → `192.168.1.60` (SSH drops, reconnects at new IP)
3. Stops Signal K **and** `signalk.socket` on rpi4b (prevents socket-activation restart)
4. Runs `sk-failover.sh` on rpi5sk — joins MNX_SYSTEMS as `192.168.1.30`, starts SK
5. Waits and confirms SK is up at `http://192.168.1.30:3000`

**State after:**
```
rpi4b  → 192.168.1.60  (SK stopped, standing by)
rpi5sk → 192.168.1.30  (SK primary on MNX_SYSTEMS)
```

---

## Restore rpi4b to Primary

```bash
bash sk-swap-to-primary.sh
```

**What happens:**
1. Confirms rpi5sk is at `192.168.1.30` and rpi4b is at `192.168.1.60`
2. Runs `sk-resume-backup.sh` on rpi5sk — disables SK pull, leaves MNX_SYSTEMS, returns to home WiFi
3. Remaps rpi4b: `192.168.1.60` → `192.168.1.30` (SSH drops, reconnects)
4. Starts Signal K on rpi4b
5. Waits and confirms SK is up at `http://192.168.1.30:3000`

**State after:**
```
rpi4b  → 192.168.1.30  (SK primary — normal)
rpi5sk → 192.168.9.244 (SK backup, mirroring rpi4b — normal)
```

---

## Dry-Run Test (no WiFi required)

Tests all swap logic **except** WiFi — safe to run from any network.

```bash
bash sk-swap-dryrun.sh
```

**What it tests:**
- rpi4b IP remap: `192.168.1.30` → `192.168.1.60` → back to `192.168.1.30`
- SK stop / start on rpi4b
- `source-sk` provider disable / re-enable in rpi5sk's `settings.json`

The script pauses at mid-swap state so you can verify, then reverses everything on Enter.

---

## Troubleshooting

### `sshpass` not found
```bash
brew install hudochenkov/sshpass/sshpass
```

### Stuck mid-swap — reset manually

**Put rpi4b back to `192.168.1.30`** (run in your SSH session to it):
```bash
echo 'raspberry' | sudo -S bash -c \
  'nmcli con modify MNX_SYSTEMS ipv4.addresses 192.168.1.30/24 && nmcli con up MNX_SYSTEMS'
```

**Put rpi5sk back to backup mode:**
```bash
sshpass -p 'raspberry' ssh pi@192.168.9.244 "sudo sk-resume-backup.sh"
```

**Start SK on rpi4b:**
```bash
ssh pi@192.168.1.30 "echo 'raspberry' | sudo -S systemctl start signalk"
```

### Check SK status
```bash
# Live status
ssh pi@192.168.1.30 "sudo systemctl status signalk --no-pager"

# Recent logs
ssh pi@192.168.1.30 "sudo journalctl -u signalk -n 30 --no-pager"
```

### signalk.socket reactivation warning
If you see `Stopping signalk.service, but it can still be activated by: signalk.socket` — this is expected on rpi4b. The real swap scripts stop the socket unit too, so SK won't restart unexpectedly during failover.

---

## Notes

- The `^C` printed during IP remaps is harmless — it's the terminal echoing the SSH connection drop when `nmcli` cuts its own session. The script catches it with `|| true`.
- rpi5sk disables its `source-sk` WebSocket pull before taking `192.168.1.30` — this prevents it connecting to itself and looping.
- rpi4b's `signalk.socket` is stopped alongside the service during swap to prevent socket-activation from restarting SK while rpi5sk is primary.
