#!/usr/bin/env bash
# WARP Manager - WARP WireGuard engine (wgcf based, non-global / fwmark routing)
# Requires common.sh to be sourced first.

WARP_ENDPOINT="${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}"
WARP_MTU="${WARP_MTU:-1280}"

# --- install the wgcf helper binary --------------------------------------
# true if the file exists and is a real ELF executable (not an HTML error page)
_is_elf() { [[ -s "$1" ]] && head -c4 "$1" 2>/dev/null | grep -qa ELF; }

wgcf_install() {
    if [[ -x "$WM_WGCF_BIN" ]] && _is_elf "$WM_WGCF_BIN"; then return 0; fi
    log_step "Installing wgcf..."
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) die "Unsupported architecture for wgcf: $(uname -m)" ;;
    esac
    # candidate versions: latest from the API first, then known-good fallbacks
    local -a tags=()
    local latest
    latest="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
              | grep -oP '"tag_name":\s*"\K[^"]+' | head -n1)"
    [[ -n "$latest" ]] && tags+=("$latest")
    tags+=(v2.2.27 v2.2.24 v2.2.22 v2.2.19)
    local tag url
    for tag in "${tags[@]}"; do
        url="https://github.com/ViRb3/wgcf/releases/download/${tag}/wgcf_${tag#v}_linux_${arch}"
        log_step "  trying wgcf ${tag}..."
        if curl -fsSL --connect-timeout 15 -o "$WM_WGCF_BIN" "$url" && _is_elf "$WM_WGCF_BIN"; then
            chmod +x "$WM_WGCF_BIN"
            log_info "wgcf ${tag} installed."
            return 0
        fi
        log_warn "  wgcf ${tag} download failed."
    done
    die "Could not install a working wgcf binary (network/GitHub blocked?). Last URL: $url"
}

# --- register a WARP account & generate a profile ------------------------
# Returns 0 on success, 1 on failure (does NOT die, so callers can recover).
warp_register() {
    ensure_dirs
    wgcf_install
    cd "$WM_WGCF_DIR" || { log_error "Could not cd into $WM_WGCF_DIR."; return 1; }
    local acct="$WM_WGCF_DIR/wgcf-account.toml"
    # drop an empty/corrupt leftover so wgcf won't refuse to overwrite it
    [[ -f "$acct" && ! -s "$acct" ]] && rm -f "$acct"

    if [[ ! -s "$acct" ]]; then
        log_step "Registering a WARP account..."
        local n=0 out wait
        while [[ ! -s "$acct" ]]; do
            out="$("$WM_WGCF_BIN" register --accept-tos </dev/null 2>&1)"
            # success = the account file now exists (ignore wgcf's exit code, which
            # can be non-zero even after the account was created), or wgcf reports
            # an account already exists.
            [[ -s "$acct" ]] && break
            grep -qi 'existing account' <<<"$out" && break
            n=$((n+1))
            if [[ $n -ge 5 ]]; then
                if grep -q '429' <<<"$out"; then
                    log_error "Cloudflare rate-limited registration (429) from this server's IP."
                    log_error "Wait a few minutes and retry, or import an account from a working server."
                else
                    log_error "wgcf register failed:"; printf '%s\n' "$out" >&2
                fi
                return 1
            fi
            if grep -q '429' <<<"$out"; then wait=$(( 15 * n )); [[ $wait -gt 45 ]] && wait=45; else wait=5; fi
            log_warn "Registration attempt $n failed; retrying in ${wait}s..."
            sleep "$wait"
        done
    fi

    log_step "Generating WireGuard profile..."
    local gout
    if ! gout="$("$WM_WGCF_BIN" generate --profile "$WM_WGCF_DIR/wgcf-profile.conf" </dev/null 2>&1)"; then
        # a corrupt account can break generate: reset once and retry a fresh register
        log_warn "generate failed ($gout); re-registering a fresh account..."
        rm -f "$acct" "$WM_WGCF_DIR/wgcf-profile.conf"
        "$WM_WGCF_BIN" register --accept-tos </dev/null >/dev/null 2>&1 || true
        if ! gout="$("$WM_WGCF_BIN" generate --profile "$WM_WGCF_DIR/wgcf-profile.conf" </dev/null 2>&1)"; then
            log_error "wgcf generate failed: $gout"
            return 1
        fi
    fi
    log_info "WARP account is ready."
    return 0
}

