#!/usr/bin/env bash
# WARP Manager - ad blocker (AdGuard lists -> sing-box rule-set)
# Requires common.sh sourced first.
#
# No AdGuard Home, no DNS server, no web UI, no Docker: the engine already sniffs
# the domain of every connection, so ad blocking is just one more routing rule.
# This file only BUILDS the block/allow lists; wiring them into the sing-box config
# lives in singbox.sh.
#
# Two sources are merged:
#   1. AdGuard DNS filter  - downloaded and parsed here into a local rule-set
#   2. geosite-category-ads-all - a ready-made remote sing-box rule-set
#
# Safety: the engine is opt-in (adblock_enabled), a bad/short download never
# replaces a good list, and a built-in allow list protects connectivity checks.

WM_ADBLOCK_DIR="${WM_STATE_DIR}/adblock"
WM_ADBLOCK_JSON="${WM_ADBLOCK_DIR}/adguard.json"      # rule-set (source format)
WM_ADBLOCK_SRS="${WM_ADBLOCK_DIR}/adguard.srs"        # rule-set (compiled, if supported)
WM_ADBLOCK_ALLOW_AUTO="${WM_ADBLOCK_DIR}/exceptions.list"  # @@ rules from the filter
WM_ADBLOCK_STAMP="${WM_ADBLOCK_DIR}/updated"          # unix ts of the last good build
WM_ADBLOCK_WHITELIST="${WM_CONF_DIR}/adblock.whitelist"    # user-managed

# AdGuard DNS filter (the same list AdGuard Home ships as its default).
WM_ADBLOCK_URL="https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"
# Ready-made ads rule-set for sing-box (second source, merged with the above).
WM_ADBLOCK_GEOSITE="category-ads-all"

# A download smaller than this is treated as broken (the real list has ~160k rules).
WM_ADBLOCK_MIN_RULES=10000

# Never block these, whatever the lists say: client apps measure their "config ping"
# against connectivity-check endpoints, and killing those makes every tunnel look
# dead. Keep this list conservative.
WM_ADBLOCK_SAFE_DOMAINS="gstatic.com connectivitycheck.gstatic.com clients3.google.com clients4.google.com captive.apple.com detectportal.firefox.com msftconnecttest.com msftncsi.com cloudflareclient.com cloudflare.com engage.cloudflareclient.com api.cloudflareclient.com"

adblock_is_enabled() { [[ "$(conf_get adblock_enabled 0)" == "1" ]]; }
adblock_enable()     { conf_set adblock_enabled 1; }
adblock_disable()    { conf_set adblock_enabled 0; }

# --- allow list ----------------------------------------------------------
# Merged allow list: built-in safe domains + the filter's own @@ exceptions +
# whatever the user added. Printed one domain per line.
adblock_allow_domains() {
    {
        printf '%s\n' $WM_ADBLOCK_SAFE_DOMAINS
        [[ -s "$WM_ADBLOCK_ALLOW_AUTO" ]] && cat "$WM_ADBLOCK_ALLOW_AUTO"
        [[ -s "$WM_ADBLOCK_WHITELIST" ]] && grep -vE '^[[:space:]]*(#|$)' "$WM_ADBLOCK_WHITELIST"
    } 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/[[:space:]]//g' | grep -E '^[a-z0-9.-]+\.[a-z]{2,}$' | sort -u
}

adblock_whitelist_add() {
    local d="${1,,}"
    [[ -n "$d" ]] || return 1
    ensure_dirs; touch "$WM_ADBLOCK_WHITELIST"
    grep -qxF "$d" "$WM_ADBLOCK_WHITELIST" 2>/dev/null || printf '%s\n' "$d" >>"$WM_ADBLOCK_WHITELIST"
}

adblock_whitelist_remove() {
    local d="${1,,}"
    [[ -f "$WM_ADBLOCK_WHITELIST" ]] || return 0
    grep -vxF "$d" "$WM_ADBLOCK_WHITELIST" >"${WM_ADBLOCK_WHITELIST}.t" 2>/dev/null || true
    mv -f "${WM_ADBLOCK_WHITELIST}.t" "$WM_ADBLOCK_WHITELIST"
}

# --- build ---------------------------------------------------------------
# Parse AdGuard syntax into plain domains. 99.7% of the list is `||domain^`;
# everything we cannot express as a domain match is skipped rather than guessed:
#   @@rules      -> exceptions file (they must not be blocked)
#   $badfilter   -> the rule is disabled upstream, drop it
#   /regex/      -> not expressible as a domain
#   wildcards *  -> not expressible as a domain suffix
_adblock_parse() {
    local src="$1" out_block="$2" out_allow="$3"
    awk -v blockf="$out_block" -v allowf="$out_allow" '
        function clean(s) {
            sub(/\$.*$/, "", s)          # drop $modifiers
            sub(/^@@/, "", s)
            sub(/^\|\|/, "", s)
            sub(/\^.*$/, "", s)          # drop the ^ separator and anything after
            sub(/^\.+/, "", s)           # ".example.com^" style rules
            sub(/\/.*$/, "", s)          # drop any path part
            sub(/^\*\./, "", s)
            return tolower(s)
        }
        function valid(d) {
            return (d ~ /^[a-z0-9.-]+$/ && d ~ /\.[a-z][a-z]+$/ \
                    && d !~ /\.\./ && d !~ /^[.-]/ && d !~ /[.-]$/ && length(d) < 254)
        }
        /^!/            { next }         # comments
        /^[[:space:]]*$/ { next }
        /\$badfilter/   { next }         # disabled upstream
        /^\//           { next }         # regex rule
        /^@@/ {
            d = clean($0); if (valid(d)) print d > allowf
            next
        }
        /\*/            { next }         # wildcard: not a plain domain
        {
            d = clean($0); if (valid(d)) print d > blockf
        }
    ' "$src"
}

