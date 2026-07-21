#!/usr/bin/env bash
# WARP Manager - nftables marking layer (transparent, no client/Xray changes)
# Requires common.sh sourced first.
#
# We create one table `inet warp` with two named sets (v4/v6). Any packet whose
# destination is in a set gets fwmark 51888, which the WireGuard PostUp rules
# route into the WARP interface. Everything else keeps the server's normal path.

WM_NFT_FILE="${WM_STATE_DIR}/warp.nft"

routing_installed() { nft list table inet "$WM_NFT_TABLE" >/dev/null 2>&1; }

# (Re)create the nft table + chains. Sets start empty; populated by providers.sh
# warpx4/warpx6 are exclusion sets: any destination in them is returned early
# (never marked) so WARP's own tunnel + private ranges can't create a loop.
routing_apply_skeleton() {
    require_root
    has_cmd nft || die "nftables (nft) is not installed."
    nft -f - <<EOF
table inet ${WM_NFT_TABLE} {
    set ${WM_SET4}  { type ipv4_addr; flags interval; auto-merge; }
    set ${WM_SET6}  { type ipv6_addr; flags interval; auto-merge; }
    set ${WM_XSET4} { type ipv4_addr; flags interval; auto-merge; }
    set ${WM_XSET6} { type ipv6_addr; flags interval; auto-merge; }

    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        ip  daddr @${WM_SET4} meta mark set ${WM_MARK_HEX} ct mark set ${WM_MARK_HEX}
        ip6 daddr @${WM_SET6} meta mark set ${WM_MARK_HEX} ct mark set ${WM_MARK_HEX}
    }

    chain output {
        type route hook output priority mangle; policy accept;
        oifname "${WM_IFACE}" return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        ip  daddr @${WM_SET4} meta mark set ${WM_MARK_HEX} ct mark set ${WM_MARK_HEX}
        ip6 daddr @${WM_SET6} meta mark set ${WM_MARK_HEX} ct mark set ${WM_MARK_HEX}
    }
}
EOF
    routing_load_exclusions
    log_info "nftables table '${WM_NFT_TABLE}' created."
}

# Populate the exclusion sets: private/reserved ranges + the WARP endpoint IPs.
routing_load_exclusions() {
    routing_installed || return 0
    local ep4 ep6 tmp
    ep4="$( { getent ahostsv4 "$WM_WARP_ENDPOINT_HOST" 2>/dev/null | awk '{print $1}';
              dig +short A "$WM_WARP_ENDPOINT_HOST" 2>/dev/null; } | grep -E '^[0-9.]+$' | sort -u )"
    ep6="$( { getent ahostsv6 "$WM_WARP_ENDPOINT_HOST" 2>/dev/null | awk '{print $1}';
              dig +short AAAA "$WM_WARP_ENDPOINT_HOST" 2>/dev/null; } | grep -E '^[0-9A-Fa-f:]+$' | sort -u )"

    tmp="${WM_STATE_DIR}/xsets.nft"
    {
        echo "flush set inet ${WM_NFT_TABLE} ${WM_XSET4}"
        echo "flush set inet ${WM_NFT_TABLE} ${WM_XSET6}"
        # RFC1918 + loopback + link-local + CGNAT + known WARP endpoint block
        echo "add element inet ${WM_NFT_TABLE} ${WM_XSET4} { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, 100.64.0.0/10, 162.159.192.0/24, 162.159.193.0/24, 162.159.195.0/24 }"
        echo "add element inet ${WM_NFT_TABLE} ${WM_XSET6} { ::1/128, fc00::/7, fe80::/10, 2606:4700:d0::/48, 2606:4700:d1::/48 }"
        local ip
        for ip in $ep4; do echo "add element inet ${WM_NFT_TABLE} ${WM_XSET4} { ${ip} }"; done
        for ip in $ep6; do echo "add element inet ${WM_NFT_TABLE} ${WM_XSET6} { ${ip} }"; done
    } >"$tmp"
    nft -f "$tmp" 2>/dev/null || log_warn "Could not fully load the exclusion set."
}

# Reset only the WARP-routed flows so a just-disabled service stops using WARP
# immediately (established/keep-alive connections would otherwise linger).
routing_reset_conntrack() {
    has_cmd conntrack || return 0
    conntrack -D --mark "$WM_FWMARK" >/dev/null 2>&1 || true
}

routing_teardown() {
    require_root
    nft delete table inet "$WM_NFT_TABLE" 2>/dev/null || true
    rm -f "$WM_NFT_FILE"
    log_info "nftables rules removed."
}

# Replace the contents of both sets atomically from two files (v4list, v6list).
# Each file: one CIDR / IP per line (blank lines and #comments ignored).
routing_load_sets() {
    local v4file="$1" v6file="$2"
    require_root
    routing_installed || routing_apply_skeleton

    local tmp="${WM_STATE_DIR}/sets.nft" list4 list6
    list4="$(grep -vE '^[[:space:]]*(#|$)' "$v4file" 2>/dev/null | paste -sd, -)"
    list6="$(grep -vE '^[[:space:]]*(#|$)' "$v6file" 2>/dev/null | paste -sd, -)"

    {
        echo "flush set inet ${WM_NFT_TABLE} ${WM_SET4}"
        echo "flush set inet ${WM_NFT_TABLE} ${WM_SET6}"
        [[ -n "$list4" ]] && echo "add element inet ${WM_NFT_TABLE} ${WM_SET4} { ${list4} }"
        [[ -n "$list6" ]] && echo "add element inet ${WM_NFT_TABLE} ${WM_SET6} { ${list6} }"
    } >"$tmp"

    if nft -f "$tmp"; then
        local n4 n6
        n4=$(grep -vcE '^[[:space:]]*(#|$)' "$v4file" 2>/dev/null); n4=${n4:-0}
        n6=$(grep -vcE '^[[:space:]]*(#|$)' "$v6file" 2>/dev/null); n6=${n6:-0}
        log_info "Sets loaded: ${n4} IPv4 prefixes, ${n6} IPv6 prefixes."
    else
        die "Failed to load nftables sets (file: $tmp)."
    fi
}

routing_count() {
    local set="$1"
    nft list set inet "$WM_NFT_TABLE" "$set" 2>/dev/null \
        | grep -oP 'elements = \{ \K[^}]*' | tr ',' '\n' | grep -c . || echo 0
}
