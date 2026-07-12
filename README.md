# cloudflare-ddns

Updates Cloudflare DNS `A`, `AAAA`, and (optionally) `HTTPS` records with the
external IPv4 / IPv6 addresses of the current machine.

```
Usage:  cloudflare-ddns.sh [OPTIONS] FQDN

Options:
  -h  Print usage help
  -q  Enable quiet mode
  -s  Update HTTPS record with external IPv4 and IPv6 addresses
  -t  TTL of records, in seconds (1 = auto, otherwise 60-86400)
  -4  Only update A record with external IPv4 address
  -6  Only update AAAA record with external IPv6 address
```

## Required variables

| Variable                | Purpose                                       |
| ----------------------- | --------------------------------------------- |
| `CLOUDFLARE_API_TOKEN`  | Scoped Cloudflare API token (Zone:DNS:Edit)   |
| `CLOUDFLARE_ZONE_ID`    | Zone ID containing the record to update       |
| `CLOUDFLARE_DDNS_A_SOURCE` | IPv4 source: `external` or `interface:<name>` |
| `CLOUDFLARE_DDNS_AAAA_SOURCE` | IPv6 source: `external` or `interface:<name>` |
| `A_HC` *(optional)*     | Healthchecks.io URL for the A record run      |
| `AAAA_HC` *(optional)*  | Healthchecks.io URL for the AAAA record run   |

`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` can be provided as environment
variables or as systemd credentials named `cloudflare_api_token` and
`cloudflare_zone_id`.

The zone ID must be its 32-character hexadecimal Cloudflare identifier. API
tokens and credential files must contain a single token value without embedded
newlines or curl-config quoting characters.

Both address-source variables default to `external`. Interface mode selects a
public address from the named interface and verifies it with a source-bound
external request before changing DNS. For example:

```sh
CLOUDFLARE_DDNS_A_SOURCE=interface:wan
CLOUDFLARE_DDNS_AAAA_SOURCE=interface:lan
```

The script fetches and validates every requested record first, plans all A,
AAAA, and HTTPS changes, and submits them through one Cloudflare DNS batch
request. If nothing changed, it skips the batch request. A lost batch response
is not retried automatically because the outcome may be ambiguous.

## Dependencies

- `bash`, `curl`, `jq`, `flock`, `awk`, `tr`
- `ip` when either address source uses `interface:<name>`
- `sendmail` (optional; used to email a per-run change summary to `root`)

## Validation

```sh
bash -n cloudflare-ddns.sh
shellcheck cloudflare-ddns.sh
tests/run.sh
```

The test harness mocks external commands and does not contact Cloudflare or IP
lookup providers.
