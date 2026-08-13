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
    # heal the legacy fwmark 0x1 / table 100 rule from older versions (see below)
    while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
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
    # Legacy cleanup: earlier versions used fwmark 0x1 / table 100, which collides
    # with the common default mark used by Xray/panels. Remove those on upgrade so a
    # previously-broken host is fully healed.
    while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true
    ip -6 route flush table 100 2>/dev/null || true
}

# How UDP 443 (QUIC) is handled:
#   route - divert it into sing-box like TCP. QUIC of the selected services is
#           blocked there so apps fall back to TCP, everything else passes through.
#           Most capable, but sing-box has to track every UDP session on the box.
#   light - never send UDP through the engine; drop QUIC at the nft level instead.
#           Apps still work (they fall back to TCP, which is the path we route via
#           WARP anyway) and the engine only ever handles TCP — roughly half the
#           work and far fewer moving parts on a busy relay.
routing_quic_mode() {
    local m; m="$(conf_get quic_mode route)"
    [[ "$m" == "light" ]] && printf 'light' || printf 'route'
}

# --- forwarded (client) traffic ------------------------------------------
# The output hook above only ever sees traffic the SERVER ITSELF generates. That
# covers every proxy that terminates the client's connection and dials out from the
# host (Xray/marznode, Hiddify, a host-networked Shadowsocks/Outline), which is why
# this worked from day one on the relay nodes. It is completely blind to two setups
# that are just as common:
#
#   * OpenVPN / WireGuard *servers*: the client's packets arrive on tun0/wg0 and are
#     ROUTED through the box (prerouting -> forward -> postrouting). They never touch
#     the output hook, so nothing was ever intercepted and every site kept seeing the
#     server's own IP — the tunnel "worked" but selective WARP routing did nothing.
#   * a proxy inside a bridged Docker container (an Outline shadowbox that is not
#     --net=host, x-ui/3x-ui in compose, ...): the container dials out from its own
#     network namespace, so from the host's point of view that is forwarded traffic
#     too, arriving on docker0 / br-xxxx.
#
# Both are picked up here, in prerouting, under exactly the same policy as local
# traffic: TCP 80/443 (plus UDP 443, depending on the QUIC mode) is TPROXY'd into
# sing-box, which decides per sniffed domain whether it goes via WARP or direct.
#
# forward_mode:
#   auto - (default) emit a pattern only when this box actually has that kind of
#          traffic. A plain Xray/marznode relay detects nothing and keeps byte for
#          byte the ruleset it had before this feature existed.
#   vpn  - always divert tun/tap/ppp/wg client traffic
#   all  - vpn + docker bridges
#   off  - local traffic only (the old behaviour)
# forward_ifaces overrides all of that with an explicit space-separated list of
# nft iifname patterns (e.g. "tun* br-abc123").
routing_forward_mode() {
    local m; m="$(conf_get forward_mode auto)"
    case "$m" in off|auto|vpn|all) printf '%s' "$m" ;; *) printf 'auto' ;; esac
}

# docker can be installed with a dead daemon; never let that hang the engine
_wm_docker() {
    has_cmd docker || return 1
    if has_cmd timeout; then timeout 5 docker "$@" 2>/dev/null; else docker "$@" 2>/dev/null; fi
}

# a live tun/tap/ppp device, or an OpenVPN that will create one the moment a client
# connects (detecting the binary matters: at boot there is no tun0 yet)
wm_detect_tuntap() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 \
        | grep -qE '^(tun|tap|ppp)[0-9]' && return 0
    has_cmd openvpn && return 0
    [[ -d /etc/openvpn ]] && return 0
    return 1
}

# WireGuard interfaces that are NOT our own WARP tunnel — i.e. a WG server carrying
# other people's traffic, whose packets are forwarded rather than locally generated.
wm_detect_foreign_wg() {
    local n
    while read -r n; do
        n="${n%%@*}"
        [[ -z "$n" || "$n" == "$WM_IFACE" ]] && continue
        return 0
    done < <( { ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}';
                wg show interfaces 2>/dev/null | tr ' ' '\n'; } )
    return 1
}

WM_PROXY_CONTAINER_RE='shadowbox|outline|shadowsocks|ss-server|xray|marz|hysteria|sing-?box|x-ui|hiddify|v2ray|trojan|openvpn'

# A proxy running in a container with its OWN netns (anything but --net=host): its
# egress leaves through a docker bridge, so the host sees it as forwarded traffic.
# Outline's own installer uses --net=host, in which case this correctly finds
# nothing — that server is already covered by the local/output path.
wm_detect_bridged_proxy() {
    local name net
    while read -r name; do
        [[ -z "$name" ]] && continue
        net="$(_wm_docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")"
        [[ "$net" == host ]] && continue
        return 0
    done < <(_wm_docker ps --format '{{.Names}} {{.Image}}' | grep -iE "$WM_PROXY_CONTAINER_RE" | awk '{print $1}')
    return 1
}

