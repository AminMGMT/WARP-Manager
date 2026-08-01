#!/usr/bin/env bash
# WARP Manager - ad blocker (uBlock Origin's filter lists -> sing-box rule-set)
# Requires common.sh sourced first.
#
# No AdGuard Home, no DNS server, no web UI, no Docker: the engine already sniffs
# the domain of every connection, so ad blocking is just one more routing rule.
# This file only BUILDS the block/allow lists; wiring them into the sing-box config
# lives in singbox.sh.
#
# ---------------------------------------------------------------------------
# What "uBlock Origin" can and cannot mean on a server
# ---------------------------------------------------------------------------
# uBlock Origin is a *browser extension*. Three things give it its power:
#   1. network filters   - ||ads.example.com^        <- domain, works here
#   2. cosmetic filters  - example.com##.ad-banner   <- needs the page DOM
#   3. scriptlets        - example.com##+js(...)     <- needs to run JS in the page
# sing-box sees the DOMAIN of a connection (TLS SNI / QUIC ClientHello) and nothing
# else: the URL path is inside the encrypted stream and there is no page to inspect.
# So (2) and (3) cannot exist server-side, and neither can any network filter that
# depends on a path or a request type. Claiming otherwise would just mean blocking
# things at random.
#
# What IS taken from uBlock, in full: its filter-list catalogue — the same lists it
# ships, with the same nine enabled by default — and from those, every rule that
# reduces to a domain. That is ~105k domains from uBlock's default set, versus the
# ~160k DNS-oriented rules of the single AdGuard list used before; the AdGuard list
# is still in the catalogue for anyone who wants both.
#
# Sources merged at build time:
#   1. the enabled filter lists from data/adblock-lists.conf (uBlock's catalogue)
#   2. geosite-category-ads-all - a ready-made remote sing-box rule-set
#
# Safety: the blocker is opt-in, a bad or short download never replaces a working
# list, one unreachable list does not fail the build, and a guard (see
# _adblock_protected) drops anything the lists would block that this server
# deliberately routes or needs for connectivity.

WM_ADBLOCK_DIR="${WM_STATE_DIR}/adblock"
WM_ADBLOCK_JSON="${WM_ADBLOCK_DIR}/adguard.json"      # rule-set (source format)
WM_ADBLOCK_SRS="${WM_ADBLOCK_DIR}/adguard.srs"        # rule-set (compiled, if supported)
# Second, much smaller rule-set, matched EARLY — ahead of the engine's YouTube and
# media carve-outs, which is the only position from which a ".youtube.com" ad host
# can be blocked at all.
#
# Only hand-verified lists belong here. Everything early runs before the routing
# rules, so a false positive would not merely block a site, it would beat a service
# the user deliberately selected — or a custom domain added after the last list
# build, which the build-time guard cannot know about yet. The bulk lists stay in
# the general rule-set below, where routing always wins.
WM_ADBLOCK_PRIO_JSON="${WM_ADBLOCK_DIR}/adguard-prio.json"
WM_ADBLOCK_PRIO_SRS="${WM_ADBLOCK_DIR}/adguard-prio.srs"
WM_ADBLOCK_PRIORITY_LISTS="youtube-ads"
WM_ADBLOCK_ALLOW_AUTO="${WM_ADBLOCK_DIR}/exceptions.list"  # @@ rules from the filters
WM_ADBLOCK_STAMP="${WM_ADBLOCK_DIR}/updated"          # unix ts of the last good build
WM_ADBLOCK_STATS="${WM_ADBLOCK_DIR}/stats"            # "<id> <domains>" per list
WM_ADBLOCK_WHITELIST="${WM_CONF_DIR}/adblock.whitelist"    # user-managed
WM_ADBLOCK_CATALOGUE="${WM_ROOT}/data/adblock-lists.conf"  # generated from uBlock
WM_ADBLOCK_LISTS="${WM_CONF_DIR}/adblock.lists"       # user's list choices (ids)

# Ready-made ads rule-set for sing-box (extra source, merged with the above).
WM_ADBLOCK_GEOSITE="category-ads-all"

