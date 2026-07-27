<p align="center">
  <img src="img/cover.png" alt="WARP Manager" width="100%">
</p>

# WARP Manager

**Selective Cloudflare WARP routing for a VPS exit node.**

TeleGram: **@BlackProtocols**

Only the services *you* pick (Gemini, ChatGPT, Netflix, ...) go through Cloudflare
WARP. All other traffic keeps your server's normal IP. **Pure Bash, no Docker, and
it never touches your tunnel / Xray / panel config.**

---

## One-command install

On the VPS (Ubuntu/Debian), as root:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/AminMGMT/WARP-Manager/main/setup.sh)"
```

That's it — it downloads everything, installs, and opens the menu automatically.

Or clone and run manually:

```bash
git clone https://github.com/AminMGMT/WARP-Manager.git
cd WARP-Manager
sudo bash install.sh
```

The installer shows a progress bar per step and opens the menu when done:

```
Installing Dependencies    [################################] 100%
Copying Files              [################################] 100%
Preparing WARP             [################################] 100%
Generating Profile         [################################] 100%

  WARP is Ready : sudo wm
```

By default the **AI** group is enabled so Gemini/ChatGPT work right away.

---

## The problem it solves

Tunnel: user in Iran → foreign VPS (e.g. Germany) → internet.
The VPS IP is blocked and some sites (like Gemini) won't open on it.
Fix: send just those sites through Cloudflare WARP, leave everything else alone.

---

## How it works

```
        User (Iran)
            │  (your tunnel — untouched)
            ▼
   ┌──────────────────────────── VPS ──────────────────────────────┐
   │  Tunnel / panel  ──►  outbound 80/443 TCP + 443 UDP (QUIC)     │
   │                              │                                  │
   │      nftables TPROXY (TCP 80/443 + UDP 443)  ──► sing-box (lo)  │
   │                              │  reads the domain (SNI / QUIC)   │
   │            ┌─────────────────┴─────────────────┐                │
   │      selected domain                     everything else        │
   │            ▼                                    ▼                │
   │   WARP (mark → WireGuard)                direct via eth0         │
   │   → clean Cloudflare IP                  → normal server IP      │
   └────────────────────────────────────────────────────────────────┘
```

- **sing-box** runs on loopback and reads the real **domain** of each connection
  (from the TLS **SNI** *and* the **QUIC ClientHello**), so it routes by domain — not
  by pre-resolved IPs. That's why **apps work, not just websites**: whatever
  endpoint/CDN an app uses, if its domain is in the selected list it goes through WARP.
- nftables TPROXYs the VPS's outbound **TCP 80/443 and UDP 443 (QUIC)** into sing-box
  (SSH and your tunnel's inbound port are untouched — only locally-generated traffic
  to those ports is diverted). Because QUIC is routed too (not dropped), apps that
  speak HTTP/3 work through WARP instead of falling back or leaking.
- Selected domains leave via WARP (a WireGuard interface, reached with `fwmark
  51888`); everything else goes direct. The WARP endpoint + private ranges are
  excluded so a loop can't form.

Nothing in your tunnel / Xray / panel changes — it's all done on the VPS, and no
public port is opened (sing-box listens on localhost only).

---

## Usage

```bash
sudo wm          # or: sudo warp-manager
```

Menu:

```
 1. Choose Services
 2. Custom Domains
 3. Ad Blocker
 4. Refresh Routes
 5. Manage
 6. Update
 7. Uninstall
 8. Exit
```

- **1) Choose Services** — toggle whole groups on/off:
  - **AI** [ Gemini & Google AI, ChatGPT, Grok, Perplexity, Copilot ]
  - **Music** [ SoundCloud, Spotify, Apple Music, Tidal ]
  - **Social Media** [ X, SnapChat, Reddit, TikTok, Instagram ]
  - **Stream** [ Netflix, HBO, Twitch, Kick ]
  - **Creative** [ Adobe, Shutterstock, PeakPX, Microsoft ]

  On apply, each service shows `Done` (green) or `Failed` (red); a failed service is
  skipped and the rest continue.
- **2) Custom Domains** — add/remove any other domain.
- **3) Ad Blocker** — block ads and trackers for everyone using the server, using the
  **AdGuard DNS filter** (~160k domains) plus sing-box's own ads rule-set. Off by
  default; turn it on and the list is downloaded and applied. No extra service, no
  DNS server, no web UI — the engine already knows each connection's domain, so this
  is just one more routing rule. The list refreshes weekly on its own. If a site ever
  breaks, add it under **Allowed domains** and it is never blocked again.
- **4) Refresh Routes** — refresh all sets now.
- **5) Manage** — Change IP · **Auto IP Health** · WARP+ License · Status · Restart ·
  Import Account.
- **6) Update** — pull the latest CLI + engine and re-apply. **Your configuration is
  preserved** (enabled services, WARP account & exit IP, WARP+ license, custom
  domains). Same as running the one-command installer again.
- **7) Uninstall** — completely removes everything.

### Non-interactive commands

```bash
sudo warp-manager --refresh      # refresh the sets
sudo warp-manager --up           # bring WARP up + apply routes
sudo warp-manager --down         # stop WARP
sudo warp-manager --change-ip    # get a new WARP IP
sudo warp-manager --license KEY  # apply a WARP+ license
sudo warp-manager --adblock-update # refresh the ad blocker list
sudo warp-manager --ip-check     # check the WARP exit IP now (rotates it if bad)
warp-manager --location          # show WARP location
warp-manager --status            # short status summary
sudo warp-manager --update       # update to the latest version (keeps your config)
sudo warp-manager --purge        # remove everything
```

---

## Groups & services

Groups live in `data/groups.conf`; each service is a file in `data/providers/<id>.conf`.

| Group        | Services                                               |
|--------------|--------------------------------------------------------|
| AI           | Gemini & Google AI, ChatGPT, Grok, Perplexity, Copilot |
| Music        | SoundCloud, Spotify, Apple Music, Tidal                |
| Social Media | X, SnapChat, Reddit, TikTok, Instagram                 |
| Stream       | Netflix, HBO, Twitch, Kick                             |
| Creative     | Adobe, Shutterstock, PeakPX, Microsoft                 |

Add your own: drop a `data/providers/<id>.conf` and reference it in `data/groups.conf`.
Provider types: `geosite` (a sing-box rule-set category, e.g. `category=openai`) or
`domain` (a `domains=` list). sing-box matches these by domain at runtime.

---

## WARP+ license

Have a WARP+ key? Menu → **Manage → WARP+ License → set**. It's applied to the
account and preserved when you change IP.

---

## End-to-end test

After installing, verify everything works:

```bash
sudo bash test/e2e.sh
```

It checks that WARP and sing-box are running, the nftables TPROXY rules are active,
the WARP exit IP differs from the server IP, the sing-box config is valid, and Gemini
is reachable through WARP. It also verifies the tunnel-safety guards (fail-open
watchdog, client connectivity check) and, when the ad blocker is on, that ads are
actually blocked while normal sites are not. Read-only and safe.

---

## Notes

- Routing is by domain (SNI / QUIC), so it works for apps and websites and doesn't
  depend on DNS. TCP 80/443 and UDP 443 (QUIC) are intercepted; other ports go direct.
- After a reboot, WARP and sing-box start automatically and a boot service re-applies
  the nftables TPROXY rules.
- **Ad blocker:** the block list lives in `/var/lib/warp-manager/adblock/` and never
  replaces a working list with a failed download. A weekly timer refreshes it, and the
  engine is only restarted when the list actually changed.
- **Auto IP health** (Manage → Auto IP Health, off by default): every 10 minutes the
  exit is probed through WARP. A new IP is requested only when the tunnel is up, the
  server's own internet works, and the exit is genuinely dead or in a blocked region
  (`IR` by default). Rotations are capped — at least 30 min apart and 4 per day — so a
  transient outage can never burn through Cloudflare's registration limits and get the
  server 429'd. Tunables in `/etc/warp-manager/manager.conf`: `ipcheck_bad_locs`,
  `ipcheck_min_interval`, `ipcheck_max_per_day`.
- **Tunnel safety:** a fail-open watchdog checks the engine every 20s. If sing-box or
  the divert path is ever unhealthy it removes the nftables rules automatically, so
  traffic falls back to direct and the server's tunnel keeps working; it re-applies
  them once things are healthy again.
- **Update:** menu → **Update** (option 6), or `sudo warp-manager --update`, or just
  re-run the one-command installer. It refreshes the CLI + engine and keeps your
  configuration untouched.
- **Cloudflare rate-limit (429):** some datacenter IPs get their WARP registration
  rate-limited. Install still completes; just wait a few minutes and do
  **Manage → Restart**, or import an account from a server that worked:
  ```bash
  # on a working server:
  cat /var/lib/warp-manager/wgcf/wgcf-account.toml
  # on the blocked server (paste it into a file, then):
  sudo warp-manager --import-account /path/to/wgcf-account.toml
  ```

---

## Uninstall

```bash
sudo bash uninstall.sh
# or from the menu: option 7
```

Removes the WARP interface, WARP account, all rules, config, systemd units, and every
warp-manager file.

---

## Acknowledgements

WARP account registration uses [wgcf](https://github.com/ViRb3/wgcf). Thanks!

## Support

If WARP Manager helps you, a star or a small tip is appreciated. 🙏

Telegram channel: **@BlackProtocols**

| Coin | Address |
|------|---------|
| Tron (TRX) | `TTzuUAtsEsrLgNpFVLNTyLVJVRRFNWESYc` |
| USDT (BEP20) | `0xc112AE9bfF7c59dEcFb34E988A397848D3093E82` |
| Toncoin (TON) | `UQD9g40QubAICJ6zPqegtCY7s-joMx2DB8aIqA0xF1aHoCDs` |

## License

Copyright © 2026 Amin Mohammadi (AminMGMT). Released under the MIT License — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
