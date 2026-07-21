#!/usr/bin/env bash
# WARP Manager - installer (run as root on the foreign VPS: Ubuntu/Debian)
#   sudo bash install.sh
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SRC_DIR="$(dirname "$SELF")"
WM_ROOT="/opt/warp-manager"
export WM_ROOT

# load libraries (functions); runtime data paths point at /opt after the copy step
# shellcheck source=/dev/null
for lib in common warp routing providers singbox; do source "${SRC_DIR}/lib/${lib}.sh"; done
require_root

INSTALL_LOG="/tmp/warp-manager-install.log"
: >"$INSTALL_LOG"

# --- progress bar --------------------------------------------------------
_draw_bar() {   # label pct
    local label="$1" pct="$2" width=32 filled bar
    filled=$(( pct * width / 100 ))
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$((width-filled))" '')"
    printf '\r%s%-26s%s [%s%s%s] %3d%%' \
        "$C_WHITE" "$label" "$C_RESET" "$C_PRIMARY" "$bar" "$C_RESET" "$pct"
}

progress_run() {   # label cmd...
    local label="$1"; shift
    ( "$@" ) </dev/null >>"$INSTALL_LOG" 2>&1 &
    local pid=$! pct=0 rc=0
    while kill -0 "$pid" 2>/dev/null; do
        pct=$(( pct < 92 ? pct + 3 : 92 ))
        _draw_bar "$label" "$pct"
        sleep 0.2
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    if [[ $rc -eq 0 ]]; then _draw_bar "$label" 100; else printf '\r%s%-26s%s [%sFAILED%s]         \n' "$C_WHITE" "$label" "$C_RESET" "$C_RED" "$C_RESET"; return $rc; fi
    printf '\n'
}

# --- steps ---------------------------------------------------------------
step_deps() {
    if has_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y wireguard-tools nftables conntrack curl jq dnsutils iproute2 ca-certificates
    elif has_cmd dnf; then
        dnf install -y wireguard-tools nftables conntrack-tools curl jq bind-utils iproute
    elif has_cmd yum; then
        yum install -y epel-release || true
        yum install -y wireguard-tools nftables conntrack-tools curl jq bind-utils iproute
    else
        echo "Unsupported package manager"; return 1
    fi
    systemctl enable nftables >/dev/null 2>&1 || true
}

step_copy() {
    mkdir -p "$WM_ROOT"
    # wipe old code/data first so removed providers don't linger on upgrades
    rm -rf "${WM_ROOT}/bin" "${WM_ROOT}/lib" "${WM_ROOT}/data"
    cp -rf "${SRC_DIR}/bin" "${SRC_DIR}/lib" "${SRC_DIR}/data" "$WM_ROOT/"
    chmod +x "${WM_ROOT}/bin/warp-manager"
    ln -sf "${WM_ROOT}/bin/warp-manager" /usr/local/bin/warp-manager
    ln -sf "${WM_ROOT}/bin/warp-manager" /usr/local/bin/wm
}

step_prepare() {
    ensure_dirs
    rm -f "${WM_STATE_DIR}/.reg_failed"
    warp_register || touch "${WM_STATE_DIR}/.reg_failed"
    singbox_install
    return 0     # never hard-fail on a 429; sing-box install must succeed though
}

step_generate() {
    # WARP interface (only if registration succeeded)
    if [[ ! -e "${WM_STATE_DIR}/.reg_failed" && -f "$WM_WGCF_DIR/wgcf-profile.conf" ]]; then
        warp_write_conf
        warp_up || true
    fi
    [[ -f "$WM_WGCF_DIR/wgcf-profile.conf" && -n "$(conf_get license_key)" ]] && warp_apply_license "$(conf_get license_key)"

    # prune stale enabled entries; default-enable the AI group
    if [[ -s "$WM_ENABLED_FILE" ]]; then
        local kid
        while read -r kid; do [[ -f "$WM_PROVIDERS_DIR/$kid.conf" ]] && echo "$kid"; done <"$WM_ENABLED_FILE" \
            | sort -u >"${WM_ENABLED_FILE}.p"
        mv -f "${WM_ENABLED_FILE}.p" "$WM_ENABLED_FILE"
    fi
    if [[ ! -s "$WM_ENABLED_FILE" ]]; then
        local id
        for id in google-ai openai grok perplexity copilot; do provider_enable "$id"; done
    fi

    # sing-box engine
    singbox_service_setup
    singbox_write_config
    if warp_is_up; then
        systemctl restart "$WM_SINGBOX_SERVICE" || true
        sleep 1
        singbox_is_up && routing_apply   # redirect ONLY if sing-box is actually up
    fi
    # re-apply the engine automatically on every boot (nft rules aren't persistent)
    install -m 644 "${SRC_DIR}/systemd/warp-manager-boot.service" /etc/systemd/system/warp-manager-boot.service
    systemctl daemon-reload
    systemctl enable warp-manager-boot.service >/dev/null 2>&1 || true
}

# show the real reason then stop
fail() {
    printf '\n%s%s%s\n' "$C_RED$C_BOLD" "$1" "$C_RESET"
    printf '%s──── last 25 lines of %s ────%s\n' "$C_GRAY" "$INSTALL_LOG" "$C_RESET"
    tail -n 25 "$INSTALL_LOG" 2>/dev/null
    printf '%s────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"
    exit 1
}

# --- run -----------------------------------------------------------------
clear 2>/dev/null || true
printf '%s  WARP Manager — Installer%s\n\n' "$C_BOLD$C_PRIMARY" "$C_RESET"

progress_run "Installing Dependencies" step_deps     || fail "Dependency install failed."
progress_run "Copying Files"           step_copy     || fail "Copy failed."
progress_run "Preparing WARP"          step_prepare  || fail "WARP setup failed."
progress_run "Generating Profile"      step_generate || fail "WARP setup failed."

echo
if warp_is_up && singbox_is_up; then
    printf '%s  WARP is Ready%s : %ssudo wm%s\n' "$C_BOLD$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET"
    printf '  %sApps and websites for the selected services now go through WARP.%s\n\n' "$C_GRAY" "$C_RESET"
else
    printf '%s  Installed, but WARP is not connected yet.%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
    printf '  Cloudflare rate-limited registration (429) from this server, OR it needs a moment.\n\n'
    printf '  %sFinish it one of these ways:%s\n' "$C_BOLD" "$C_RESET"
    printf '   • wait a few minutes, then:  %ssudo wm%s → Manage → Restart\n' "$C_WHITE" "$C_RESET"
    printf '   • or import an account from one of your working servers:\n'
    printf '       copy  %s/var/lib/warp-manager/wgcf/wgcf-account.toml%s  from a working server, then:\n' "$C_WHITE" "$C_RESET"
    printf '       %ssudo warp-manager --import-account /path/to/wgcf-account.toml%s\n\n' "$C_WHITE" "$C_RESET"
fi
sleep 1

# auto-open the CLI menu
if [[ -t 0 && -t 1 ]]; then
    exec /usr/local/bin/wm
else
    echo "Run 'sudo wm' to open the menu."
fi
