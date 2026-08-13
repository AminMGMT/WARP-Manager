#!/usr/bin/env bash
# WARP Manager - complete removal.
# Requires common.sh sourced first, and NOTHING else: uninstall runs on hosts where
# the rest of the tree may already be half-deleted by an earlier partial attempt.
#
# This is the single implementation used by both `wm -> Uninstall` and
# `bash uninstall.sh`. It used to be two hand-maintained lists that drifted apart —
# the standalone uninstaller never removed the policy-routing rules, so after it ran
# the box still carried `ip rule fwmark 0xcab2 lookup 51890`, the WARP table, the
# runtime sysctls and sometimes the wgcf link itself. None of that is persisted to
# disk, which is exactly why a reboot "finished" the uninstall.
#
# Everything here is idempotent and survivable: each step is independent, so a
# failure in one does not leave the rest undone, and running it twice is harmless.

# `ip rule del` returns non-zero once nothing matches, which is the loop's exit
# condition — but a bounded loop is the only version that cannot hang a server if
# some iproute2 build ever decides to return 0 forever.
_purge_del_rules() {   # <ip-args...>
    local n=0
    while (( n++ < 64 )) && ip "$@" 2>/dev/null; do :; done
}

# --- 1. systemd ----------------------------------------------------------
# Matched by glob, not by a hand-written list: every unit this project installs is
# named warp-manager-*, so a unit added later can never be forgotten here.
_purge_systemd() {
    local u
    while read -r u; do
        [[ -z "$u" ]] && continue
        systemctl disable --now "$u" >/dev/null 2>&1 || true
    done < <( { systemctl list-unit-files --no-legend 'warp-manager-*' 2>/dev/null | awk '{print $1}';
                cd /etc/systemd/system 2>/dev/null && ls warp-manager-*.service warp-manager-*.timer 2>/dev/null; } | sort -u )
    rm -f /etc/systemd/system/warp-manager-*.service /etc/systemd/system/warp-manager-*.timer
    rm -rf /etc/systemd/system/warp-manager-*.d
    rm -f /etc/systemd/system/multi-user.target.wants/warp-manager-*.service \
          /etc/systemd/system/timers.target.wants/warp-manager-*.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    # without this the removed units linger in `systemctl --failed` until reboot
    systemctl reset-failed 'warp-manager-*' >/dev/null 2>&1 || true
}

# --- 2. leftover processes -----------------------------------------------
# A binary that is unlinked while running keeps running — and keeps holding the
# tproxy port. Only ever kill the process that is running OUR config file: the
# admin may well have a sing-box of their own, and it must not be touched.
_purge_processes() {
    pkill -f "sing-box run -c ${WM_SINGBOX_CONF}" 2>/dev/null || true
    pkill -f "warp-manager --watchdog" 2>/dev/null || true
}

# --- 3. nftables ---------------------------------------------------------
_purge_nftables() {
    has_cmd nft || return 0
    nft delete table inet "$WM_NFT_TABLE" 2>/dev/null || true
    # wg-quick builds its own kill-switch table for the interface; normally torn
    # down by `wg-quick down`, but not if the link was removed some other way.
    nft delete table ip "wg-quick-${WM_IFACE}" 2>/dev/null || true
    nft delete table ip6 "wg-quick-${WM_IFACE}" 2>/dev/null || true
}

# --- 4. policy routing ---------------------------------------------------
# The part the standalone uninstaller used to miss entirely. These rules and tables
# live only in the running kernel, so leaving them behind is precisely the residue
# that "disappears after a reboot".
_purge_routing() {
    has_cmd ip || return 0
    local t
    for t in "$WM_TPROXY_TABLE" "$WM_TABLE"; do
        _purge_del_rules      rule del table "$t"
        _purge_del_rules   -6 rule del table "$t"
        ip    route flush table "$t" 2>/dev/null || true
        ip -6 route flush table "$t" 2>/dev/null || true
    done
    # Legacy (pre-0xcab2) fwmark 0x1 / table 100. Table 100 is a plausible table for
    # someone else to be using, so it is only flushed when one of OUR rules for it
    # was actually there.
    local legacy=0
    ip    rule show 2>/dev/null | grep -q 'fwmark 0x1 lookup 100' && legacy=1
    ip -6 rule show 2>/dev/null | grep -q 'fwmark 0x1 lookup 100' && legacy=1
    if (( legacy )); then
        _purge_del_rules      rule del fwmark 0x1 lookup 100
        _purge_del_rules   -6 rule del fwmark 0x1 lookup 100
        ip    route flush table 100 2>/dev/null || true
        ip -6 route flush table 100 2>/dev/null || true
    fi
}

