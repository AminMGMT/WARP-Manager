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
for lib in common warp routing providers; do source "${SRC_DIR}/lib/${lib}.sh"; done
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
    ( "$@" ) >>"$INSTALL_LOG" 2>&1 &
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
    warp_register
}

step_generate() {
    warp_write_conf
    warp_up
    routing_apply_skeleton
    # prune stale enabled entries whose provider no longer exists (upgrades)
    if [[ -s "$WM_ENABLED_FILE" ]]; then
        local kid
        while read -r kid; do [[ -f "$WM_PROVIDERS_DIR/$kid.conf" ]] && echo "$kid"; done <"$WM_ENABLED_FILE" \
            | sort -u >"${WM_ENABLED_FILE}.p"
        mv -f "${WM_ENABLED_FILE}.p" "$WM_ENABLED_FILE"
    fi
    # default: enable the AI group so Gemini/ChatGPT work right away
    if [[ ! -s "$WM_ENABLED_FILE" ]]; then
        local id
        for id in google-ai openai grok perplexity copilot; do provider_enable "$id"; done
    fi
    conf_set refresh_min "$WM_DEFAULT_REFRESH_MIN"
    [[ -n "$(conf_get license_key)" ]] && warp_apply_license "$(conf_get license_key)"
    providers_refresh
    install -m 644 "${SRC_DIR}/systemd/warp-manager-refresh.service" /etc/systemd/system/warp-manager-refresh.service
    install -m 644 "${SRC_DIR}/systemd/warp-manager-refresh.timer"   /etc/systemd/system/warp-manager-refresh.timer
    systemctl daemon-reload
    systemctl enable --now warp-manager-refresh.timer >/dev/null 2>&1 || true
}

# --- run -----------------------------------------------------------------
clear 2>/dev/null || true
printf '%s  WARP Manager — Installer%s\n\n' "$C_BOLD$C_PRIMARY" "$C_RESET"

progress_run "Installing Dependencies" step_deps     || die "Dependency install failed. See $INSTALL_LOG"
progress_run "Copying Files"           step_copy     || die "Copy failed. See $INSTALL_LOG"
progress_run "Preparing WARP"          step_prepare  || die "WARP registration failed. See $INSTALL_LOG"
progress_run "Generating Profile"      step_generate || die "WARP setup failed. See $INSTALL_LOG"

printf '\n%s  WARP is Ready%s : %ssudo wm%s\n\n' "$C_BOLD$C_GREEN" "$C_RESET" "$C_WHITE" "$C_RESET"
sleep 1

# auto-open the CLI menu
if [[ -t 0 && -t 1 ]]; then
    exec /usr/local/bin/wm
else
    echo "Run 'sudo wm' to open the menu."
fi