# Turn a newline-separated domain list into a sing-box rule-set (source format).
# `||d^` means "d and every subdomain", which in sing-box is an exact `domain`
# match plus a `.d` `domain_suffix` match — the same pairing used for providers.
_adblock_write_ruleset() {
    local domains_file="$1" dest="$2"
    jq -n --rawfile doms "$domains_file" '
        ($doms | split("\n") | map(select(length > 0))) as $d
        | { version: 1,
            rules: [ { domain: $d, domain_suffix: ($d | map("." + .)) } ] }
    ' >"$dest"
}

# Download + rebuild the block list. Returns 1 without touching the existing list
# if anything looks wrong, so a bad fetch can never degrade a working install.
adblock_build() {
    ensure_dirs
    mkdir -p "$WM_ADBLOCK_DIR"
    has_cmd jq || { log_error "jq is required for the ad blocker."; return 1; }

    local tmp raw blk alw
    tmp="$(mktemp -d)" || return 1
    raw="$tmp/raw.txt"; blk="$tmp/block.txt"; alw="$tmp/allow.txt"
    : >"$blk"; : >"$alw"

    log_step "Downloading AdGuard DNS filter..."
    if ! curl -fsSL --connect-timeout 20 --max-time 120 -o "$raw" "$WM_ADBLOCK_URL"; then
        rm -rf "$tmp"
        log_error "Could not download the filter list (network/GitHub blocked?)."
        return 1
    fi

    log_step "Building the block list..."
    _adblock_parse "$raw" "$blk" "$alw"

    local n; n=$(wc -l <"$blk" 2>/dev/null || echo 0)
    if [[ "$n" -lt "$WM_ADBLOCK_MIN_RULES" ]]; then
        rm -rf "$tmp"
        log_error "Filter list looks broken (only ${n} domains); keeping the previous list."
        return 1
    fi

    # Drop allow-listed domains from the block set so an exception always wins.
    local allow_all; allow_all="$tmp/allow_all.txt"
    { cat "$alw"; printf '%s\n' $WM_ADBLOCK_SAFE_DOMAINS;
      [[ -s "$WM_ADBLOCK_WHITELIST" ]] && grep -vE '^[[:space:]]*(#|$)' "$WM_ADBLOCK_WHITELIST"; } \
        2>/dev/null | tr 'A-Z' 'a-z' | sort -u >"$allow_all"
    sort -u "$blk" | comm -23 - "$allow_all" >"$tmp/final.txt"

    n=$(wc -l <"$tmp/final.txt")
    _adblock_write_ruleset "$tmp/final.txt" "$tmp/adguard.json" || {
        rm -rf "$tmp"; log_error "Could not build the rule-set."; return 1; }
    jq -e . "$tmp/adguard.json" >/dev/null 2>&1 || {
        rm -rf "$tmp"; log_error "Generated rule-set is not valid JSON."; return 1; }

    install -m 644 "$tmp/adguard.json" "$WM_ADBLOCK_JSON"
    install -m 644 "$allow_all" "$WM_ADBLOCK_ALLOW_AUTO"

    # A compiled rule-set loads faster and uses less memory; fall back to the
    # source format when this sing-box build has no `rule-set compile`.
    rm -f "$WM_ADBLOCK_SRS"
    if "$WM_SINGBOX_BIN" rule-set compile --output "$WM_ADBLOCK_SRS" "$WM_ADBLOCK_JSON" >/dev/null 2>&1 \
       && [[ -s "$WM_ADBLOCK_SRS" ]]; then
        log_info "Ad blocker: ${n} domains (compiled rule-set)."
    else
        rm -f "$WM_ADBLOCK_SRS"
        log_info "Ad blocker: ${n} domains."
    fi

    date +%s >"$WM_ADBLOCK_STAMP"
    rm -rf "$tmp"
    return 0
}

# Path + format the sing-box config should reference (compiled when available).
adblock_ruleset_path()   { [[ -s "$WM_ADBLOCK_SRS" ]] && printf '%s' "$WM_ADBLOCK_SRS" || printf '%s' "$WM_ADBLOCK_JSON"; }
adblock_ruleset_format() { [[ -s "$WM_ADBLOCK_SRS" ]] && printf 'binary' || printf 'source'; }
adblock_has_list()       { [[ -s "$WM_ADBLOCK_JSON" ]]; }

# Number of blocked domains in the current list (0 when there is none).
adblock_count() {
    [[ -s "$WM_ADBLOCK_JSON" ]] || { echo 0; return; }
    jq -r '[.rules[].domain // [] | length] | add // 0' "$WM_ADBLOCK_JSON" 2>/dev/null || echo 0
}

# Human-readable age of the list, e.g. "2h ago" / "never".
adblock_last_update() {
    [[ -s "$WM_ADBLOCK_STAMP" ]] || { echo "never"; return; }
    local t now d
    t="$(cat "$WM_ADBLOCK_STAMP" 2>/dev/null || echo 0)"; now="$(date +%s)"
    d=$(( (now - t) / 60 ))
    if   [[ $d -lt 60 ]];   then echo "${d}m ago"
    elif [[ $d -lt 1440 ]]; then echo "$((d/60))h ago"
    else echo "$((d/1440))d ago"; fi
}