# --- 5. the WARP interface -----------------------------------------------
_purge_interface() {
    systemctl disable --now "wg-quick@${WM_IFACE}" >/dev/null 2>&1 || true
    systemctl reset-failed "wg-quick@${WM_IFACE}" >/dev/null 2>&1 || true
    # wg-quick down is the clean path (it runs PostDown); if the unit was already
    # gone or failed, the link is still there and only ip can remove it.
    if ip link show "$WM_IFACE" >/dev/null 2>&1; then
        wg-quick down "$WM_IFACE" >/dev/null 2>&1 || true
    fi
    ip link show "$WM_IFACE" >/dev/null 2>&1 && ip link del "$WM_IFACE" 2>/dev/null
    rm -f "$WM_WG_CONF"
    return 0
}

# --- 6. sysctl -----------------------------------------------------------
# Deleting the file is not enough: `sysctl --system` re-applies what is on disk, it
# does not revert a value that is no longer requested by anything, so the setting
# stays live until reboot.
#
# route_localnet is ours alone (TPROXY needs it) and its kernel default is 0, so it
# is reset explicitly. ip_forward / forwarding are deliberately NOT touched — the
# box may be an OpenVPN or NAT gateway and zeroing them would cut every user off.
# rp_filter is left as-is too: we relaxed it to 2 and cannot know what it was.
_purge_sysctl() {
    rm -f /etc/sysctl.d/99-warp-manager.conf
    sysctl -qw net.ipv4.conf.all.route_localnet=0 2>/dev/null || true
    sysctl -qw net.ipv4.conf.lo.route_localnet=0 2>/dev/null || true
    # run last so any OTHER file that wants these values wins over the reset above
    sysctl --system >/dev/null 2>&1 || true
}

# --- 7. files ------------------------------------------------------------
_purge_files() {
    rm -f /usr/local/bin/warp-manager /usr/local/bin/wm /usr/local/bin/wgcf "$WM_SINGBOX_BIN"
    rm -rf "$WM_CONF_DIR" "$WM_STATE_DIR" "$WM_ROOT"
    rm -f "$WM_LOG"
}

# --- 8. verify -----------------------------------------------------------
# Prints whatever is still on the box, one item per line. Empty output = clean.
# Worth having because every failure mode above is silent: the uninstall "succeeds"
# and the leftovers only show up as strange behaviour later.
purge_leftovers() {
    local left=""
    ip link show "$WM_IFACE" >/dev/null 2>&1 && left+="interface ${WM_IFACE} still up"$'\n'
    has_cmd nft && nft list table inet "$WM_NFT_TABLE" >/dev/null 2>&1 && left+="nftables table inet ${WM_NFT_TABLE}"$'\n'
    if has_cmd ip; then
        { ip rule show 2>/dev/null; ip -6 rule show 2>/dev/null; } \
            | grep -qE "lookup (${WM_TPROXY_TABLE}|${WM_TABLE})\b" \
            && left+="policy routing rules (tables ${WM_TABLE}/${WM_TPROXY_TABLE})"$'\n'
    fi
    compgen -G "/etc/systemd/system/warp-manager-*" >/dev/null 2>&1 && left+="systemd units in /etc/systemd/system"$'\n'
    pgrep -f "sing-box run -c ${WM_SINGBOX_CONF}" >/dev/null 2>&1 && left+="a sing-box process is still running"$'\n'
    local p
    for p in "$WM_ROOT" "$WM_CONF_DIR" "$WM_STATE_DIR" /usr/local/bin/warp-manager /usr/local/bin/wm; do
        [[ -e "$p" ]] && left+="${p}"$'\n'
    done
    printf '%s' "$left"
}

# The order matters in one place only: the rules and the interface must go before
# the files, or a failure half-way leaves a box with no tooling left to clean it.
purge_everything() {
    require_root
    _purge_systemd
    _purge_processes
    _purge_nftables
    _purge_routing
    _purge_interface
    _purge_sysctl
    _purge_files
}
