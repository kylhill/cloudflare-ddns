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

CURL="curl -fsS -m 10 --retry 5"
CF_API="https://api.cloudflare.com/client/v4

print_usage() {
    echo ""
    echo "Usage:  $0 [OPTIONS] FQDN"
    echo ""
    echo "Updates Cloudflare DNS A and AAAA records with external IPv4 and IPv6 addresses of the current machine"
    echo ""
    echo "Options:"
    echo "  -h  Print usage help"
    echo "  -q  Enable quiet mode"
    echo "  -s  Update HTTPS record with external IPv4 and IPv6 addresses"
    echo "  -t  TTL of records, in seconds"
    echo "  -4  Only update A record with external IPv4 address"
    echo "  -6  Only update AAAA record with external IPv6 address"
}

valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
valid_ipv6() {
    [[ "$1" =~ : ]]
}

qprint() {
    if [[ "$QUIET" -eq 0 ]]; then
        echo -e "$1"
    fi
}

get_ip() {
    if [[ "$1" == "-4" || "$1" == "-6" ]]; then
        $CURL_GET "$1" https://api.cloudflare.com/cdn-cgi/trace | awk -F= '/ip/ { print $2 }'
    else
        echo "get_ip: Must specify either -4 or -6 as an argument"
        exit 1
    fi
}

get_record() {
    curl -fsS  -m 10 --retry 5 -X GET "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=$1&name=$RECORD&page=1&per_page=1" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json"
}

get_record_ip() {
    if [[ -z "$1" ]]; then
        echo "get_record_ip: Must provide host record as an argument"
        exit 1
    else
        echo "$1" | jq -r '{"result"}[] | .[0] | .content'
    fi
}

get_record_id() {
    if [[ -z "$1" ]]; then
        echo "get_record_id: Must provide host record as an argument"
        exit 1
    else
        echo "$1" | jq -r '{"result"}[] | .[0] | .id'
    fi
}

create_host_record() {
    if [[ "$#" -ne 2 ]]; then
        echo "create_host_record: Must provide record type and IP address"
        exit 1
    else
        curl -fsS -o /dev/null -X POST "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"'"$1"'","name":"'"$RECORD"'","content":"'"$2"'","ttl":"'"$TTL"'","proxied":false}'
    fi
}

update_host_record() {
    if [[ "$#" -ne 3 ]]; then
        echo "update_host_record: Must provide record ID, record type, and IP address"
        exit 1
    else
        curl -fsS -o /dev/null -X PATCH "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records/$1" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"'"$2"'","name":"'"$RECORD"'","content":"'"$3"'","ttl":"'"$TTL"'","proxied":false}'
    fi
}

create_https_record() {
    if [[ "$#" -ne 2 ]]; then
        echo "create_https_record: Must provide IPv4 and IPv6 addresses"
        exit 1
    else
        curl -fsS -o /dev/null -X POST "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"HTTPS","name":"'"$RECORD"'","data":{"priority":"1","target":".","value":"alpn=\"h3,h2\" ipv4hint=\"'"$1"'\" ipv6hint=\"'"$2"'\""},"ttl":"'"$TTL"'"}'
    fi
}

update_https_record() {
    if [[ "$#" -ne 3 ]]; then
        echo "create_https_record: Must provide record ID, IPv4, and IPv6 addresses"
        exit 1
    else
        curl -fsS -o /dev/null -X PATCH "$CF_API/zones/$CLOUDFLARE_ZONE_ID/dns_records/$1" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"HTTPS","name":"'"$RECORD"'","data":{"priority":"1","target":".","value":"alpn=\"h3,h2\" ipv4hint=\"'"$2"'\" ipv6hint=\"'"$3"'\""},"ttl":"'"$TTL"'"}'
    fi
}

while getopts "qt:s46h" FLAG
do
    case "$FLAG" in
        q) QUIET=1;;
        t) TTL=${OPTARG};;
        s) DO_HTTPS=true;;
        4) DO_IPV4=true;;
        6) DO_IPV6=true;;
        h) print_usage; exit 1;;
        *) print_usage; exit 1;;
    esac
done

shift $((OPTIND - 1))
if [[ -z "$1" ]]; then
    print_usage
    exit 1
else
    RECORD="$1"
fi

# If neither -4 nor -6 is specified, do both
if [[ "$DO_IPV4" = false && "$DO_IPV6" = false ]]; then
    DO_IPV4=true
    DO_IPV6=true
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Install it via 'apt install jq'."
    exit 1
fi

if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
    echo "Error: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID must be defined."
    exit 1
fi

