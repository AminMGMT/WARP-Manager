#!/usr/bin/env bash
# WARP Manager - common helpers, constants, config
# shellcheck disable=SC2034,SC2155

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
WM_ROOT="${WM_ROOT:-/opt/warp-manager}"
WM_CONF_DIR="${WM_CONF_DIR:-/etc/warp-manager}"
WM_STATE_DIR="${WM_STATE_DIR:-/var/lib/warp-manager}"
WM_LOG="${WM_LOG:-/var/log/warp-manager.log}"

WM_PROVIDERS_DIR="${WM_ROOT}/data/providers"
WM_GROUPS_FILE="${WM_ROOT}/data/groups.conf"
WM_ENABLED_FILE="${WM_CONF_DIR}/enabled.list"      # one provider id per line
WM_CUSTOM_FILE="${WM_CONF_DIR}/custom.domains"      # one domain per line
WM_CONF_FILE="${WM_CONF_DIR}/manager.conf"          # key=value settings

# WireGuard / WARP
WM_IFACE="${WM_IFACE:-wgcf}"
WM_WG_CONF="/etc/wireguard/${WM_IFACE}.conf"
WM_WGCF_DIR="${WM_STATE_DIR}/wgcf"                  # holds wgcf-account.toml / profile
WM_WGCF_BIN="/usr/local/bin/wgcf"

# Routing marks/tables (kept identical to the WireGuard PostUp rules)
WM_TABLE="51888"
WM_FWMARK="51888"
WM_MARK_HEX="0xcab0"                                # 51888 in hex, used by nftables

# nftables objects
WM_NFT_TABLE="warp"                                 # table inet warp

# sing-box (SNI-based routing engine)
WM_SINGBOX_BIN="/usr/local/bin/sing-box"
WM_SINGBOX_CONF="${WM_CONF_DIR}/sing-box.json"
WM_SINGBOX_PORT="47921"                             # local redirect port (loopback only)
WM_SINGBOX_VER="1.10.7"                             # pinned; config format is 1.10.x
WM_MARK_WARP="51888"                                # -> table 51888 -> wgcf (WARP)
WM_MARK_DIRECT="51889"                              # sing-box direct marker (loop guard)

CF_TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

# last-known WARP exit IP, cached so the menu header never blocks on the network
WM_EXIT_IP_CACHE="${WM_STATE_DIR}/exit-ip"

# WARP endpoint host (used to build the routing-loop exclusion set)
WM_WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
# Cloudflare registration API host — must bypass the redirect so wgcf can register
WM_WARP_API_HOST="api.cloudflareclient.com"

# nftables exclusion sets (never route these via WARP -> avoids loops)
WM_XSET4="warpx4"
WM_XSET6="warpx6"

# geosite domain source (v2fly community list)
WM_GEOSITE_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"

# ---------------------------------------------------------------------------
# Colors  (palette: dark red, white, gray)
# ---------------------------------------------------------------------------
if [[ -t 1 || "${WM_FORCE_COLOR:-0}" == 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_PRIMARY=$'\033[38;5;124m'     # dark red (primary UI chrome)
    C_PRIMARY2=$'\033[38;5;160m'    # brighter red accent
    C_WHITE=$'\033[97m'
    C_RED=$'\033[38;5;196m'; C_GREEN=$'\033[38;5;40m'; C_YELLOW=$'\033[38;5;214m'
    C_GRAY=$'\033[38;5;245m'; C_DARK=$'\033[38;5;240m'
    # aliases kept for existing code
    C_ORANGE="$C_PRIMARY"; C_ORANGE2="$C_PRIMARY2"
    C_CYAN="$C_PRIMARY"; C_BLUE="$C_PRIMARY"; C_MAGENTA="$C_PRIMARY2"
else
    C_RESET=; C_BOLD=; C_DIM=; C_PRIMARY=; C_PRIMARY2=; C_WHITE=; C_RED=; C_GREEN=
    C_YELLOW=; C_GRAY=; C_DARK=; C_ORANGE=; C_ORANGE2=; C_CYAN=; C_BLUE=; C_MAGENTA=
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local color="$C_RESET"
    case "$level" in
        INFO) color="$C_GREEN" ;;
        WARN) color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
        STEP) color="$C_ORANGE" ;;
    esac
    printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$*" >&2
    printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >>"$WM_LOG" 2>/dev/null || true
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_step()  { _log STEP  "$@"; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Guards / helpers
# ---------------------------------------------------------------------------
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This must be run as root (use sudo)."
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# key=value config read/write in WM_CONF_FILE
conf_get() {
    local key="$1" def="${2:-}"
    [[ -f "$WM_CONF_FILE" ]] || { printf '%s' "$def"; return; }
    local val
    val="$(grep -E "^${key}=" "$WM_CONF_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    [[ -n "$val" ]] && printf '%s' "$val" || printf '%s' "$def"
}
conf_set() {
    local key="$1" val="$2"
    mkdir -p "$WM_CONF_DIR"
    touch "$WM_CONF_FILE"
    if grep -qE "^${key}=" "$WM_CONF_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$WM_CONF_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >>"$WM_CONF_FILE"
    fi
}

ensure_dirs() {
    mkdir -p "$WM_CONF_DIR" "$WM_STATE_DIR" "$WM_WGCF_DIR"
    touch "$WM_ENABLED_FILE" "$WM_CUSTOM_FILE"
}

# enabled provider list helpers
provider_is_enabled() { grep -qxF "$1" "$WM_ENABLED_FILE" 2>/dev/null; }
provider_enable()  { provider_is_enabled "$1" || echo "$1" >>"$WM_ENABLED_FILE"; }
provider_disable() {
    [[ -f "$WM_ENABLED_FILE" ]] || return 0
    grep -vxF "$1" "$WM_ENABLED_FILE" >"${WM_ENABLED_FILE}.tmp" 2>/dev/null || true
    mv -f "${WM_ENABLED_FILE}.tmp" "$WM_ENABLED_FILE"
}
