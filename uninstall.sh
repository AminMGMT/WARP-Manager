#!/usr/bin/env bash
# WARP Manager - uninstaller (full purge)
set -uo pipefail
WM_ROOT="${WM_ROOT:-/opt/warp-manager}"
export WM_ROOT
SRC="$WM_ROOT/lib"
[[ -f "$SRC/common.sh" ]] || SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib"
# shellcheck source=/dev/null
source "$SRC/common.sh" 2>/dev/null || { echo "WARP Manager not found."; }
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo bash uninstall.sh"; exit 1; }

echo "This removes EVERYTHING: WARP interface, WARP account, sing-box, rules,"
echo "config, systemd units, and all warp-manager files."
read -rp "Type 'yes' to confirm: " yn
[[ "$yn" == "yes" ]] || { echo "Cancelled."; exit 0; }

systemctl disable --now warp-manager-boot.service >/dev/null 2>&1 || true
systemctl disable --now warp-manager-singbox.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/warp-manager-boot.service /etc/systemd/system/warp-manager-singbox.service
nft delete table inet "${WM_NFT_TABLE:-warp}" 2>/dev/null || true
systemctl disable --now "wg-quick@${WM_IFACE:-wgcf}" >/dev/null 2>&1 || true
rm -f "/etc/wireguard/${WM_IFACE:-wgcf}.conf" /etc/sysctl.d/99-warp-manager.conf
rm -f /usr/local/bin/warp-manager /usr/local/bin/wm /usr/local/bin/wgcf "${WM_SINGBOX_BIN:-/usr/local/bin/sing-box}"
systemctl daemon-reload >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true
rm -rf "${WM_CONF_DIR:-/etc/warp-manager}" "${WM_STATE_DIR:-/var/lib/warp-manager}" "$WM_ROOT"

echo "Done. WARP Manager has been completely removed."