# nft iifname patterns whose FORWARDED traffic is diverted. Empty output = the
# prerouting divert is not installed at all.
routing_forward_ifaces() {
    local mode; mode="$(routing_forward_mode)"
    [[ "$mode" == off ]] && return 0
    local custom; custom="$(conf_get forward_ifaces "")"
    if [[ -n "$custom" ]]; then printf '%s\n' $custom; return 0; fi
    case "$mode" in
        vpn) printf 'tun*\ntap*\nppp*\nwg*\n'; return 0 ;;
        all) printf 'tun*\ntap*\nppp*\nwg*\ndocker*\nbr-*\n'; return 0 ;;
    esac
    wm_detect_tuntap        && printf 'tun*\ntap*\nppp*\n'
    wm_detect_foreign_wg    && printf 'wg*\n'
    wm_detect_bridged_proxy && printf 'docker*\nbr-*\n'
    return 0
}

routing_forward_active() { [[ -n "$(routing_forward_ifaces)" ]]; }

routing_apply() {
    require_root
    has_cmd nft || die "nftables (nft) is not installed."
    _routing_iprules
    local qmode; qmode="$(routing_quic_mode)"
    # Only divert IPv6 when WARP's IPv6 path is proven to work; otherwise v6 traffic
    # would be sent into a black hole (see warp_v6_works) while v4 is perfectly fine.
    local v6=0; warp_v6_works && v6=1
    [[ "$v6" -eq 0 ]] && wm_have_v6 && log_warn "WARP has no working IPv6; IPv6 traffic will go direct."

    # Forwarded-traffic divert (OpenVPN/WireGuard clients, bridged containers).
    # Built here so that when nothing is detected both strings stay empty and the
    # emitted ruleset is identical to the pre-existing one.
    local fwd_pats fwd_jump="" fwd_chain="" pat
    fwd_pats="$(routing_forward_ifaces | grep -vE '^[[:space:]]*$' | sort -u)"
    if [[ -n "$fwd_pats" ]]; then
        while read -r pat; do
            [[ -z "$pat" ]] && continue
            fwd_jump+="        iifname \"${pat}\" jump fwd_divert"$'\n'
        done <<<"$fwd_pats"
        # Guards first, in the same spirit as mangle_output: our own tunnel, our own
        # marks, anything addressed to this machine (a VPN client opening the panel
        # must not be proxied), and the private/reserved + WARP-endpoint sets.
        # `counter` is deliberate: it is the only honest answer to "is my OpenVPN
        # traffic actually reaching the engine?" (see `warp-manager --diagnose`).
        fwd_chain="
    chain fwd_divert {
        iifname \"${WM_IFACE}\" return
        meta mark ${WM_MARK_HEX} return
        meta mark 0xcab1 return
        meta mark ${WM_TPROXY_MARK} return
        fib daddr type local return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        meta nfproto ipv4 tcp dport { 80, 443 } counter tproxy ip to 127.0.0.1:${WM_SINGBOX_PORT} meta mark set ${WM_TPROXY_MARK} accept"
        if [[ "$qmode" == route ]]; then
            fwd_chain+="
        meta nfproto ipv4 udp dport 443 counter tproxy ip to 127.0.0.1:${WM_SINGBOX_PORT} meta mark set ${WM_TPROXY_MARK} accept"
        fi
        if [[ "$v6" -eq 1 ]]; then
            fwd_chain+="
        meta nfproto ipv6 tcp dport { 80, 443 } counter tproxy ip6 to [::1]:${WM_SINGBOX_PORT} meta mark set ${WM_TPROXY_MARK} accept"
            [[ "$qmode" == route ]] && fwd_chain+="
        meta nfproto ipv6 udp dport 443 counter tproxy ip6 to [::1]:${WM_SINGBOX_PORT} meta mark set ${WM_TPROXY_MARK} accept"
        fi
        # light mode: same deal as for local traffic — QUIC never reaches the engine,
        # dropping it makes the client fall back to TCP, which is the path we route.
        [[ "$qmode" == light ]] && fwd_chain+="
        udp dport 443 counter drop"
        fwd_chain+="
    }
"
    fi
    # v6 tproxy/mark lines are emitted only when the host has IPv6 (see the $( … )
    # blocks inside the ruleset), so a v4-only box stays clean.
    # Rebuild idempotently: ensure the table exists, delete it, then recreate — so a
    # re-apply never appends duplicate rules to the existing chains.
    nft -f - <<EOF
table inet ${WM_NFT_TABLE} {}
delete table inet ${WM_NFT_TABLE}
table inet ${WM_NFT_TABLE} {
    # The reserved/private ranges are declared inline so they are excluded from the
    # instant the table exists. routing_load_exclusions re-adds them together with
    # the resolved WARP endpoint IPs; if that ever fails, local traffic is still safe.
    set ${WM_XSET4} { type ipv4_addr; flags interval; auto-merge;
        elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8,
                     169.254.0.0/16, 100.64.0.0/10,
                     162.159.192.0/24, 162.159.193.0/24, 162.159.195.0/24 } }
    set ${WM_XSET6} { type ipv6_addr; flags interval; auto-merge;
        elements = { ::1/128, fc00::/7, fe80::/10,
                     2606:4700:d0::/48, 2606:4700:d1::/48 } }
${fwd_chain}
    # Diverted (output-marked) packets loop back to lo and land here; TPROXY hands
    # them to sing-box. Gated on our mark so inbound traffic (SSH, the proxy's own
    # 443 listener, ...) is never touched.
    chain mangle_prerouting {
        type filter hook prerouting priority mangle; policy accept;
        meta mark ${WM_TPROXY_MARK} meta nfproto ipv4 meta l4proto tcp tproxy ip to 127.0.0.1:${WM_SINGBOX_PORT} accept
$( [[ "$qmode" == route ]] && printf '        meta mark %s meta nfproto ipv4 meta l4proto udp tproxy ip to 127.0.0.1:%s accept' "$WM_TPROXY_MARK" "$WM_SINGBOX_PORT" )
$( [[ "$v6" -eq 1 ]] && printf '        meta mark %s meta nfproto ipv6 meta l4proto tcp tproxy ip6 to [::1]:%s accept' "$WM_TPROXY_MARK" "$WM_SINGBOX_PORT" )
$( [[ "$v6" -eq 1 && "$qmode" == route ]] && printf '        meta mark %s meta nfproto ipv6 meta l4proto udp tproxy ip6 to [::1]:%s accept' "$WM_TPROXY_MARK" "$WM_SINGBOX_PORT" )
        # Forwarded client traffic (OpenVPN/WireGuard/bridged containers). These
        # jumps come last so a packet already carrying our divert mark — i.e. one
        # looping back through lo from mangle_output — is handled above and never
        # reaches them.
${fwd_jump}    }

    # Mark locally-generated 80/443 TCP and 443 UDP so it is rerouted to lo (above).
    # 'type route' forces a re-route when the mark changes.
    chain mangle_output {
        type route hook output priority mangle; policy accept;
        # Anything already routed out through WARP is left alone. Without this,
        # probes bound to the tunnel (warp_trace_ip, the IP health check) would be
        # diverted into sing-box and silently sent out direct instead — reporting
        # the wrong exit IP and making the health check judge the wrong path.
        oifname "${WM_IFACE}" return
        meta mark ${WM_MARK_HEX} return
        meta mark 0xcab1 return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        meta nfproto ipv4 tcp dport { 80, 443 } counter meta mark set ${WM_TPROXY_MARK}
$( [[ "$qmode" == route ]] && printf '        meta nfproto ipv4 udp dport 443 counter meta mark set %s' "$WM_TPROXY_MARK" )
$( [[ "$v6" -eq 1 ]] && printf '        meta nfproto ipv6 tcp dport { 80, 443 } counter meta mark set %s' "$WM_TPROXY_MARK" )
$( [[ "$v6" -eq 1 && "$qmode" == route ]] && printf '        meta nfproto ipv6 udp dport 443 counter meta mark set %s' "$WM_TPROXY_MARK" )
    }
$( [[ "$qmode" == light ]] && cat <<QEOF

    # light mode: QUIC never reaches the engine. Dropping it makes clients fall back
    # to TCP, which is the path we actually route through WARP.
    chain quic_drop {
        type filter hook output priority 0; policy accept;
        oifname "${WM_IFACE}" return
        meta mark ${WM_MARK_HEX} return
        meta mark 0xcab1 return
        ip  daddr @${WM_XSET4} return
        ip6 daddr @${WM_XSET6} return
        udp dport 443 drop
    }
QEOF
)
}
EOF
    routing_load_exclusions
    if [[ "$qmode" == light ]]; then
        log_info "nftables rules applied (TCP 80/443 → sing-box; QUIC dropped, clients use TCP)."
    else
        log_info "nftables TPROXY rules applied (TCP 80/443 + UDP 443 → sing-box)."
    fi
    if [[ -n "$fwd_pats" ]]; then
        log_info "Forwarded client traffic is diverted too ($(printf '%s' "$fwd_pats" | tr '\n' ' '))."
    fi
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

