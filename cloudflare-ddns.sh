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
A_ATTEMPTED=false
AAAA_ATTEMPTED=false
SCRIPT_NAME="${0##*/}"
USER_AGENT="cloudflare-ddns/2.1"

# Ephemeral system-wide state (root-writable tmpfs).
# Holds per-record locks; safe to lose across reboots.
STATE_DIR="/run/cloudflare-ddns"

CF_API="https://api.cloudflare.com/client/v4"

# Curl base options
#   --fail-with-body : print body on HTTP error before exit
#   --connect-timeout: bound DNS/TCP/TLS handshake
#   -m / --max-time  : bound total transfer
CURL_BASE=(
    curl -sS
    --fail-with-body
    -A "$USER_AGENT"
    --connect-timeout 5
    --max-time 15
)
# Read-only / idempotent requests can retry liberally
CURL_GET=("${CURL_BASE[@]}" --retry 5 --retry-delay 2 --retry-max-time 30)
# POSTs (record creation) are NOT idempotent: a transient 5xx on a request
# that actually reached Cloudflare could create a duplicate on retry. Retry
# only on connection-level errors (curl's default), and at most once.
CURL_POST=("${CURL_BASE[@]}" --retry 1 --retry-delay 2)
# PATCH (record update) is idempotent, so retry liberally on any error.
CURL_PATCH=("${CURL_BASE[@]}" --retry 3 --retry-delay 2 --retry-max-time 20 --retry-all-errors)
# IP detection: tight timeout, single retry; we already iterate fallbacks
CURL_IP=(
    curl -sS --fail-with-body -A "$USER_AGENT"
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

print_usage() {
    cat <<EOF

Usage:  $SCRIPT_NAME [OPTIONS] FQDN

Updates Cloudflare DNS A and AAAA records with external IPv4 and IPv6 addresses of the current machine

Options:
  -h  Print usage help
  -q  Enable quiet mode
  -s  Update HTTPS record with external IPv4 and IPv6 addresses
  -t  TTL of records, in seconds (1 = auto, otherwise 120-86400)
  -4  Only update A record with external IPv4 address
  -6  Only update AAAA record with external IPv6 address
EOF
}

err()    { printf '%s\n' "$*" >&2; }
qprint() { [[ "$QUIET" -eq 0 ]] && printf '%s\n' "$1"; return 0; }

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        (( octet <= 255 )) || return 1
    done
    return 0
}

valid_ipv6() {
    [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:* ]]
}

# Fetch external IP for the given family from one of several providers.
# Usage: get_ip -4|-6
get_ip() {
    local family="$1" url ip last_err=""
    case "$family" in -4|-6) ;; *) err "get_ip: must specify -4 or -6"; return 1;; esac

    for url in \
        "https://api.cloudflare.com/cdn-cgi/trace" \
        "https://icanhazip.com"
    do
        if ! ip=$("${CURL_IP[@]}" "$family" "$url" 2>&1); then
            last_err="$ip"
            continue
        fi
        if [[ "$url" == *cdn-cgi/trace* ]]; then
            ip=$(awk -F= '/^ip=/ { print $2; exit }' <<<"$ip")
        else
            ip=$(printf '%s' "$ip" | tr -d '[:space:]')
        fi
        if [[ -n "$ip" ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    err "Failed to determine external IP ($family). Last error: $last_err"
    return 1
}

# Verify a Cloudflare API JSON response has success:true; on failure, print errors and exit.
check_success() {
    local body="$1" context="$2"
    local ok
    ok=$(jq -r '.success // false' <<<"$body" 2>/dev/null || echo false)
    if [[ "$ok" != "true" ]]; then
        err "Cloudflare API error during $context:"
        jq -r '.errors[]? | "  [\(.code)] \(.message)"' <<<"$body" >&2 2>/dev/null \
            || printf '%s\n' "$body" >&2
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
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        "${args[@]}" \
        "$CF_API$path"
}

# Usage: cf_api_mutate METHOD PATH DATA
cf_api_mutate() {
    local method="$1" path="$2" data="$3"
    local -a curl_cmd
    case "$method" in
        POST)  curl_cmd=("${CURL_POST[@]}") ;;
        PATCH|PUT) curl_cmd=("${CURL_PATCH[@]}") ;;
        *)     curl_cmd=("${CURL_PATCH[@]}") ;;
    esac
    "${curl_cmd[@]}" \
        -X "$method" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary "$data" \
        "$CF_API$path"
}

