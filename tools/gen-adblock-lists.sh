#!/usr/bin/env bash
# Regenerate data/adblock-lists.conf from a uBlock Origin checkout.
#
#   tools/gen-adblock-lists.sh /path/to/uBlock
#
# The point is that "which filter lists exist" and "which are on by default" come
# from uBlock's own assets/assets.json, never from a hand-kept copy here — so a
# newer uBlock source is all it takes to follow their choices.
set -euo pipefail

SRC="${1:-}"
[[ -n "$SRC" ]] || { echo "usage: $0 /path/to/uBlock-source" >&2; exit 1; }
ASSETS="${SRC%/}/assets/assets.json"
[[ -f "$ASSETS" ]] || { echo "not a uBlock source tree (no assets/assets.json): $SRC" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/data/adblock-lists.conf"

python3 - "$ASSETS" "$OUT" <<'PY'
import json, re, sys

assets, out_path = sys.argv[1], sys.argv[2]
d = json.load(open(assets))

def url_of(v):
    cu = v.get('contentURL')
    return cu if isinstance(cu, str) else cu[0]

def title_of(v, k):
    """uBlock titles look like "\U0001F1E9\U0001F1EAde \U0001F1E8\U0001F1EDch \U0001F1E6\U0001F1F9at: EasyList Germany".

    The flags are emoji, the codes repeat them as text, and the menu pads titles
    into columns with printf %-Ns which counts BYTES — so anything non-ASCII makes
    the row sit short. Keep the country codes (they are the only thing telling a
    regional list apart) but render them as an ASCII "[de/ch/at] " prefix.
    """
    t = v.get('title') or k
    t = re.sub(r'[\U0001F1E6-\U0001F1FF\u200d\ufe0f]', '', t)   # flags anywhere
    t = re.sub(r'\s+', ' ', t).strip()

    prefix = ''
    head, sep, tail = t.partition(':')
    if sep and re.fullmatch(r'(?:[a-z]{2}\s*)+', head.strip()):
        prefix = '[' + '/'.join(head.split()) + '] '
        t = tail.strip()

    t = t.replace('\u2013', '-').replace('\u2014', '-').replace('\u2019', "'")
    t = t.encode('ascii', 'ignore').decode('ascii')
    t = re.sub(r'\(\s*\)', '', t)               # "AdGuard Chinese ()" -> non-ASCII name gone
    t = re.sub(r'\s+', ' ', t.replace('|', '/')).strip()
    return (prefix + t).strip() or k

rows = [(k, v) for k, v in d.items() if v.get('content') == 'filters']
on  = [r for r in rows if not r[1].get('off')]
off = [r for r in rows if r[1].get('off')]

with open(out_path, 'w') as f:
    f.write("""# WARP Manager - ad blocker filter-list catalogue.
#
# Generated from uBlock Origin's own assets/assets.json by
# tools/gen-adblock-lists.sh, so "which lists exist" and "which are on by default"
# are uBlock's answers rather than a hand-kept copy. Point the script at a newer
# uBlock source to follow their choices.
#
# Format:  id|on|off|Title|URL
#   the second field is the DEFAULT state; the user's own choices live in
#   /etc/warp-manager/adblock.lists and always win.
#
# Only the domain-expressible rules of each list are used: sing-box sees the domain
# of a connection (TLS SNI / QUIC), never the URL path or the page DOM, so cosmetic
# filters (##selector) and scriptlets (##+js) cannot apply server-side. Rules
# carrying a path, a $domain= scope or a request-type modifier are skipped rather
# than guessed at, because widening one of those to a whole domain is how an ad
# blocker takes a site down.
""")
    f.write("\n# ---- uBlock Origin's default set (enabled out of the box) ----\n")
    for k, v in on:
        f.write(f"{k}|on|{title_of(v,k)}|{url_of(v)}\n")
    f.write("\n# ---- available, off by default (uBlock's optional + regional lists) ----\n")
    for k, v in off:
        f.write(f"{k}|off|{title_of(v,k)}|{url_of(v)}\n")

    # Sources that are not part of uBlock's catalogue. Kept in this script rather
    # than hand-edited into the output, so regenerating never drops them.
    f.write("""
# ---- extra sources (not part of uBlock's catalogue) ----
# "file:" entries ship with WARP Manager and need no network.
youtube-ads|on|YouTube ad and tracking domains|file:data/adblock-youtube.txt
athar-youtube|off|YouTube ad domains + googlevideo hosts (see note)|https://raw.githubusercontent.com/Athar5443/Youtube_BlockAds_List/refs/heads/main/blocklist.txt
anti-ad|off|anti-AD (large Chinese/global domain list)|https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-domains.txt
neodev|off|NeoDev own blocklist|https://raw.githubusercontent.com/neodevpro/neodevhost/master/ownblocklist
217heidai-dns|off|217heidai adblockfilters (DNS)|https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblockdns.txt
stevenblack-fng|off|StevenBlack fakenews + gambling|https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-only/hosts
d3host|off|Turtlecute33 d3host|https://raw.githubusercontent.com/Turtlecute33/adblocktest/master/src/d3host.adblock
yokoffing-privacy|off|yokoffing Privacy Essentials|https://raw.githubusercontent.com/yokoffing/filterlists/main/privacy_essentials.txt
yokoffing-annoyance|off|yokoffing Annoyance List|https://raw.githubusercontent.com/yokoffing/filterlists/main/annoyance_list.txt
yokoffing-youtube|off|yokoffing YouTube Clear View (cosmetic - no effect server-side)|https://raw.githubusercontent.com/yokoffing/filterlists/main/youtube_clear_view.txt
""")

print(f"{out_path}: {len(on)} enabled by default, {len(off)} optional, {len(rows)} total")
PY
