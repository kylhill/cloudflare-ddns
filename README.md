# cloudflare-ddns

Updates Cloudflare DNS `A`, `AAAA`, and (optionally) `HTTPS` records with the
external IPv4 / IPv6 addresses of the current machine.

```
Usage:  cloudflare-ddns.sh [OPTIONS] FQDN

Options:
  -h  Print usage help
  -q  Enable quiet mode
  -s  Update HTTPS record with external IPv4 and IPv6 addresses
  -t  TTL of records, in seconds (1 = auto, otherwise 120-86400)
  -4  Only update A record with external IPv4 address
  -6  Only update AAAA record with external IPv6 address
```

## Required environment

| Variable                | Purpose                                       |
| ----------------------- | --------------------------------------------- |
| `CLOUDFLARE_API_TOKEN`  | Scoped Cloudflare API token (Zone:DNS:Edit)   |
| `CLOUDFLARE_ZONE_ID`    | Zone ID containing the record to update       |
| `A_HC` *(optional)*     | Healthchecks.io URL for the A record run      |
| `AAAA_HC` *(optional)*  | Healthchecks.io URL for the AAAA record run   |

## Dependencies

- `bash`, `curl`, `jq`, `flock`
- `sendmail` (optional; used to email a per-run change summary to `root`)