verify_token() {
    local body
    body=$(cf_api_get "/user/tokens/verify") || {
        err "Token verification request failed"
        [[ -n "$body" ]] && printf '%s\n' "$body" >&2
        return 1
    }
    check_success "$body" "token verification"
}

# Get all records matching type + name (up to 100).
get_records() {
    cf_api_get "/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
        "type=$1" "name=$RECORD" "page=1" "per_page=100"
}

# Refuse to proceed if more than one record matches; safer than silently
# updating only the first.
record_count() {
    jq -r '.result | length' <<<"$1"
}

# Parse id + content + proxied + ttl from result[0]. Outputs four lines.
parse_record() {
    jq -r '
        .result[0] // {} |
        [(.id // ""), (.content // ""), ((.proxied // false) | tostring), ((.ttl // 0) | tostring)] |
        .[]
    ' <<<"$1"
}

# Parse id + ipv4hint + ipv6hint + ttl from an HTTPS result[0]. Outputs four lines.
# Hints are extracted from the SvcParams string so comparison is robust to
# whitespace / ordering / quoting differences from the API.
parse_https_record() {
    jq -r '
        .result[0] // {} as $r |
        ($r.data.value // "") as $v |
        [
            ($r.id // ""),
            ($v | capture("ipv4hint=\"(?<v>[^\"]+)\"") | .v // ""),
            ($v | capture("ipv6hint=\"(?<v>[^\"]+)\"") | .v // ""),
            (($r.ttl // 0) | tostring)
        ] | .[]
    ' <<<"$1"
}

create_host_record() {
    local type="$1" ip="$2" proxied="$3" data body
    data=$(jq -nc \
        --arg type "$type" --arg name "$RECORD" --arg ip "$ip" \
        --argjson ttl "$TTL" --argjson proxied "$proxied" \
        '{type:$type, name:$name, content:$ip, ttl:$ttl, proxied:$proxied}')
    body=$(cf_api_mutate POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$data")
    check_success "$body" "create $type record"
}

update_host_record() {
    local id="$1" type="$2" ip="$3" proxied="$4" data body
    data=$(jq -nc \
        --arg type "$type" --arg name "$RECORD" --arg ip "$ip" \
        --argjson ttl "$TTL" --argjson proxied "$proxied" \
        '{type:$type, name:$name, content:$ip, ttl:$ttl, proxied:$proxied}')
    body=$(cf_api_mutate PATCH "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$id" "$data")
    check_success "$body" "update $type record"
}

# Build SvcParams string for an HTTPS record (only include hints we have)
https_value() {
    local ipv4="$1" ipv6="$2" value
    value='alpn="h3,h2"'
    [[ -n "$ipv4" ]] && value+=" ipv4hint=\"$ipv4\""
    [[ -n "$ipv6" ]] && value+=" ipv6hint=\"$ipv6\""
    printf '%s' "$value"
}

https_record_data() {
    local value="$1"
    jq -nc --arg name "$RECORD" --arg value "$value" --argjson ttl "$TTL" \
        '{type:"HTTPS", name:$name, ttl:$ttl, data:{priority:1, target:".", value:$value}}'
}

create_https_record() {
    local value="$1" data body
    data=$(https_record_data "$value")
    body=$(cf_api_mutate POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$data")
    check_success "$body" "create HTTPS record"
}

update_https_record() {
    local id="$1" value="$2" data body
    data=$(https_record_data "$value")
    body=$(cf_api_mutate PATCH "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$id" "$data")
    check_success "$body" "update HTTPS record"
}

ping_hc() {
    local url="$1"
    [[ -z "$url" ]] && return 0
    "${CURL_GET[@]}" -o /dev/null "$url" || err "Healthcheck ping to $url failed"
}

# Update or create a host (A/AAAA) record
# Usage: sync_host_record TYPE IP HC_URL
sync_host_record() {
    local type="$1" ip="$2" hc_url="$3"
    local response count cf_id cf_ip cf_proxied cf_ttl

    response=$(get_records "$type")
    check_success "$response" "list $type records" || return 1

    count=$(record_count "$response")
    if (( count > 1 )); then
        err "Found $count $type records for $RECORD; refusing to update. Remove duplicates in the Cloudflare dashboard."
        return 1
    fi

    { read -r cf_id; read -r cf_ip; read -r cf_proxied; read -r cf_ttl; } < <(parse_record "$response")

    if [[ -z "$cf_id" ]]; then
        create_host_record "$type" "$ip" false
        printf '%sCreated new %s record for %s, %s%s\n' "$C_PURPLE" "$type" "$RECORD" "$ip" "$C_RESET"
        NOTIFY_LINES+=("Created $type record for $RECORD: $ip")
    elif [[ "$ip" != "$cf_ip" ]]; then
        # Preserve existing proxied state set in the dashboard
        update_host_record "$cf_id" "$type" "$ip" "$cf_proxied"
        printf '%sUpdated %s record for %s from %s to %s%s\n' \
            "$C_PURPLE" "$type" "$RECORD" "$cf_ip" "$ip" "$C_RESET"
        NOTIFY_LINES+=("Updated $type record for $RECORD: $cf_ip -> $ip")
    elif [[ "$cf_ttl" != "$TTL" ]]; then
        update_host_record "$cf_id" "$type" "$ip" "$cf_proxied"
        printf '%sUpdated TTL of %s record for %s from %s to %s%s\n' \
            "$C_PURPLE" "$type" "$RECORD" "$cf_ttl" "$TTL" "$C_RESET"
        NOTIFY_LINES+=("Updated TTL of $type record for $RECORD: $cf_ttl -> $TTL")
    else
        qprint "${C_YELLOW}No change to $type record for $RECORD, $cf_ip${C_RESET}"
    fi

    ping_hc "$hc_url"
}

# Failure trap: ping /fail only for families we actually attempted, so a
# -4-only run that fails doesn't falsely mark the AAAA healthcheck failed.
on_error() {
    local rc=$?
    if [[ "$A_ATTEMPTED" = true && -n "$A_HC" ]]; then
        "${CURL_GET[@]}" -o /dev/null "${A_HC%/}/fail" 2>/dev/null || true
    fi
    if [[ "$AAAA_ATTEMPTED" = true && -n "$AAAA_HC" ]]; then
        "${CURL_GET[@]}" -o /dev/null "${AAAA_HC%/}/fail" 2>/dev/null || true
    fi
    exit "$rc"
}

# Exit trap: flush batched notification email so partial progress (e.g. a
# successful A update before an AAAA failure) still gets reported.
on_exit() {
    local rc=$?
    if (( ${#NOTIFY_LINES[@]} > 0 )) && command -v sendmail >/dev/null; then
        local subject="Cloudflare DDNS for $RECORD Updated"
        (( rc != 0 )) && subject="Cloudflare DDNS for $RECORD Updated (with errors, rc=$rc)"
        {
            printf 'Subject: %s\n\n' "$subject"
            printf '%s\n' "${NOTIFY_LINES[@]}"
        } | sendmail root || true
    fi
}
trap on_error ERR
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
RECORD="$1"

# If neither -4 nor -6 is specified, do both
if [[ "$DO_IPV4" = false && "$DO_IPV6" = false ]]; then
    DO_IPV4=true
    DO_IPV6=true
fi

# ---- preflight checks ----
if ! command -v jq &> /dev/null; then
    err "jq is not installed. Install it via 'apt install jq'."
    exit 1
fi

if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
    err "Error: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID must be defined."
    exit 1
fi

if ! [[ "$TTL" =~ ^[0-9]+$ ]] || ! { [[ "$TTL" == "1" ]] || (( TTL >= 120 && TTL <= 86400 )); }; then
    err "TTL must be 1 (auto) or an integer between 120 and 86400"
    exit 1
fi

# ---- ephemeral state dir + single-instance lock (per record) ----
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
LOCK_FILE="$STATE_DIR/${RECORD}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    err "Another instance is already running for $RECORD"
    exit 1
fi

# ---- API token sanity check ----
verify_token

# ---- A record ----
if [[ "$DO_IPV4" = true ]]; then
    A_ATTEMPTED=true
    IPV4=$(get_ip -4)
    if ! valid_ipv4 "$IPV4"; then
        err "Invalid IPv4 detected: $IPV4"
        exit 1
    fi
    qprint "Current IPv4 is $IPV4"
    sync_host_record A "$IPV4" "$A_HC"
fi

# ---- AAAA record ----
if [[ "$DO_IPV6" = true ]]; then
    AAAA_ATTEMPTED=true
    IPV6=$(get_ip -6)
    if ! valid_ipv6 "$IPV6"; then
        err "Invalid IPv6 detected: $IPV6"
        exit 1
    fi
    qprint "Current IPv6 is $IPV6"
    sync_host_record AAAA "$IPV6" "$AAAA_HC"
fi

# ---- HTTPS record ----
if [[ "$DO_HTTPS" = true ]]; then
    https_resp=$(get_records HTTPS)
    check_success "$https_resp" "list HTTPS records"

    https_count=$(record_count "$https_resp")
    if (( https_count > 1 )); then
        err "Found $https_count HTTPS records for $RECORD; refusing to update. Remove duplicates in the Cloudflare dashboard."
        exit 1
    fi

    { read -r cf_https_id; read -r cf_ipv4hint; read -r cf_ipv6hint; read -r cf_https_ttl; } < <(parse_https_record "$https_resp")

    # If a family wasn't refreshed in this run (e.g. -4-only), preserve the
    # existing hint from Cloudflare so we don't silently drop it.
    if [[ "$DO_IPV4" = true && -z "$IPV4" ]]; then
        IPV4=$(get_ip -4)
        valid_ipv4 "$IPV4" || { err "Invalid IPv4 detected: $IPV4"; exit 1; }
    elif [[ "$DO_IPV4" = false ]]; then
        IPV4="$cf_ipv4hint"
    fi
    if [[ "$DO_IPV6" = true && -z "$IPV6" ]]; then
        IPV6=$(get_ip -6)
        valid_ipv6 "$IPV6" || { err "Invalid IPv6 detected: $IPV6"; exit 1; }
    elif [[ "$DO_IPV6" = false ]]; then
        IPV6="$cf_ipv6hint"
    fi

    if [[ -z "$cf_https_id" ]]; then
        create_https_record "$(https_value "$IPV4" "$IPV6")"
        printf '%sCreated new HTTPS record for %s%s\n' "$C_PURPLE" "$RECORD" "$C_RESET"
        NOTIFY_LINES+=("Created HTTPS record for $RECORD")
    elif [[ "$cf_ipv4hint" != "$IPV4" || "$cf_ipv6hint" != "$IPV6" ]]; then
        update_https_record "$cf_https_id" "$(https_value "$IPV4" "$IPV6")"
        printf '%sUpdated HTTPS record for %s%s\n' "$C_PURPLE" "$RECORD" "$C_RESET"
        NOTIFY_LINES+=("Updated HTTPS record for $RECORD (ipv4hint=$IPV4 ipv6hint=$IPV6)")
    elif [[ "$cf_https_ttl" != "$TTL" ]]; then
        update_https_record "$cf_https_id" "$(https_value "$IPV4" "$IPV6")"
        printf '%sUpdated TTL of HTTPS record for %s from %s to %s%s\n' \
            "$C_PURPLE" "$RECORD" "$cf_https_ttl" "$TTL" "$C_RESET"
        NOTIFY_LINES+=("Updated TTL of HTTPS record for $RECORD: $cf_https_ttl -> $TTL")
    else
        qprint "${C_YELLOW}No change to HTTPS record for $RECORD${C_RESET}"
    fi
fi