# A merged result smaller than this is treated as broken (uBlock's default set
# yields ~105k domains, so this floor only ever trips on a real failure).
WM_ADBLOCK_MIN_RULES=10000

# Filter modifiers that still mean "this whole domain", so the rule survives the
# translation to a domain match. Everything else ($script, $image, $xhr, $domain=,
# $redirect, $removeparam, ...) scopes the rule to a request type or a referring
# site that a server cannot observe, and $badfilter means the rule is switched off
# upstream. Those are skipped rather than widened — widening a scoped rule to a
# whole domain is exactly how an ad blocker takes a site down.
WM_ADBLOCK_SAFE_MODIFIERS="all doc document popup third-party 3p"

# Never block these, whatever the lists say: client apps measure their "config ping"
# against connectivity-check endpoints, and killing those makes every tunnel look
# dead. Keep this list conservative.
WM_ADBLOCK_SAFE_DOMAINS="gstatic.com www.gstatic.com connectivitycheck.gstatic.com clients3.google.com clients4.google.com www.google.com google.com youtube.com www.youtube.com googlevideo.com www.googlevideo.com apple.com www.apple.com captive.apple.com detectportal.firefox.com msftconnecttest.com www.msftconnecttest.com msftncsi.com www.msftncsi.com cloudflareclient.com cloudflare.com engage.cloudflareclient.com api.cloudflareclient.com"

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

# --- filter-list catalogue ------------------------------------------------
# Rows are "id|default|title|url"; see data/adblock-lists.conf.
adblock_lists_all()   { grep -vE '^[[:space:]]*(#|$)' "$WM_ADBLOCK_CATALOGUE" 2>/dev/null; }
adblock_list_field()  { adblock_lists_all | awk -F'|' -v id="$1" -v n="$2" '$1==id{print $n; exit}'; }
adblock_list_title()  { adblock_list_field "$1" 3; }
adblock_list_url()    { adblock_list_field "$1" 4; }

# The user's choices live in their own file and win; with no file at all, uBlock's
# own defaults apply, so a fresh install matches what uBlock ships.
#
# The test is the file EXISTING, not it having content. "I want nothing enabled" is
# a real choice, and judging by size made an empty selection look like no selection
# — so turning the last list off silently brought all of uBlock's defaults back.
# The header written by _adblock_lists_write keeps the file non-empty anyway, but
# existence is the correct question either way.
adblock_list_is_enabled() {
    if [[ -f "$WM_ADBLOCK_LISTS" ]]; then
        grep -qxF "$1" "$WM_ADBLOCK_LISTS"
    else
        [[ "$(adblock_list_field "$1" 2)" == "on" ]]
    fi
}
adblock_lists_enabled() {
    local id
    while IFS='|' read -r id _; do
        [[ -n "$id" ]] && adblock_list_is_enabled "$id" && printf '%s\n' "$id"
    done < <(adblock_lists_all)
    # Without this the function inherits the status of the LAST id's check, and the
    # catalogue ends on a disabled list — so every caller using `&&` would see a
    # perfectly good list of enabled lists as a failure.
    return 0
}
# Materialise the defaults into the user file the first time a choice is made, so
# "enabled" never silently changes underneath the user when uBlock's defaults move.
# Write a selection from ids on stdin. The header is what makes "nothing enabled"
# representable: the file stays present and non-empty, so it still reads as a
# deliberate choice rather than as an absent one.
_adblock_lists_write() {
    ensure_dirs
    local tmp="${WM_ADBLOCK_LISTS}.new"
    {
        printf '# WARP Manager - filter lists chosen from the menu, one id per line.\n'
        printf '# Delete this file to go back to the lists uBlock enables by default.\n'
        grep -vE '^[[:space:]]*(#|$)' || true
    } >"$tmp"
    mv -f "$tmp" "$WM_ADBLOCK_LISTS"
}

