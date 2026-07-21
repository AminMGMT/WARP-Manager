#!/usr/bin/env bash
# WARP Manager - provider registry + set population
# Requires common.sh and routing.sh sourced first.

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

# --- resolvers -----------------------------------------------------------
# Emit resolved A records (one IP per line) for a single domain.
_resolve4() {
    local d="$1"
    if has_cmd dig; then
        dig +short +time=3 +tries=2 A "$d" 2>/dev/null | grep -E '^[0-9.]+$'
    else
        getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}
_resolve6() {
    local d="$1"
    if has_cmd dig; then
        dig +short +time=3 +tries=2 AAAA "$d" 2>/dev/null | grep -E '^[0-9A-Fa-f:]+$'
    else
        getent ahostsv6 "$d" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}
# Resolve MANY domains (read from stdin) in parallel -> IPs on stdout.
_resolve_many4() {
    if has_cmd dig; then
        xargs -r -P 16 -n1 dig +short +time=3 +tries=1 A 2>/dev/null | grep -E '^[0-9.]+$'
    else
        while read -r d; do [[ -n "$d" ]] && getent ahostsv4 "$d" | awk '{print $1}'; done
    fi
}
_resolve_many6() {
    if has_cmd dig; then
        xargs -r -P 16 -n1 dig +short +time=3 +tries=1 AAAA 2>/dev/null | grep -E '^[0-9A-Fa-f:]+$'
    else
        while read -r d; do [[ -n "$d" ]] && getent ahostsv6 "$d" | awk '{print $1}'; done
    fi
}

# --- geosite (v2fly domain-list-community) -------------------------------
# Print all resolvable domains of a geosite category (follows include:, caches).
declare -A _GS_SEEN
_geosite_domains() {
    local cat="$1" depth="${2:-0}"
    [[ "$depth" -gt 4 ]] && return
    [[ -n "${_GS_SEEN[$cat]:-}" ]] && return
    _GS_SEEN[$cat]=1

    local cache="${WM_STATE_DIR}/geosite/${cat}.raw"
    mkdir -p "${WM_STATE_DIR}/geosite"
    local fresh
    fresh="$(curl -fsSL --connect-timeout 8 "${WM_GEOSITE_BASE}/${cat}" 2>/dev/null)"
    if [[ -n "$fresh" ]]; then
        printf '%s\n' "$fresh" >"$cache"
    elif [[ ! -f "$cache" ]]; then
        log_warn "geosite:${cat} could not be fetched and no cache exists."
        return
    fi

    local line entry
    while IFS= read -r line; do
        line="${line%%#*}"                       # strip inline comment
        line="${line#"${line%%[![:space:]]*}"}"  # ltrim
        [[ -z "$line" ]] && continue
        entry="${line%% *}"                       # drop @attributes
        case "$entry" in
            include:*) _geosite_domains "${entry#include:}" $((depth+1)) ;;
            full:*)    echo "${entry#full:}" ;;
            domain:*)  echo "${entry#domain:}" ;;
            keyword:*|regexp:*) : ;;
            *)         echo "$entry" ;;
        esac
    done <"$cache"
}

# count lines of a file (0 if missing) — safe under `set -u`
_count_file() { [[ -f "$1" ]] && { wc -l <"$1" | tr -d ' '; } || echo 0; }

_provider_cache() { printf '%s/cache/%s' "$WM_STATE_DIR" "$1"; }

# --- resolve ONE provider fresh into the two accumulator files (no cache) -
_gather_raw() {
    local id="$1" v4="$2" v6="$3"
    local type; type="$(prov_field "$id" type)"
    case "$type" in
        cidr)
            local url; url="$(prov_field "$id" url)"
            [[ -n "$url" ]] || return
            local json; json="$(curl -fsSL --connect-timeout 8 "$url" 2>/dev/null)"
            [[ -z "$json" ]] && return
            if has_cmd jq; then
                jq -r '.prefixes[]?.ipv4Prefix // empty' <<<"$json" >>"$v4"
                jq -r '.prefixes[]?.ipv6Prefix // empty' <<<"$json" >>"$v6"
            else
                grep -oP '"ipv4Prefix":\s*"\K[^"]+' <<<"$json" >>"$v4"
                grep -oP '"ipv6Prefix":\s*"\K[^"]+' <<<"$json" >>"$v6"
            fi
            ;;
        domain)
            local domains; domains="$(prov_field "$id" domains)"
            printf '%s\n' $domains | _resolve_many4 >>"$v4"
            printf '%s\n' $domains | _resolve_many6 >>"$v6"
            ;;
        geosite)
            local cats extra
            cats="$(prov_field "$id" category)"
            extra="$(prov_field "$id" domains)"
            _GS_SEEN=()
            {
                local c
                for c in $cats; do _geosite_domains "$c"; done
                printf '%s\n' $extra
            } | sort -u >"${v4}.dom"
            _resolve_many4 <"${v4}.dom" >>"$v4"
            _resolve_many6 <"${v4}.dom" >>"$v6"
            rm -f "${v4}.dom"
            ;;
    esac
}

