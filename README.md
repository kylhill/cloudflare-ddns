# cloudflare-ddns
```
Usage:  ./cloudflare-ddns.sh [OPTIONS] FQDN

Updates Cloudflare DNS A and AAAA records with external IPv4 and IPv6 addresses of the current machine

Options:
  -q  Enable quiet mode
  -t  TTL of records, in seconds
  -4  Only update A record with external IPv4 address
  -6  Only update A record with external IPv6 address

NOTE: A/AAAA records must already exist in Cloudflare for FQDN
```
