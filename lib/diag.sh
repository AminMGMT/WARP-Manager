#!/usr/bin/env bash
# WARP Manager - traffic diagnose.
# Requires common.sh, warp.sh, routing.sh, singbox.sh sourced first.
#
# Answers one question the status screen cannot: "my users' traffic is not going
# through WARP — where does it actually leave this server, and is that path
# intercepted?" There are exactly two paths, and they are intercepted by two
# different nftables hooks:
#
#   local     - the server itself opens the connection to the site. Every proxy
#               that terminates the client session does this: Xray/marznode,
#               Hiddify, Shadowsocks/Outline on --net=host, plus curl & co.
#               Intercepted in the OUTPUT hook.
#   forwarded - the client's own packets are ROUTED through the box. OpenVPN and
#               WireGuard servers work this way, and so does any proxy inside a
#               bridged Docker container. Intercepted in the PREROUTING hook.
#
# Until the prerouting path existed, an OpenVPN box was never touched at all: the
# tunnel worked, and every site saw the server's plain IP. This screen makes that
# visible instead of leaving it to be guessed.

_diag_ok()   { printf '%s✔%s' "$C_GREEN" "$C_RESET"; }
_diag_bad()  { printf '%s✘%s' "$C_RED" "$C_RESET"; }
_diag_dash() { printf '%s–%s' "$C_GRAY" "$C_RESET"; }

# summed packet counters of a chain (the divert rules carry `counter`)
_diag_packets() {
    nft list chain inet "$WM_NFT_TABLE" "$1" 2>/dev/null \
        | grep -oE 'counter packets [0-9]+' | awk '{s+=$3} END {print s+0}'
}

_diag_row() {   # what where covered-flag note
    printf '   %-22s %-13s %s %s\n' "$1" "$2" "$3" "${4:-}"
}

# --- what is running on this box -----------------------------------------
_diag_openvpn() {
    local ifaces svc=""
    ifaces="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 \
              | grep -E '^(tun|tap)[0-9]' | tr '\n' ' ')"
    svc="$(systemctl list-units --no-legend --state=running 'openvpn*' 2>/dev/null \
           | awk '{print $1}' | head -n2 | tr '\n' ' ')"
    svc="${svc% }"
    [[ -z "$ifaces$svc" ]] && { pgrep -x openvpn >/dev/null 2>&1 && svc="openvpn (process)"; }
    [[ -z "$ifaces$svc" ]] && return 1
    printf '%s%s' "${svc}" "${ifaces:+${svc:+/ }${ifaces}}"
}

_diag_wg_servers() {
    local n out=""
    while read -r n; do
        n="${n%%@*}"
        [[ -z "$n" || "$n" == "$WM_IFACE" ]] && continue
        case " $out " in *" $n "*) continue ;; esac
        out+="$n "
    done < <( { ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}';
                wg show interfaces 2>/dev/null | tr ' ' '\n'; } )
    [[ -n "$out" ]] && printf '%s' "${out% }"
}

# every running container that matches a proxy name/image, with its network mode
_diag_containers() {
    local name img net
    while read -r name img; do
        [[ -z "$name" ]] && continue
        net="$(_wm_docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")"
        printf '%s\t%s\t%s\n' "$name" "${net:-?}" "$img"
    done < <(_wm_docker ps --format '{{.Names}} {{.Image}}' | grep -iE "$WM_PROXY_CONTAINER_RE")
}

# host-networked proxies that dial out themselves (Xray, outline-ss-server, ...)
_diag_host_proxies() {
    local p out=""
    for p in xray v2ray sing-box hysteria outline-ss-server ss-server shadowsocks-libev trojan; do
        pgrep -x "$p" >/dev/null 2>&1 && out+="$p "
    done
    [[ -n "$out" ]] && printf '%s' "${out% }"
}

# does the installed forward divert cover an interface with this name?
_diag_iface_covered() {   # iface-name
    local pat
    while read -r pat; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053
        [[ "$1" == $pat ]] && return 0
    done < <(routing_forward_ifaces)
    return 1
}

