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
 3. Refresh Routes
 4. Manage
 5. Update
 6. Uninstall
 7. Exit
```

- **1) Choose Services** — toggle whole groups on/off:
  - **AI** [ Gemini & Google AI, ChatGPT, Grok, Perplexity, Copilot ]
  - **Music** [ SoundCloud, Spotify, Apple Music, Tidal ]
  - **Social Media** [ X, SnapChat, Reddit ]
  - **Stream** [ Netflix, Twitch, Kick ]

  On apply, each service shows `Done` (green) or `Failed` (red); a failed service is
  skipped and the rest continue.
- **2) Custom Domains** — add/remove any other domain.
- **3) Refresh Routes** — refresh all sets now.
- **4) Manage** — Change IP · WARP+ License · Status · Restart · Import Account.
- **5) Update** — pull the latest CLI + engine and re-apply. **Your configuration is
  preserved** (enabled services, WARP account & exit IP, WARP+ license, custom
  domains). Same as running the one-command installer again.
- **6) Uninstall** — completely removes everything.

### Non-interactive commands

```bash
sudo warp-manager --refresh      # refresh the sets
sudo warp-manager --up           # bring WARP up + apply routes
sudo warp-manager --down         # stop WARP
sudo warp-manager --change-ip    # get a new WARP IP
sudo warp-manager --license KEY  # apply a WARP+ license
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
| Social Media | X, SnapChat, Reddit                                    |
| Stream       | Netflix, Twitch, Kick                                  |

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
is reachable through WARP. Read-only and safe.

---

## Notes

- Routing is by domain (SNI / QUIC), so it works for apps and websites and doesn't
  depend on DNS. TCP 80/443 and UDP 443 (QUIC) are intercepted; other ports go direct.
- After a reboot, WARP and sing-box start automatically and a boot service re-applies
  the nftables TPROXY rules.
- **Update:** menu → **Update** (option 5), or `sudo warp-manager --update`, or just
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
# or from the menu: option 6
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
