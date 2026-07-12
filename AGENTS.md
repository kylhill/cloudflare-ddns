# Cloudflare DDNS Agent Instructions

## Overview

Single-file Bash script (`cloudflare-ddns.sh`) that updates Cloudflare DNS `A`, `AAAA`, and optionally `HTTPS` records with the machine's current external IP addresses. Designed to run as a systemd service.

## Dependencies

Runtime: `bash`, `curl`, `jq`, `flock`, `awk`, `tr`. Optional: `sendmail`.

`ip` is required only when `CLOUDFLARE_DDNS_A_SOURCE` or
`CLOUDFLARE_DDNS_AAAA_SOURCE` uses `interface:<name>`.

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
- transactional batch planning and submission without POST retries
- Cloudflare GET failure body reporting
- duplicate detection from filtered results and multi-page exact-query refusal
- TTL `60` acceptance and PATCH payloads
- lowercase/exact record queries
- invalid IP provider output fallback
- interface-derived IPv6 filtering
- HTTPS SvcParams, priority, and target preservation while refreshing address hints
- mixed batch POST/PATCH operations, no-op runs, batch failures, and partial-family hint preservation

## Architecture

The script is a single linear flow:

1. **Argument parsing** (`getopts`) → sets `DO_IPV4`, `DO_IPV6`, `DO_HTTPS`, `TTL`, `QUIET`, `RECORD`
2. **Preflight checks** — verifies required commands installed, env vars set, FQDN valid, TTL valid, `RUNTIME_DIRECTORY` set
3. **Credential loading** — reads `CLOUDFLARE_API_TOKEN`/`CLOUDFLARE_ZONE_ID` from the environment, or from systemd credentials in `$CREDENTIALS_DIRECTORY`
4. **Single-instance lock** via `flock` on `$RUNTIME_DIRECTORY/<record>.lock` — the script **requires** `RUNTIME_DIRECTORY` to be set (exported by systemd's `RuntimeDirectory=cloudflare-ddns`)
5. **Token verification** — calls `GET /user/tokens/verify`
6. **Record fetch** — fetches and duplicate-checks all requested A, AAAA, and HTTPS records before planning changes
7. **IP detection** (`get_ip -4|-6` or interface selection) — discovers and validates every requested address
8. **Batch planning** — builds minimal `patches` and complete `posts` arrays without mutating Cloudflare
9. **Batch submission** — sends at most one non-retried `POST /dns_records/batch`, then validates the complete response before reporting success
10. **Exit trap** — pings `/fail` on Healthchecks.io for any attempted-but-failed family; emails `root` via `sendmail` for changes or failures

## Key Conventions

**Curl profiles** — Three named curl arrays with deliberately different retry policies:
- `CURL_GET`: 5 retries (idempotent)
- `CURL_POST`: no retries (the batch outcome can be ambiguous if its response is lost)
- `CURL_IP`: tight timeouts, 1 retry (fallback loop handles the rest)

All curl profiles use `-q` to ignore user/global curl config files.

**Single batch mutation** — planners must never call Cloudflare mutation endpoints. All required changes go into one `patches`/`posts` payload sent through the DNS batch endpoint.

**Secrets via environment or systemd credentials** — `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` may come from the environment, or from systemd credential files named `cloudflare_api_token` and `cloudflare_zone_id` under `$CREDENTIALS_DIRECTORY`. The commented-out block at the top is for documentation only; never uncomment and commit real values.

**Duplicate record guard** — If the API returns more than one record for a name+type, the script refuses to update and exits. Fix duplicates in the Cloudflare dashboard first.

**DNS-only host records** — A and AAAA records must reconcile to `proxied:false`; a proxied-state mismatch is managed drift and belongs in the minimal batch PATCH.

**HTTPS record quirks** — HTTPS records must NOT include a `proxied` field in the API payload; the Cloudflare API rejects it. When updating HTTPS records, preserve every existing SvcParam except the `ipv4hint`/`ipv6hint` value intentionally refreshed by the run.

**Color output** — `C_PURPLE`/`C_YELLOW`/`C_RESET` are set only when stdout is a TTY; they're empty strings otherwise. Always wrap color output in `printf` with the variables, never hardcode ANSI codes.

**`qprint`** — Use for informational "no change" messages that should be suppressed with `-q`. Use plain `printf` for change notifications (always shown).
