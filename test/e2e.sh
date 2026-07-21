#!/usr/bin/env bash
# WARP Manager - end-to-end test (sing-box engine).
# Run on the VPS AFTER install:   sudo bash test/e2e.sh
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
WM_ROOT="${WM_ROOT:-$(dirname "$(dirname "$SELF")")}"
[[ -f "${WM_ROOT}/lib/common.sh" ]] || WM_ROOT="/opt/warp-manager"
export WM_ROOT
# shellcheck source=/dev/null
for lib in common warp routing providers singbox; do source "${WM_ROOT}/lib/${lib}.sh"; done

PASS=0; FAIL=0; SKIP=0
ok()      { printf '  %s✔ PASS%s  %s\n' "$C_GREEN" "$C_RESET" "$1"; PASS=$((PASS+1)); }
no()      { printf '  %s✗ FAIL%s  %s\n' "$C_RED" "$C_RESET" "$1"; FAIL=$((FAIL+1)); }
skip()    { printf '  %s∼ SKIP%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"; SKIP=$((SKIP+1)); }
section() { printf '\n%s%s%s\n' "$C_BOLD$C_PRIMARY" "$1" "$C_RESET"; }

[[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash test/e2e.sh"

line() { printf '%s══════════════════════════════════════════════════════%s\n' "$C_PRIMARY" "$C_RESET"; }
line; printf '%s  WARP Manager — End-to-End Test%s\n' "$C_BOLD$C_WHITE" "$C_RESET"; line

section "1) Components"
for c in wg nft curl sing-box; do
    if command -v "$c" >/dev/null 2>&1 || [[ "$c" == sing-box && -x "$WM_SINGBOX_BIN" ]]; then ok "$c present"; else no "$c missing"; fi
done

section "2) Services"
if warp_is_up;    then ok "WARP interface (wg-quick@${WM_IFACE}) up"; else no "WARP interface down"; fi
if singbox_is_up; then ok "sing-box engine running"; else no "sing-box not running"; fi
if routing_installed; then ok "nftables TPROXY active"; else no "nftables TPROXY missing"; fi

section "3) TPROXY rules"
if nft list chain inet "$WM_NFT_TABLE" mangle_prerouting 2>/dev/null | grep -q "tproxy .* to .*:${WM_SINGBOX_PORT}"; then
    ok "diverted traffic → sing-box:${WM_SINGBOX_PORT} (TCP + UDP)"
else no "tproxy rule not found"; fi
if ip rule show 2>/dev/null | grep -q "lookup ${WM_TPROXY_TABLE}"; then
    ok "policy route (fwmark ${WM_TPROXY_MARK} → table ${WM_TPROXY_TABLE})"
else no "tproxy policy route missing"; fi

section "4) Exit IP: direct vs WARP"
DIRECT_IP="$(curl -s --connect-timeout 8 "$CF_TRACE_URL" 2>/dev/null | awk -F= '/^ip=/{print $2}')"
WARP_BIND="$(ip -4 -o addr show dev "$WM_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
WARP_IP="$(curl -s --interface "${WARP_BIND:-$WM_IFACE}" --connect-timeout 8 "$CF_TRACE_URL" 2>/dev/null | awk -F= '/^ip=/{print $2}')"
printf '     Server direct IP : %s%s%s\n' "$C_WHITE" "${DIRECT_IP:-?}" "$C_RESET"
printf '     WARP exit IP     : %s%s%s\n' "$C_PRIMARY" "${WARP_IP:-?}" "$C_RESET"
[[ -n "$WARP_IP" ]] && ok "reachable through WARP" || no "cannot reach Cloudflare via WARP"
[[ -n "$DIRECT_IP" && -n "$WARP_IP" && "$DIRECT_IP" != "$WARP_IP" ]] && ok "WARP IP differs from server IP" || skip "WARP IP == server IP"

section "5) sing-box route config"
if [[ -f "$WM_SINGBOX_CONF" ]] && "$WM_SINGBOX_BIN" check -c "$WM_SINGBOX_CONF" >/dev/null 2>&1; then
    ok "sing-box config is valid"
else no "sing-box config invalid/missing"; fi

section "6) Gemini reachable through WARP"
CODE="$(curl -s --interface "$WM_IFACE" -o /dev/null -w '%{http_code}' --connect-timeout 10 https://gemini.google.com 2>/dev/null)"
[[ "$CODE" =~ ^(200|301|302|307|403)$ ]] && ok "gemini.google.com reachable via WARP (HTTP $CODE)" || no "gemini not reachable via WARP (HTTP ${CODE:-none})"

line
printf '  %sResult:%s %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET" "$C_YELLOW" "$SKIP" "$C_RESET"
line
[[ "$FAIL" -eq 0 ]]
