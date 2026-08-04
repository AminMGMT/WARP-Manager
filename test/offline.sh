#!/usr/bin/env bash
# WARP Manager - offline test suite.
#
#   bash test/offline.sh
#
# Runs anywhere: no root, no VPS, no network, nothing installed. It stubs systemd
# and the network and exercises the logic that is otherwise only reachable on a
# live relay — the catalogue, the menu selection maths, presets, the ad-blocker
# parser and guard, and the generated sing-box config.
#
# test/e2e.sh is the complement: it checks a real installation on a real server.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WM_ROOT="${WM_ROOT:-$(dirname "$SELF")}"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export WM_CONF_DIR="$SB/conf" WM_STATE_DIR="$SB/state" WM_LOG="$SB/log"
mkdir -p "$WM_CONF_DIR" "$WM_STATE_DIR"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
no()  { printf '  \033[31mFAIL\033[0m %s\n     expected [%s]\n     actual   [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1" "$2" "$3"; }
sect(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- load the real code, with the host-specific bits stubbed ----------------
for lib in common warp routing providers adblock ipcheck singbox automation presets; do
    source "${WM_ROOT}/lib/${lib}.sh"
done
WM_PROVIDERS_DIR="${WM_ROOT}/data/providers"
WM_GROUPS_FILE="${WM_ROOT}/data/groups.conf"
WM_ADBLOCK_CATALOGUE="${WM_ROOT}/data/adblock-lists.conf"
WM_ENABLED_FILE="${WM_CONF_DIR}/enabled.list"
WM_CUSTOM_FILE="${WM_CONF_DIR}/custom.domains"
WM_CONF_FILE="${WM_CONF_DIR}/manager.conf"
WM_ADBLOCK_WHITELIST="${WM_CONF_DIR}/adblock.whitelist"
WM_ADBLOCK_LISTS="${WM_CONF_DIR}/adblock.lists"
WM_SINGBOX_CONF="${WM_CONF_DIR}/sing-box.json"
: >"$WM_ENABLED_FILE"; : >"$WM_CUSTOM_FILE"; : >"$WM_ADBLOCK_WHITELIST"

require_root() { :; }
ensure_dirs()  { mkdir -p "$WM_CONF_DIR" "$WM_STATE_DIR"; touch "$WM_ENABLED_FILE" "$WM_CUSTOM_FILE" "$WM_ADBLOCK_WHITELIST"; }
systemctl()    { return 0; }
# BSD sed needs an argument for -i, GNU sed must not have one; same semantics.
conf_set() {
    local key="$1" val="$2"
    mkdir -p "$WM_CONF_DIR"; touch "$WM_CONF_FILE"
    grep -vE "^${key}=" "$WM_CONF_FILE" >"${WM_CONF_FILE}.t" 2>/dev/null || :
    printf '%s=%s\n' "$key" "$val" >>"${WM_CONF_FILE}.t"; mv -f "${WM_CONF_FILE}.t" "$WM_CONF_FILE"
}
if ! grep -oP 'x' <<<'x' >/dev/null 2>&1; then       # BSD grep: no -P
    prov_field() {
        local id key f
        id="$1"; key="$2"; f="$WM_PROVIDERS_DIR/${id}.conf"
        [[ -f "$f" ]] || return 1
        sed -n "s/^${key}=//p" "$f" | head -n1
    }
fi

# ===========================================================================
sect "Service catalogue"
mapfile -t GNAMES < <(awk '/^\[.*\]$/ { gsub(/^\[|\]$/,""); print }' "$WM_GROUPS_FILE")
ALL_IDS="$(awk '/^[[:space:]]*(#|$)|^\[.*\]$/ { next } { print $1 }' "$WM_GROUPS_FILE" | awk '!s[$0]++')"
is "categories are non-empty" "0" "$([[ ${#GNAMES[@]} -gt 0 ]] && echo 0 || echo 1)"
DANGLING="$(while read -r id; do [[ -f "$WM_PROVIDERS_DIR/${id}.conf" ]] || echo "$id"; done <<<"$ALL_IDS")"
is "every catalogue id has a provider file" "" "$DANGLING"
ORPHAN="$(comm -13 <(sort <<<"$ALL_IDS") <(cd "$WM_PROVIDERS_DIR" && ls ./*.conf | sed 's#^\./##;s/\.conf$//' | sort))"
is "every provider file is reachable" "" "$ORPHAN"
MISMATCH="$(for f in "$WM_PROVIDERS_DIR"/*.conf; do b="$(basename "$f" .conf)"; [[ "$b" == "$(prov_field "$b" id)" ]] || echo "$b"; done)"
is "id= matches the filename" "" "$MISMATCH"
NONAME="$(while read -r id; do [[ -n "$(prov_field "$id" name)" ]] || echo "$id"; done <<<"$ALL_IDS")"
is "every provider has a name" "" "$NONAME"
EMPTY="$(while read -r id; do
    [[ -n "$(prov_field "$id" domains)$(prov_field "$id" category)" ]] || echo "$id"
done <<<"$ALL_IDS")"
is "every provider matches something" "" "$EMPTY"
BADDOM="$(while read -r id; do
    for d in $(prov_field "$id" domains); do
        [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || echo "$id:$d"
    done
done <<<"$ALL_IDS")"
is "all provider domains are well-formed" "" "$BADDOM"

sect "Ad-blocker filter-list catalogue"
is "catalogue is ASCII (columns line up)" "0" "$(LC_ALL=C grep -c '[^ -~]' "$WM_ADBLOCK_CATALOGUE" || true)"
DEFAULT_ON="$(adblock_lists_all | awk -F'|' '$2=="on"' | wc -l | tr -d ' ')"
is "uBlock defaults are enabled when unset" "$DEFAULT_ON" "$(adblock_lists_enabled | wc -l | tr -d ' ')"
# remote lists are http(s); bundled ones ship with the repo as file:<path>
BADURL="$(adblock_lists_all | awk -F'|' '$4 !~ /^(https?:\/\/|file:)/ { print $1 }')"
is "every list has a usable source" "" "$BADURL"
BADFILE="$(adblock_lists_all | awk -F'|' '$4 ~ /^file:/ { print $4 }' | sed 's/^file://' \
           | while read -r rel; do [[ -s "${WM_ROOT}/${rel}" ]] || echo "$rel"; done)"
is "every bundled list exists" "" "$BADFILE"
DUPID="$(adblock_lists_all | cut -d'|' -f1 | sort | uniq -d)"
is "no duplicate list ids" "" "$DUPID"
adblock_list_enable IRN-0
is "a user choice is stored"        "0" "$(adblock_list_is_enabled IRN-0; echo $?)"
is "defaults survive the first choice" "$(( DEFAULT_ON + 1 ))" "$(adblock_lists_enabled | wc -l | tr -d ' ')"
adblock_list_disable ublock-filters
is "a list can be turned off" "1" "$(adblock_list_is_enabled ublock-filters; echo $?)"
adblock_lists_reset
is "reset returns to uBlock defaults" "$DEFAULT_ON" "$(adblock_lists_enabled | wc -l | tr -d ' ')"
TOTAL_LISTS="$(adblock_lists_all | wc -l | tr -d ' ')"
adblock_lists_set_all on
is "select all enables every list" "$TOTAL_LISTS" "$(adblock_lists_enabled | wc -l | tr -d ' ')"
adblock_lists_set_all off
is "select none really disables all" "0" "$(adblock_lists_enabled | wc -l | tr -d ' ')"
is "an empty selection is still a selection" "0" \
   "$([[ -f "$WM_ADBLOCK_LISTS" ]] && echo 0 || echo 1)"
# the bug this replaced: disabling the last list used to bring the defaults back
adblock_lists_reset
for _id in $(adblock_lists_enabled); do adblock_list_disable "$_id"; done
is "disabling one by one ends at zero" "0" "$(adblock_lists_enabled | wc -l | tr -d ' ')"
adblock_lists_reset

sect "Ad-blocker filter parsing"
cat >"$SB/fix.txt" <<'FIX'
! comment
[Adblock Plus 2.0]
||plain.test^
||withall.test^$all
||thirdparty.test^$third-party
||popup.test^$popup
||typed.test^$script
||scoped.test^$domain=other.com
||disabled.test^$badfilter
||haspath.test/ads/x.gif
||wild*card.test^
/regex-rule/
site.test##.ad-banner
site.test#@#.ad-banner
site.test#?#div:has(> .ad)
site.test##+js(aopr, x)
@@||global-exception.test^
@@||scoped-exception.test^$domain=viz.com
0.0.0.0 hostsfile.test
127.0.0.1 localhost
FIX
: >"$SB/b"; : >"$SB/a"; _adblock_parse "$SB/fix.txt" "$SB/b" "$SB/a"
BLK="$(sort "$SB/b" | tr '\n' ' ' | xargs)"
is "keeps only whole-domain rules" "hostsfile.test plain.test popup.test thirdparty.test withall.test" "$BLK"
is "keeps only unscoped exceptions" "global-exception.test" "$(sort "$SB/a" | tr '\n' ' ' | xargs)"
is "localhost never blocked" "0" "$(grep -c '^localhost$' "$SB/b" || true)"

sect "Ad-blocker guard (routed services must survive)"
GUARD="$SB/guard"; _adblock_protected >"$GUARD"
is "a routed domain is protected"      "1" "$(grep -c '^slackb\.com$' "$GUARD" || true)"
is "a routed short domain is protected" "1" "$(grep -c '^t\.co$' "$GUARD" || true)"
is "parents are protected too"          "1" "$(grep -c '^qq\.com$' "$GUARD" || true)"
is "connectivity checks are protected"  "1" "$(grep -c '^gstatic\.com$' "$GUARD" || true)"
is "no bare TLD is protected" "" "$(grep -E '^[a-z]+$' "$GUARD" || true)"
# a custom domain must be guarded straight from its own file: _custom.conf is only
# written at apply time, so one added since the last list build would be unguarded
printf 'adform.net\n' >"$WM_CUSTOM_FILE"
_adblock_protected >"$GUARD"
is "a custom domain is protected" "1" "$(grep -c '^adform\.net$' "$GUARD" || true)"
: >"$WM_CUSTOM_FILE"
_adblock_protected >"$GUARD"
printf 'slackb.com\nt.co\nqq.com\ndoubleclick.net\n' | sort >"$SB/blk2"
is "guard removes routed, keeps ads" "doubleclick.net" "$(comm -23 "$SB/blk2" "$GUARD" | tr '\n' ' ' | xargs)"

sect "Menu maths"
parse_nums() { :; }   # replaced below by the real one from bin/warp-manager
eval "$(sed -n '/^parse_nums() {/,/^}/p' "${WM_ROOT}/bin/warp-manager")"
is "single number"        "3"         "$(parse_nums '3' 20 | tr '\n' ' ' | xargs)"
is "space separated"      "1 4 7"     "$(parse_nums '1 4 7' 20 | tr '\n' ' ' | xargs)"
is "comma separated"      "1 4 7"     "$(parse_nums '1,4,7' 20 | tr '\n' ' ' | xargs)"
is "range"                "2 3 4 5"   "$(parse_nums '2-5' 20 | tr '\n' ' ' | xargs)"
is "reversed range"       "2 3 4 5"   "$(parse_nums '5-2' 20 | tr '\n' ' ' | xargs)"
is "out of range clamped" "20"        "$(parse_nums '0 20 21 -3' 20 | tr '\n' ' ' | xargs)"
is "garbage ignored"      ""          "$(parse_nums 'abc x-y ,' 20 | tr '\n' ' ' | xargs)"

sect "Presets"
printf 'openai\nclaude\nnetflix\n' >"$WM_ENABLED_FILE"
printf 'example.com\n' >"$WM_CUSTOM_FILE"
printf 'allowed.test\n' >"$WM_ADBLOCK_WHITELIST"
conf_set quic_mode route; conf_set license_key "SECRET-123"; conf_set autorestart_interval 12
conf_set unrelated_key "must-survive"
adblock_list_enable IRN-0
TOKEN="$(preset_export_token)"
is "token is one line"     "1"      "$(printf '%s' "$TOKEN" | grep -c .)"
is "token has no spaces"   "0"      "$(printf '%s' "$TOKEN" | grep -c '[[:space:]]')"
is "token prefix"          "WMP1"   "${TOKEN%%.*}"
# wipe the server, restore from the token alone
: >"$WM_ENABLED_FILE"; : >"$WM_CUSTOM_FILE"; : >"$WM_ADBLOCK_WHITELIST"
rm -f "$WM_CONF_FILE" "$WM_ADBLOCK_LISTS"
conf_set unrelated_key "must-survive"
preset_import "$TOKEN" >/dev/null 2>&1
is "services restored"     "claude netflix openai" "$(sort "$WM_ENABLED_FILE" | tr '\n' ' ' | xargs)"
is "custom domains restored" "example.com"  "$(cat "$WM_CUSTOM_FILE")"
is "white list restored"   "allowed.test"   "$(cat "$WM_ADBLOCK_WHITELIST")"
is "settings restored"     "route"          "$(conf_get quic_mode)"
is "license restored"      "SECRET-123"     "$(conf_get license_key)"
is "filter lists restored" "0"              "$(adblock_list_is_enabled IRN-0; echo $?)"
is "unlisted keys untouched" "must-survive" "$(conf_get unrelated_key)"
is "wrapped paste accepted" "0" "$(preset_import "$(printf '%s' "$TOKEN" | fold -w 40)" >/dev/null 2>&1; echo $?)"
BEFORE="$(cat "$WM_ENABLED_FILE")"
is "corrupt checksum refused" "1" "$(preset_import "${TOKEN%.*}.999" >/dev/null 2>&1; echo $?)"
is "truncated token refused"  "1" "$(preset_import "${TOKEN:0:${#TOKEN}-30}" >/dev/null 2>&1; echo $?)"
is "empty input refused"      "1" "$(preset_import '' >/dev/null 2>&1; echo $?)"
is "a refused import changes nothing" "$BEFORE" "$(cat "$WM_ENABLED_FILE")"
is "license can be left out" "0" "$(preset_export_token nolicense | { read -r t; preset_token_decode "$t"; } | grep -c '^license_key=' || true)"

sect "Auto restart"
is "off by default"        "1"  "$(rm -f "$WM_CONF_FILE"; autorestart_is_enabled; echo $?)"
is "default interval"      "6"  "$(autorestart_interval)"
is "rejects zero"          "1"  "$(autorestart_set_interval 0; echo $?)"
is "rejects out of range"  "1"  "$(autorestart_set_interval 500; echo $?)"
is "rejects text"          "1"  "$(autorestart_set_interval abc; echo $?)"
is "accepts a real value"  "0"  "$(autorestart_set_interval 24; echo $?)"
is "stores it"             "24" "$(autorestart_interval)"

sect "sing-box config"
warp_v6_works()   { return 1; }
warp_is_healthy() { return 0; }
singbox_available_rulesets() { printf '%s\n' "$@"; }
ADS=0
adblock_is_enabled() { [[ "$ADS" == 1 ]]; }
adblock_has_list()   { [[ "$ADS" == 1 ]]; }
adblock_ruleset_path()  { echo "$SB/ads.json"; }
adblock_ruleset_format(){ echo source; }
PRIO=1
adblock_has_prio()      { [[ "$PRIO" == 1 ]]; }
adblock_prio_path()     { echo "$SB/ads-prio.json"; }
adblock_prio_format()   { echo source; }
adblock_allow_domains() { echo 'excepted.example'; }
printf '%s\n' $ALL_IDS >"$WM_ENABLED_FILE"

for m in light route; do
    conf_set quic_mode "$m"
    singbox_write_config >/dev/null 2>&1
    is "[$m] generates valid JSON" "0" "$(jq -e . "$WM_SINGBOX_CONF" >/dev/null 2>&1; echo $?)"
done
conf_set quic_mode light
# every rule-set the rules reference must also be declared, or sing-box refuses to start
undeclared() {
    jq -r '[.route.rules[].rule_set // empty] | flatten | unique - ([.] | .[0:0])' "$WM_SINGBOX_CONF" >/dev/null
    comm -23 <(jq -r '[.route.rules[].rule_set // empty] | flatten | unique | .[]' "$WM_SINGBOX_CONF" | sort) \
             <(jq -r '[.route.rule_set[].tag] | unique | .[]' "$WM_SINGBOX_CONF" | sort)
}
ADS=1; singbox_write_config >/dev/null 2>&1
is "ads on: no undeclared rule-set" "" "$(undeclared)"

# Rule ORDER is the whole design here, so assert the positions, not just presence.
idx() { jq --arg t "$1" '[.route.rules[] | ((.rule_set//[]) | index($t)) != null] | index(true)' "$WM_SINGBOX_CONF"; }
idx_dom() { jq --arg d "$1" '[.route.rules[] | (((.domain//[])+(.domain_suffix//[])) | index($d)) != null] | index(true)' "$WM_SINGBOX_CONF"; }
I_LOCAL="$(idx adguard-ads)"
I_PRIO_ADS="$(idx adguard-ads-prio)"
I_GEO="$(idx geosite-category-ads-all)"
I_MEDIA="$(idx_dom .googlevideo.com)"
I_PING="$(idx_dom www.gstatic.com)"
I_PRIO="$(idx_dom music.youtube.com)"
I_WARP="$(jq '[.route.rules[] | .outbound=="warp"] | index(true)' "$WM_SINGBOX_CONF")"
N_RULES="$(jq '.route.rules | length' "$WM_SINGBOX_CONF")"
# the connectivity block is two rules (suffix + exact); both must precede the ads
is "connectivity checks come first"       "1" "$([[ "$I_PING" -lt "$I_LOCAL" ]] && echo 1 || echo 0)"
is "curated ad list beats the media pin"  "1" "$([[ "$I_PRIO_ADS" -lt "$I_MEDIA" ]] && echo 1 || echo 0)"
# the regression this split exists to prevent: the bulk list must never outrank a
# routed service or a custom domain added since the last list build
is "bulk ad list runs after routing"      "1" "$([[ "$I_LOCAL" -gt "$I_WARP" ]] && echo 1 || echo 0)"
is "bulk ad list runs after the media pin" "1" "$([[ "$I_LOCAL" -gt "$I_MEDIA" ]] && echo 1 || echo 0)"
is "priority routing beats the media pin" "1" "$([[ "$I_PRIO"  -lt "$I_MEDIA" ]] && echo 1 || echo 0)"
is "remote ad set is the last rule"       "1" "$([[ "$I_GEO" -eq $(( N_RULES - 1 )) ]] && echo 1 || echo 0)"
is "remote ad set runs after routing"     "1" "$([[ "$I_GEO" -gt "$I_WARP" ]] && echo 1 || echo 0)"
is "connectivity checks stay direct" "direct" \
   "$(jq -r 'first(.route.rules[] | select((.domain//[]) | index("www.gstatic.com")) | .outbound)' "$WM_SINGBOX_CONF")"
is "www.cloudflare.com stays direct" "direct" \
   "$(jq -r 'first(.route.rules[] | select((.domain//[]) | index("www.cloudflare.com")) | .outbound)' "$WM_SINGBOX_CONF")"
# Reported by a user: with the ad blocker ON, aistudio.google.com and
# analytics.google.com stopped working even though Google was routed. The allow
# list was emitted as domain_suffix "direct" rules ABOVE the routing rules, so
# ".google.com" (a connectivity-safe domain) sent all of Google out on the server
# IP. Turning the blocker off "fixed" it. Enabling an ad blocker must never change
# where a selected service is routed.
I_ALLOW="$(idx_dom .google.com)"
is "allow list never outranks routing" "1" "$([[ "$I_ALLOW" -gt "$I_WARP" ]] && echo 1 || echo 0)"
is "allow list still outranks the block" "1" "$([[ "$I_ALLOW" -lt "$I_LOCAL" ]] && echo 1 || echo 0)"
first_out() {   # which outbound wins for a hostname
    jq -r --arg d "$1" '[ .route.rules[]
        | select( ((.domain//[]) | index($d)) != null
               or ((.domain_suffix//[]) | map(. as $s | ($d|endswith($s))) | any) ) ][0].outbound // "none"' \
        "$WM_SINGBOX_CONF"
}
for d in aistudio.google.com analytics.google.com music.apple.com; do
    is "$d is routed with ads on" "warp" "$(first_out "$d")"
done
is "connectivity check still direct with ads on" "direct" "$(first_out www.gstatic.com)"

is "video playback stays direct" "direct" \
   "$(jq -r 'first(.route.rules[] | select((.domain_suffix//[]) | index(".googlevideo.com")) | .outbound)' "$WM_SINGBOX_CONF")"

# The regression that mattered: a server that cannot reach GitHub still gets the
# locally built list instead of silently losing all ad blocking.
singbox_available_rulesets() { return 0; }
singbox_write_config >/dev/null 2>&1
# both local sets survive; only the remote one drops out
is "geosite unreachable: still blocks" "2" \
   "$(jq '[.route.rules[] | select(.outbound=="block" and .rule_set!=null)] | length' "$WM_SINGBOX_CONF")"
is "geosite unreachable: local sets only" '["adguard-ads-prio","adguard-ads"]' \
   "$(jq -c '[.route.rules[] | select(.outbound=="block") | .rule_set] | flatten' "$WM_SINGBOX_CONF")"
# with no curated list built, the early rule and its declaration must both vanish
PRIO=0; singbox_write_config >/dev/null 2>&1
is "no curated list: no early rule" "0" \
   "$(jq '[.route.rules[] | select((.rule_set//[]) | index("adguard-ads-prio"))] | length' "$WM_SINGBOX_CONF")"
is "no curated list: no dangling declaration" "" "$(undeclared)"
is "no curated list: valid JSON" "0" "$(jq -e . "$WM_SINGBOX_CONF" >/dev/null 2>&1; echo $?)"
PRIO=1; singbox_write_config >/dev/null 2>&1
is "geosite unreachable: no undeclared rule-set" "" "$(undeclared)"
is "geosite unreachable: valid JSON" "0" "$(jq -e . "$WM_SINGBOX_CONF" >/dev/null 2>&1; echo $?)"
singbox_available_rulesets() { printf '%s\n' "$@"; }
ADS=0; singbox_write_config >/dev/null 2>&1
is "ads off: no block rule" "0" "$(jq '[.route.rules[] | select(.outbound=="block" and .rule_set!=null)] | length' "$WM_SINGBOX_CONF")"

sect "Systemd unit coverage"
UNITS="$(grep -ohE 'warp-manager-[a-z]+\.(service|timer)' "${WM_ROOT}/bin/warp-manager" "${WM_ROOT}"/lib/*.sh | sort -u)"
MISSING=""
while read -r u; do
    [[ -z "$u" ]] && continue
    grep -q -- "$u" "${WM_ROOT}/uninstall.sh" || MISSING+="$u "
done <<<"$UNITS"
is "uninstall.sh removes every unit" "" "${MISSING% }"


sect "YouTube ad domains (bundled list, built for real)"
unset -f adblock_is_enabled adblock_has_list adblock_ruleset_path adblock_ruleset_format adblock_allow_domains
source "${WM_ROOT}/lib/adblock.sh"
WM_ADBLOCK_DIR="${WM_STATE_DIR}/adblock"
WM_ADBLOCK_JSON="${WM_ADBLOCK_DIR}/adguard.json"
WM_ADBLOCK_SRS="${WM_ADBLOCK_DIR}/adguard.srs"
WM_ADBLOCK_ALLOW_AUTO="${WM_ADBLOCK_DIR}/exceptions.list"
WM_ADBLOCK_STAMP="${WM_ADBLOCK_DIR}/updated"
WM_ADBLOCK_STATS="${WM_ADBLOCK_DIR}/stats"
WM_ADBLOCK_MIN_RULES=1            # this one list is small on purpose
WM_SINGBOX_BIN=/nonexistent       # no compiler here; source format is the fallback
printf 'youtube-ads\n' | _adblock_lists_write
if adblock_build >/dev/null 2>&1; then
    ok "bundled list builds with no network"
    BLOCKED="$(cat <(jq -r '.rules[0].domain[]?' "$WM_ADBLOCK_JSON" 2>/dev/null) \
                   <(jq -r '.rules[0].domain[]?' "$WM_ADBLOCK_PRIO_JSON" 2>/dev/null) | sort -u)"
    for d in doubleclick.net pagead2.googlesyndication.com www.googletagservices.com \
             ads.youtube.com adservice.google.com s0.2mdn.net; do
        is "blocks $d" "1" "$(grep -cxF "$d" <<<"$BLOCKED" || true)"
    done
    is "no googlevideo host is blocked" "0" "$(grep -c 'googlevideo\.com' <<<"$BLOCKED" || true)"
    is "youtube.com itself is not blocked" "0" "$(grep -cxF 'youtube.com' <<<"$BLOCKED" || true)"
    is "adblock_count spans both rule-sets" \
       "$(( $(_adblock_count_file "$WM_ADBLOCK_JSON") + $(_adblock_count_file "$WM_ADBLOCK_PRIO_JSON") ))" \
       "$(adblock_count)"
    is "curated list went to the early rule-set" "1" \
       "$([[ -s "$WM_ADBLOCK_PRIO_JSON" ]] && echo 1 || echo 0)"
    is "list size matches the shipped file" \
       "$(grep -cvE '^[[:space:]]*(#|$)' "${WM_ROOT}/data/adblock-youtube.txt")" \
       "$(grep -c . <<<"$BLOCKED")"
else
    no "bundled list builds with no network" "build ok" "build failed"
fi

printf '\n'
printf '  \033[1mResult:\033[0m \033[32m%d passed\033[0m  \033[31m%d failed\033[0m\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