# --- fail-open watchdog ----------------------------------------------------
# The tunnel's relay traffic must NEVER be hostage to this engine. A systemd timer
# runs `warp-manager --watchdog` every 20s: if sing-box (or the divert path) is
# unhealthy it removes the nft rules immediately — traffic flows direct, the tunnel
# stays alive — and re-applies them automatically once things are healthy again.
WM_WATCHDOG_SERVICE="warp-manager-watchdog.service"
WM_WATCHDOG_TIMER="warp-manager-watchdog.timer"
WM_WATCHDOG_STATE="${WM_STATE_DIR}/watchdog.down"

watchdog_service_setup() {
    require_root
    cat >/etc/systemd/system/${WM_WATCHDOG_SERVICE} <<EOF
[Unit]
Description=WARP Manager - fail-open watchdog (protects the tunnel)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-manager --watchdog
EOF
    cat >/etc/systemd/system/${WM_WATCHDOG_TIMER} <<EOF
[Unit]
Description=WARP Manager - fail-open watchdog timer

[Timer]
OnBootSec=30
OnUnitActiveSec=20
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${WM_WATCHDOG_TIMER}" >/dev/null 2>&1 || true
}

# probe an HTTP(S) endpoint; while the redirect is installed this exercises the
# full divert path (nft mark -> lo -> tproxy -> sing-box -> direct outbound)
_watchdog_probe() {
    curl -s --max-time 6 -o /dev/null "https://www.gstatic.com/generate_204" 2>/dev/null \
        || curl -s --max-time 6 -o /dev/null "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null
}

