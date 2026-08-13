[← back to README](../README.md)

# Ad Blocker

Blocks ads and trackers using **uBlock Origin's filter lists** — the same catalogue uBlock
ships, with the same nine lists enabled by default, plus its optional and regional lists
(71 in total, selectable under `Ad Blocker → Filter Lists`).

Runs inside the routing engine that is already there: no DNS server, no extra service, no
web UI, no container.

## What it can and cannot block

Only the domain-expressible rules are used. sing-box sees the domain of each connection
(TLS SNI / QUIC) and never the URL path or the page DOM, so cosmetic filters (`##selector`)
and scriptlets (`##+js`) cannot apply server-side.

That still captures **85% of uBlock's network filters** — about 105,000 domains from the
default set, or ~128,000 with the optional lists enabled.

## Safety

A domain a selected service needs is never blocked. Every provider domain is subtracted from
the block list when it is built, and the bulk ad rules are evaluated *after* the routing
rules — so a service you chose to route always wins over a generic ad list.

`WARP → White Lists` adds your own never-block domains, for the case where a site genuinely
needs a tracking or analytics host to work.

## Updates

Lists refresh automatically every week. A failed download never replaces a list that was
already working, and a server that cannot reach GitHub still keeps its last good list. To
refresh by hand:

```bash
sudo warp-manager --adblock-update
```
