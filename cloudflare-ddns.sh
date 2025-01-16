#!/bin/bash

#########
# SECRETS - Update with your Cloudflare API token and zone ID
#CLOUDFLARE_API_TOKEN=""
#CLOUDFLARE_ZONE_ID=""

# HEALTHCHECKS - Update with your Healthchecks to ping
#A_HC=""
#AAAA_HC=""
#########

set -euo pipefail

QUIET=0
TTL=3600
DO_HTTPS=false
DO_IPV4=false
DO_IPV6=false
CF_UPDATED=false

print_usage() {
    echo "Usage: $0 [-q] [-t TTL] [-s] [-4] [-6] [-h] RECORD"
    echo "  -q        Quiet mode"
    echo "  -t TTL    Set TTL value"
    echo "  -s        Use HTTPS"
    echo "  -4        Use IPv4"
    echo "  -6        Use IPv6"
    echo "  -h        Show this help message"
}

qprint() {
    if [ "$QUIET" -eq 0 ]; then
        echo -e "$1"
    fi
}

get_ip() {
    local ip_version=$1
    if [[ "$ip_version" == "-4" || "$ip_version" == "-6" ]]; then
        curl -fsS "$ip_version" https://api.cloudflare.com/cdn-cgi/trace | awk -F= '/ip/ { print $2 }'
    else
        echo "get_ip: Must specify either -4 or -6 as an argument"
        exit 1
    fi
}

get_record() {
    local record_type=$1
    curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=$record_type&name=$RECORD&page=1&per_page=1" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json"
}

get_record_ip() {
    local record=$1
    if [ -z "$record" ]; then
        echo "get_record_ip: Must provide host record as an argument"
        exit 1
    else
        echo "$record" | jq -r '{"result"}[] | .[0] | .content'
    fi
}

get_record_id() {
    local record=$1
    if [ -z "$record" ]; then
        echo "get_record_id: Must provide host record as an argument"
        exit 1
    else
        echo "$record" | jq -r '{"result"}[] | .[0] | .id'
    fi
}

create_host_record() {
    local record_type=$1
    local ip_address=$2
    if [ "$#" -ne 2 ]; then
        echo "create_host_record: Must provide record type and IP address"
        exit 1
    else
        curl -fsS -o /dev/null -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"'"$record_type"'","name":"'"$RECORD"'","content":"'"$ip_address"'","ttl":"'"$TTL"'","proxied":false}'
    fi
}

update_host_record() {
    local record_id=$1
    local record_type=$2
    local ip_address=$3
    if [ "$#" -ne 3 ]; then
        echo "update_host_record: Must provide record ID, record type, and IP address"
        exit 1
    else
        curl -fsS -o /dev/null -X PATCH "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$record_id" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"'"$record_type"'","name":"'"$RECORD"'","content":"'"$ip_address"'","ttl":"'"$TTL"'","proxied":false}'
    fi
}

create_https_record() {
    local ipv4_address=$1
    local ipv6_address=$2
    if [ "$#" -ne 2 ]; then
        echo "create_https_record: Must provide IPv4 and IPv6 addresses"
        exit 1
    else
        curl -fsS -o /dev/null -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"HTTPS","name":"'"$RECORD"'","data":{"priority":"1","target":".","value":"alpn=\"h2\" ipv4hint=\"'"$ipv4_address"'\" ipv6hint=\"'"$ipv6_address"'\""},"ttl":"'"$TTL"'"}'
    fi
}

update_https_record() {
    local record_id=$1
    local ipv4_address=$2
    local ipv6_address=$3
    if [ "$#" -ne 3 ]; then
        echo "update_https_record: Must provide record ID, IPv4, and IPv6 addresses"
        exit 1
    else
        curl -fsS -o /dev/null -X PATCH "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$record_id" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"HTTPS","name":"'"$RECORD"'","data":{"priority":"1","target":".","value":"alpn=\"h2\" ipv4hint=\"'"$ipv4_address"'\" ipv6hint=\"'"$ipv6_address"'\""},"ttl":"'"$TTL"'"}'
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

# Shift off the options and optional --
shift $((OPTIND - 1))

# Check if RECORD is provided
if [ -z "$1" ]; then
    print_usage
    exit 1
else
    RECORD="$1"
fi

# If neither -4 nor -6 is specified, do both
if [ "$DO_IPV4" = false && "$DO_IPV6" = false ]; then
    DO_IPV4=true
    DO_IPV6=true
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Install it via 'apt install jq'."
    exit 1
fi

