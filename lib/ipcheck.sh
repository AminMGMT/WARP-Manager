#!/usr/bin/env bash
# WARP Manager - WARP exit IP health check + automatic rotation.
# Requires common.sh and warp.sh sourced first.
#
# A freshly registered WARP account sometimes lands on an exit IP that is dead or
# in a region that defeats the point of using WARP. This watches the exit from the
# background and registers a new account when the current IP is genuinely bad.
#
# Rotating is disruptive (WireGuard restart) and Cloudflare rate-limits
# registration (429), so a rotation only happens when ALL of these hold:
#   * the tunnel itself is up            - otherwise it is not an IP problem
#   * the server's direct internet works - otherwise it is a general outage
#   * the exit really looks bad          - dead probes, or a blocked location
#   * we are inside the rate budget      - min interval + max rotations per day
# Anything else is logged and left alone.

WM_IPCHECK_SERVICE="warp-manager-ipcheck.service"
WM_IPCHECK_TIMER="warp-manager-ipcheck.timer"
WM_IPCHECK_LAST="${WM_STATE_DIR}/ipcheck.last"    # unix ts of the last rotation
WM_IPCHECK_COUNT="${WM_STATE_DIR}/ipcheck.count"  # "<epoch-day> <rotations today>"

# Exit locations that make WARP pointless here. Overridable in manager.conf.
WM_IPCHECK_BAD_LOCS_DEFAULT="IR"
# Endpoints probed through WARP. Kept small and stable on purpose.
WM_IPCHECK_CANARIES="https://gemini.google.com https://chatgpt.com https://www.google.com"

ipcheck_is_enabled() { [[ "$(conf_get ipcheck_enabled 0)" == "1" ]]; }
ipcheck_enable()     { conf_set ipcheck_enabled 1; }
ipcheck_disable()    { conf_set ipcheck_enabled 0; }

_ipcheck_min_interval() { conf_get ipcheck_min_interval 1800; }   # 30 min
_ipcheck_max_per_day()  { conf_get ipcheck_max_per_day 4; }
_ipcheck_bad_locs()     { conf_get ipcheck_bad_locs "$WM_IPCHECK_BAD_LOCS_DEFAULT"; }

# --- rate budget ---------------------------------------------------------
# Rotations are counted per calendar day so a bad night cannot burn through the
# registration quota and get this server 429'd.
_ipcheck_rotations_today() {
    local day today line
    today=$(( $(date +%s) / 86400 ))
    line="$(cat "$WM_IPCHECK_COUNT" 2>/dev/null || echo "")"
    day="${line%% *}"
    [[ "$day" == "$today" ]] && printf '%s' "${line##* }" || printf '0'
}

_ipcheck_record_rotation() {
    local today n
    today=$(( $(date +%s) / 86400 ))
    n=$(( $(_ipcheck_rotations_today) + 1 ))
    printf '%s %s\n' "$today" "$n" >"$WM_IPCHECK_COUNT" 2>/dev/null || true
    date +%s >"$WM_IPCHECK_LAST" 2>/dev/null || true
}

_ipcheck_budget_ok() {
    local last now gap
    last="$(cat "$WM_IPCHECK_LAST" 2>/dev/null || echo 0)"; now="$(date +%s)"
    gap="$(_ipcheck_min_interval)"
    if (( now - last < gap )); then
        log_info "ip-check: last rotation was $(( (now-last)/60 ))m ago; waiting (min ${gap}s)."
        return 1
    fi
    local n max; n="$(_ipcheck_rotations_today)"; max="$(_ipcheck_max_per_day)"
    if (( n >= max )); then
        log_warn "ip-check: reached ${max} rotations today; not rotating again until tomorrow."
        return 1
    fi
    return 0
}

# --- probes --------------------------------------------------------------
# The server's own connection, bypassing WARP. If this is down the problem is the
# network, not the exit IP, and rotating would be pointless churn.
_ipcheck_direct_ok() {
    curl -s -o /dev/null --max-time 8 "$CF_TRACE_URL" 2>/dev/null
}

# Fetch the trace through WARP once; sets IPCHECK_IP / IPCHECK_LOC.
_ipcheck_trace() {
    local t; t="$(curl -s --interface "$(_warp_bind_addr)" --connect-timeout 5 --max-time 10 "$CF_TRACE_URL" 2>/dev/null)"
    IPCHECK_IP="$(awk -F= '/^ip=/{print $2}' <<<"$t")"
    IPCHECK_LOC="$(awk -F= '/^loc=/{print $2}' <<<"$t")"
    [[ -n "$IPCHECK_IP" ]]
}

