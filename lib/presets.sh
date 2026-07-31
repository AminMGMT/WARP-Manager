#!/usr/bin/env bash
# WARP Manager - preset export / import.
# Requires common.sh (and adblock.sh for the allow-list path) sourced first.
#
# A preset is this server's *choices*, not its identity: which services are routed,
# the custom domains, the white list, and the settings (QUIC mode, ad blocker, auto
# IP health, auto restart, WARP+ key). Pick your 34 services once, export a code,
# paste it on the next server, done — no clicking through the catalogue again.
#
# Deliberately NOT in a preset: the WARP account (wgcf-account.toml). That is the
# server's exit identity — copying it would put several servers on one WARP account
# and one exit IP. Moving an account between servers is a different operation with a
# different reason (Cloudflare 429s a fresh registration), and it has its own menu
# entry and --import-account flag.
#
# Two shapes of the same thing:
#   * a TOKEN  — one line, "WMP1.<base64 of gzipped payload>.<crc>", made to be
#                copy-pasted over SSH or a chat. This is what the menu shows.
#   * a FILE   — the payload in plain text, for backups and for diffing what
#                changed between two servers.
# Import accepts either, so a token pasted in a hurry and a file kept on disk are
# interchangeable.

WM_PRESET_VERSION=1
WM_PRESET_TOKEN_PREFIX="WMP1"

# Settings carried by a preset. Anything not listed stays whatever the target server
# already has, so a preset can never silently change something it does not describe.
WM_PRESET_KEYS="quic_mode adblock_enabled ipcheck_enabled ipcheck_bad_locs ipcheck_max_per_day ipcheck_min_interval autorestart_enabled autorestart_interval license_key"

_preset_section() {   # <file> <section> -> the lines of that section
    awk -v s="[$2]" '
        $0 == s      { inside = 1; next }
        /^\[.*\]$/   { inside = 0 }
        inside && !/^[[:space:]]*(#|$)/ { print }
    ' "$1"
}

# --- export --------------------------------------------------------------
# Writes the preset to stdout; the caller decides where it lands.
# Pass "nolicense" to leave the WARP+ key out — the token is only encoded, not
# encrypted, so a preset meant to travel through a chat should not carry a secret.
preset_export() {
    local mode="${1:-}" key val
    printf '# warp-manager preset v%s\n' "$WM_PRESET_VERSION"
    printf '# exported %s from %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname 2>/dev/null || echo unknown)"

    printf '\n[settings]\n'
    for key in $WM_PRESET_KEYS; do
        [[ "$mode" == nolicense && "$key" == license_key ]] && continue
        val="$(conf_get "$key")"
        [[ -n "$val" ]] && printf '%s=%s\n' "$key" "$val"
    done

    printf '\n[services]\n'
    grep -vE '^[[:space:]]*(#|$)' "$WM_ENABLED_FILE" 2>/dev/null | sort || true

    printf '\n[custom-domains]\n'
    grep -vE '^[[:space:]]*(#|$)' "$WM_CUSTOM_FILE" 2>/dev/null || true

    printf '\n[white-list]\n'
    grep -vE '^[[:space:]]*(#|$)' "$WM_ADBLOCK_WHITELIST" 2>/dev/null || true

    # Only written once the user has actually chosen; absent means "whatever uBlock
    # enables by default", which is what a target server should then also follow.
    if [[ -s "$WM_ADBLOCK_LISTS" ]]; then
        printf '\n[filter-lists]\n'
        grep -vE '^[[:space:]]*(#|$)' "$WM_ADBLOCK_LISTS" 2>/dev/null || true
    fi
    return 0
}

preset_export_to() {
    local dest="$1" mode="${2:-}"
    [[ -n "$dest" ]] || { log_error "No destination given."; return 1; }
    local dir; dir="$(dirname "$dest")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || { log_error "Cannot create ${dir}."; return 1; }
    preset_export "$mode" >"$dest" || { log_error "Could not write ${dest}."; return 1; }
    chmod 600 "$dest" 2>/dev/null || true     # it may carry the WARP+ key
    return 0
}

# true when this server actually has a licence that a preset could leak
preset_has_license() { [[ -n "$(conf_get license_key)" ]]; }

preset_default_path() {
    printf '/root/warp-manager-preset-%s.txt' "$(date '+%Y%m%d-%H%M')"
}

# --- token ---------------------------------------------------------------
# One line, no spaces, safe to paste anywhere: the payload gzipped and base64'd,
# with a checksum so a truncated or mangled paste is rejected instead of importing
# half a configuration.
#
# This is encoding, not encryption — it hides the contents from a casual glance but
# anyone holding the token can decode it. Since the token carries the WARP+ key,
# the menu says so and treats it as a secret.
_preset_crc() { cksum | awk '{print $1}'; }

preset_token_encode() {   # payload on stdin -> token on stdout
    local body crc tmp
    tmp="$(mktemp)"; cat >"$tmp"
    crc="$(_preset_crc <"$tmp")"
    # `base64 -w0` is GNU-only; folding by hand keeps this working anywhere
    body="$(gzip -9 -c "$tmp" | base64 | tr -d '\n\r ')"
    rm -f "$tmp"
    [[ -n "$body" ]] || return 1
    printf '%s.%s.%s\n' "$WM_PRESET_TOKEN_PREFIX" "$body" "$crc"
}

preset_token_decode() {   # <token> -> payload on stdout
    local tok="$1" body crc got tmp
    # a pasted token may arrive wrapped across terminal lines; base64 never contains
    # whitespace, so stripping all of it can only help
    tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
    [[ "$tok" == "${WM_PRESET_TOKEN_PREFIX}."* ]] || return 1
    tok="${tok#"${WM_PRESET_TOKEN_PREFIX}".}"
    body="${tok%.*}"; crc="${tok##*.}"
    [[ -n "$body" && -n "$crc" && "$crc" =~ ^[0-9]+$ ]] || return 1
    tmp="$(mktemp)"
    if ! printf '%s' "$body" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null >"$tmp"; then
        rm -f "$tmp"; return 1
    fi
    got="$(_preset_crc <"$tmp")"
    if [[ "$got" != "$crc" ]]; then rm -f "$tmp"; return 1; fi
    cat "$tmp"; rm -f "$tmp"
}

preset_export_token() { preset_export "${1:-}" | preset_token_encode; }

# Accept a token OR a path and hand back a payload file. The caller must remove the
# file afterwards when it is not the path it passed in (see preset_release).
preset_resolve() {
    local src="$1" tmp
    [[ -n "$src" ]] || return 1
    if [[ -f "$src" ]]; then
        preset_is_valid "$src" || return 1
        printf '%s' "$src"; return 0
    fi
    tmp="$(mktemp)"
    if preset_token_decode "$src" >"$tmp" 2>/dev/null && preset_is_valid "$tmp"; then
        printf '%s' "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}
preset_release() {   # <resolved-path> <original-arg>
    [[ "$1" != "$2" ]] && rm -f "$1"
    return 0
}

# --- import --------------------------------------------------------------
# A file only counts as a preset if it says so, so a wrong path cannot wipe the
# configuration with garbage.
preset_is_valid() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    head -n1 "$f" | grep -q '^# warp-manager preset v'
}

# What the file would change, without changing anything. Used to show a summary
# before the user commits to it.
preset_summary() {
    local f="$1" n_srv n_dom n_wl unknown
    n_srv="$(_preset_section "$f" services       | grep -c . || true)"
    n_dom="$(_preset_section "$f" custom-domains | grep -c . || true)"
    n_wl="$( _preset_section "$f" white-list     | grep -c . || true)"
    printf '   Services       %s\n' "$n_srv"
    printf '   Custom domains %s\n' "$n_dom"
    printf '   White list     %s\n' "$n_wl"
    printf '   Settings       %s\n' "$(_preset_section "$f" settings | grep -c . || true)"
    if _preset_section "$f" settings | grep -q '^license_key='; then
        printf '   WARP+ license  %sincluded — it will replace the key on this server%s\n' "$C_YELLOW" "$C_RESET"
    fi
    # services this build does not know about (older/newer catalogue)
    unknown="$(_preset_section "$f" services | while read -r id; do
        [[ -n "$id" && ! -f "$WM_PROVIDERS_DIR/${id}.conf" ]] && printf '%s ' "$id"
    done)"
    [[ -n "$unknown" ]] && printf '   %sNot in this catalogue (will be skipped): %s%s\n' \
        "$C_YELLOW" "${unknown% }" "$C_RESET"
    return 0
}

