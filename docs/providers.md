[← back to README](../README.md)

# Providers

More than **100 predefined services**, organised into categories. Select what you want from
the menu — no manual routing rules.

| Category | Providers |
|----------|-----------|
| 🤖 AI | ChatGPT, Gemini, Claude, Cursor, Copilot, Grok, Perplexity, Midjourney, ElevenLabs, Runway, Suno, Udio, Windsurf and more |
| 🎵 Music | Spotify, Apple Music, YouTube Music, SoundCloud, Tidal, Deezer, Bandcamp, Amazon Music and more |
| 🌐 Social Media | X, Instagram, Threads, TikTok, Facebook, Reddit, Pinterest, Bluesky and more |
| 💬 Messaging | Telegram, Discord, WhatsApp, Signal, LINE, WeChat |
| 🎬 Streaming | Netflix, Disney+, HBO Max, Apple TV+, Amazon Prime Video, Twitch, Kick and more |
| 💻 Developer | GitHub, GitLab, Docker Hub, Hugging Face, npm, PyPI, Railway, Render, Vercel and more |
| 🎮 Gaming | Steam, Epic Games, Riot Games, Battle.net, Xbox, PlayStation Network and more |
| ☁️ Cloud | AWS, Cloudflare, Azure, DigitalOcean, Google Cloud |
| 📈 Productivity | Notion, Slack, Zoom, Figma, Canva, Linear, Airtable, Miro |
| 💳 Payment | PayPal, Stripe, Wise, Revolut |
| 🟢 Google | All Google services (except YouTube) |
| 🔵 Microsoft | All Microsoft services |
| 🟣 Adobe | All Adobe services |

---

## Duplicates

Some providers appear in more than one category — WhatsApp and WeChat are under both
**Messaging** and **Social Media**, for example. Both entries point at the same underlying
rule, so changing either one changes both.

## Custom providers

Need something that isn't included? Drop a definition in `data/providers/` and it appears in
the menu. Categories are defined in `data/groups.conf`. No source changes required.

For a handful of domains, `WARP → Custom Domains` is quicker — a provider file is worth it
when you want the entry to be named, grouped, and carried by [presets](menu.md#presets).
