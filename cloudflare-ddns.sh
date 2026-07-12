#!/bin/bash

#########
# SECRETS - Update with your Cloudflare API token and zone ID
#CLOUDFLARE_API_TOKEN=""
#CLOUDFLARE_ZONE_ID=""

# HEALTHCHECKS - Update with your Healthchecks to ping (success + /fail on error)
#A_HC=""
#AAAA_HC=""
#########

# Bail immediately on errors
set -euo pipefail

# Defaults for optional/secret variables (avoid unbound errors under `set -u`)
: "${CLOUDFLARE_API_TOKEN:=}"
: "${CLOUDFLARE_ZONE_ID:=}"
: "${A_HC:=}"
: "${AAAA_HC:=}"

QUIET=0
TTL=3600
DO_HTTPS=false
DO_IPV4=false
DO_IPV6=false
IPV4=""
IPV6=""
A_STATUS=disabled
AAAA_STATUS=disabled
USER_AGENT="cloudflare-ddns/2.4"

CF_API="https://api.cloudflare.com/client/v4"
CF_AUTH_CONFIG=""
A_SOURCE=""
AAAA_SOURCE=""

# Curl base options
#   --fail-with-body : print body on HTTP error before exit
#   --connect-timeout: bound DNS/TCP/TLS handshake
#   -m / --max-time  : bound total transfer
CURL_BASE=(
    curl -q -sS
    --fail-with-body
    -A "$USER_AGENT"
    --connect-timeout 5
    --max-time 15
)
# Read-only / idempotent requests can retry liberally
CURL_GET=("${CURL_BASE[@]}" --retry 5 --retry-delay 2 --retry-max-time 30 --retry-all-errors)
# The DNS batch POST is not retried because a lost response leaves its outcome
# ambiguous even though the database operation may have completed.
CURL_POST=("${CURL_BASE[@]}")
# IP detection: tight timeout, single retry; we already iterate fallbacks
CURL_IP=(
    curl -q -sS --fail-with-body -A "$USER_AGENT"
    --connect-timeout 3 --max-time 5
    --retry 1 --retry-delay 1
)

# Color escapes only when stdout is a TTY
if [[ -t 1 ]]; then
    C_PURPLE=$'\033[1;35m'
    C_YELLOW=$'\033[1;33m'
    C_RESET=$'\033[0m'
else
    C_PURPLE=""
    C_YELLOW=""
    C_RESET=""
fi

# Notification batch (one mail per run)
NOTIFY_LINES=()
PLAN_JSON='{"patches":[],"posts":[],"messages":[]}'

print_usage() {
    cat <<EOF

Usage:  ${0##*/} [OPTIONS] FQDN

Updates Cloudflare DNS A and AAAA records with external IPv4 and IPv6 addresses of the current machine

Options:
  -h  Print usage help
  -q  Enable quiet mode
  -s  Update HTTPS record with external IPv4 and IPv6 addresses
  -t  TTL of records, in seconds (1 = auto, otherwise 60-86400)
  -4  Only update A record with external IPv4 address
  -6  Only update AAAA record with external IPv6 address
EOF
}

err()    { printf '%s\n' "$*" >&2; }
qprint() { [[ "$QUIET" -eq 0 ]] && printf '%s\n' "$1"; return 0; }

require_cmd() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "$cmd is not installed or not in PATH."
            return 1
        fi
    done
}

normalize_record() {
    local record="${1%.}"
    printf '%s' "${record,,}"
}

