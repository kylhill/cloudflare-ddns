#!/bin/bash

#########
# SECRETS - Update with your Cloudflare API token and zone ID
#CLOUDFLARE_API_TOKEN=""
#CLOUDFLARE_ZONE_ID=""

# HEALTHCHECKS - Update with your Healthchecks to ping
#A_HC=""
#AAAA_HC=""
#########

# Bail immediately on errors
set -euo pipefail

QUIET=0
TTL=3600
DO_HTTPS=false
DO_IPV4=false
DO_IPV6=false
CF_UPDATED=false
IPV4=""
IPV6=""

CURL=(curl -fsS -m 10 --retry 5)
CF_API="https://api.cloudflare.com/client/v4"

print_usage() {
    cat <<EOF

Usage:  $0 [OPTIONS] FQDN

Updates Cloudflare DNS A and AAAA records with external IPv4 and IPv6 addresses of the current machine

Options:
  -h  Print usage help
  -q  Enable quiet mode
  -s  Update HTTPS record with external IPv4 and IPv6 addresses
  -t  TTL of records, in seconds (120-86400)
  -4  Only update A record with external IPv4 address
  -6  Only update AAAA record with external IPv6 address
EOF
}

err() {
    printf '%s\n' "$*" >&2
}

qprint() {
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%b\n' "$1"
    fi
}

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        (( octet <= 255 )) || return 1
    done
    return 0
}

valid_ipv6() {
    # Basic sanity: contains ':' and only hex/colon characters
    [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:* ]]
}

get_ip() {
    local family="$1"
    case "$family" in
        -4|-6) ;;
        *) err "get_ip: must specify -4 or -6"; return 1;;
    esac
    "${CURL[@]}" "$family" https://api.cloudflare.com/cdn-cgi/trace \
        | awk -F= '/^ip=/ { print $2 }'
}

cf_api() {
    # Usage: cf_api METHOD PATH [DATA]
    local method="$1" path="$2" data="${3:-}"
    local args=(
        -X "$method"
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
        -H "Content-Type: application/json"
    )
    if [[ -n "$data" ]]; then
        args+=(--data "$data")
    fi
    "${CURL[@]}" "${args[@]}" "$CF_API/zones/$CLOUDFLARE_ZONE_ID$path"
}

get_record() {
    cf_api GET "/dns_records?type=$1&name=$RECORD&page=1&per_page=1"
}

get_record_field() {
    # Usage: get_record_field RECORD_JSON FIELD
    # Returns empty string if no record exists
    jq -r --arg f "$2" '.result[0][$f] // ""' <<<"$1"
}

create_host_record() {
    local type="$1" ip="$2" data
    data=$(jq -nc --arg type "$type" --arg name "$RECORD" --arg ip "$ip" --argjson ttl "$TTL" \
        '{type:$type, name:$name, content:$ip, ttl:$ttl, proxied:false}')
    cf_api POST "/dns_records" "$data" >/dev/null
}

update_host_record() {
    local id="$1" type="$2" ip="$3" data
    data=$(jq -nc --arg type "$type" --arg name "$RECORD" --arg ip "$ip" --argjson ttl "$TTL" \
        '{type:$type, name:$name, content:$ip, ttl:$ttl, proxied:false}')
    cf_api PATCH "/dns_records/$id" "$data" >/dev/null
}

https_record_data() {
    local ipv4="$1" ipv6="$2" value
    value="alpn=\"h3,h2\""
    [[ -n "$ipv4" ]] && value+=" ipv4hint=\"$ipv4\""
    [[ -n "$ipv6" ]] && value+=" ipv6hint=\"$ipv6\""
    jq -nc --arg name "$RECORD" --arg value "$value" --argjson ttl "$TTL" \
        '{type:"HTTPS", name:$name, ttl:$ttl, data:{priority:1, target:".", value:$value}}'
}

create_https_record() {
    local data
    data=$(https_record_data "$1" "$2")
    cf_api POST "/dns_records" "$data" >/dev/null
}

