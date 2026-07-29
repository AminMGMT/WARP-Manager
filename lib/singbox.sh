#!/usr/bin/env bash
# WARP Manager - sing-box engine (SNI-based selective routing)
# Requires common.sh (and providers.sh for prov_field/providers_list) sourced first.
#
# sing-box listens on loopback as a `tproxy` inbound (TCP + UDP), sniffs the domain
# from each connection (TLS SNI and QUIC ClientHello), and sends the selected
# services out via WARP (routing_mark 51888 -> table 51888 -> wgcf) while everything
# else goes direct. Apps work because routing is decided by the real domain, not by
# pre-resolved IPs, and because QUIC/UDP 443 is routed too (not just TCP).

WM_SINGBOX_SERVICE="warp-manager-singbox.service"

_is_elf_sb() { [[ -s "$1" ]] && head -c4 "$1" 2>/dev/null | grep -qa ELF; }

# --- install the sing-box binary -----------------------------------------
singbox_install() {
    if [[ -x "$WM_SINGBOX_BIN" ]] && _is_elf_sb "$WM_SINGBOX_BIN"; then return 0; fi
    log_step "Installing sing-box..."
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) die "Unsupported architecture for sing-box: $(uname -m)" ;;
    esac
    local ver tmp url
    for ver in "$WM_SINGBOX_VER" 1.10.6 1.10.5 1.10.3; do
        url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
        tmp="$(mktemp -d)"
        log_step "  trying sing-box ${ver}..."
        if curl -fsSL --connect-timeout 20 -o "$tmp/sb.tgz" "$url" \
           && tar -xzf "$tmp/sb.tgz" -C "$tmp" \
           && [[ -f "$tmp/sing-box-${ver}-linux-${arch}/sing-box" ]]; then
            install -m 755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$WM_SINGBOX_BIN"
            rm -rf "$tmp"
            if _is_elf_sb "$WM_SINGBOX_BIN"; then log_info "sing-box ${ver} installed."; return 0; fi
        fi
        rm -rf "$tmp"
        log_warn "  sing-box ${ver} download failed."
    done
    die "Could not install sing-box (network/GitHub blocked?)."
}

# --- geosite rule-sets, cached locally -----------------------------------
# sing-box can fetch remote rule-sets itself, but that makes GitHub a RUNTIME
# dependency: on a server where raw.githubusercontent.com is slow or filtered the
# engine stalls or crash-loops at startup — and because every outbound 80/443 is
# already being diverted into it, that takes the whole server's traffic down with
# it. So we download them ourselves, keep them on disk, and hand sing-box local
# files only. A failed download degrades to "this category is not matched" instead
# of breaking the engine.
WM_RULESET_DIR="${WM_STATE_DIR}/rulesets"
WM_RULESET_MAX_AGE=$(( 7 * 86400 ))
_singbox_geosite_url() {
    printf 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-%s.srs' "$1"
}

# Download a geosite rule-set if missing or stale. Never removes a usable file.
singbox_fetch_ruleset() {
    local name="$1" dest="${WM_RULESET_DIR}/geosite-${name}.srs" age tmp
    mkdir -p "$WM_RULESET_DIR"
    if [[ -s "$dest" ]]; then
        age=$(( $(date +%s) - $(stat -c %Y "$dest" 2>/dev/null || echo 0) ))
        (( age < WM_RULESET_MAX_AGE )) && return 0
    fi
    tmp="$(mktemp)"
    if curl -fsSL --connect-timeout 15 --max-time 90 -o "$tmp" "$(_singbox_geosite_url "$name")" \
       && [[ -s "$tmp" ]]; then
        install -m 644 "$tmp" "$dest"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"
    # keep whatever we already had; only report failure when there is nothing
    [[ -s "$dest" ]]
}

# Echo the geosite names we actually have a local rule-set for.
singbox_available_rulesets() {
    local n
    for n in "$@"; do
        [[ -z "$n" ]] && continue
        if singbox_fetch_ruleset "$n"; then printf '%s\n' "$n"
        else log_warn "geosite '${n}' could not be downloaded; its category will not be matched."; fi
    done
}

