# Cloudflare DDNS Agent Instructions

## Overview

Single-file Bash script (`cloudflare-ddns.sh`) that updates Cloudflare DNS `A`, `AAAA`, and optionally `HTTPS` records with the machine's current external IP addresses. Designed to run as a systemd service.

## Dependencies

Runtime: `bash`, `curl`, `jq`, `flock`, `awk`, `tr`. Optional: `sendmail`.

`ip` is required only when `CLOUDFLARE_DDNS_AAAA_IFACE` is set.

No build step or package manager.

## Validation

Run these before finishing script changes:

```bash
bash -n cloudflare-ddns.sh
shellcheck cloudflare-ddns.sh
tests/run.sh
```

Run `bash -n tests/run.sh` after editing the harness itself. The harness is self-contained and mocks `curl`, `ip`, and `sendmail`; it must not contact Cloudflare, Healthchecks.io, or public IP providers.

The harness covers:
- record creation without POST retries
- Cloudflare GET failure body reporting
- duplicate detection from filtered results and multi-page exact-query refusal
- TTL `60` acceptance and PATCH payloads
- lowercase/exact record queries
- invalid IP provider output fallback
- interface-derived IPv6 filtering
- HTTPS SvcParams, priority, and target preservation while refreshing address hints

## Architecture

The script is a single linear flow:

1. **Argument parsing** (`getopts`) → sets `DO_IPV4`, `DO_IPV6`, `DO_HTTPS`, `TTL`, `QUIET`, `RECORD`
2. **Preflight checks** — verifies required commands installed, env vars set, FQDN valid, TTL valid, `RUNTIME_DIRECTORY` set
3. **Single-instance lock** via `flock` on `$RUNTIME_DIRECTORY/<record>.lock` — the script **requires** `RUNTIME_DIRECTORY` to be set (exported by systemd's `RuntimeDirectory=cloudflare-ddns`)
4. **Token verification** — calls `GET /user/tokens/verify`
5. **IP detection** (`get_ip -4|-6`) — tries three providers in order: `cloudflare cdn-cgi/trace`, `icanhazip.com`, `ifconfig.co`
6. **DNS sync** (`sync_host_record`) — GET existing record, then create/PATCH/skip based on IP and TTL comparison
7. **HTTPS record sync** (if `-s`) — preserves existing SvcParams and whichever hint wasn't refreshed this run
8. **Exit trap** — pings `/fail` on Healthchecks.io for any attempted-but-failed family; emails `root` via `sendmail` if any changes were made

## Key Conventions

**Curl profiles** — Four named curl arrays with deliberately different retry policies:
- `CURL_GET`: 5 retries (idempotent)
- `CURL_POST`: no retries (non-idempotent; duplicate records are hard to undo)
- `CURL_PATCH`: 3 retries with `--retry-all-errors` (idempotent)
- `CURL_IP`: tight timeouts, 1 retry (fallback loop handles the rest)

All curl profiles use `-q` to ignore user/global curl config files.

**Mutate calls use `|| true`** — `cf_api_mutate` calls are followed by `|| true` so `set -e` doesn't fire before `check_success` can extract and display the API error body.

**Secrets via environment** — `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` must come from the environment (not the script). The commented-out block at the top is for documentation only; never uncomment and commit real values.

**Duplicate record guard** — If the API returns more than one record for a name+type, the script refuses to update and exits. Fix duplicates in the Cloudflare dashboard first.

**Proxied state preservation** — When updating a host record, `cf_proxied` is read from the existing record and passed back unchanged. Never hardcode `proxied: false` on updates.

**HTTPS record quirks** — HTTPS records must NOT include a `proxied` field in the API payload; the Cloudflare API rejects it. When updating HTTPS records, preserve every existing SvcParam except the `ipv4hint`/`ipv6hint` value intentionally refreshed by the run.

**Color output** — `C_PURPLE`/`C_YELLOW`/`C_RESET` are set only when stdout is a TTY; they're empty strings otherwise. Always wrap color output in `printf` with the variables, never hardcode ANSI codes.

**`qprint`** — Use for informational "no change" messages that should be suppressed with `-q`. Use plain `printf` for change notifications (always shown).
