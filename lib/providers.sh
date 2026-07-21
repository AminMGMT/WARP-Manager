#!/usr/bin/env bash
# WARP Manager - provider registry (metadata only).
# With the sing-box engine, routing is by domain (sing-box handles matching), so
# there is no IP resolution here anymore — providers just describe each service.
# Requires common.sh sourced first.

# List provider ids (basename of *.conf)
providers_list() {
    local f
    for f in "$WM_PROVIDERS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        basename "$f" .conf
    done
}

# Read a single field from a provider file: prov_field <id> <key>
prov_field() {
    local id="$1" key="$2"
    local f="$WM_PROVIDERS_DIR/${id}.conf"
    [[ -f "$f" ]] || return 1
    grep -oP "^${key}=\K.*" "$f" | head -n1
}

# Resolve a single domain's first A record (used only by the e2e test).
_resolve4() {
    local d="$1"
    if has_cmd dig; then
        dig +short +time=3 +tries=2 A "$d" 2>/dev/null | grep -E '^[0-9.]+$'
    else
        getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}