update_https_record() {
    local id="$1" data
    data=$(https_record_data "$2" "$3")
    cf_api PATCH "/dns_records/$id" "$data" >/dev/null
}

# Update or create a host (A/AAAA) record
# Usage: sync_host_record TYPE IP HC_URL
sync_host_record() {
    local type="$1" ip="$2" hc_url="$3"
    local record cf_ip cf_id

    record=$(get_record "$type")
    cf_ip=$(get_record_field "$record" content)
    cf_id=$(get_record_field "$record" id)

    if [[ -z "$cf_id" ]]; then
        create_host_record "$type" "$ip"
        CF_UPDATED=true
        printf '\033[1;35mCreated new %s record for %s, %s\033[0m\n' "$type" "$RECORD" "$ip"
    elif [[ "$ip" != "$cf_ip" ]]; then
        update_host_record "$cf_id" "$type" "$ip"
        CF_UPDATED=true
        printf '\033[1;35mUpdated %s record for %s from %s to %s\033[0m\n' "$type" "$RECORD" "$cf_ip" "$ip"
        if command -v sendmail >/dev/null; then
            printf 'Subject:Cloudflare DDNS for %s Updated\n\nCloudflare DDNS %s record for %s updated from %s to %s\n' \
                "$RECORD" "$type" "$RECORD" "$cf_ip" "$ip" | sendmail root
        fi
    else
        qprint "\033[1;33mNo change to $type record for $RECORD, $cf_ip\033[0m"
    fi

    if [[ -n "$hc_url" ]]; then
        "${CURL[@]}" -o /dev/null "$hc_url" || err "Healthcheck ping to $hc_url failed"
    fi
}

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

if ! command -v jq &> /dev/null; then
    err "jq is not installed. Install it via 'apt install jq'."
    exit 1
fi

if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
    err "Error: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID must be defined."
    exit 1
fi

if ! [[ "$TTL" =~ ^[0-9]+$ ]] || (( TTL < 120 || TTL > 86400 )); then
    err "TTL must be an integer between 120 and 86400"
    exit 1
fi

if [[ "$DO_IPV4" = true ]]; then
    IPV4=$(get_ip -4)
    if ! valid_ipv4 "$IPV4"; then
        err "Invalid IPv4 detected: $IPV4"
        exit 1
    fi
    qprint "Current IPv4 is $IPV4"
    sync_host_record A "$IPV4" "$A_HC"
fi

if [[ "$DO_IPV6" = true ]]; then
    IPV6=$(get_ip -6)
    if ! valid_ipv6 "$IPV6"; then
        err "Invalid IPv6 detected: $IPV6"
        exit 1
    fi
    qprint "Current IPv6 is $IPV6"
    sync_host_record AAAA "$IPV6" "$AAAA_HC"
fi

if [[ "$DO_HTTPS" = true ]]; then
    # Get the current external IPv4 and IPv6 addresses, if needed
    if [[ -z "$IPV4" ]]; then
        IPV4=$(get_ip -4)
        valid_ipv4 "$IPV4" || { err "Invalid IPv4 detected: $IPV4"; exit 1; }
    fi
    if [[ -z "$IPV6" ]]; then
        IPV6=$(get_ip -6)
        valid_ipv6 "$IPV6" || { err "Invalid IPv6 detected: $IPV6"; exit 1; }
    fi

    CF_HTTPS_RECORD=$(get_record HTTPS)
    CF_HTTPS_ID=$(get_record_field "$CF_HTTPS_RECORD" id)

    if [[ -z "$CF_HTTPS_ID" ]]; then
        create_https_record "$IPV4" "$IPV6"
        CF_UPDATED=true
        printf '\033[1;35mCreated new HTTPS record for %s\033[0m\n' "$RECORD"
    elif [[ "$CF_UPDATED" = true ]]; then
        update_https_record "$CF_HTTPS_ID" "$IPV4" "$IPV6"
        printf '\033[1;35mUpdated HTTPS record for %s\033[0m\n' "$RECORD"
    else
        qprint "\033[1;33mNo change to HTTPS record for $RECORD\033[0m"
    fi
fi