# Resolve a provider fresh and (re)write its cache. Sets _GATHER_COUNT.
_provider_refresh_cache() {
    local id="$1" c; c="$(_provider_cache "$id")"
    mkdir -p "${WM_STATE_DIR}/cache"
    local t4 t6; t4="$(mktemp)"; t6="$(mktemp)"
    _gather_raw "$id" "$t4" "$t6"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$t4" | sort -u >"${c}.v4"
    grep -E '^[0-9A-Fa-f:]+(/[0-9]+)?$' "$t6" | sort -u >"${c}.v6"
    rm -f "$t4" "$t6"
    _GATHER_COUNT=$(( $(_count_file "${c}.v4") + $(_count_file "${c}.v6") ))
}

# --- append a provider's IPs to the accumulators, using cache when present -
# Only resolves (and caches) when the cache is missing/empty, so toggling other
# services is instant. Sets _GATHER_COUNT.
_gather_provider() {
    local id="$1" v4="$2" v6="$3" c; c="$(_provider_cache "$id")"
    if [[ ! -s "${c}.v4" && ! -s "${c}.v6" ]]; then
        _provider_refresh_cache "$id"
    fi
    cat "${c}.v4" 2>/dev/null >>"$v4" || true
    cat "${c}.v6" 2>/dev/null >>"$v6" || true
    _GATHER_COUNT=$(( $(_count_file "${c}.v4") + $(_count_file "${c}.v6") ))
}

# --- custom domains, cached; re-resolved only when the custom file changed --
# force=1 forces a fresh resolve. Returns 0 if any custom domains exist.
_gather_custom() {
    local v4="$1" v6="$2" force="${3:-0}" c="${WM_STATE_DIR}/cache/_custom"
    if [[ ! -s "$WM_CUSTOM_FILE" ]] || ! grep -qvE '^[[:space:]]*(#|$)' "$WM_CUSTOM_FILE"; then
        return 1
    fi
    mkdir -p "${WM_STATE_DIR}/cache"
    if [[ "$force" == 1 || ( ! -s "${c}.v4" && ! -s "${c}.v6" ) || "$WM_CUSTOM_FILE" -nt "${c}.v4" ]]; then
        local t4 t6 d; t4="$(mktemp)"; t6="$(mktemp)"
        while read -r d; do
            [[ -z "$d" || "$d" == \#* ]] && continue
            _resolve4 "$d" >>"$t4"; _resolve6 "$d" >>"$t6"
        done < "$WM_CUSTOM_FILE"
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$t4" | sort -u >"${c}.v4"
        grep -E '^[0-9A-Fa-f:]+(/[0-9]+)?$' "$t6" | sort -u >"${c}.v6"
        rm -f "$t4" "$t6"
    fi
    cat "${c}.v4" 2>/dev/null >>"$v4" || true
    cat "${c}.v6" 2>/dev/null >>"$v6" || true
    return 0
}

# Validate, de-dup, cache and load two accumulator files into nftables.
# dig can print error lines to stdout (DNS timeouts); strict validation is the
# last line of defense so garbage never reaches nftables.
_providers_finalize() {
    local v4="$1" v6="$2"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$v4" | sort -u >"${v4}.s" && mv -f "${v4}.s" "$v4"
    grep -E '^[0-9A-Fa-f:]+(/[0-9]+)?$' "$v6" | sort -u >"${v6}.s" && mv -f "${v6}.s" "$v6"
    cp -f "$v4" "${WM_STATE_DIR}/last_v4.list"
    cp -f "$v6" "${WM_STATE_DIR}/last_v6.list"
    routing_load_sets "$v4" "$v6"
}

# --- rebuild every enabled provider + custom domains, then load into nft -
providers_refresh() {
    require_root
    ensure_dirs
    routing_installed || routing_apply_skeleton
    routing_load_exclusions
    local v4 v6
    v4="$(mktemp)"; v6="$(mktemp)"

    # timer path: force-refresh each enabled provider's cache (keeps caches fresh)
    local any=0 id c
    while read -r id; do
        [[ -z "$id" ]] && continue
        [[ -f "$WM_PROVIDERS_DIR/${id}.conf" ]] || continue
        _provider_refresh_cache "$id"
        c="$(_provider_cache "$id")"
        cat "${c}.v4" 2>/dev/null >>"$v4" || true
        cat "${c}.v6" 2>/dev/null >>"$v6" || true
        any=1
    done < <(grep -vE '^[[:space:]]*(#|$)' "$WM_ENABLED_FILE" 2>/dev/null)

    _gather_custom "$v4" "$v6" 1 && any=1     # force fresh custom resolve

    [[ "$any" -eq 0 ]] && log_warn "No services enabled; sets will be empty (all traffic goes direct)."
    _providers_finalize "$v4" "$v6"
    rm -f "$v4" "$v6" "${v4}.s" "${v6}.s"
}