# How many canaries are unreachable through WARP.
_ipcheck_failed_canaries() {
    local bind u fails=0
    bind="$(_warp_bind_addr)"
    for u in $WM_IPCHECK_CANARIES; do
        curl -s -o /dev/null --interface "$bind" --connect-timeout 6 --max-time 12 "$u" 2>/dev/null \
            || fails=$((fails+1))
    done
    printf '%s' "$fails"
}

# --- main ----------------------------------------------------------------
# Returns 0 always: this runs from a timer and must never mark the unit failed.
ipcheck_run() {
    require_root
    ipcheck_is_enabled || return 0
    warp_is_up || return 0                    # nothing to judge
    wm_maintenance_active && return 0         # a planned restart is in progress

    local reason=""
    if ! _ipcheck_trace; then
        reason="no answer through WARP"
    else
        local bad; bad="$(_ipcheck_bad_locs)"
        if [[ -n "$IPCHECK_LOC" ]] && grep -qiw -- "$IPCHECK_LOC" <<<"${bad//,/ }"; then
            reason="exit location is ${IPCHECK_LOC}"
        else
            local f; f="$(_ipcheck_failed_canaries)"
            local total; total=$(wc -w <<<"$WM_IPCHECK_CANARIES")
            # only a clear majority counts, so one flaky site cannot trigger a rotation
            if (( f > total / 2 )); then reason="${f}/${total} sites unreachable through WARP"; fi
        fi
    fi

    if [[ -z "$reason" ]]; then
        warp_cache_refresh_bg                 # healthy: keep the menu header fresh
        return 0
    fi

    # Confirm the server itself is online before blaming the exit IP.
    if ! _ipcheck_direct_ok; then
        log_warn "ip-check: WARP looks bad (${reason}) but the server's own connection is down too; not rotating."
        return 0
    fi

    _ipcheck_budget_ok || return 0

    log_warn "ip-check: rotating WARP IP — ${reason}."
    _ipcheck_record_rotation
    wm_maintenance_begin
    if warp_change_ip >/dev/null 2>&1; then
        singbox_reload >/dev/null 2>&1 || true
        wm_maintenance_end
        _ipcheck_trace
        # warp_change_ip succeeds whenever the tunnel is healthy afterwards, which
        # includes "Cloudflare handed back the same address". Log which one it was,
        # so a server stuck on one exit is visible in the journal instead of looking
        # like a rotation that worked.
        if [[ -n "$WARP_OLD_IP" && "${IPCHECK_IP:-}" == "$WARP_OLD_IP" ]]; then
            log_warn "ip-check: still on ${IPCHECK_IP} (${IPCHECK_LOC:-?}) — Cloudflare returned the same exit."
        else
            log_info "ip-check: new WARP exit ${IPCHECK_IP:-unknown} (${IPCHECK_LOC:-?})."
        fi
    else
        wm_maintenance_end
        log_error "ip-check: could not get a new IP (rate-limited?); the previous account is back."
    fi
    return 0
}

# --- systemd -------------------------------------------------------------
ipcheck_timer_setup() {
    require_root
    cat >/etc/systemd/system/${WM_IPCHECK_SERVICE} <<EOF
[Unit]
Description=WARP Manager - check the WARP exit IP and rotate it if it is bad
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-manager --ip-check
EOF
    cat >/etc/systemd/system/${WM_IPCHECK_TIMER} <<EOF
[Unit]
Description=WARP Manager - periodic WARP exit IP health check

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
RandomizedDelaySec=90

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    if ipcheck_is_enabled; then
        systemctl enable --now "${WM_IPCHECK_TIMER}" >/dev/null 2>&1 || true
    else
        systemctl disable --now "${WM_IPCHECK_TIMER}" >/dev/null 2>&1 || true
    fi
}

# One-line summary for the menu.
ipcheck_status_line() {
    if ipcheck_is_enabled; then
        printf 'on — checks every 10m, max %s rotations/day (%s used today)' \
            "$(_ipcheck_max_per_day)" "$(_ipcheck_rotations_today)"
    else
        printf 'off'
    fi
}