# --- generate the sing-box config from the enabled providers -------------
singbox_write_config() {
    ensure_dirs
    local geosf domsf id cat
    geosf="$(mktemp)"; domsf="$(mktemp)"
    while read -r id; do
        [[ -z "$id" ]] && continue
        [[ -f "$WM_PROVIDERS_DIR/${id}.conf" ]] || continue
        cat="$(prov_field "$id" category)"
        [[ -n "$cat" ]] && printf '%s\n' "$cat" >>"$geosf"
        # split the space-separated domain list into one-per-line (shell-agnostic)
        prov_field "$id" domains | tr ' ' '\n' >>"$domsf"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$WM_ENABLED_FILE" 2>/dev/null)

    # keep only the categories we have a local rule-set for (see above)
    local avail; avail="$(singbox_available_rulesets $(grep -vE '^[[:space:]]*$' "$geosf" | sort -u))"
    printf '%s\n' "$avail" >"$geosf"

    local geos_json doms_json
    geos_json="$(grep -vE '^[[:space:]]*$' "$geosf" | sort -u | jq -R . | jq -s .)"
    doms_json="$(grep -vE '^[[:space:]]*$' "$domsf" | sort -u | jq -R . | jq -s .)"
    [[ -z "$geos_json" ]] && geos_json='[]'
    [[ -z "$doms_json" ]] && doms_json='[]'
    local ng nd; ng=$(grep -vcE '^[[:space:]]*$' "$geosf"); nd=$(grep -vcE '^[[:space:]]*$' "$domsf")
    rm -f "$geosf" "$domsf"

    # A tproxy inbound handles both TCP and UDP (QUIC), so sing-box can sniff the
    # SNI out of QUIC ClientHello too and route apps (not just browsers) via WARP.
    # The IPv6 inbound is only added when the host actually has ::1 (many VPS don't).
    local has_v6=false; wm_have_v6 && has_v6=true

    # Ad blocker: only wired in when it is enabled AND a built list exists, so a
    # missing/failed download can never leave sing-box pointing at a dead rule-set.
    local ads=false ads_path="" ads_format="" allow_json='[]'
    if adblock_is_enabled && adblock_has_list && singbox_fetch_ruleset "$WM_ADBLOCK_GEOSITE"; then
        ads=true
        ads_path="$(adblock_ruleset_path)"
        ads_format="$(adblock_ruleset_format)"
        allow_json="$(adblock_allow_domains | jq -R . | jq -s .)"
        [[ -z "$allow_json" ]] && allow_json='[]'
    fi

    # If WARP is down, sending the selected services to it would blackhole them
    # (mark -> table 51888 -> a device that is gone), which surfaces as TLS
    # "unexpected eof" on every selected site. Degrade to direct instead: the
    # services lose their clean IP but keep working, and the watchdog restores
    # the WARP path as soon as the tunnel is back.
    # In light mode QUIC never reaches the engine (nft drops it), so the inbound is
    # TCP-only and the per-service QUIC block rules are pointless.
    local qmode; qmode="$(routing_quic_mode)"
    local net_json='null'; [[ "$qmode" == light ]] && net_json='"tcp"'

    local warp_mode="warp"; warp_is_up || warp_mode="degraded"
    [[ "$warp_mode" == "degraded" ]] && log_warn "WARP is down; selected services will go direct until it is back."

    jq -n \
        --argjson geos "$geos_json" \
        --argjson domains "$doms_json" \
        --argjson has_v6 "$has_v6" \
        --argjson ads "$ads" \
        --argjson allow "$allow_json" \
        --arg adspath "$ads_path" \
        --arg adsformat "$ads_format" \
        --arg adsgeosite "$WM_ADBLOCK_GEOSITE" \
        --arg rsdir "$WM_RULESET_DIR" \
        --arg warpmode "$warp_mode" \
        --argjson net "$net_json" \
        --arg port "$WM_SINGBOX_PORT" \
        --arg warpmark "$WM_MARK_WARP" \
        --arg dirmark "$WM_MARK_DIRECT" '
    {
      log: { level: "warn", timestamp: true },
      inbounds: (
        [ ( { type:"tproxy", tag:"tproxy4", listen:"127.0.0.1", listen_port:($port|tonumber),
              sniff:true, sniff_override_destination:false }
            + ( if $net then {network:$net} else {} end ) ) ]
        + ( if $has_v6 then
              [ ( { type:"tproxy", tag:"tproxy6", listen:"::1", listen_port:($port|tonumber),
                    sniff:true, sniff_override_destination:false }
                  + ( if $net then {network:$net} else {} end ) ) ]
            else [] end )
      ),
      outbounds: [
        # In degraded mode the "warp" outbound is a plain direct one: the tunnel is
        # down, so marking would only send the traffic into a black hole.
        ( if $warpmode == "warp"
          then { type:"direct", tag:"warp", routing_mark:($warpmark|tonumber) }
          else { type:"direct", tag:"warp", routing_mark:($dirmark|tonumber) } end ),
        { type:"direct", tag:"direct", routing_mark:($dirmark|tonumber) },
        { type:"block",  tag:"block" }
      ],
      route: {
        rules: (
          # Carve-outs that always stay direct, placed first so they win over the
          # broad google.com / googleapis.com WARP rules below:
          #  - YouTube: keeps heavy video off the tunnel (youtubei.googleapis.com is
          #    YouTube''s API).
          #  - clients3/clients4.google.com: Android/client connectivity checks
          #    (generate_204) — client apps measure their "config ping" against
          #    these; they must never depend on WARP''s health.
          # Connectivity-check endpoints are pinned to direct on purpose: client apps
          # (V2rayNG & co) measure their "config ping" against them, so they must
          # never depend on WARP being healthy.
          # Two deliberate omissions:
          #  - ".apple.com" would pull music.apple.com out of the Apple Music routing.
          #  - "www.google.com" stays on WARP: the Gemini app talks to it, and routing
          #    is per-domain, so it cannot be direct for /generate_204 and WARP for the
          #    app. Point clients at gstatic.com/generate_204 for a WARP-independent ping.
          [ { domain_suffix: [".youtube.com",".googlevideo.com",".ytimg.com",".ggpht.com",
                              ".gstatic.com",".msftconnecttest.com",".msftncsi.com"], outbound:"direct" },
            { domain: ["youtube.com","youtu.be","googlevideo.com","ytimg.com","youtubei.googleapis.com",
                       "clients3.google.com","clients4.google.com",
                       "gstatic.com","www.gstatic.com","connectivitycheck.gstatic.com",
                       "www.apple.com","captive.apple.com",
                       "msftconnecttest.com","www.msftconnecttest.com","msftncsi.com","www.msftncsi.com",
                       "detectportal.firefox.com"], outbound:"direct" } ]
          +
          # Ad blocker. The allow list is matched BEFORE the block rule so a false
          # positive can always be undone from the menu, and blocking happens before
          # the WARP rules so ads are dropped rather than tunnelled.
          ( if $ads and ($allow|length) > 0
            then [ { domain: $allow, outbound:"direct" },
                   { domain_suffix: ($allow|map("."+.)), outbound:"direct" } ]
            else [] end )
          +
          ( if $ads then [ { rule_set: ["adguard-ads","geosite-"+$adsgeosite], outbound:"block" } ] else [] end )
          +
          # Block QUIC (UDP) of the SELECTED services, so the app falls back to TCP —
          # which we route through WARP reliably. QUIC-over-WARP is flaky (UDP through
          # the tunnel), and a native app that sticks to QUIC would otherwise hang.
          # Skipped entirely in light mode: there, nft already drops QUIC before it
          # can reach the engine, so no UDP ever arrives here.
          ( if $net then [] else
            ( if ($geos|length)    > 0 then [ { network:"udp", rule_set: ($geos|map("geosite-"+.)), outbound:"block" } ] else [] end )
            +
            ( if ($domains|length) > 0 then [ { network:"udp", domain: $domains, outbound:"block" },
                                              { network:"udp", domain_suffix: ($domains|map("."+.)), outbound:"block" } ] else [] end )
            end )
          +
          ( if ($geos|length)    > 0 then [ { rule_set: ($geos|map("geosite-"+.)), outbound:"warp" } ] else [] end )
          +
          ( if ($domains|length) > 0 then [ { domain: $domains, outbound:"warp" },
                                            { domain_suffix: ($domains|map("."+.)), outbound:"warp" } ] else [] end )
        ),
        # All rule-sets are local files: sing-box never reaches out to GitHub while
        # it is on the traffic path (see singbox_fetch_ruleset).
        rule_set: ( ( $geos | map({
          tag:("geosite-"+.), type:"local", format:"binary",
          path:($rsdir + "/geosite-" + . + ".srs")
        }) )
        + ( if $ads
            then [ # locally built from the AdGuard DNS filter
                   { tag:"adguard-ads", type:"local", format:$adsformat, path:$adspath },
                   # second source: the ready-made ads rule-set, also cached locally
                   { tag:("geosite-"+$adsgeosite), type:"local", format:"binary",
                     path:($rsdir + "/geosite-" + $adsgeosite + ".srs") } ]
            else [] end ) ),
        final: "direct"
      }
    }' > "$WM_SINGBOX_CONF"
    chmod 644 "$WM_SINGBOX_CONF"
    # remember which mode this config was written for, so the watchdog can rebuild
    # it when WARP comes back (or goes away) instead of leaving it stale
    printf '%s\n' "$warp_mode" >"${WM_STATE_DIR}/singbox.mode" 2>/dev/null || true
    if [[ "$ads" == true ]]; then
        log_info "sing-box config written (${ng} rule-sets, ${nd} domains, ad blocker on: $(adblock_count) domains)."
    else
        log_info "sing-box config written (${ng} rule-sets, ${nd} domains)."
    fi
}

