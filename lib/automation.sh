#!/usr/bin/env bash
# WARP Manager - scheduled engine restart.
# Requires common.sh (and warp.sh / singbox.sh / routing.sh for the actual work).
#
# WARP tunnels degrade slowly rather than dying outright: a WireGuard peer that has
# not rekeyed cleanly, a sing-box that has been up for weeks, an exit IP that has
# quietly gone stale. A periodic restart clears all of that without anyone watching.
#
# It is off by default. When on, the timer runs the same sequence as "Restart All
# Services" from the menu, which means the divert rules come down BEFORE anything is
# stopped (singbox_reload does that) — traffic flows direct through the gap instead
# of into a black hole, and the fail-open watchdog is told this is planned work so a
# scheduled restart is never mistaken for a fault.

WM_AUTORESTART_SERVICE="warp-manager-autorestart.service"
WM_AUTORESTART_TIMER="warp-manager-autorestart.timer"

autorestart_is_enabled() { [[ "$(conf_get autorestart_enabled 0)" == "1" ]]; }
autorestart_enable()     { conf_set autorestart_enabled 1; }
autorestart_disable()    { conf_set autorestart_enabled 0; }

# Restart interval in hours. Clamped to something sane: below an hour this would
# restart the engine more often than the ad list or the IP check ever run, and a
# restart is never free for the users being relayed.
autorestart_interval()   { conf_get autorestart_interval 6; }
autorestart_set_interval() {
    local h="$1"
    [[ "$h" =~ ^[0-9]+$ ]] || return 1
    (( h >= 1 && h <= 168 )) || return 1
    conf_set autorestart_interval "$h"
}

# --- the scheduled job ---------------------------------------------------
# Returns 0 even when a step fails: this runs from a timer and must never mark the
# unit failed (a failed unit would keep systemd from running the next one).
autorestart_run() {
    require_root
    autorestart_is_enabled || return 0

    log_info "auto-restart: scheduled restart starting."
    wm_maintenance_begin
    if warp_is_up; then
        warp_restart || log_warn "auto-restart: WARP did not come back cleanly."
    fi
    # engine_apply lives in bin/warp-manager; --auto-restart is only ever reached
    # from there, and the whole script is parsed before the subcommand runs.
    if engine_apply; then
        log_info "auto-restart: done (exit $(warp_trace_ip 2>/dev/null || echo '?'))."
    else
        log_error "auto-restart: the engine did not come back; traffic is flowing direct."
    fi
    wm_maintenance_end
    return 0
}

# --- systemd -------------------------------------------------------------
autorestart_timer_setup() {
    require_root
    local h; h="$(autorestart_interval)"
    cat >/etc/systemd/system/${WM_AUTORESTART_SERVICE} <<EOF
[Unit]
Description=WARP Manager - scheduled restart of WARP and the routing engine
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-manager --auto-restart
EOF
    cat >/etc/systemd/system/${WM_AUTORESTART_TIMER} <<EOF
[Unit]
Description=WARP Manager - periodic restart of WARP and the routing engine

[Timer]
OnBootSec=${h}h
OnUnitActiveSec=${h}h
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    if autorestart_is_enabled; then
        systemctl enable --now "${WM_AUTORESTART_TIMER}" >/dev/null 2>&1 || true
    else
        systemctl disable --now "${WM_AUTORESTART_TIMER}" >/dev/null 2>&1 || true
    fi
}

# When the next run is due, straight from systemd so it cannot drift from reality.
autorestart_next_run() {
    autorestart_is_enabled || { printf '%s' "-"; return; }
    local n
    n="$(systemctl show "${WM_AUTORESTART_TIMER}" -p NextElapseUSecRealtime --value 2>/dev/null)"
    [[ -n "$n" && "$n" != "n/a" && "$n" != "0" ]] && printf '%s' "$n" || printf '%s' "pending"
}