valid_record() {
    local record="$1" label
    [[ ${#record} -le 253 ]] || return 1
    [[ "$record" == *.* ]] || return 1
    [[ "$record" != .* && "$record" != *. ]] || return 1
    [[ "$record" != *..* ]] || return 1
    [[ "$record" =~ ^[a-z0-9.-]+$ ]] || return 1

    IFS=. read -r -a labels <<<"$record"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

canonical_ipv6() {
    local ip="${1,,}" ipv4_part prefix a b c d group part
    local head tail missing i out=""
    local -a head_parts=() tail_parts=() parts=()
    valid_ipv6 "$ip" || return 1
    if [[ "$ip" == *.* ]]; then
        ipv4_part="${ip##*:}"
        prefix="${ip%:*}"
        IFS=. read -r a b c d <<<"$ipv4_part"
        printf -v group '%x' "$((10#$a * 256 + 10#$b))"
        ip="$prefix:$group"
        printf -v group '%x' "$((10#$c * 256 + 10#$d))"
        ip+="${ip:+:}$group"
    fi
    if [[ "$ip" == *::* ]]; then
        head="${ip%%::*}"; tail="${ip#*::}"
        [[ -n "$head" ]] && IFS=: read -r -a head_parts <<<"$head"
        [[ -n "$tail" ]] && IFS=: read -r -a tail_parts <<<"$tail"
        missing=$((8 - ${#head_parts[@]} - ${#tail_parts[@]}))
        parts=("${head_parts[@]}")
        for (( i = 0; i < missing; i++ )); do parts+=(0); done
        parts+=("${tail_parts[@]}")
    else
        IFS=: read -r -a parts <<<"$ip"
    fi
    for part in "${parts[@]}"; do
        printf -v group '%04x' "$((16#$part))"
        out+="${out:+:}$group"
    done
    printf '%s' "$out"
}

addresses_equal() {
    local family="$1" left="$2" right="$3" left_normal right_normal
    case "$family" in
        -4) [[ "$left" == "$right" ]] ;;
        -6)
            left_normal=$(canonical_ipv6 "$left") || return 1
            right_normal=$(canonical_ipv6 "$right") || return 1
            [[ "$left_normal" == "$right_normal" ]]
            ;;
        *) return 1 ;;
    esac
}

address_value_changed() {
    local family="$1" old="$2" new="$3"
    [[ -z "$old" && -z "$new" ]] && return 1
    ! addresses_equal "$family" "$old" "$new"
}

valid_ipv6() {
    local ip="$1" head tail part
    local -a head_parts tail_parts parts
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    if [[ "$ip" == *.* ]]; then
        local ipv4_part="${ip##*:}"
        valid_ipv4 "$ipv4_part" || return 1
        ip="${ip%:*}:0:0"
    fi

    if [[ "$ip" == *::* ]]; then
        [[ "$ip" != *::*::* ]] || return 1
        head="${ip%%::*}"
        tail="${ip#*::}"
        if [[ -z "$head" ]]; then
            head_parts=()
        else
            IFS=: read -r -a head_parts <<<"$head"
        fi
        if [[ -z "$tail" ]]; then
            tail_parts=()
        else
            IFS=: read -r -a tail_parts <<<"$tail"
        fi
        parts=("${head_parts[@]}" "${tail_parts[@]}")
        ((${#parts[@]} < 8)) || return 1
    else
        IFS=: read -r -a parts <<<"$ip"
        ((${#parts[@]} == 8)) || return 1
    fi

    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    return 0
}

valid_ip_for_family() {
    case "$1" in
        -4) valid_ipv4 "$2" ;;
        -6) valid_ipv6 "$2" ;;
        *) return 1 ;;
    esac
}

# Query an externally observed IP, optionally binding to an exact source IP.
# Usage: query_external_ip -4|-6 [SOURCE_IP]
query_external_ip() {
    local family="$1" source_ip="${2:-}" url ip last_err=""
    local -a bind_args=()
    case "$family" in -4|-6) ;; *) err "query_external_ip: must specify -4 or -6"; return 1;; esac
    [[ -n "$source_ip" ]] && bind_args=(--interface "host!$source_ip")

    for url in \
        "https://api.cloudflare.com/cdn-cgi/trace" \
        "https://icanhazip.com" \
        "https://ifconfig.co"
    do
        if ! ip=$("${CURL_IP[@]}" "$family" "${bind_args[@]}" "$url" 2>&1); then
            last_err="$ip"
            continue
        fi
        if [[ "$url" == *cdn-cgi/trace* ]]; then
            ip=$(awk -F= '/^ip=/ { print $2; exit }' <<<"$ip")
        else
            ip=$(printf '%s' "$ip" | tr -d '[:space:]')
        fi
        if valid_ip_for_family "$family" "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
        last_err="invalid response from $url: $ip"
    done
    if [[ -n "$source_ip" ]]; then
        err "Failed to verify interface address $source_ip ($family). Last error: $last_err"
    else
        err "Failed to determine external IP ($family). Last error: $last_err"
    fi
    return 1
}

verify_interface_ip() {
    local family="$1" selected="$2" observed
    observed=$(query_external_ip "$family" "$selected") || return 1
    if ! addresses_equal "$family" "$observed" "$selected"; then
        err "Interface address $selected does not match externally observed address $observed ($family)"
        return 1
    fi
}

public_ipv4() {
    local ip="$1" a b c
    valid_ipv4 "$ip" || return 1
    IFS=. read -r a b c _ <<<"$ip"
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
    (( a != 0 && a != 10 && a != 127 && a < 224 )) || return 1
    (( !(a == 100 && b >= 64 && b <= 127) )) || return 1
    (( !(a == 169 && b == 254) && !(a == 172 && b >= 16 && b <= 31) )) || return 1
    (( !(a == 192 && b == 168) && !(a == 192 && b == 0 && (c == 0 || c == 2)) )) || return 1
    (( !(a == 198 && (b == 18 || b == 19 || b == 51 && c == 100)) )) || return 1
    (( !(a == 203 && b == 0 && c == 113) )) || return 1
    return 0
}

select_interface_ipv4() {
    local iface="$1" json
    local -a candidates
    json=$(ip -j -4 addr show dev "$iface") || { err "Failed to read IPv4 addresses from interface $iface"; return 1; }
    mapfile -t candidates < <(jq -r '.[]?.addr_info[]? | select(.family == "inet" and .scope == "global") | select(((.flags // []) | index("tentative") | not) and ((.flags // []) | index("dadfailed") | not) and ((.flags // []) | index("deprecated") | not)) | .local' <<<"$json")
    local -a usable=(); local candidate
    for candidate in "${candidates[@]}"; do public_ipv4 "$candidate" && usable+=("$candidate"); done
    if ((${#usable[@]} != 1)); then
        err "Expected exactly one stable public IPv4 address on interface $iface; found ${#usable[@]}"
        return 1
    fi
    printf '%s' "${usable[0]}"
}

select_interface_ipv6() {
    local iface="$1" published="${2:-}" excluded="${3:-}" json addr lifetime
    local -a addresses=() lifetimes=()
    json=$(ip -j -6 addr show dev "$iface") || { err "Failed to read IPv6 addresses from interface $iface"; return 1; }
    while IFS=$'\t' read -r addr lifetime; do
        [[ "$addr" =~ ^[23] ]] || continue
        [[ -n "$excluded" && "$addr" == "$excluded" ]] && continue
        addresses+=("$addr"); lifetimes+=("$lifetime")
    done < <(jq -r '.[]?.addr_info[]? | select(.family == "inet6" and .scope == "global") | select(((.flags // []) | index("temporary") | not) and ((.flags // []) | index("tentative") | not) and ((.flags // []) | index("dadfailed") | not) and ((.flags // []) | index("deprecated") | not)) | [.local, (.preferred_life_time // 0 | tostring)] | @tsv' <<<"$json")
    ((${#addresses[@]} > 0)) || { err "No stable public global IPv6 address found on interface $iface"; return 1; }
    local i best=-1 best_lft=-1 numeric ties=0
    for i in "${!addresses[@]}"; do
        if [[ -n "$published" ]] && addresses_equal -6 "${addresses[i]}" "$published"; then
            printf '%s' "${addresses[i]}"
            return 0
        fi
        [[ "${lifetimes[i]}" == "forever" ]] && numeric=2147483647 || numeric=${lifetimes[i]%%sec*}
        [[ "$numeric" =~ ^[0-9]+$ ]] || numeric=0
        if (( numeric > best_lft )); then best=$i; best_lft=$numeric; ties=1
        elif (( numeric == best_lft )); then ((ties+=1)); fi
    done
    (( ties == 1 )) || { err "Multiple equally preferred public IPv6 addresses remain on interface $iface; refusing an ambiguous choice"; return 1; }
    printf '%s' "${addresses[best]}"
}

# Verify a Cloudflare API JSON response has success:true; on failure, print errors and exit.
check_success() {
    local body="$1" context="$2"
    local ok
    ok=$(jq -r '.success // false' <<<"$body" 2>/dev/null || echo false)
    if [[ "$ok" != "true" ]]; then
        err "Cloudflare API error during $context:"
        if ! jq -e '.errors // empty' <<<"$body" >/dev/null 2>&1; then
            # Non-JSON (e.g. HTML 502 page from a proxy); truncate to keep logs readable
            printf '%s\n' "$body" | head -n 20 >&2
        else
            jq -r '.errors[]? | "  [\(.code)] \(.message)"' <<<"$body" >&2
        fi
        return 1
    fi
}

# Usage: cf_api_get  PATH [QUERY_KEY=VAL ...]
cf_api_get() {
    local path="$1"; shift
    local args=(-G)
    local kv
    for kv in "$@"; do
        args+=(--data-urlencode "$kv")
    done
    "${CURL_GET[@]}" \
        --config "$CF_AUTH_CONFIG" \
        -H "Content-Type: application/json" \
        "${args[@]}" \
        "$CF_API$path"
}

# Batch creation is transactional at Cloudflare's database layer, but a POST
# whose response is lost has an ambiguous outcome and therefore must not retry.
cf_api_batch() {
    local data="$1"
    "${CURL_POST[@]}" \
        -X POST \
        --config "$CF_AUTH_CONFIG" \
        -H "Content-Type: application/json" \
        --data-binary "$data" \
        "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records/batch"
}

load_systemd_credentials() {
    [[ -n "${CREDENTIALS_DIRECTORY:-}" ]] || return 0
    if [[ -z "$CLOUDFLARE_API_TOKEN" && -r "$CREDENTIALS_DIRECTORY/cloudflare_api_token" ]]; then
        CLOUDFLARE_API_TOKEN=$(<"$CREDENTIALS_DIRECTORY/cloudflare_api_token")
    fi
    if [[ -z "$CLOUDFLARE_ZONE_ID" && -r "$CREDENTIALS_DIRECTORY/cloudflare_zone_id" ]]; then
        CLOUDFLARE_ZONE_ID=$(<"$CREDENTIALS_DIRECTORY/cloudflare_zone_id")
    fi
}

create_curl_auth_config() {
    umask 077
    CF_AUTH_CONFIG=$(mktemp "$STATE_DIR/cloudflare-auth.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" >"$CF_AUTH_CONFIG"
    chmod 600 "$CF_AUTH_CONFIG"
}

validate_credentials() {
    if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
        err "Error: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID must be defined."
        return 1
    fi
    if [[ "$CLOUDFLARE_API_TOKEN" == *$'\n'* || "$CLOUDFLARE_API_TOKEN" == *$'\r'* ||
          "$CLOUDFLARE_API_TOKEN" == *'"'* || "$CLOUDFLARE_API_TOKEN" == *\\* ]]; then
        err "Error: CLOUDFLARE_API_TOKEN contains characters unsafe for curl configuration."
        return 1
    fi
    if [[ ! "$CLOUDFLARE_ZONE_ID" =~ ^[0-9A-Fa-f]{32}$ ]]; then
        err "Error: CLOUDFLARE_ZONE_ID must be a 32-character hexadecimal identifier."
        return 1
    fi
}

get_records_checked() {
    local type="$1" body pages count
    body=$(cf_api_get "/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
        "type=$type" "name.exact=$RECORD" "page=1" "per_page=100") || {
        err "Cloudflare API request failed while listing $type records:"
        [[ -n "$body" ]] && printf '%s\n' "$body" >&2
        return 1
    }
    check_success "$body" "list $type records" || return 1
    { read -r pages; read -r count; } < <(
        jq -r '[.result_info.total_pages // 1, (.result | length)] | .[]' <<<"$body"
    )
    if (( pages > 1 )); then
        err "Found more than one page of $type records for $RECORD; refusing to update. Remove duplicates in the Cloudflare dashboard."
        return 1
    fi
    if (( count > 1 )); then
        err "Found $count $type records for $RECORD; refusing to update. Remove duplicates in the Cloudflare dashboard."
        return 1
    fi
    printf '%s' "$body"
}

# Parse id + content + proxied + ttl from result[0]. Outputs four lines.
parse_record() {
    jq -r '
        .result[0] // {} |
        [(.id // ""), (.content // ""), ((.proxied // false) | tostring), ((.ttl // 0) | tostring)] |
        .[]
    ' <<<"$1"
}

# Parse id + value + priority + target + ttl from an HTTPS result[0].
# Outputs five lines. Hints are extracted from the SvcParams string in Bash
# so comparison is robust to whitespace / ordering / quoting differences from
# the API.
parse_https_record() {
    jq -r '
        .result[0] // {} as $r |
        ($r.data.value // "") as $v |
        [
            ($r.id // ""),
            $v,
            (($r.data.priority // 1) | tostring),
            ($r.data.target // "."),
            (($r.ttl // 0) | tostring)
        ] | .[]
    ' <<<"$1"
}

append_plan_operation() {
    local collection="$1" operation="$2" output="$3" notification="$4" family="$5"
    PLAN_JSON=$(jq -c \
        --arg collection "$collection" --argjson operation "$operation" \
        --arg output "$output" --arg notification "$notification" --arg family "$family" \
        '.[$collection] += [$operation] |
         .messages += [{console:$output, notification:$notification, family:$family}]' <<<"$PLAN_JSON")
}

plan_host_record() {
    local type="$1" ip="$2" response="$3"
    local cf_id cf_ip cf_proxied cf_ttl data message output family content_changed=false
    { read -r cf_id; read -r cf_ip; read -r cf_proxied; read -r cf_ttl; } < <(parse_record "$response")
    [[ "$type" == A ]] && family=-4 || family=-6
    if [[ -n "$cf_id" ]] && ! addresses_equal "$family" "$ip" "$cf_ip"; then
        content_changed=true
    fi

    if [[ -z "$cf_id" ]]; then
        data=$(jq -nc --arg type "$type" --arg name "$RECORD" --arg ip "$ip" \
            --argjson ttl "$TTL" '{type:$type, name:$name, content:$ip, ttl:$ttl, proxied:false}')
        output="Created new $type record for $RECORD, $ip"
        message="Created $type record for $RECORD: $ip"
        append_plan_operation posts "$data" "$output" "$message" "$type"
    elif [[ "$content_changed" == true || "$cf_ttl" != "$TTL" || "$cf_proxied" != false ]]; then
        data=$(jq -nc --arg id "$cf_id" '{id:$id}')
        [[ "$content_changed" == true ]] && data=$(jq -c --arg value "$ip" '.content=$value' <<<"$data")
        [[ "$cf_ttl" != "$TTL" ]] && data=$(jq -c --argjson value "$TTL" '.ttl=$value' <<<"$data")
        [[ "$cf_proxied" != false ]] && data=$(jq -c '.proxied=false' <<<"$data")
        if [[ "$content_changed" == true ]]; then
            output="Updated $type record for $RECORD from $cf_ip to $ip"
            message="Updated $type record for $RECORD: $cf_ip -> $ip"
        elif [[ "$cf_ttl" != "$TTL" ]]; then
            output="Updated TTL of $type record for $RECORD from $cf_ttl to $TTL"
            message="Updated TTL of $type record for $RECORD: $cf_ttl -> $TTL"
        else
            output="Disabled Cloudflare proxying for $type record $RECORD"
            message="Disabled proxying for $type record $RECORD"
        fi
        append_plan_operation patches "$data" "$output" "$message" "$type"
    else
        qprint "${C_YELLOW}No change to $type record for $RECORD, $cf_ip${C_RESET}"
        return 0
    fi
}

# Parse the SvcParams once, extract both existing hints, and rebuild the value
# while preserving all unrelated tokens. Outputs old and desired hints followed
# by the rebuilt value, one field per line.
transform_https_hints() {
    local value="${1:-}" ipv4="$2" ipv6="$3" token="" ch key item token_value out=""
    local old4="" old6="" in_quote=0 ipv4_count=0 ipv6_count=0 i
    local -a tokens=()
    [[ -z "$value" ]] && value='alpn="h3,h2"'
    if [[ "$value" == *\\* ]]; then
        err "HTTPS SvcParams contain escape sequences that cannot be preserved safely; refusing to update"
        return 1
    fi
    for (( i = 0; i < ${#value}; i++ )); do
        ch="${value:i:1}"
        if [[ "$ch" == '"' ]]; then
            token+="$ch"
            in_quote=$((1 - in_quote))
        elif [[ "$ch" =~ [[:space:]] && $in_quote -eq 0 ]]; then
            [[ -n "$token" ]] && tokens+=("$token")
            token=""
        else
            token+="$ch"
        fi
    done
    if (( in_quote != 0 )); then
        err "HTTPS SvcParams contain an unterminated quoted value; refusing to update"
        return 1
    fi
    [[ -n "$token" ]] && tokens+=("$token")

    for item in "${tokens[@]}"; do
        key="${item%%=*}"
        case "$key" in
            ipv4hint|ipv6hint)
                token_value="${item#*=}"
                if [[ "$token_value" == \"*\" && "$token_value" == *\" ]]; then
                    token_value="${token_value#\"}"
                    token_value="${token_value%\"}"
                fi
                if [[ "$key" == ipv4hint ]]; then
                    ((ipv4_count+=1)); old4="$token_value"
                else
                    ((ipv6_count+=1)); old6="$token_value"
                fi
                ;;
            *) out+="${out:+ }$item" ;;
        esac
    done
    if (( ipv4_count > 1 || ipv6_count > 1 )); then
        err "HTTPS SvcParams contain duplicate address hints; refusing to update"
        return 1
    fi
    [[ "$DO_IPV4" = false ]] && ipv4="$old4"
    [[ "$DO_IPV6" = false ]] && ipv6="$old6"
    [[ -n "$ipv4" ]] && out+="${out:+ }ipv4hint=\"$ipv4\""
    [[ -n "$ipv6" ]] && out+="${out:+ }ipv6hint=\"$ipv6\""
    printf '%s\n%s\n%s\n%s\n%s\n' "$old4" "$old6" "$ipv4" "$ipv6" "$out"
}

plan_https_record() {
    local ipv4="$1" ipv6="$2" response="$3"
    local id value priority target ttl old4 old6 new_value data output message transformed
    local ipv4_changed=false ipv6_changed=false
    { read -r id; read -r value; read -r priority; read -r target; read -r ttl; } < <(parse_https_record "$response")
    transformed=$(transform_https_hints "$value" "$ipv4" "$ipv6") || return 1
    { read -r old4; read -r old6; read -r ipv4; read -r ipv6; read -r new_value; } <<<"$transformed"
    address_value_changed -4 "$old4" "$ipv4" && ipv4_changed=true
    address_value_changed -6 "$old6" "$ipv6" && ipv6_changed=true

    if [[ -z "$id" ]]; then
        # HTTPS records must not include proxied; Cloudflare rejects that field.
        data=$(jq -nc --arg name "$RECORD" --arg value "$new_value" --argjson ttl "$TTL" \
            '{type:"HTTPS", name:$name, ttl:$ttl,
              data:{priority:1, target:".", value:$value}}')
        output="Created new HTTPS record for $RECORD"
        message="Created HTTPS record for $RECORD"
        append_plan_operation posts "$data" "$output" "$message" HTTPS
    elif [[ "$ipv4_changed" == true || "$ipv6_changed" == true || "$ttl" != "$TTL" ]]; then
        data=$(jq -nc --arg id "$id" '{id:$id}')
        if [[ "$ipv4_changed" == true || "$ipv6_changed" == true ]]; then
            data=$(jq -c --arg value "$new_value" --arg target "$target" --argjson priority "$priority" \
                '.data={priority:$priority,target:$target,value:$value}' <<<"$data")
        fi
        [[ "$ttl" != "$TTL" ]] && data=$(jq -c --argjson value "$TTL" '.ttl=$value' <<<"$data")
        output="Updated HTTPS record for $RECORD"
        message="Updated HTTPS record for $RECORD (ipv4hint=$ipv4 ipv6hint=$ipv6)"
        append_plan_operation patches "$data" "$output" "$message" HTTPS
    else
        qprint "${C_YELLOW}No change to HTTPS record for $RECORD${C_RESET}"
        return 0
    fi
}

ping_hc() {
    local family="$1" url="$2"
    [[ -z "$url" ]] && return 0
    # Monitoring delivery is best-effort after DNS reconciliation succeeds.
    "${CURL_GET[@]}" -o /dev/null "$url" || err "$family healthcheck ping failed"
}

submit_dns_batch() {
    local batch body expected_patches expected_posts error_count actual_patches actual_posts
    { read -r expected_patches; read -r expected_posts; } < <(
        jq -r '[(.patches | length), (.posts | length)] | .[]' <<<"$PLAN_JSON"
    )
    batch=$(jq -c '{patches, posts} | with_entries(select(.value | length > 0))' <<<"$PLAN_JSON")
    if ! body=$(cf_api_batch "$batch"); then
        err "Cloudflare DNS batch request failed; its outcome may be ambiguous. Check Cloudflare state before retrying."
        [[ -n "$body" ]] && printf '%s\n' "$body" >&2
        return 1
    fi
    check_success "$body" "DNS batch update" || return 1
    { read -r error_count; read -r actual_patches; read -r actual_posts; } < <(
        jq -r '[(.errors // [] | length), (.result.patches // [] | length),
                (.result.posts // [] | length)] | .[]' <<<"$body"
    )
    if (( error_count > 0 )); then
        err "Cloudflare DNS batch response contained operation errors:"
        jq -r '.errors[]? | "  [\(.code)] \(.message)"' <<<"$body" >&2
        return 1
    fi
    if (( actual_patches != expected_patches || actual_posts != expected_posts )); then
        err "Cloudflare DNS batch response did not account for every planned operation"
        return 1
    fi
}

# Exit trap: ping failed attempted families, remove temporary credentials, and
# send one notification for completed changes or a failed run.
# `set +e` so a "false" condition (e.g. empty NOTIFY_LINES) inside the trap
# doesn't override the script's real exit status under `set -e`.
on_exit() {
    local rc=$?
    set +e
    [[ -n "$CF_AUTH_CONFIG" ]] && rm -f -- "$CF_AUTH_CONFIG"
    if (( rc != 0 )); then
        if [[ "$A_STATUS" == attempted && -n "$A_HC" ]]; then
            "${CURL_GET[@]}" -o /dev/null "${A_HC%/}/fail" 2>/dev/null || true
        fi
        if [[ "$AAAA_STATUS" == attempted && -n "$AAAA_HC" ]]; then
            "${CURL_GET[@]}" -o /dev/null "${AAAA_HC%/}/fail" 2>/dev/null || true
        fi
    fi
    if { [[ ${#NOTIFY_LINES[@]} -gt 0 ]] || (( rc != 0 )); } && command -v sendmail >/dev/null; then
        local host date_hdr subject
        host=$(hostname -f 2>/dev/null || hostname)
        date_hdr=$(date -R)
        subject="[$host] Cloudflare DDNS for ${RECORD:-unknown} updated"
        (( rc != 0 )) && subject="[$host] Cloudflare DDNS for ${RECORD:-unknown} failed (rc=$rc)"
        {
            printf 'To: root\n'
            printf 'Date: %s\n' "$date_hdr"
            printf 'Subject: %s\n' "$subject"
            printf 'MIME-Version: 1.0\n'
            printf 'Content-Type: text/plain; charset=UTF-8\n'
            printf '\n'
            printf '%s\n' "${NOTIFY_LINES[@]}"
            if (( rc != 0 )); then
                printf '\nRecord: %s\nExit code: %s\n' "${RECORD:-unknown}" "$rc"
                printf 'Family status: A=%s, AAAA=%s\n' "$A_STATUS" "$AAAA_STATUS"
                printf 'Inspect the systemd journal for detailed errors.\n'
            fi
        } | sendmail root || true
    fi
    exit "$rc"
}
trap on_exit EXIT

# ---- argument parsing ----
while getopts "qt:s46h" FLAG; do
    case "$FLAG" in
        q) QUIET=1;;
        t) TTL=${OPTARG};;
        s) DO_HTTPS=true;;
        4) DO_IPV4=true;;
        6) DO_IPV6=true;;
        h) print_usage; exit 0;;
        *) print_usage; exit 1;;
    esac
done
shift $((OPTIND - 1))
if [[ $# -lt 1 || -z "${1:-}" ]]; then
    print_usage
    exit 1
fi
RECORD=$(normalize_record "$1")
if ! valid_record "$RECORD"; then
    err "Invalid FQDN: $1"
    exit 1
fi

# If neither -4 nor -6 is specified, do both
if [[ "$DO_IPV4" = false && "$DO_IPV6" = false ]]; then
    DO_IPV4=true
    DO_IPV6=true
fi

# Explicit source policy: external (the default) or interface:<name>.
A_SOURCE=${CLOUDFLARE_DDNS_A_SOURCE:-external}
AAAA_SOURCE=${CLOUDFLARE_DDNS_AAAA_SOURCE:-external}
case "$A_SOURCE" in external|interface:?*) ;; *) err "Invalid CLOUDFLARE_DDNS_A_SOURCE: $A_SOURCE"; exit 1;; esac
case "$AAAA_SOURCE" in external|interface:?*) ;; *) err "Invalid CLOUDFLARE_DDNS_AAAA_SOURCE: $AAAA_SOURCE"; exit 1;; esac

# ---- preflight checks ----
load_systemd_credentials
require_cmd curl jq flock awk tr
if [[ "$A_SOURCE" == interface:* || "$AAAA_SOURCE" == interface:* ]]; then
    require_cmd ip
fi

validate_credentials

if ! [[ "$TTL" =~ ^[0-9]+$ ]] || ! { [[ "$TTL" == "1" ]] || (( TTL >= 60 && TTL <= 86400 )); }; then
    err "TTL must be 1 (auto) or an integer between 60 and 86400"
    exit 1
fi

# ---- single-instance lock (per record) ----
# State dir is managed by systemd via `RuntimeDirectory=cloudflare-ddns`,
# which exports RUNTIME_DIRECTORY. The unit is the only supported caller.
if [[ -z "${RUNTIME_DIRECTORY:-}" ]]; then
    err "RUNTIME_DIRECTORY is not set; this script expects to be launched from systemd with RuntimeDirectory=cloudflare-ddns"
    exit 1
fi
STATE_DIR="${RUNTIME_DIRECTORY%%:*}"
if [[ ! -d "$STATE_DIR" || ! -w "$STATE_DIR" ]]; then
    err "Runtime directory is not writable: $STATE_DIR"
    exit 1
fi
create_curl_auth_config
# Sanitize record name so unusual input can't escape STATE_DIR
RECORD_SAFE=${RECORD//[^A-Za-z0-9._-]/_}
LOCK_FILE="$STATE_DIR/${RECORD_SAFE}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    err "Another instance is already running for $RECORD"
    exit 1
fi

# ---- fetch and validate current records before planning any mutations ----
A_RESPONSE=''; AAAA_RESPONSE=''; HTTPS_RESPONSE=''
if [[ "$DO_IPV4" = true ]]; then
    A_STATUS=attempted
    A_RESPONSE=$(get_records_checked A)
fi
if [[ "$DO_IPV6" = true ]]; then
    AAAA_STATUS=attempted
    AAAA_RESPONSE=$(get_records_checked AAAA)
fi
if [[ "$DO_HTTPS" = true ]]; then
    HTTPS_RESPONSE=$(get_records_checked HTTPS)
fi

# ---- discover and validate every requested address ----
if [[ "$DO_IPV4" = true ]]; then
    if [[ "$A_SOURCE" == interface:* ]]; then
        IPV4=$(select_interface_ipv4 "${A_SOURCE#interface:}")
        verify_interface_ip -4 "$IPV4"
    else
        IPV4=$(query_external_ip -4)
    fi
    if ! valid_ipv4 "$IPV4"; then
        err "Invalid IPv4 detected: $IPV4"
        exit 1
    fi
    qprint "Current IPv4 is $IPV4"
fi

if [[ "$DO_IPV6" = true ]]; then
    if [[ "$AAAA_SOURCE" == interface:* ]]; then
        { read -r _; read -r published_ip; } < <(parse_record "$AAAA_RESPONSE")
        IPV6=$(select_interface_ipv6 "${AAAA_SOURCE#interface:}" "$published_ip")
        if ! verify_interface_ip -6 "$IPV6"; then
            if [[ -n "$published_ip" ]] && addresses_equal -6 "$IPV6" "$published_ip"; then
                err "Published IPv6 address is no longer externally usable; trying the longest-lived preferred alternative"
                IPV6=$(select_interface_ipv6 "${AAAA_SOURCE#interface:}" "" "$published_ip")
                verify_interface_ip -6 "$IPV6"
            else
                exit 1
            fi
        fi
    else
        IPV6=$(query_external_ip -6)
    fi
    if ! valid_ipv6 "$IPV6"; then
        err "Invalid IPv6 detected: $IPV6"
        exit 1
    fi
    qprint "Current IPv6 is $IPV6"
fi

# ---- calculate the complete batch without mutating Cloudflare ----
if [[ "$DO_IPV4" = true ]]; then plan_host_record A "$IPV4" "$A_RESPONSE"; fi
if [[ "$DO_IPV6" = true ]]; then plan_host_record AAAA "$IPV6" "$AAAA_RESPONSE"; fi
if [[ "$DO_HTTPS" = true ]]; then
    plan_https_record "$IPV4" "$IPV6" "$HTTPS_RESPONSE"
fi

# ---- apply all planned changes as one database transaction ----
if jq -e '((.patches | length) + (.posts | length)) > 0' <<<"$PLAN_JSON" >/dev/null; then
    submit_dns_batch
    mapfile -t completed_output < <(jq -r '.messages[].console' <<<"$PLAN_JSON")
    for line in "${completed_output[@]}"; do
        printf '%s%s%s\n' "$C_PURPLE" "$line" "$C_RESET"
    done
    mapfile -t NOTIFY_LINES < <(jq -r '.messages[].notification' <<<"$PLAN_JSON")
fi

# Changed families become successful only after the batch succeeds. Unchanged
# families are successful once discovery, query, validation, and planning pass.
if [[ "$DO_IPV4" = true ]]; then
    A_STATUS=successful
    ping_hc A "$A_HC"
fi
if [[ "$DO_IPV6" = true ]]; then
    AAAA_STATUS=successful
    ping_hc AAAA "$AAAA_HC"
fi
