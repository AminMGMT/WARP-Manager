[← back to README](../README.md)

# Menu Reference

```bash
sudo wm          # or: sudo warp-manager
```

```text
1. WARP ● ON
    1. Choose Services
    2. Custom Domains
    3. White Lists
    4. Connection
        1. Change IP
        2. Auto IP Health
        3. QUIC Handling
        4. Client Traffic
        5. Diagnose
    5. Automation
        1. Auto Restart
        2. Refresh Routes
    6. Presets
        1. Export Preset
        2. Import Preset
        3. Import WARP Account
    7. WARP+ License
    8. Status
    9. Restart WARP

2. Ad Blocker ○ OFF
3. Restart All Services
4. Update
5. Uninstall
6. Exit
```

---

## Choose Services

Pick which services go through WARP. Over **100 providers** across AI, Streaming, Social
Media, Gaming, Developer Tools and more — see [Providers](providers.md).

```text
Choose Services      21 of 105 selected

1. ◐ AI
2. ○ Music
3. ○ Social Media
...

a  Select All
n  Select None
i  Invert Selection
0  Apply & Back
```

Input accepts a single number, a list, or a range:

```text
3
1 5 9
2-7
```

Categories with a single provider (such as **All Google Services**) toggle immediately
instead of opening a submenu.

## Custom Domains

Any domain not covered by the built-in database, one per line:

```text
example.com
api.example.com
```

## White Lists

Domains the Ad Blocker must never block — useful when a site needs a tracking or analytics
domain to function. See [Ad Blocker](ad-blocker.md).

## Connection

Everything about the tunnel itself.

| Entry | What it does |
|---|---|
| **Change IP** | Request a new WARP exit IP (keeps your WARP+ license). |
| **Auto IP Health** | Periodically verifies the exit is still usable and rotates it when it is not. |
| **QUIC Handling** | `route` sends UDP 443 through the engine; `light` drops it so clients fall back to TCP — less load on a busy relay. |
| **Client Traffic** | Whether traffic *routed through* the box (OpenVPN, WireGuard server, bridged containers) is intercepted too. See [How It Works](how-it-works.md#which-traffic-gets-intercepted). |
| **Diagnose** | Shows every traffic path on the server and whether it is intercepted. See [Troubleshooting](troubleshooting.md). |

### Auto IP Health

A new WARP IP is requested only when WARP is connected, the VPS has normal internet, and the
current exit is unavailable or in a blocked region. Rotations are rate-limited on purpose so
Cloudflare does not start refusing them.

## Automation

Scheduled WARP restart and route refresh — keeps long-running servers healthy without
manual intervention.

## Presets

Move a whole configuration between servers. A preset carries the selected services, custom
domains, white list, Ad Blocker settings, QUIC mode, Client Traffic mode, Auto Restart, Auto
IP Health, and optionally the WARP+ license.

```bash
# straight from one server to another
ssh b "warp-manager --import-preset $(ssh a warp-manager --export-preset)"
```

**Import WARP Account** copies a `wgcf-account.toml` from a working server — the way around
a rate-limited registration.

## WARP+ License

Apply or replace a Cloudflare WARP+ license. It is preserved across IP changes.

## Status

WARP state and exit IP, location, engine status, redirect status, client-traffic coverage,
Ad Blocker state, and the list of selected services.

## Restart WARP / Restart All Services

**Restart WARP** restarts just the tunnel and rebuilds the routing engine behind it.
**Restart All Services** does WARP, sing-box, the nftables rules and the background timers.

---

## Command line

| Command | |
|---|---|
| `warp-manager` | interactive menu (`wm` is a shorthand) |
| `--status` / `--diagnose` | one-line status / full traffic-path report |
| `--up` / `--down` / `--refresh` | start, stop, re-apply the engine |
| `--change-ip` / `--location` | request a new WARP IP / show where the current one is |
| `--license KEY` | apply a WARP+ license |
| `--import-account FILE` | import a `wgcf-account.toml` |
| `--export-preset [--no-license\|FILE]` | print or write this server's preset |
| `--import-preset CODE\|FILE` | apply a preset and restart the engine |
| `--adblock-update` | refresh the ad-blocker list now |
| `--ip-check` / `--auto-restart` | run the scheduled job now |
| `--update` | update to the latest version, keeping your config |
| `--purge` / `--leftovers` | remove everything / list anything still present |
