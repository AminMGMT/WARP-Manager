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

    jq -n \
        --argjson geos "$geos_json" \
        --argjson domains "$doms_json" \
        --argjson has_v6 "$has_v6" \
        --arg port "$WM_SINGBOX_PORT" \
        --arg warpmark "$WM_MARK_WARP" \
        --arg dirmark "$WM_MARK_DIRECT" '
    {
      log: { level: "warn", timestamp: true },
      inbounds: (
        [ { type:"tproxy", tag:"tproxy4", listen:"127.0.0.1", listen_port:($port|tonumber),
            sniff:true, sniff_override_destination:false } ]
        + ( if $has_v6 then
              [ { type:"tproxy", tag:"tproxy6", listen:"::1", listen_port:($port|tonumber),
                  sniff:true, sniff_override_destination:false } ]
            else [] end )
      ),
      outbounds: [
        { type:"direct", tag:"warp",   routing_mark:($warpmark|tonumber) },
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
          [ { domain_suffix: [".youtube.com",".googlevideo.com",".ytimg.com",".ggpht.com"], outbound:"direct" },
            { domain: ["youtube.com","youtu.be","googlevideo.com","ytimg.com","youtubei.googleapis.com",
                       "clients3.google.com","clients4.google.com"], outbound:"direct" } ]
          +
          # Block QUIC (UDP) of the SELECTED services first, so the app falls back to
          # TCP — which we route through WARP reliably. QUIC-over-WARP is flaky (UDP
          # through the tunnel), and a native app that sticks to QUIC would otherwise
          # hang. Non-selected traffic keeps its QUIC (goes direct untouched).
          ( if ($geos|length)    > 0 then [ { network:"udp", rule_set: ($geos|map("geosite-"+.)), outbound:"block" } ] else [] end )
          +
          ( if ($domains|length) > 0 then [ { network:"udp", domain: $domains, outbound:"block" },
                                            { network:"udp", domain_suffix: ($domains|map("."+.)), outbound:"block" } ] else [] end )
          +
          ( if ($geos|length)    > 0 then [ { rule_set: ($geos|map("geosite-"+.)), outbound:"warp" } ] else [] end )
          +
          ( if ($domains|length) > 0 then [ { domain: $domains, outbound:"warp" },
                                            { domain_suffix: ($domains|map("."+.)), outbound:"warp" } ] else [] end )
        ),
        rule_set: ( $geos | map({
          tag:("geosite-"+.), type:"remote", format:"binary",
          url:("https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-"+.+".srs"),
          download_detour:"direct", update_interval:"24h"
        }) ),
        final: "direct"
      }
    }' > "$WM_SINGBOX_CONF"
    chmod 644 "$WM_SINGBOX_CONF"
    log_info "sing-box config written (${ng} rule-sets, ${nd} domains)."
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
        systemctl restart "${WM_SINGBOX_SERVICE}"
        sleep 1
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