# --- systemd service -----------------------------------------------------
singbox_service_setup() {
    require_root
    cat >/etc/systemd/system/${WM_SINGBOX_SERVICE} <<EOF
[Unit]
Description=WARP Manager - sing-box selective routing engine
After=network-online.target wg-quick@${WM_IFACE}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WM_SINGBOX_BIN} run -c ${WM_SINGBOX_CONF}
Restart=on-failure
RestartSec=3
# needs CAP_NET_ADMIN (runs as root) to set the routing mark on outbound sockets

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${WM_SINGBOX_SERVICE}" >/dev/null 2>&1 || true
}

singbox_reload() {
    require_root
    singbox_write_config
    if "$WM_SINGBOX_BIN" check -c "$WM_SINGBOX_CONF" >/dev/null 2>&1; then
        # Tell the watchdog this restart is intentional, so the short gap while
        # sing-box comes back is not treated as a failure and does not fail open.
        wm_maintenance_begin
        # Take the divert rules down FIRST. While sing-box is restarting its tproxy
        # socket is gone, and any traffic still being diverted would be blackholed —
        # that is what makes a reload look like the whole tunnel dropping. With the
        # rules off, traffic simply flows direct for a moment.
        local had_rules=0
        if routing_installed; then had_rules=1; routing_teardown >/dev/null 2>&1; fi
        systemctl restart "${WM_SINGBOX_SERVICE}"
        if ! singbox_wait_ready 15; then
            log_error "sing-box did not start listening on ${WM_SINGBOX_PORT}; leaving traffic direct."
            wm_maintenance_end
            return 1
        fi
        # Only now is it safe to send traffic back through the engine.
        [[ "$had_rules" -eq 1 ]] && routing_apply >/dev/null 2>&1
        wm_maintenance_end
    else
        log_error "sing-box config check failed:"
        "$WM_SINGBOX_BIN" check -c "$WM_SINGBOX_CONF" 2>&1 | sed 's/^/   /' >&2
        return 1
    fi
    if singbox_is_up; then log_info "sing-box reloaded."; else
        log_error "sing-box failed to start:"; journalctl -u "${WM_SINGBOX_SERVICE}" --no-pager -n 15 >&2
        return 1
    fi
}

singbox_is_up() { systemctl is-active --quiet "${WM_SINGBOX_SERVICE}"; }

# systemd calling the unit "active" is not enough: traffic is only safe once the
# tproxy socket is really accepting. Everything diverted before that is blackholed.
singbox_is_listening() {
    ss -lnt 2>/dev/null | grep -q ":${WM_SINGBOX_PORT}[[:space:]]" \
        || ss -lnu 2>/dev/null | grep -q ":${WM_SINGBOX_PORT}[[:space:]]"
}

# Wait up to N seconds for the engine to actually accept connections.
singbox_wait_ready() {
    local n="${1:-15}"
    while (( n-- > 0 )); do
        singbox_is_listening && return 0
        sleep 1
    done
    return 1
}
