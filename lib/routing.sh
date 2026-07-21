#!/usr/bin/env bash
# WARP Manager - nftables redirect layer for the sing-box engine.
# Requires common.sh sourced first.
#
# Locally-generated HTTP/HTTPS (the tunnel's outbound) is redirected into sing-box
# on loopback, which sniffs the domain and routes it. sing-box's own outbound is
# marked (51888 warp / 51889 direct) and skipped here to avoid a loop. QUIC (UDP
# 443) is dropped for non-excluded destinations so apps fall back to TCP (which we
# can sniff). SSH and the tunnel's inbound port are untouched (only 80/443 output).

routing_installed() { nft list table inet "$WM_NFT_TABLE" >/dev/null 2>&1; }

routing_apply() {
    require_root
    has_cmd nft || die "nftables (nft) is not installed."
    nft -f - <<EOF
table inet ${WM_NFT_TABLE} {
    set ${WM_XSET4} { type ipv4_addr; flags interval; auto-merge; }
    set ${WM_XSET6} { type ipv6_addr; flags interval; auto-merge; }

    chain nat_output {
        type nat hook output priority -100; policy accept;
        meta mark ${WM_MARK_WARP} return
        meta mark ${WM_MARK_DIRECT} return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        tcp dport { 80, 443 } redirect to :${WM_SINGBOX_PORT}
    }

    chain quic_drop {
        type filter hook output priority 0; policy accept;
        meta mark ${WM_MARK_WARP} return
        meta mark ${WM_MARK_DIRECT} return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        udp dport 443 drop
    }
}
EOF
    routing_load_exclusions
    log_info "nftables redirect rules applied."
}

# private/reserved ranges + the WARP endpoint IPs are never redirected
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
        echo "add element inet ${WM_NFT_TABLE} ${WM_XSET4} { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, 100.64.0.0/10, 162.159.192.0/24, 162.159.193.0/24, 162.159.195.0/24 }"
        echo "add element inet ${WM_NFT_TABLE} ${WM_XSET6} { ::1/128, fc00::/7, fe80::/10, 2606:4700:d0::/48, 2606:4700:d1::/48 }"
        local ip
        for ip in $ep4; do echo "add element inet ${WM_NFT_TABLE} ${WM_XSET4} { ${ip} }"; done
        for ip in $ep6; do echo "add element inet ${WM_NFT_TABLE} ${WM_XSET6} { ${ip} }"; done
    } >"$tmp"
    nft -f "$tmp" 2>/dev/null || log_warn "Could not fully load the exclusion set."
}

routing_teardown() {
    require_root
    nft delete table inet "$WM_NFT_TABLE" 2>/dev/null || true
    log_info "nftables redirect rules removed."
}
