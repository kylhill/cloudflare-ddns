#!/bin/bash

#########
# SECRETS - Update with your Cloudflare API token and zone ID
CLOUDFLARE_API_TOKEN=""
CLOUDFLARE_ZONE_ID=""

# HEALTHCHECKS - Update with your Healthchecks to ping
#A_HC=""
#AAAA_HC=""
#########

# Bail immediately on errors
set -e
set -o pipefail

print_usage() {
    echo ""
    echo "Usage:  $0 [OPTIONS] FQDN"
    echo ""
    echo "Updates Cloudflare DNS A and AAAA records with external IPv4 and IPv6 addresses of the current machine"
    echo ""
    echo "Options:"
    echo "  -q  Enable quiet mode"
    echo "  -t  TTL of records, in seconds"
    echo "  -4  Only update A record with external IPv4 address"
    echo "  -6  Only update A record with external IPv6 address"
    echo ""
    echo "NOTE: A/AAAA records must already exist in Cloudflare for FQDN"
}

QUIET=0
TTL=43200
DO_IPV4=0
DO_IPV6=0

while getopts "qt:46" FLAG
do
    case "$FLAG" in
        q) QUIET=1;;
        t) TTL=${OPTARG};;
        4) DO_IPV4=1;;
        6) DO_IPV6=1;;
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
if [[ "$DO_IPV4" -eq 0 && "$DO_IPV6" -eq 0 ]]; then
    DO_IPV4=1
    DO_IPV6=1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Install it via 'apt install jq'."
    exit 1
fi

if [[ "$DO_IPV4" -ne 0 ]]; then
    # Get the current external IPv4 address
    IPV4=$(curl -fsS -X GET -4 https://ifconfig.co)

    if [[ "$QUIET" -eq 0 ]]; then
        echo "Current IPv4 is $IPV4"
    fi

    # Get the Cloudflare A record
    CF_A_RECORD=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=A&name=$RECORD" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json")

    CF_A_RECORD_IP=$(echo "$CF_A_RECORD" | jq -r '{"result"}[] | .[0] | .content')

    if [[ "$IPV4" == "$CF_A_RECORD_IP" ]]; then
        if [[ "$QUIET" -eq 0 ]]; then
            echo -e "\033[1;33mNo Change: Cloudflare A record is $CF_A_RECORD_IP\033[0m"
        fi
    else
        CF_A_RECORD_ID=$(echo "$CF_A_RECORD" | jq -r '{"result"}[] | .[0] | .id')

        # Update the Cloudflare A record
        curl -fsS -o /dev/null -X PUT "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$CF_A_RECORD_ID" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$RECORD\",\"content\":\"$IPV4\",\"ttl\":\"$TTL\",\"proxied\":false}"

        if [[ "$QUIET" -eq 0 ]]; then
            echo -e "\033[1;35mUpdated: Cloudflare A record updated from $CF_A_RECORD_IP to $IPV4\033[0m"
        fi
    fi

    if [[ -n "$A_HC" ]]; then
        # Ping Healthcheck
        curl -fsS -m 10 --retry 5 -o /dev/null "$A_HC"
    fi
fi

if [[ "$DO_IPV6" -ne 0 ]]; then
    # Get the current external IPv6 address
    IPV6=$(curl -fsS -X GET -6 https://ifconfig.co)

    if [[ "$QUIET" -eq 0 ]]; then
        echo "Current IPv6 is $IPV6"
    fi

    # Get the Cloudflare A record
    CF_AAAA_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=AAAA&name=$RECORD" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json")

    CF_AAAA_RECORD_IP=$(echo "$CF_AAAA_RECORD" | jq -r '{"result"}[] | .[0] | .content')

    if [[ "$IPV6" == "$CF_AAAA_RECORD_IP" ]]; then
        if [[ "$QUIET" -eq 0 ]]; then
            echo -e "\033[1;33mNo Change: Cloudflare AAAA record is $CF_AAAA_RECORD_IP\033[0m"
        fi
    else
        CF_AAAA_RECORD_ID=$(echo "$CF_AAAA_RECORD" | jq -r '{"result"}[] | .[0] | .id')

        # Update Cloudflare AAAA the record
        curl -fsS -o /dev/null -X PUT "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$CF_AAAA_RECORD_ID" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"AAAA\",\"name\":\"$RECORD\",\"content\":\"$IPV6\",\"ttl\":\"$TTL\",\"proxied\":false}"

        if [[ "$QUIET" -eq 0 ]]; then
            echo -e "\033[1;35mUpdated: Cloudflare AAAA record updated from $CF_AAAA_RECORD_IP to $IPV6\033[0m"
        fi
    fi

    if [[ -n "$AAAA_HC" ]]; then
        # Ping Healthcheck
        curl -fsS -m 10 --retry 5 -o /dev/null "$AAAA_HC"
    fi
fi