diag_run() {
    require_root
    local fwd_pats fwd_on=0
    fwd_pats="$(routing_forward_ifaces | grep -vE '^[[:space:]]*$' | sort -u | tr '\n' ' ')"
    [[ -n "$fwd_pats" ]] && fwd_on=1

    printf '\n %sTraffic Diagnose%s\n\n' "$C_BOLD$C_PRIMARY" "$C_RESET"

    printf ' %sEngine%s\n' "$C_PRIMARY$C_BOLD" "$C_RESET"
    printf '   WARP tunnel          %s\n' "$(warp_is_up && printf '%s● up%s' "$C_GREEN" "$C_RESET" || printf '%s○ down%s' "$C_RED" "$C_RESET")"
    printf '   sing-box             %s\n' "$(singbox_is_up && singbox_is_listening && printf '%s● listening on %s%s' "$C_GREEN" "$WM_SINGBOX_PORT" "$C_RESET" || printf '%s○ not ready%s' "$C_RED" "$C_RESET")"
    printf '   nftables redirect    %s\n\n' "$(routing_installed && printf '%s● installed%s' "$C_GREEN" "$C_RESET" || printf '%s○ absent%s' "$C_RED" "$C_RESET")"

    printf ' %sInterception paths%s   %s(where traffic can be caught)%s\n' "$C_PRIMARY$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '   %-22s %s   %spackets %s%s\n' "local (output hook)" \
        "$(routing_installed && printf '%son%s ' "$C_GREEN" "$C_RESET" || printf '%soff%s' "$C_GRAY" "$C_RESET")" \
        "$C_GRAY" "$(_diag_packets mangle_output)" "$C_RESET"
    printf '     %sthe server dials out itself — Xray/marznode, Hiddify, Outline on --net=host%s\n' "$C_GRAY" "$C_RESET"
    if [[ "$fwd_on" -eq 1 ]]; then
        printf '   %-22s %s   %spackets %s%s\n' "forwarded (prerouting)" \
            "$(routing_installed && printf '%son%s ' "$C_GREEN" "$C_RESET" || printf '%soff%s' "$C_GRAY" "$C_RESET")" \
            "$C_GRAY" "$(_diag_packets fwd_divert)" "$C_RESET"
        printf '     %sinterfaces: %s(mode: %s)%s\n' "$C_GRAY" "$fwd_pats" "$(routing_forward_mode)" "$C_RESET"
    else
        printf '   %-22s %soff%s\n' "forwarded (prerouting)" "$C_GRAY" "$C_RESET"
        printf '     %spackets routed THROUGH the box — OpenVPN, WireGuard server, bridged Docker%s\n' "$C_GRAY" "$C_RESET"
    fi
    echo

    # --- what is on the box, and is its path covered ---------------------
    printf ' %sDetected on this server%s\n' "$C_PRIMARY$C_BOLD" "$C_RESET"
    local found=0 missing=0 v n net img

    if v="$(_diag_openvpn)"; then
        found=1
        if _diag_iface_covered tun0 || _diag_iface_covered tap0; then
            _diag_row "OpenVPN" "forwarded" "$(_diag_ok)" "$C_GRAY${v}$C_RESET"
        else
            missing=1
            _diag_row "OpenVPN" "forwarded" "$(_diag_bad)" "${C_YELLOW}not intercepted${C_RESET} ${C_GRAY}${v}${C_RESET}"
        fi
    fi

    if v="$(_diag_wg_servers)"; then
        found=1
        for n in $v; do
            if _diag_iface_covered "$n"; then
                _diag_row "WireGuard ($n)" "forwarded" "$(_diag_ok)" ""
            else
                missing=1
                _diag_row "WireGuard ($n)" "forwarded" "$(_diag_bad)" "${C_YELLOW}not intercepted${C_RESET}"
            fi
        done
    fi

    while IFS=$'\t' read -r n net img; do
        [[ -z "$n" ]] && continue
        found=1
        if [[ "$net" == host ]]; then
            # shares the host netns: its outbound IS locally generated
            _diag_row "$n (docker)" "local" "$(routing_installed && _diag_ok || _diag_bad)" \
                "${C_GRAY}--net=host, ${img}${C_RESET}"
        elif _diag_iface_covered docker0 || _diag_iface_covered "br-$net"; then
            _diag_row "$n (docker)" "forwarded" "$(_diag_ok)" "${C_GRAY}net=${net}, ${img}${C_RESET}"
        else
            missing=1
            _diag_row "$n (docker)" "forwarded" "$(_diag_bad)" \
                "${C_YELLOW}not intercepted${C_RESET} ${C_GRAY}net=${net}${C_RESET}"
        fi
    done < <(_diag_containers)

    if v="$(_diag_host_proxies)"; then
        found=1
        _diag_row "$v" "local" "$(routing_installed && _diag_ok || _diag_bad)" "${C_GRAY}runs on the host${C_RESET}"
    fi

    [[ "$found" -eq 0 ]] && printf '   %sNo VPN/proxy server recognised. Only this box'"'"'s own traffic is routed.%s\n' "$C_GRAY" "$C_RESET"
    echo

    # --- verdict ---------------------------------------------------------
    printf ' %sVerdict%s\n' "$C_PRIMARY$C_BOLD" "$C_RESET"
    if ! routing_installed; then
        printf '   %sThe redirect is not installed — nothing is being routed through WARP.%s\n' "$C_RED" "$C_RESET"
        printf '   %sRestart All Services, or check whether the watchdog failed open.%s\n' "$C_GRAY" "$C_RESET"
    elif [[ "$missing" -eq 1 ]]; then
        printf '   %sSomething on this server sends its users'"'"' traffic on a path that is not%s\n' "$C_YELLOW" "$C_RESET"
        printf '   %sintercepted, so those users keep the server'"'"'s plain IP.%s\n' "$C_YELLOW" "$C_RESET"
        printf '   %sFix: WARP → Connection → Client Traffic → set the mode to "all".%s\n' "$C_WHITE" "$C_RESET"
    elif [[ "$fwd_on" -eq 1 && "$(_diag_packets fwd_divert)" == "0" ]]; then
        printf '   %sEverything is wired up, but no forwarded packet has hit the divert yet.%s\n' "$C_YELLOW" "$C_RESET"
        printf '   %sConnect a client and re-run this screen; if it stays 0 the traffic is not%s\n' "$C_GRAY" "$C_RESET"
        printf '   %sarriving on %s.%s\n' "$C_GRAY" "$fwd_pats" "$C_RESET"
    else
        printf '   %sEvery detected path is intercepted.%s\n' "$C_GREEN" "$C_RESET"
    fi
    echo
}