# Replaces the selections wholesale — that is the point of a preset: the target
# server ends up matching the source, not merged with it. Only settings the file
# actually names are touched.
#
# Takes a token or a path; preset_import_payload does the work on a resolved file.
preset_import() {
    local src="$1" f rc
    f="$(preset_resolve "$src")" || {
        log_error "Not a warp-manager preset (token or file): ${src}"
        return 1
    }
    preset_import_payload "$f"; rc=$?
    preset_release "$f" "$src"
    return $rc
}

preset_import_payload() {
    local f="$1"
    preset_is_valid "$f" || { log_error "Not a warp-manager preset file: ${f}"; return 1; }
    ensure_dirs

    local line key val id
    while IFS= read -r line; do
        key="${line%%=*}"; val="${line#*=}"
        [[ -z "$key" || "$key" == "$line" ]] && continue
        # only keys a preset is allowed to carry
        grep -qw -- "$key" <<<"$WM_PRESET_KEYS" || continue
        conf_set "$key" "$val"
    done < <(_preset_section "$f" settings)

    : >"$WM_ENABLED_FILE"
    while read -r id; do
        [[ -z "$id" ]] && continue
        # skip ids this build has no provider for, instead of writing dead entries
        [[ -f "$WM_PROVIDERS_DIR/${id}.conf" ]] || { log_warn "preset: unknown service '${id}' skipped."; continue; }
        printf '%s\n' "$id" >>"$WM_ENABLED_FILE"
    done < <(_preset_section "$f" services)

    _preset_section "$f" custom-domains >"$WM_CUSTOM_FILE"
    _preset_section "$f" white-list     >"$WM_ADBLOCK_WHITELIST"

    # No [filter-lists] section means the source server was on uBlock's defaults;
    # clearing the file puts this one on the defaults too, rather than leaving a
    # stale selection behind that the preset never mentioned.
    if grep -q '^\[filter-lists\]' "$f"; then
        _preset_section "$f" filter-lists >"${WM_ADBLOCK_LISTS}.new"
        mv -f "${WM_ADBLOCK_LISTS}.new" "$WM_ADBLOCK_LISTS"
    else
        rm -f "$WM_ADBLOCK_LISTS"
    fi

    log_info "preset: imported $(grep -c . "$WM_ENABLED_FILE" 2>/dev/null || echo 0) services from ${f}."
    return 0
}