if (( TTL < 120 || TTL > 86400 )); then
    echo "TTL must be between 120-86400"
    exit 1
fi

if [[ "$DO_IPV4" = true ]]; then
    # Get the current external IPv4 address
    IPV4=$(get_ip -4)
    if ! valid_ip "$IPV4"; then
        echo "Invalid IPv4 detected: $IPV4"
        exit 1
    fi
    qprint "Current IPv4 is $IPV4"

    # Get the IPv4 address in the Cloudflare A record
    CF_A_RECORD=$(get_record A)
    CF_A_RECORD_IP=$(get_record_ip "$CF_A_RECORD")

    if [[ "$CF_A_RECORD_IP" == "null" ]]; then
        # Create new Cloudflare A record
        create_host_record A "$IPV4"
        CF_UPDATED=true

        echo -e "\033[1;35mCreated new A record for $RECORD, $IPV4\033[0m"
    elif [[ "$IPV4" != "$CF_A_RECORD_IP" ]]; then
        # Update Cloudflare A record
        update_host_record "$(get_record_id "$CF_A_RECORD")" A "$IPV4"
        CF_UPDATED=true

        echo -e "\033[1;35mUpdated A record for $RECORD from $CF_A_RECORD_IP to $IPV4\033[0m"
        if command -v sendmail >/dev/null; then
            echo -e "Subject:Cloudflare DDNS for $RECORD Updated\n\nCloudflare DDNS A record for $RECORD updated from $CF_A_RECORD_IP to $IPV4" | sendmail root
        fi
    else
        # No update needed
        qprint "\033[1;33mNo change to A record for $RECORD, $CF_A_RECORD_IP\033[0m"
    fi

    if [[ -n "$A_HC" ]]; then
        # Ping Healthcheck
        $CURL_GET -o /dev/null "$A_HC"
    fi
fi

if [[ "$DO_IPV6" = true ]]; then
    # Get the current external IPv6 address
    IPV6=$(get_ip -6)
    if ! valid_ipv6 "$IPV6"; then
        echo "Invalid IPv6 detected: $IPV6"
        exit 1
    fi    
    qprint "Current IPv6 is $IPV6"

    # Get the IPv6 address in the Cloudflare AAAA record
    CF_AAAA_RECORD=$(get_record AAAA)
    CF_AAAA_RECORD_IP=$(get_record_ip "$CF_AAAA_RECORD")

    if [[ "$CF_AAAA_RECORD_IP" == "null" ]]; then
        # Create new Cloudflare AAAA record
        create_host_record AAAA "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mCreated new AAAA record for $RECORD, $IPV6\033[0m"
    elif [[ "$IPV6" != "$CF_AAAA_RECORD_IP" ]]; then
        # Update Cloudflare AAAA record
        update_host_record "$(get_record_id "$CF_AAAA_RECORD")" AAAA "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mUpdated AAAA record for $RECORD from $CF_AAAA_RECORD_IP to $IPV6\033[0m"
        if command -v sendmail >/dev/null; then
            echo -e "Subject:Cloudflare DDNS for $RECORD Updated\n\nCloudflare DDNS AAAA record for $RECORD updated from $CF_AAAA_RECORD_IP to $IPV6" | sendmail root
        fi
    else
        # No update needed
        qprint "\033[1;33mNo change to AAAA record for $RECORD, $CF_AAAA_RECORD_IP\033[0m"
    fi

    if [[ -n "$AAAA_HC" ]]; then
        # Ping Healthcheck
        $CURL_GET -o /dev/null "$AAAA_HC"
    fi
fi

if [[ "$DO_HTTPS" = true ]]; then
    # Get the current external IPv4 and IPv6 addresses, if needed
    if [[ -z "$IPV4" ]]; then
        IPV4=$(get_ip -4)
    fi
    if [[ -z "$IPV6" ]]; then
        IPV6=$(get_ip -6)
    fi

    # Get the current Cloudflare HTTPS record
    CF_HTTPS_RECORD=$(get_record HTTPS)

    if [[ "$CF_HTTPS_RECORD" == "null" ]]; then
        # Create new Cloudflare HTTPS record
        create_https_record "$IPV4" "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mCreated new HTTPS record for $RECORD\033[0m"
    elif [[ "$CF_UPDATED" = true ]]; then
        # Update Cloudflare HTTPS record
        update_https_record "$(get_record_id "$CF_HTTPS_RECORD")" "$IPV4" "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mUpdated HTTPS record for $RECORD\033[0m"
    else
        # No update needed
        qprint "\033[1;33mNo change to HTTPS record for $RECORD\033[0m"
    fi
fi
