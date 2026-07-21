#!/usr/bin/env bash
# WARP Manager - one-command online installer.
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/AminMGMT/WARP-Manager/main/setup.sh)"
set -euo pipefail

REPO="AminMGMT/WARP-Manager"
BRANCH="main"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Please run as root (use sudo)."
    exit 1
fi

# make sure we can download + extract
if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates
    fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading WARP Manager..."
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" -o "$TMP/wm.tar.gz"
tar -xzf "$TMP/wm.tar.gz" -C "$TMP"

cd "$TMP/WARP-Manager-${BRANCH}"
bash install.sh
