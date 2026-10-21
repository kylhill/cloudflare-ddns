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

## Configuration variables

| Variable                | Purpose                                       |
| ----------------------- | --------------------------------------------- |
| `CLOUDFLARE_API_TOKEN`  | Scoped Cloudflare API token (Zone:DNS:Edit)   |
| `CLOUDFLARE_ZONE_ID`    | Zone ID containing the record to update       |
| `CLOUDFLARE_DDNS_A_SOURCE` | IPv4 source: `external` or `interface:<name>` |
| `CLOUDFLARE_DDNS_AAAA_SOURCE` | IPv6 source: `external` or `interface:<name>` |
| `A_HC` *(optional)*     | Monitoring ping URL for the A record run      |
| `AAAA_HC` *(optional)*  | Monitoring ping URL for the AAAA record run   |
| `CLOUDFLARE_DDNS_HEALTHCHECK_PROVIDER` | `healthchecks` (default) or `uptime-kuma` |

`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` can be provided as environment
variables or as systemd credentials named `cloudflare_api_token` and
`cloudflare_zone_id`.

Supply monitoring URLs using credentials named `cloudflare_a_healthcheck` and
`cloudflare_aaaa_healthcheck`. Environment variables `A_HC` and `AAAA_HC` remain
supported and take precedence, but credentials keep bearer URLs out of unit
files and service environments. Monitoring URLs also stay out of curl's
command line. Percent-encoded query parameters are preserved literally.

For Uptime Kuma push URLs, set `CLOUDFLARE_DDNS_HEALTHCHECK_PROVIDER=uptime-kuma`.
The script sets `status=up` on success and `status=down` on failure, preserving
other query parameters. For Healthchecks.io, failures use the `/fail` path.
Monitoring delivery failures are logged without exposing the URL and do not
change the DNS reconciliation result.

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

The batch is transactional in Cloudflare's database, but propagation through
Cloudflare's distributed DNS network is not atomic. Resolvers can temporarily
observe a mixture of old and new A, AAAA, and HTTPS data after a successful
update.

New HTTPS records contain address hints only; the script does not assume
support for HTTP/2 or HTTP/3. Existing SvcParams, including an empty value, are
preserved except for the selected address hints. HTTPS AliasMode records
(priority 0) are refused before any batch is submitted because clients ignore
their address hints; manage the referenced service endpoint instead.

## Dependencies

- Bash 4 or newer
- curl 7.76 or newer, `jq`, and `flock`
- Standard system utilities: `awk`, `tr`, `mktemp`, `rm`, `head`,
  `hostname`, and `date`
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

## Example systemd units

The repository includes [cloudflare-ddns.service](cloudflare-ddns.service) and
[cloudflare-ddns.timer](cloudflare-ddns.timer), adapted from the deployment
units used by the accompanying infrastructure role. Before installing them:

1. Replace `host.example.com` in `ExecStart` with the record to update and
   adjust the flags, TTL, address sources, and optional healthcheck URLs.
2. Store the token and zone ID in `/etc/cloudflare-ddns/api-token` and
   `/etc/cloudflare-ddns/zone-id`, owned by root with mode `0400`.
   For monitoring, store each URL in `/etc/cloudflare-ddns/a-healthcheck` or
   `/etc/cloudflare-ddns/aaaa-healthcheck` with the same ownership and mode,
   and enable the corresponding `LoadCredential=` lines in the service.
3. Install the script at `/usr/local/bin/cloudflare-ddns.sh` and the units under
   `/etc/systemd/system/`, then enable `cloudflare-ddns.timer`.

The service waits for `network-online.target` at boot and retries failed runs
after two minutes, allowing at most three starts within thirty minutes. Each
run fetches current DNS state before planning changes; the batch POST itself
is never retried. Once the start limit expires, the regular timer can start
the service again.