_adblock_lists_materialise() {
    [[ -f "$WM_ADBLOCK_LISTS" ]] && return 0
    # Through a temp file, never straight into the target: the redirect truncates
    # it first, and adblock_lists_enabled reads that same file to decide each id.
    # As soon as one line landed, the rest would be judged against a half-written
    # selection instead of the defaults.
    adblock_lists_enabled | _adblock_lists_write
}
adblock_list_enable() {
    _adblock_lists_materialise
    grep -qxF "$1" "$WM_ADBLOCK_LISTS" 2>/dev/null || printf '%s\n' "$1" >>"$WM_ADBLOCK_LISTS"
}
adblock_list_disable() {
    _adblock_lists_materialise
    grep -vxF "$1" "$WM_ADBLOCK_LISTS" 2>/dev/null | _adblock_lists_write
}
# Every list at once. One write instead of 71, and "off" really means off.
adblock_lists_set_all() {
    if [[ "${1:-}" == on ]]; then
        adblock_lists_all | cut -d'|' -f1 | _adblock_lists_write
    else
        : | _adblock_lists_write
    fi
}
adblock_lists_reset() { rm -f "$WM_ADBLOCK_LISTS"; }   # back to uBlock's defaults
# domains contributed by one list at the last build (for the menu)
adblock_list_count() {
    [[ -s "$WM_ADBLOCK_STATS" ]] || { echo "-"; return; }
    awk -v id="$1" '$1==id{print $2; f=1} END{if(!f)print "-"}' "$WM_ADBLOCK_STATS"
}

# --- fetching -------------------------------------------------------------
# Download a list, following uBlock's own `!#include <relative-path>` directive.
#
# Several catalogue entries are nothing but a stub of includes — "uBlock filters –
# Annoyances" is 9 lines, all of them comments plus one include, and PersianBlocker
# is a stub over eight sub-lists. Without this they parse to zero domains and look
# like empty lists rather than unfetched ones.
#
# Depth is capped and each target is fetched at most once: an include cycle in a
# third-party list must not turn a weekly refresh into an endless download loop.
WM_ADBLOCK_INCLUDE_DEPTH=3

_adblock_fetch_list() {
    local url="$1" dest="$2"
    : >"$dest"
    _adblock_fetch_into "$url" "$dest" 0 "" && [[ -s "$dest" ]]
}