watchdog_run() {
    require_root
    # A planned engine restart (ad-list refresh, re-apply) is not a fault.
    wm_maintenance_active && return 0
    # Keep the menu's exit-IP cache warm; this runs every 20s anyway, so the header
    # is correct shortly after WARP comes up without anyone opening the menu.
    _warp_cache_stale && warp_cache_refresh_bg

    # The config is written either for a working WARP tunnel or for "degraded"
    # (selected services go direct). If reality no longer matches what the running
    # config assumes, rebuild it — otherwise a tunnel that came back stays unused,
    # or one that went away keeps black-holing the selected services.
    if singbox_is_up; then
        local want have streak
        want="$(warp_is_healthy && echo warp || echo degraded)"
        have="$(cat "${WM_STATE_DIR}/singbox.mode" 2>/dev/null || echo warp)"
        if [[ "$want" != "$have" ]]; then
            # Rebuilding restarts the engine, so never do it on a single reading.
            # Require the new state to hold for a few consecutive checks (~1 min);
            # a transient blip then costs nothing instead of a restart.
            streak=$(( $(cat "${WM_STATE_DIR}/mode.streak" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$streak" >"${WM_STATE_DIR}/mode.streak" 2>/dev/null || true
            if (( streak >= 3 )); then
                log_info "watchdog: WARP is now ${want}; rebuilding the engine config."
                rm -f "${WM_STATE_DIR}/mode.streak"
                singbox_reload >/dev/null 2>&1 || true
            fi
        else
            rm -f "${WM_STATE_DIR}/mode.streak" 2>/dev/null || true
        fi
    fi
    if ! singbox_is_up; then
        if routing_installed; then
            routing_teardown
            date +%s >"$WM_WATCHDOG_STATE" 2>/dev/null
            log_warn "watchdog: sing-box is down — redirect removed (fail-open, tunnel safe)."
        fi
        return 0
    fi
    if routing_installed; then
        # two probes must BOTH fail before we fail open (avoids one-off blips)
        if ! _watchdog_probe && ! _watchdog_probe; then
            routing_teardown
            date +%s >"$WM_WATCHDOG_STATE" 2>/dev/null
            log_warn "watchdog: divert path unhealthy — redirect removed (fail-open, tunnel safe)."
        fi
    else
        # Self-heal ONLY after our own fail-open (state file present) — never
        # override an admin who removed the redirect on purpose. Wait at least
        # 5 min after the fail-open so an unhealthy engine can't flap on/off.
        [[ -f "$WM_WATCHDOG_STATE" ]] || return 0
        local last now
        last="$(cat "$WM_WATCHDOG_STATE" 2>/dev/null || echo 0)"; now="$(date +%s)"
        if (( now - last >= 300 )) && warp_is_up && _watchdog_probe; then
            routing_apply
            rm -f "$WM_WATCHDOG_STATE"
            log_info "watchdog: healthy again — redirect re-applied."
        fi
    fi
    return 0
}
