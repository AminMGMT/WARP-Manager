[← back to README](../README.md)

# How It Works

## The problem

Many VPS providers cannot reach services such as **Gemini**, and others are rate-limited or
geo-restricted. Sending everything through Cloudflare WARP fixes that but changes the
server's exit IP for *all* traffic, which is usually not what you want.

WARP Manager routes **only the services you choose** through WARP. Every other connection
keeps the VPS's normal public IP, and your existing tunnel, proxy and panel stay untouched.

---

## Architecture

```
                              Client
                                 │
                        (Tunnel / VPN / Proxy)
                                 │
                                 ▼
┌────────────────────────────── VPS ──────────────────────────────┐
│                                                                 │
│               Outbound TCP 80/443 + UDP 443                     │
│                            │                                    │
│                            ▼                                    │
│                    nftables TPROXY                              │
│                            │                                    │
│                            ▼                                    │
│                      sing-box Engine                            │
│                (TLS SNI + QUIC Inspection)                      │
│                            │                                    │
│              ┌─────────────┴─────────────┐                      │
│              │                           │                      │
│       Selected Services           Everything Else               │
│              │                           │                      │
│              ▼                           ▼                      │
│      Cloudflare WARP              Native Server IP              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

WARP Manager intercepts the VPS's HTTP/HTTPS traffic with **nftables TPROXY** and hands it
to a local **sing-box**.

Instead of routing by IP, sing-box reads the real destination domain from the TLS **Server
Name Indication (SNI)** and the **QUIC ClientHello**. Matching connections go out through
the WARP WireGuard interface; everything else leaves through the normal interface. Because
the decision is made per domain, applications keep working when their backend IPs or CDNs
change.

---

## Which traffic gets intercepted

There are two ways users' traffic can leave the server, and each needs its own nftables hook:

| Path | Who works this way | Hook |
|---|---|---|
| **Local** — the server opens the connection to the site itself | Xray, Marzban, Marznode, Hiddify, Shadowsocks/Outline on `--net=host`, plus the server's own `curl` | `output` |
| **Forwarded** — the client's packets are *routed through* the server | **OpenVPN**, a **WireGuard server**, or a proxy in a **bridged Docker container** (e.g. an Outline `shadowbox` that is not `--net=host`) | `prerouting` |

A forwarded packet never passes the `output` hook. On an OpenVPN box that meant the tunnel
worked but every site kept seeing the server's plain IP. Both paths are covered now, under
the same per-domain policy.

`WARP → Connection → Client Traffic` controls the forwarded path:

| Mode | Behaviour |
|---|---|
| `auto` *(default)* | Divert only what is actually detected — OpenVPN/tun, a WireGuard interface other than `wgcf`, or a proxy container that is not `--net=host`. A plain Xray/Marznode relay detects nothing and its ruleset is unchanged. |
| `vpn` | Always divert `tun` / `tap` / `ppp` / `wg` client traffic. |
| `all` | `vpn` plus Docker bridges. Use this when `auto` missed something. |
| `off` | The server's own traffic only. |

`WARP → Connection → Diagnose` (or `warp-manager --diagnose`) lists every path found on the
box, whether it is intercepted, and the live packet counters — so "my users aren't going
through WARP" becomes something you can read instead of guess. See
[Troubleshooting](troubleshooting.md).

---

## Tunnel safety

WARP Manager never modifies your tunnel, proxy or panel configuration. It works entirely on
the VPS, on traffic that is already on its way out.

If the routing engine becomes unavailable, a **fail-open watchdog** removes the redirect
rules automatically, so traffic keeps flowing through the server's normal connection instead
of breaking existing tunnels. It re-applies them once the engine is healthy again.

## Connectivity checks

Connectivity-check domains used by operating systems (`gstatic.com/generate_204`,
`msftconnecttest.com`, `captive.apple.com`, …) always stay direct, so Android, Windows and
iOS clients never report a false "No Internet" — and client apps measuring their config ping
never depend on WARP's health.

## Automatic startup

After a reboot, WARP, sing-box, the nftables rules and the background timers are restored
automatically. Nothing to run by hand.

---

## Design goals

- Route only the traffic that actually needs WARP.
- Leave existing tunnels, proxies and panels untouched.
- No Docker, no DNS hijacking, no public listening ports.
- Fail open if the routing engine becomes unavailable.
- Support both HTTP/2 and HTTP/3 (QUIC).
- Keep the configuration simple enough to migrate between servers.