# Import a wgcf-account.toml registered elsewhere (bypasses 429-blocked IPs).
warp_import_account() {
    require_root
    local src="$1"
    [[ -s "$src" ]] || { log_error "Account file not found: $src"; return 1; }
    grep -qE 'private_key|access_token' "$src" || { log_error "Not a valid wgcf-account.toml: $src"; return 1; }
    ensure_dirs; wgcf_install
    cp -f "$src" "$WM_WGCF_DIR/wgcf-account.toml"
    cd "$WM_WGCF_DIR" || return 1
    if ! "$WM_WGCF_BIN" generate --profile "$WM_WGCF_DIR/wgcf-profile.conf" </dev/null >/dev/null 2>&1; then
        log_error "Could not generate a profile from the imported account."
        return 1
    fi
    local lic; lic="$(conf_get license_key)"; [[ -n "$lic" ]] && warp_apply_license "$lic"
    warp_write_conf
    warp_up
    log_info "Account imported. WARP exit: $(warp_trace_ip)"
}

# --- build our own wg config with non-global fwmark routing --------------
warp_write_conf() {
    local prof="$WM_WGCF_DIR/wgcf-profile.conf"
    [[ -f "$prof" ]] || die "wgcf profile not found; run warp_register first."

    local priv addr4 addr6 pub endpoint
    priv="$(grep -oP '^PrivateKey\s*=\s*\K.*' "$prof" | head -n1)"
    addr4="$(grep -oP '^Address\s*=\s*\K[0-9.]+/[0-9]+' "$prof" | head -n1)"
    addr6="$(grep -oP '^Address\s*=\s*\K[0-9a-fA-F:]+/[0-9]+' "$prof" | head -n1)"
    pub="$(grep -oP '^PublicKey\s*=\s*\K.*' "$prof" | head -n1)"
    endpoint="$(grep -oP '^Endpoint\s*=\s*\K.*' "$prof" | head -n1)"
    [[ -n "$endpoint" ]] || endpoint="$WARP_ENDPOINT"
    [[ -n "$priv" && -n "$pub" && -n "$addr4" ]] || die "Failed to parse wgcf profile."

    mkdir -p /etc/wireguard
    {
        cat <<EOF
# Generated by WARP Manager - do not edit by hand.
# Non-global mode: only packets marked with fwmark ${WM_FWMARK} exit via WARP.
[Interface]
PrivateKey = ${priv}
Address = ${addr4}
EOF
        [[ -n "$addr6" ]] && echo "Address = ${addr6}"
        cat <<EOF
MTU = ${WARP_MTU}
Table = off
PostUp   = ip -4 route add default dev ${WM_IFACE} table ${WM_TABLE}
PostUp   = ip -4 rule add fwmark ${WM_FWMARK} lookup ${WM_TABLE}
PostUp   = ip -4 rule add from ${addr4%%/*} lookup ${WM_TABLE}
PostUp   = ip -6 route add default dev ${WM_IFACE} table ${WM_TABLE} 2>/dev/null || true
PostUp   = ip -6 rule add fwmark ${WM_FWMARK} lookup ${WM_TABLE} 2>/dev/null || true
$( [[ -n "$addr6" ]] && echo "PostUp   = ip -6 rule add from ${addr6%%/*} lookup ${WM_TABLE} 2>/dev/null || true" )
PostDown = ip -4 rule del fwmark ${WM_FWMARK} lookup ${WM_TABLE} 2>/dev/null || true
PostDown = ip -4 rule del from ${addr4%%/*} lookup ${WM_TABLE} 2>/dev/null || true
PostDown = ip -6 rule del fwmark ${WM_FWMARK} lookup ${WM_TABLE} 2>/dev/null || true
$( [[ -n "$addr6" ]] && echo "PostDown = ip -6 rule del from ${addr6%%/*} lookup ${WM_TABLE} 2>/dev/null || true" )
PostDown = ip -4 route flush table ${WM_TABLE} 2>/dev/null || true
PostDown = ip -6 route flush table ${WM_TABLE} 2>/dev/null || true

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}
PersistentKeepalive = 25
EOF
    } >"$WM_WG_CONF"
    chmod 600 "$WM_WG_CONF"
    log_info "WireGuard config written: ${WM_WG_CONF}"
}

# Make sure a WARP account is registered and the wg config exists (self-healing).
# Returns 1 (without dying) if registration is blocked, so callers can recover.
warp_ensure_config() {
    if [[ ! -f "$WM_WG_CONF" ]]; then
        log_warn "WARP config not found; setting up WARP now..."
        warp_register || return 1
        warp_write_conf
    elif [[ ! -f "$WM_WGCF_DIR/wgcf-profile.conf" ]]; then
        warp_register || return 1
        warp_write_conf
    fi
    [[ -f "$WM_WG_CONF" ]]
}

warp_up() {
    require_root
    warp_ensure_config || { log_error "WARP is not configured (registration blocked?). Import an account or retry."; return 1; }
    _warp_sysctl
    systemctl enable "wg-quick@${WM_IFACE}" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "wg-quick@${WM_IFACE}"; then
        systemctl restart "wg-quick@${WM_IFACE}"
    else
        systemctl start "wg-quick@${WM_IFACE}"
    fi
    sleep 1
    if systemctl is-active --quiet "wg-quick@${WM_IFACE}"; then
        log_info "WARP interface (${WM_IFACE}) is up."
    else
        log_error "Failed to bring up the WARP interface:"
        journalctl -u "wg-quick@${WM_IFACE}" --no-pager -n 20 >&2 || true
        return 1
    fi
}

warp_down() {
    require_root
    systemctl disable "wg-quick@${WM_IFACE}" >/dev/null 2>&1 || true
    systemctl stop "wg-quick@${WM_IFACE}" >/dev/null 2>&1 || true
    rm -f "$WM_EXIT_IP_CACHE"        # stale IP must not linger in the header
    log_info "WARP interface stopped."
}

warp_restart() {
    require_root
    warp_ensure_config
    systemctl restart "wg-quick@${WM_IFACE}" || { log_error "Restart failed:"; journalctl -u "wg-quick@${WM_IFACE}" --no-pager -n 15 >&2; return 1; }
    sleep 1
    warp_status_short
}

_warp_sysctl() {
    # loose reverse-path filtering so WARP replies are accepted
    cat >/etc/sysctl.d/99-warp-manager.conf <<EOF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv6.conf.all.forwarding = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null 2>&1 || true
}

warp_is_up() { systemctl is-active --quiet "wg-quick@${WM_IFACE}"; }

warp_status_short() {
    if warp_is_up; then
        echo "${C_GREEN}running${C_RESET}"
    else
        echo "${C_RED}stopped${C_RESET}"
    fi
}

# Query the exit identity as seen *through* WARP (forces egress via the wgcf device).
# Bounded by --max-time so a dead tunnel can never hang the caller; the result is
# cached so the menu header can render instantly without touching the network.
warp_trace_ip() {
    warp_is_up || { echo "-"; return; }
    local out
    out="$(curl -s --interface "$WM_IFACE" --connect-timeout 4 --max-time 8 "$CF_TRACE_URL" 2>/dev/null \
        | awk -F= '/^ip=/{ip=$2} /^warp=/{w=$2} END{if(ip!="")printf "%s (warp=%s)",ip,w; else print "-"}')"
    [[ -z "$out" ]] && out="-"
    # refresh the cache only on a real answer, so a transient failure keeps the last IP
    [[ "$out" != "-" ]] && printf '%s' "$out" >"$WM_EXIT_IP_CACHE" 2>/dev/null
    printf '%s\n' "$out"
}

# Instant, non-blocking exit IP for the menu header: reads the cached value only.
# Never touches the network, so redrawing a menu is always fast.
warp_exit_ip_cached() {
    warp_is_up || { echo "-"; return; }
    if [[ -s "$WM_EXIT_IP_CACHE" ]]; then cat "$WM_EXIT_IP_CACHE"; else echo "-"; fi
}

# Show geo/location of the WARP exit (country + Cloudflare datacenter + city).
warp_location() {
    warp_is_up || { echo "WARP is not running."; return; }
    local t ip loc colo
    t="$(curl -s --interface "$WM_IFACE" --connect-timeout 4 --max-time 8 "$CF_TRACE_URL" 2>/dev/null)"
    ip="$(awk -F= '/^ip=/{print $2}' <<<"$t")"
    loc="$(awk -F= '/^loc=/{print $2}' <<<"$t")"
    colo="$(awk -F= '/^colo=/{print $2}' <<<"$t")"
    [[ -z "$ip" ]] && { echo "Could not reach Cloudflare through WARP."; return; }
    # bonus: city/org via ipinfo (best effort, may be unavailable)
    local city org info
    info="$(curl -s --interface "$WM_IFACE" --connect-timeout 4 --max-time 8 "https://ipinfo.io/${ip}/json" 2>/dev/null)"
    city="$(grep -oP '"city":\s*"\K[^"]+' <<<"$info" 2>/dev/null)"
    org="$(grep -oP '"org":\s*"\K[^"]+'  <<<"$info" 2>/dev/null)"
    printf 'IP:          %s\n' "$ip"
    printf 'Country:     %s\n' "${loc:-?}"
    printf 'CF datacenter: %s\n' "${colo:-?}"
    [[ -n "$city" ]] && printf 'City:        %s\n' "$city"
    [[ -n "$org"  ]] && printf 'Network:     %s\n' "$org"
}

# Register a fresh WARP account -> new exit IP. Re-applies a stored license if any.
warp_change_ip() {
    require_root
    log_step "Creating a new WARP account (changing IP)..."
    rm -f "$WM_WGCF_DIR/wgcf-account.toml" "$WM_WGCF_DIR/wgcf-profile.conf"
    warp_register || { log_error "Registration failed (rate-limited?). Keeping previous account if any."; return 1; }
    local lic; lic="$(conf_get license_key)"
    [[ -n "$lic" ]] && warp_apply_license "$lic"
    warp_write_conf
    warp_up
    log_info "New WARP IP: $(warp_trace_ip)"
}

# Apply a WARP+ license key to the current account.
warp_apply_license() {
    require_root
    local key="$1"
    [[ -n "$key" ]] || { log_warn "License key is empty."; return 1; }
    wgcf_install
    [[ -f "$WM_WGCF_DIR/wgcf-account.toml" ]] || warp_register
    cd "$WM_WGCF_DIR" || return 1
    if grep -q '^license_key' wgcf-account.toml 2>/dev/null; then
        sed -i "s|^license_key.*|license_key = '${key}'|" wgcf-account.toml
    else
        printf "license_key = '%s'\n" "$key" >>wgcf-account.toml
    fi
    log_step "Applying WARP+ license..."
    if "$WM_WGCF_BIN" update >/dev/null 2>&1; then
        "$WM_WGCF_BIN" generate --profile "$WM_WGCF_DIR/wgcf-profile.conf" >/dev/null 2>&1
        conf_set license_key "$key"
        log_info "WARP+ license applied."
    else
        log_error "Failed to apply license (invalid key or device limit reached)."
        return 1
    fi
}

warp_clear_license() {
    require_root
    conf_set license_key ""
    log_info "License cleared (free WARP). Change IP or refresh to apply."
}

# Report WARP account type (WARP vs WARP+) via trace warp= field.
warp_plan() {
    warp_is_up || { echo "-"; return; }
    local w; w="$(curl -s --interface "$WM_IFACE" --connect-timeout 4 --max-time 8 "$CF_TRACE_URL" 2>/dev/null | awk -F= '/^warp=/{print $2}')"
    case "$w" in
        plus) echo "WARP+" ;;
        on)   echo "WARP" ;;
        *)    echo "-" ;;
    esac
}