_adblock_fetch_into() {
    local url="$1" dest="$2" depth="$3" seen="$4"
    (( depth > WM_ADBLOCK_INCLUDE_DEPTH )) && return 0
    case " $seen " in *" $url "*) return 0 ;; esac      # already pulled in

    # Lists shipped with WARP Manager itself (file:<path>, relative to WM_ROOT).
    # They need no network, so a server that cannot reach GitHub still gets them.
    if [[ "$url" == file:* ]]; then
        local src="${WM_ROOT}/${url#file:}"
        [[ -s "$src" ]] || { log_warn "    bundled list missing: ${src}"; return 1; }
        cat "$src" >>"$dest"
        return 0
    fi

    local tmp; tmp="$(mktemp)"
    if ! curl -fsSL --connect-timeout 20 --max-time 120 -o "$tmp" "$url"; then
        rm -f "$tmp"
        # a missing sub-list is not fatal: the parent's own rules still count
        (( depth > 0 )) && { log_warn "    include unreachable: ${url}"; return 0; }
        return 1
    fi
    cat "$tmp" >>"$dest"
    local base inc target
    base="${url%/*}"
    while read -r inc; do
        [[ -n "$inc" ]] || continue
        case "$inc" in
            http://*|https://*) target="$inc" ;;
            /*)                 continue ;;               # absolute path: not ours to resolve
            *)                  target="${base}/${inc}" ;;
        esac
        log_step "    + include $(basename "$inc")"
        _adblock_fetch_into "$target" "$dest" $((depth + 1)) "$seen $url"
    done < <(awk '/^!#include[[:space:]]/ { sub(/^!#include[[:space:]]+/, ""); sub(/\r$/, ""); print $1 }' "$tmp")
    rm -f "$tmp"
    return 0
}

# --- build ---------------------------------------------------------------
# Parse one filter list into domains. Handles the two formats uBlock's catalogue
# actually contains: adblock syntax and hosts files.
#
# Kept:   ||domain^                      (and with only WM_ADBLOCK_SAFE_MODIFIERS)
#         0.0.0.0 domain / 127.0.0.1 domain
#         @@||domain^                    -> exceptions, which only ever unblock
# Skipped: cosmetic (##, #@#, #?#, #$#) and scriptlets - impossible server-side
#         rules with a path or a wildcard  - not expressible as a domain
#         $domain=/$script/$image/...     - scoped to something a server cannot see
#         $badfilter                      - the rule is disabled upstream
_adblock_parse() {
    local src="$1" out_block="$2" out_allow="$3"
    awk -v blockf="$out_block" -v allowf="$out_allow" -v safemods="$WM_ADBLOCK_SAFE_MODIFIERS" '
        BEGIN { n = split(safemods, sm, " "); for (i = 1; i <= n; i++) SAFE[sm[i]] = 1 }
        function valid(d) {
            return (d ~ /^[a-z0-9.-]+$/ && d ~ /\.[a-z][a-z]+$/ \
                    && d !~ /\.\./ && d !~ /^[.-]/ && d !~ /[.-]$/ && length(d) < 254)
        }
        # every modifier must still mean "the whole domain", or the rule is dropped
        function mods_ok(opt,   k, a, i, m) {
            if (opt == "") return 1
            k = split(opt, a, ",")
            for (i = 1; i <= k; i++) { m = a[i]; sub(/=.*$/, "", m); if (!(m in SAFE)) return 0 }
            return 1
        }
        { sub(/\r$/, "") }                       # lists are often CRLF
        /^[[:space:]]*$/ { next }
        /^[!\[]/         { next }                # adblock comments / [Adblock Plus 2.0]
        # hosts format (Peter Lowe, Dan Pollock): "0.0.0.0 tracker.example"
        /^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]+/ {
            d = tolower($2)
            if (d != "localhost" && d !~ /^localhost\./ && valid(d)) print d > blockf
            next
        }
        /^#/             { next }                # hosts comment / generic cosmetic
        /#[@$?%]*#/      { next }                # cosmetic filter or scriptlet
        # Plain domain lists: one bare hostname per line, no adblock syntax at all.
        # anti-AD, NeoDev and several YouTube lists ship this way, and without this
        # they parse to nothing at all. Only a line that is EXACTLY a hostname counts,
        # so a filter rule can never be mistaken for one.
        /^[a-z0-9.-]+$/ {
            d = tolower($0)
            if (valid(d)) print d > blockf
            next
        }
        {
            line = $0
            isallow = 0
            if (substr(line, 1, 2) == "@@") { isallow = 1; line = substr(line, 3) }
            if (substr(line, 1, 2) != "||") next # anchored-domain rules only
            line = substr(line, 3)
            # split pattern from $modifiers
            p = index(line, "$")
            if (p > 0) { opt = substr(line, p + 1); pat = substr(line, 1, p - 1) }
            else       { opt = "";                  pat = line }
            sub(/\^$/, "", pat)
            if (pat == "" || index(pat, "/") || index(pat, "*") || index(pat, "^")) next
            d = tolower(pat)
            if (!valid(d)) next
            # Exceptions get the SAME modifier discipline as block rules, and for a
            # sharper reason. Nearly all of them are scoped:
            #   @@||doubleclick.net^$script,xhr,domain=viz.com
            # means "allow doubleclick on viz.com", not "never block doubleclick".
            # Honouring that scope is impossible here, and obeying it globally would
            # quietly un-block doubleclick, google-analytics and ~1000 more while the
            # blocker still looked healthy. Only 5 of ~1035 domain exceptions in
            # uBlock default set are unscoped. So a scoped exception is ignored,
            # which errs toward blocking — the list author intent everywhere else —
            # and any site it does break is one entry in White Lists.
            if (!mods_ok(opt)) next
            if (isallow) { print d > allowf; next }
            print d > blockf
        }
    ' "$src"
}

# Domains this server must never block, whatever the lists say:
#   * the connectivity-check endpoints (killing those makes every tunnel look dead)
#   * every domain in the provider catalogue - these are routed on purpose, and
#     uBlock's default set really does list some of them (slackb.com, t.co)
#   * the user's own white list
# Each domain also protects its parents, because blocking a parent takes the child
# with it: `.qq.com` as a suffix rule would swallow weixin.qq.com.
_adblock_protected() {
    {
        printf '%s\n' $WM_ADBLOCK_SAFE_DOMAINS
        [[ -d "$WM_PROVIDERS_DIR" ]] && \
            grep -h '^domains=' "$WM_PROVIDERS_DIR"/*.conf 2>/dev/null | sed 's/^domains=//' | tr ' ' '\n'
        # Custom domains are read straight from their own file, not only via the
        # generated _custom.conf provider: that file is written at apply time, so
        # relying on it alone leaves a domain added since the last list build
        # unguarded.
        [[ -s "$WM_CUSTOM_FILE" ]] && grep -vE '^[[:space:]]*(#|$)' "$WM_CUSTOM_FILE"
        [[ -s "$WM_ADBLOCK_WHITELIST" ]] && grep -vE '^[[:space:]]*(#|$)' "$WM_ADBLOCK_WHITELIST"
    } 2>/dev/null \
    | tr 'A-Z' 'a-z' | sed 's/[[:space:]]//g' | grep -E '^[a-z0-9.-]+\.[a-z]{2,}$' \
    | awk '{
        print
        # walk up to (but not into) the public suffix: a.b.example.com also
        # protects b.example.com and example.com
        s = $0
        while (gsub(/^[^.]+\./, "", s) > 0) { if (split(s, p, ".") < 2) break; print s }
      }' \
    | sort -u
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
    [[ -s "$WM_ADBLOCK_CATALOGUE" ]] || { log_error "Filter-list catalogue missing: $WM_ADBLOCK_CATALOGUE"; return 1; }

    local tmp blk pblk alw stats
    tmp="$(mktemp -d)" || return 1
    blk="$tmp/block.txt"; pblk="$tmp/prio.txt"; alw="$tmp/allow.txt"; stats="$tmp/stats"
    : >"$blk"; : >"$pblk"; : >"$alw"; : >"$stats"

    # Fetch every enabled list. One unreachable source must not cost the whole
    # blocker — the merged total is sanity-checked at the end instead.
    local id url title raw lblk lalw got=0 failed=0 nlists=0
    while read -r id; do
        [[ -n "$id" ]] || continue
        nlists=$((nlists+1))
        url="$(adblock_list_url "$id")"; title="$(adblock_list_title "$id")"
        [[ -n "$url" ]] || { log_warn "  unknown filter list '${id}'; skipped."; continue; }
        raw="$tmp/${id}.raw"; lblk="$tmp/${id}.blk"; lalw="$tmp/${id}.alw"
        : >"$lblk"; : >"$lalw"
        log_step "  fetching ${title}..."
        if ! _adblock_fetch_list "$url" "$raw"; then
            log_warn "  could not download ${title}; continuing without it."
            failed=$((failed+1)); continue
        fi
        _adblock_parse "$raw" "$lblk" "$lalw"
        printf '%s %s\n' "$id" "$(_adblock_nlines "$lblk")" >>"$stats"
        # Hand-verified lists go to the early rule-set; everything else to the
        # general one that is evaluated after routing.
        if [[ " $WM_ADBLOCK_PRIORITY_LISTS " == *" $id "* ]]; then
            cat "$lblk" >>"$pblk"
        else
            cat "$lblk" >>"$blk"
        fi
        cat "$lalw" >>"$alw"
        got=$((got+1))
        rm -f "$raw"
    done < <(adblock_lists_enabled)

    if [[ "$nlists" -eq 0 ]]; then
        rm -rf "$tmp"
        log_error "No filter list is enabled (Ad Blocker → Filter Lists); keeping the previous list."
        return 1
    fi
    if [[ "$got" -eq 0 ]]; then
        rm -rf "$tmp"
        log_error "None of the ${nlists} enabled filter lists could be downloaded; keeping the previous list."
        return 1
    fi
    [[ "$failed" -gt 0 ]] && log_warn "${failed} of ${nlists} lists were unreachable."

    log_step "Building the block list..."
    sort -u "$blk" "$pblk" >"$tmp/merged.txt"
    local n; n=$(_adblock_nlines "$tmp/merged.txt")
    if [[ "$n" -lt "$WM_ADBLOCK_MIN_RULES" ]]; then
        rm -rf "$tmp"
        log_error "Filter lists look broken (only ${n} domains); keeping the previous list."
        return 1
    fi

    # An exception, a routed provider domain or a user allow-list entry always wins
    # over a block rule — see _adblock_protected for why this is not optional.
    #
    # Two distinct sets, and mixing them up would be expensive:
    #   guard  - subtracted from the block list HERE, at build time. It holds every
    #            provider domain, and those must NOT become runtime "direct" rules:
    #            sing-box evaluates the ad-blocker allow rules before the WARP
    #            rules, so that would quietly send every selected service direct.
    #   alw    - the lists' own @@ exceptions, which do become runtime allow rules,
    #            because they also have to override the second (remote) ads source.
    local guard; guard="$tmp/guard.txt"
    { cat "$alw"; _adblock_protected; } 2>/dev/null \
        | tr 'A-Z' 'a-z' | sort -u >"$guard"
    sort -u "$blk"  >"$tmp/block_sorted.txt"
    sort -u "$pblk" >"$tmp/prio_sorted.txt"
    comm -23 "$tmp/block_sorted.txt" "$guard" >"$tmp/final.txt"
    comm -23 "$tmp/prio_sorted.txt"  "$guard" >"$tmp/final_prio.txt"
    # a domain in the early set never needs to be in the general one as well
    comm -23 "$tmp/final.txt" "$tmp/final_prio.txt" >"$tmp/final.dedup" \
        && mv -f "$tmp/final.dedup" "$tmp/final.txt"
    sort -u "$alw" >"$tmp/exceptions.txt"

    local np ng
    ng=$(_adblock_nlines "$tmp/final.txt")
    np=$(_adblock_nlines "$tmp/final_prio.txt")
    local dropped=$(( n - ng - np ))
    [[ "$dropped" -gt 0 ]] && log_info "Ad blocker: ${dropped} domains held back (routed services, allow list, list exceptions)."
    n=$(( ng + np ))

    _adblock_write_ruleset "$tmp/final.txt" "$tmp/adguard.json" || {
        rm -rf "$tmp"; log_error "Could not build the rule-set."; return 1; }
    jq -e . "$tmp/adguard.json" >/dev/null 2>&1 || {
        rm -rf "$tmp"; log_error "Generated rule-set is not valid JSON."; return 1; }

    install -m 644 "$tmp/adguard.json" "$WM_ADBLOCK_JSON"
    install -m 644 "$tmp/exceptions.txt" "$WM_ADBLOCK_ALLOW_AUTO"
    install -m 644 "$stats" "$WM_ADBLOCK_STATS"

    # The early rule-set only exists while a priority list is actually enabled;
    # leaving a stale file behind would keep blocking after it was turned off.
    rm -f "$WM_ADBLOCK_PRIO_JSON" "$WM_ADBLOCK_PRIO_SRS"
    if [[ "$np" -gt 0 ]]; then
        _adblock_write_ruleset "$tmp/final_prio.txt" "$tmp/prio.json" \
            && jq -e . "$tmp/prio.json" >/dev/null 2>&1 \
            && install -m 644 "$tmp/prio.json" "$WM_ADBLOCK_PRIO_JSON" \
            || { rm -rf "$tmp"; log_error "Could not build the early rule-set."; return 1; }
    fi

    # A compiled rule-set loads faster and uses less memory; fall back to the
    # source format when this sing-box build has no `rule-set compile`.
    rm -f "$WM_ADBLOCK_SRS"
    if "$WM_SINGBOX_BIN" rule-set compile --output "$WM_ADBLOCK_SRS" "$WM_ADBLOCK_JSON" >/dev/null 2>&1 \
       && [[ -s "$WM_ADBLOCK_SRS" ]]; then
        [[ -s "$WM_ADBLOCK_PRIO_JSON" ]] && \
            { "$WM_SINGBOX_BIN" rule-set compile --output "$WM_ADBLOCK_PRIO_SRS" "$WM_ADBLOCK_PRIO_JSON" >/dev/null 2>&1 \
              || rm -f "$WM_ADBLOCK_PRIO_SRS"; }
        log_info "Ad blocker: ${n} domains (${np} matched ahead of routing) (compiled rule-set)."
    else
        rm -f "$WM_ADBLOCK_SRS" "$WM_ADBLOCK_PRIO_SRS"
        log_info "Ad blocker: ${n} domains (${np} matched ahead of routing)."
    fi

    date +%s >"$WM_ADBLOCK_STAMP"
    rm -rf "$tmp"
    return 0
}

# Path + format the sing-box config should reference (compiled when available).
adblock_ruleset_path()   { [[ -s "$WM_ADBLOCK_SRS" ]] && printf '%s' "$WM_ADBLOCK_SRS" || printf '%s' "$WM_ADBLOCK_JSON"; }
adblock_ruleset_format() { [[ -s "$WM_ADBLOCK_SRS" ]] && printf 'binary' || printf 'source'; }
adblock_has_list()       { [[ -s "$WM_ADBLOCK_JSON" ]]; }

# The early rule-set exists only while a priority list is enabled.
adblock_has_prio()        { [[ -s "$WM_ADBLOCK_PRIO_JSON" ]]; }
adblock_prio_path()       { [[ -s "$WM_ADBLOCK_PRIO_SRS" ]] && printf '%s' "$WM_ADBLOCK_PRIO_SRS" || printf '%s' "$WM_ADBLOCK_PRIO_JSON"; }
adblock_prio_format()     { [[ -s "$WM_ADBLOCK_PRIO_SRS" ]] && printf 'binary' || printf 'source'; }

# Count non-empty lines. `grep -c` prints 0 AND exits 1 on no match, so the usual
# `$(grep -c . f || echo 0)` yields the two-line string "0\n0" for an empty file —
# which then blows up any arithmetic it is fed into. Read stdout, ignore the status.
_adblock_nlines() {
    local c
    c="$(grep -c . "$1" 2>/dev/null)"
    printf '%s' "${c:-0}"
}

_adblock_count_file() {
    [[ -s "$1" ]] || { echo 0; return; }
    jq -r '[.rules[].domain // [] | length] | add // 0' "$1" 2>/dev/null || echo 0
}
# Number of blocked domains across BOTH rule-sets (0 when there is none).
adblock_count() {
    echo $(( $(_adblock_count_file "$WM_ADBLOCK_JSON") + $(_adblock_count_file "$WM_ADBLOCK_PRIO_JSON") ))
}

# --- refresh + scheduled updates -----------------------------------------
# Rebuild the list and, if the blocker is on, load it into the running engine.
# The engine is only restarted when the list actually changed, and the restart is
# wrapped in a maintenance window so the fail-open watchdog does not read the
# planned downtime as a fault.
adblock_refresh() {
    require_root
    local before after
    before="$(sha1sum "$WM_ADBLOCK_JSON" 2>/dev/null | cut -d' ' -f1)"
    adblock_build || return 1
    after="$(sha1sum "$WM_ADBLOCK_JSON" 2>/dev/null | cut -d' ' -f1)"

    adblock_is_enabled || return 0
    if [[ "$before" == "$after" ]] && singbox_is_up; then
        log_info "Ad list unchanged; engine left running."
        return 0
    fi
    singbox_reload      # already runs inside a maintenance window
}

WM_ADBLOCK_SERVICE="warp-manager-adblock.service"
WM_ADBLOCK_TIMER="warp-manager-adblock.timer"

# Weekly refresh. The randomised delay keeps a fleet of servers from fetching at
# the same moment, and Persistent catches up a run missed while powered off.
adblock_timer_setup() {
    require_root
    cat >/etc/systemd/system/${WM_ADBLOCK_SERVICE} <<EOF
[Unit]
Description=WARP Manager - refresh the ad blocker list
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-manager --adblock-update
EOF
    cat >/etc/systemd/system/${WM_ADBLOCK_TIMER} <<EOF
[Unit]
Description=WARP Manager - weekly ad blocker list refresh

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    if adblock_is_enabled; then
        systemctl enable --now "${WM_ADBLOCK_TIMER}" >/dev/null 2>&1 || true
    else
        systemctl disable --now "${WM_ADBLOCK_TIMER}" >/dev/null 2>&1 || true
    fi
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
