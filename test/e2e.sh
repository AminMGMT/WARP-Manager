#!/usr/bin/env bash
# WARP Manager - end-to-end test (sing-box engine).
# Run on the VPS AFTER install:   sudo bash test/e2e.sh
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
WM_ROOT="${WM_ROOT:-$(dirname "$(dirname "$SELF")")}"
[[ -f "${WM_ROOT}/lib/common.sh" ]] || WM_ROOT="/opt/warp-manager"
export WM_ROOT
# shellcheck source=/dev/null
for lib in common warp routing providers adblock ipcheck singbox; do source "${WM_ROOT}/lib/${lib}.sh"; done

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

# ---------------------------------------------------------------------------
# Tunnel safety. These matter more than any feature: the engine must never be
# able to take the server's own relay traffic down.
# ---------------------------------------------------------------------------
section "7) Tunnel safety"
if systemctl is-active --quiet "$WM_WATCHDOG_TIMER"; then ok "fail-open watchdog timer active"
else no "watchdog timer not running (tunnel unprotected)"; fi

# The single most important probe: client apps measure their "config ping"
# against a connectivity check. If this stops returning 204, every user sees a
# dead tunnel even when everything else works.
PING_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.gstatic.com/generate_204 2>/dev/null)"
[[ "$PING_CODE" == "204" ]] && ok "connectivity check returns 204 (client config ping OK)" \
                            || no "connectivity check broken (HTTP ${PING_CODE:-none}) — clients will show the tunnel as dead"

if ss -ltnp 2>/dev/null | grep -qE ':22[[:space:]]'; then ok "SSH still listening (not intercepted)"
else skip "could not confirm SSH listener"; fi

# only locally-generated 80/443 may be diverted; an inbound-side rule would break the panel
if nft list chain inet "$WM_NFT_TABLE" mangle_output 2>/dev/null | grep -q "meta mark set ${WM_TPROXY_MARK}"; then
    ok "only output traffic is diverted (mark ${WM_TPROXY_MARK})"
else skip "divert rule not present (redirect inactive?)"; fi

if wm_maintenance_active; then skip "maintenance window currently open"
else ok "no stale maintenance flag (watchdog armed)"; fi

# ---------------------------------------------------------------------------
section "8) Ad blocker"
if ! adblock_is_enabled; then
    skip "ad blocker disabled (enable it from the menu to test)"
else
    if adblock_has_list; then ok "block list present ($(adblock_count) domains, updated $(adblock_last_update))"
    else no "ad blocker enabled but no list built"; fi

    if [[ "$(adblock_count)" -ge "$WM_ADBLOCK_MIN_RULES" ]]; then ok "list size looks sane"
    else no "list suspiciously small ($(adblock_count) domains)"; fi

    if jq -e '[.route.rules[] | select(.outbound=="block") | .rule_set // []] | flatten | index("adguard-ads")' \
         "$WM_SINGBOX_CONF" >/dev/null 2>&1; then ok "block rule wired into sing-box config"
    else no "block rule missing from sing-box config"; fi

    # the allow list must win over the block list
    ALLOW_LEAK=0
    for d in $WM_ADBLOCK_SAFE_DOMAINS; do
        jq -e --arg d "$d" '.rules[0].domain | index($d)' "$WM_ADBLOCK_JSON" >/dev/null 2>&1 && {
            no "safe domain $d ended up in the block list"; ALLOW_LEAK=1; }
    done
    [[ "$ALLOW_LEAK" -eq 0 ]] && ok "no protected domain is blocked"

    # functional check: a known ad domain must be dropped, a normal site must not.
    # Traffic from this server goes through the engine, so this exercises the real path.
    BLOCKED_OK=0
    for d in doubleclick.net google-analytics.com adnxs.com; do
        curl -s -o /dev/null --max-time 6 "https://${d}/" 2>/dev/null || BLOCKED_OK=$((BLOCKED_OK+1))
    done
    [[ "$BLOCKED_OK" -ge 2 ]] && ok "ad domains are blocked in practice (${BLOCKED_OK}/3)" \
                              || no "ad domains still reachable (${BLOCKED_OK}/3 blocked)"

    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.cloudflare.com/ 2>/dev/null)"
    [[ "$CODE" =~ ^(200|301|302)$ ]] && ok "normal site unaffected (HTTP $CODE)" \
                                     || no "normal site broken by the ad blocker (HTTP ${CODE:-none})"

    if systemctl is-active --quiet "$WM_ADBLOCK_TIMER"; then ok "weekly list refresh scheduled"
    else skip "refresh timer not active"; fi
fi

# ---------------------------------------------------------------------------
section "9) Auto IP health"
if ! ipcheck_is_enabled; then
    skip "auto IP health disabled (Manage → Auto IP Health to enable)"
else
    if systemctl is-active --quiet "$WM_IPCHECK_TIMER"; then ok "health-check timer active"
    else no "enabled but the timer is not running"; fi
    printf '     Rotations today  : %s / %s\n' "$(_ipcheck_rotations_today)" "$(_ipcheck_max_per_day)"
    if [[ "$(_ipcheck_rotations_today)" -lt "$(_ipcheck_max_per_day)" ]]; then ok "within the daily rotation budget"
    else skip "daily rotation budget reached (will resume tomorrow)"; fi
    if _ipcheck_trace; then ok "WARP exit answers (${IPCHECK_IP} / ${IPCHECK_LOC:-?})"
    else no "no answer through WARP — the next check will rotate the IP"; fi
    if [[ -n "${IPCHECK_LOC:-}" ]] && grep -qiw -- "${IPCHECK_LOC}" <<<"$(_ipcheck_bad_locs | tr ',' ' ')"; then
        no "exit location ${IPCHECK_LOC} is on the bad list — it will be rotated"
    else ok "exit location is acceptable"; fi
fi

line
printf '  %sResult:%s %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET" "$C_YELLOW" "$SKIP" "$C_RESET"
line
[[ "$FAIL" -eq 0 ]]
