#!/usr/bin/env bash
# WARP Manager - uninstaller (full purge)
#   sudo bash uninstall.sh
#
# The actual removal lives in lib/purge.sh, shared with `wm -> Uninstall`. This file
# used to carry its own hand-written copy of the steps, which drifted: it never
# removed the policy-routing rules, the runtime sysctls or a wgcf link that systemd
# had not managed to drop — none of which are on disk, so only a reboot cleared them.
set -uo pipefail
WM_ROOT="${WM_ROOT:-/opt/warp-manager}"
export WM_ROOT

SRC="$WM_ROOT/lib"
[[ -f "$SRC/common.sh" ]] || SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib"
[[ -f "$SRC/common.sh" && -f "$SRC/purge.sh" ]] || { echo "WARP Manager libraries not found ($SRC)."; exit 1; }
# purge.sh deliberately needs nothing but common.sh, so an installation that is
# already half-deleted can still be cleaned up properly.
# shellcheck source=/dev/null
source "$SRC/common.sh"
# shellcheck source=/dev/null
source "$SRC/purge.sh"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo bash uninstall.sh"; exit 1; }

echo "This removes EVERYTHING: WARP interface, WARP account, sing-box, nftables and"
echo "policy-routing rules, config, systemd units, and all warp-manager files."
read -rp "Type 'yes' to confirm: " yn
[[ "$yn" == "yes" ]] || { echo "Cancelled."; exit 0; }

purge_everything

LEFT="$(purge_leftovers)"
if [[ -z "$LEFT" ]]; then
    echo "Done. WARP Manager has been completely removed — no reboot needed."
else
    echo "Removed, but these are still present:"
    printf '%s\n' "$LEFT" | sed 's/^/   /'
    echo "Run it once more, or reboot to clear them."
    exit 1
fi
