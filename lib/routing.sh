#!/usr/bin/env bash
# WARP Manager - nftables TPROXY layer for the sing-box engine.
# Requires common.sh sourced first.
#
# Locally-generated traffic (the proxy's outbound) to 80/443 TCP and 443 UDP (QUIC)
# is marked in the output hook, policy-routed to loopback, and TPROXY'd into
# sing-box's tproxy inbound. sing-box sniffs the domain (from TLS SNI *and* QUIC
# ClientHello), sends the selected services out via WARP (routing_mark 51888) and
# everything else direct. Because we intercept UDP 443 too, apps that speak QUIC
# work through WARP instead of being dropped — no forced TCP fallback needed.
#
# sing-box's own outbound is marked (51888 warp / 51889 direct) and returned here to
# avoid a loop. The WARP endpoint + private/reserved ranges are excluded so the
# WireGuard handshake and local traffic are never intercepted.

routing_installed() { nft list table inet "$WM_NFT_TABLE" >/dev/null 2>&1; }

# policy routing so marked packets are delivered locally (to the tproxy socket).
# del-then-add keeps it idempotent without parsing `ip rule` hex output.
_routing_iprules() {
    # TPROXY to 127.0.0.1 needs local routing of the (external) dst address via lo
    sysctl -qw net.ipv4.conf.all.route_localnet=1 2>/dev/null || true
    sysctl -qw net.ipv4.conf.lo.route_localnet=1 2>/dev/null || true
    ip rule del fwmark "$WM_TPROXY_MARK" lookup "$WM_TPROXY_TABLE" 2>/dev/null || true
    ip rule add fwmark "$WM_TPROXY_MARK" lookup "$WM_TPROXY_TABLE" 2>/dev/null || true
    ip route replace local default dev lo table "$WM_TPROXY_TABLE" 2>/dev/null || true
    if wm_have_v6; then
        ip -6 rule del fwmark "$WM_TPROXY_MARK" lookup "$WM_TPROXY_TABLE" 2>/dev/null || true
        ip -6 rule add fwmark "$WM_TPROXY_MARK" lookup "$WM_TPROXY_TABLE" 2>/dev/null || true
        ip -6 route replace local default dev lo table "$WM_TPROXY_TABLE" 2>/dev/null || true
    fi
}

_routing_iprules_del() {
    ip rule del fwmark "$WM_TPROXY_MARK" lookup "$WM_TPROXY_TABLE" 2>/dev/null || true
    ip route flush table "$WM_TPROXY_TABLE" 2>/dev/null || true
    ip -6 rule del fwmark "$WM_TPROXY_MARK" lookup "$WM_TPROXY_TABLE" 2>/dev/null || true
    ip -6 route flush table "$WM_TPROXY_TABLE" 2>/dev/null || true
}

routing_apply() {
    require_root
    has_cmd nft || die "nftables (nft) is not installed."
    _routing_iprules
    # v6 tproxy/mark lines are emitted only when the host has IPv6 (see the $( … )
    # blocks inside the ruleset), so a v4-only box stays clean.
    nft -f - <<EOF
table inet ${WM_NFT_TABLE} {
    set ${WM_XSET4} { type ipv4_addr; flags interval; auto-merge; }
    set ${WM_XSET6} { type ipv6_addr; flags interval; auto-merge; }

    # Diverted (output-marked) packets loop back to lo and land here; TPROXY hands
    # them to sing-box. Gated on our mark so inbound traffic (SSH, the proxy's own
    # 443 listener, ...) is never touched.
    chain mangle_prerouting {
        type filter hook prerouting priority mangle; policy accept;
        meta mark ${WM_TPROXY_MARK} meta nfproto ipv4 meta l4proto tcp tproxy ip to 127.0.0.1:${WM_SINGBOX_PORT} accept
        meta mark ${WM_TPROXY_MARK} meta nfproto ipv4 meta l4proto udp tproxy ip to 127.0.0.1:${WM_SINGBOX_PORT} accept
$( wm_have_v6 && printf '        meta mark %s meta nfproto ipv6 meta l4proto tcp tproxy ip6 to [::1]:%s accept\n        meta mark %s meta nfproto ipv6 meta l4proto udp tproxy ip6 to [::1]:%s accept' "$WM_TPROXY_MARK" "$WM_SINGBOX_PORT" "$WM_TPROXY_MARK" "$WM_SINGBOX_PORT" )
    }

    # Mark locally-generated 80/443 TCP and 443 UDP so it is rerouted to lo (above).
    # 'type route' forces a re-route when the mark changes.
    chain mangle_output {
        type route hook output priority mangle; policy accept;
        meta mark ${WM_MARK_HEX} return
        meta mark 0xcab1 return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        meta nfproto ipv4 tcp dport { 80, 443 } meta mark set ${WM_TPROXY_MARK}
        meta nfproto ipv4 udp dport 443 meta mark set ${WM_TPROXY_MARK}
$( wm_have_v6 && printf '        meta nfproto ipv6 tcp dport { 80, 443 } meta mark set %s\n        meta nfproto ipv6 udp dport 443 meta mark set %s' "$WM_TPROXY_MARK" "$WM_TPROXY_MARK" )
    }
}
EOF
    routing_load_exclusions
    log_info "nftables TPROXY rules applied (TCP 80/443 + UDP 443 → sing-box)."
}

# private/reserved ranges + the WARP endpoint IPs are never routed via WARP
routing_load_exclusions() {
    routing_installed || return 0
    # Exclude both the WireGuard endpoint AND the registration API host, so wgcf's
    # own HTTPS calls (register / generate / change-IP) are never redirected into
    # sing-box — otherwise they get hijacked and fail with EOF.
    local ep4 ep6 tmp
    ep4="$( { getent ahostsv4 "$WM_WARP_ENDPOINT_HOST" "$WM_WARP_API_HOST" 2>/dev/null | awk '{print $1}';
              dig +short A "$WM_WARP_ENDPOINT_HOST" "$WM_WARP_API_HOST" 2>/dev/null; } | grep -E '^[0-9.]+$' | sort -u )"
    ep6="$( { getent ahostsv6 "$WM_WARP_ENDPOINT_HOST" "$WM_WARP_API_HOST" 2>/dev/null | awk '{print $1}';
              dig +short AAAA "$WM_WARP_ENDPOINT_HOST" "$WM_WARP_API_HOST" 2>/dev/null; } | grep -E '^[0-9A-Fa-f:]+$' | sort -u )"

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
    _routing_iprules_del
    log_info "nftables TPROXY rules removed."
}