# Check for required environment variables
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "Error: CLOUDFLARE_API_TOKEN is not set."
    exit 1
fi

if [ -z "$CLOUDFLARE_ZONE_ID" ]; then
    echo "Error: CLOUDFLARE_ZONE_ID is not set."
    exit 1
fi

# Update IPv4 record if needed
if [ "$DO_IPV4" = true ]; then
    # Get the current external IPv4 address
    IPV4=$(get_ip -4)
    qprint "Current IPv4 is $IPV4"

    # Get the IPv4 address in the Cloudflare A record
    CF_A_RECORD=$(get_record A)
    CF_A_RECORD_IP=$(get_record_ip "$CF_A_RECORD")

    if [ "$CF_A_RECORD_IP" == "null" ]; then
        # Create new Cloudflare A record
        create_host_record A "$IPV4"
        CF_UPDATED=true

        echo -e "\033[1;35mCreated new A record for $RECORD, $IPV4\033[0m"
    elif [ "$IPV4" != "$CF_A_RECORD_IP" ]; then
        # Update Cloudflare A record
        update_host_record "$(get_record_id "$CF_A_RECORD")" A "$IPV4"
        CF_UPDATED=true

        echo -e "\033[1;35mUpdated A record for $RECORD from $CF_A_RECORD_IP to $IPV4\033[0m"
        echo -e "Subject:Cloudflare DDNS for $RECORD Updated\n\nCloudflare DDNS A record for $RECORD updated from $CF_A_RECORD_IP to $IPV4" | sendmail root
    else
        # No update needed
        qprint "\033[1;33mNo change to A record for $RECORD, $CF_A_RECORD_IP\033[0m"
    fi

    if [ -n "$A_HC" ]; then
        # Ping Healthcheck
        curl -fsS -m 10 --retry 5 -o /dev/null "$A_HC"
    fi
fi

# Update IPv6 record if needed
if [ "$DO_IPV6" = true ]; then
    # Get the current external IPv6 address
    IPV6=$(get_ip -6)
    qprint "Current IPv6 is $IPV6"

    # Get the IPv6 address in the Cloudflare AAAA record
    CF_AAAA_RECORD=$(get_record AAAA)
    CF_AAAA_RECORD_IP=$(get_record_ip "$CF_AAAA_RECORD")

    if [ "$CF_AAAA_RECORD_IP" == "null" ]; then
        # Create new Cloudflare AAAA record
        create_host_record AAAA "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mCreated new AAAA record for $RECORD, $IPV6\033[0m"
    elif [ "$IPV6" != "$CF_AAAA_RECORD_IP" ]; then
        # Update Cloudflare AAAA record
        update_host_record "$(get_record_id "$CF_AAAA_RECORD")" AAAA "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mUpdated AAAA record for $RECORD from $CF_AAAA_RECORD_IP to $IPV6\033[0m"
        echo -e "Subject:Cloudflare DDNS for $RECORD Updated\n\nCloudflare DDNS AAAA record for $RECORD updated from $CF_AAAA_RECORD_IP to $IPV6" | sendmail root
    else
        # No update needed
        qprint "\033[1;33mNo change to AAAA record for $RECORD, $CF_AAAA_RECORD_IP\033[0m"
    fi

    if [ -n "$AAAA_HC" ]; then
        # Ping Healthcheck
        curl -fsS -m 10 --retry 5 -o /dev/null "$AAAA_HC"
    fi
fi

# Update HTTPS record if needed
if [ "$DO_HTTPS" = true ]; then
    # Get the current external IPv4 and IPv6 addresses, if needed
    if [ -z "$IPV4" ]; then
        IPV4=$(get_ip -4)
    fi
    if [ -z "$IPV6" ]; then
        IPV6=$(get_ip -6)
    fi

    # Get the current Cloudflare HTTPS record
    CF_HTTPS_RECORD=$(get_record HTTPS)

    if [ "$CF_HTTPS_RECORD" == "null" ]; then
        # Create new Cloudflare HTTPS record
        create_https_record "$IPV4" "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35Created new HTTPS record for $RECORD\033[0m"
    elif [ "$CF_UPDATED" = true ]; then
        # Update Cloudflare HTTPS record
        update_https_record "$(get_record_id "$CF_HTTPS_RECORD")" "$IPV4" "$IPV6"
        CF_UPDATED=true

        echo -e "\033[1;35mUpdated HTTPS record for $RECORD\033[0m"
    else
        # No update needed
        qprint "\033[1;33mNo change to HTTPS record for $RECORD\033[0m"
    fi
fi
