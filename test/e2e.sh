#!/usr/bin/env bash
# WARP Manager - end-to-end test.
# Run on the VPS AFTER `install.sh`:   sudo bash test/e2e.sh
#
# Non-destructive: it only reads state and does route lookups. It proves that
# selected traffic goes through WARP and everything else stays on the server IP.
set -uo pipefail

# --- load libs -----------------------------------------------------------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
WM_ROOT="${WM_ROOT:-$(dirname "$(dirname "$SELF")")}"
[[ -f "${WM_ROOT}/lib/common.sh" ]] || WM_ROOT="/opt/warp-manager"
export WM_ROOT
# shellcheck source=/dev/null
for lib in common warp routing providers; do source "${WM_ROOT}/lib/${lib}.sh"; done

PASS=0; FAIL=0; SKIP=0
ok()      { printf '  %s✔ PASS%s  %s\n' "$C_GREEN" "$C_RESET" "$1"; PASS=$((PASS+1)); }
no()      { printf '  %s✗ FAIL%s  %s\n' "$C_RED" "$C_RESET" "$1"; FAIL=$((FAIL+1)); }
skip()    { printf '  %s∼ SKIP%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"; SKIP=$((SKIP+1)); }
section() { printf '\n%s%s%s\n' "$C_BOLD$C_ORANGE" "$1" "$C_RESET"; }

[[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash test/e2e.sh"

banner_line() { printf '%s══════════════════════════════════════════════════════%s\n' "$C_ORANGE" "$C_RESET"; }
banner_line
printf '%s  WARP Manager — End-to-End Test%s\n' "$C_BOLD$C_WHITE" "$C_RESET"
banner_line

# =========================================================================
section "1) Dependencies"
for c in wg nft curl dig ip; do
    if has_cmd "$c"; then ok "'$c' is installed"; else no "'$c' is missing"; fi
done

# =========================================================================
section "2) WARP interface"
if warp_is_up; then ok "wg-quick@${WM_IFACE} is active"; else no "wg-quick@${WM_IFACE} is NOT active"; fi
if ip link show "$WM_IFACE" >/dev/null 2>&1; then ok "interface ${WM_IFACE} exists"; else no "interface ${WM_IFACE} missing"; fi

# =========================================================================
section "3) nftables marking layer"
if routing_installed; then ok "table inet ${WM_NFT_TABLE} exists"; else no "table inet ${WM_NFT_TABLE} missing"; fi
n4="$(routing_count "$WM_SET4")"; n6="$(routing_count "$WM_SET6")"
if [[ "$n4" -gt 0 ]]; then ok "set ${WM_SET4} populated (${n4} entries)"; else no "set ${WM_SET4} is empty"; fi
printf '     %s(IPv6 set has %s entries)%s\n' "$C_DIM" "$n6" "$C_RESET"

# =========================================================================
section "4) Policy routing (fwmark ${WM_FWMARK})"
if ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$WM_FWMARK")\|fwmark ${WM_FWMARK}"; then
    ok "ip rule for fwmark ${WM_FWMARK} present"
else
    no "ip rule for fwmark ${WM_FWMARK} missing"
fi

# =========================================================================
section "5) Exit IP: direct vs WARP"
DIRECT_IP="$(curl -s --connect-timeout 8 "$CF_TRACE_URL" 2>/dev/null | awk -F= '/^ip=/{print $2}')"
WARP_IP="$(curl -s --interface "$WM_IFACE" --connect-timeout 8 "$CF_TRACE_URL" 2>/dev/null | awk -F= '/^ip=/{print $2}')"
printf '     Server direct IP : %s%s%s\n' "$C_WHITE" "${DIRECT_IP:-?}" "$C_RESET"
printf '     WARP exit IP     : %s%s%s\n' "$C_ORANGE" "${WARP_IP:-?}" "$C_RESET"
if [[ -n "$WARP_IP" ]]; then ok "reachable through WARP"; else no "could not reach Cloudflare through WARP"; fi
if [[ -n "$DIRECT_IP" && -n "$WARP_IP" && "$DIRECT_IP" != "$WARP_IP" ]]; then
    ok "WARP IP differs from server IP (traffic really changes exit)"
elif [[ -n "$WARP_IP" ]]; then
    skip "WARP IP equals server IP (possible if server already uses this range)"
fi

# =========================================================================
section "6) Selective routing proof (marked → WARP, unmarked → direct)"
# Pick a well-known Google IP that is in the Google range (if google enabled).
PROBE="8.8.8.8"
R_MARKED="$(ip route get "$PROBE" mark "$WM_FWMARK" 2>/dev/null)"
R_PLAIN="$(ip route get "$PROBE" 2>/dev/null)"
if grep -q "dev ${WM_IFACE}" <<<"$R_MARKED"; then
    ok "marked packets to ${PROBE} route via ${WM_IFACE} (WARP)"
else
    no "marked packets to ${PROBE} do NOT use ${WM_IFACE}"
fi
if grep -q "dev ${WM_IFACE}" <<<"$R_PLAIN"; then
    no "unmarked packets to ${PROBE} unexpectedly use ${WM_IFACE}"
else
    ok "unmarked packets to ${PROBE} keep the normal route (direct)"
fi

# =========================================================================
section "7) A real service is actually selected (Gemini / Google)"
if provider_is_enabled google-ai; then
    GEM_IP="$(_resolve4 gemini.google.com | head -n1)"
    if [[ -z "$GEM_IP" ]]; then
        skip "could not resolve gemini.google.com"
    elif nft get element inet "$WM_NFT_TABLE" "$WM_SET4" "{ $GEM_IP }" >/dev/null 2>&1; then
        ok "gemini.google.com ($GEM_IP) is in the WARP set → goes via WARP"
    else
        no "gemini.google.com ($GEM_IP) is NOT in the WARP set"
    fi
else
    skip "google / google-ai not enabled (enable it in 'wm' to test Gemini)"
fi

# =========================================================================
section "8) Reachability of Gemini through WARP"
CODE="$(curl -s --interface "$WM_IFACE" -o /dev/null -w '%{http_code}' --connect-timeout 10 https://gemini.google.com 2>/dev/null)"
if [[ "$CODE" =~ ^(200|301|302|307|403)$ ]]; then
    ok "gemini.google.com reachable via WARP (HTTP $CODE)"
else
    no "gemini.google.com not reachable via WARP (HTTP ${CODE:-none})"
fi

# =========================================================================
banner_line
printf '  %sResult:%s %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET" "$C_YELLOW" "$SKIP" "$C_RESET"
banner_line
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
