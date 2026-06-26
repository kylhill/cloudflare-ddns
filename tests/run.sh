#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/cloudflare-ddns.sh"
TEST_TMP=$(mktemp -d)
MOCKBIN="$TEST_TMP/bin"
CURL_LOG="$TEST_TMP/curl.log"
IP_LOG="$TEST_TMP/ip.log"
SENDMAIL_LOG="$TEST_TMP/sendmail.log"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mkdir -p "$MOCKBIN"

cat >"$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=GET
family=""
data=""
type=""
name_exact=""
url=""

raw=""
for arg in "$@"; do
    raw+="${raw:+ }$arg"
done

while (($#)); do
    case "$1" in
        -X)
            method="$2"
            shift 2
            ;;
        --data-binary)
            data="$2"
            shift 2
            ;;
        --data-urlencode)
            case "$2" in
                type=*) type="${2#type=}" ;;
                name.exact=*) name_exact="${2#name.exact=}" ;;
            esac
            shift 2
            ;;
        -4|-6)
            family="$1"
            shift
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

printf 'method=%s family=%s type=%s name_exact=%s url=%s data=%s raw=%s\n' \
    "$method" "$family" "$type" "$name_exact" "$url" "$data" "$raw" >>"$TEST_CURL_LOG"

json_record() {
    local id="$1" content="$2" proxied="$3" ttl="$4"
    jq -nc --arg id "$id" --arg content "$content" --argjson proxied "$proxied" --argjson ttl "$ttl" \
        '{id:$id, content:$content, proxied:$proxied, ttl:$ttl}'
}

json_https_record() {
    local id="$1" value="$2" ttl="$3"
    jq -nc --arg id "$id" --arg value "$value" --argjson ttl "$ttl" \
        '{id:$id, type:"HTTPS", ttl:$ttl, data:{priority:1, target:".", value:$value}}'
}

records_response() {
    local total="$1" result="$2" pages="${3:-1}"
    jq -nc --argjson result "$result" --argjson total "$total" --argjson pages "$pages" \
        '{success:true, result:$result, result_info:{count:($result | length), total_count:$total, total_pages:$pages}}'
}

if [[ "$url" == */user/tokens/verify ]]; then
    printf '{"success":true,"result":{"status":"active"}}\n'
    exit 0
fi

if [[ "$url" == *cdn-cgi/trace ]]; then
    if [[ "${TEST_SCENARIO:-}" == invalid_provider_fallback ]]; then
        case "$family" in
            -4) printf '<html>not an ip</html>\n' ;;
            -6) printf ':::\n' ;;
            *) exit 7 ;;
        esac
        exit 0
    fi
    case "$family" in
        -4) printf 'ip=198.51.100.42\n' ;;
        -6) printf 'ip=2001:db8::42\n' ;;
        *) exit 7 ;;
    esac
    exit 0
fi

if [[ "$url" == *icanhazip.com ]]; then
    case "$family" in
        -4) printf '198.51.100.43\n' ;;
        -6) printf '2001:db8::43\n' ;;
        *) exit 7 ;;
    esac
    exit 0
fi

if [[ "$url" == http://hc.example/* ]]; then
    printf 'ok\n'
    exit 0
fi

if [[ "$method" == GET && "$url" == */dns_records ]]; then
    case "${TEST_SCENARIO:-}" in
        create_a)
            records_response 0 '[]'
            ;;
        get_failure)
            printf '{"success":false,"errors":[{"code":9109,"message":"bad token fixture"}]}\n'
            exit 22
            ;;
        duplicate)
            records_response 2 "[$(json_record A1 198.51.100.42 false 3600),$(json_record A2 198.51.100.43 false 3600)]"
            ;;
        multi_page)
            records_response 100 "[$(json_record A1 198.51.100.42 false 3600)]" 2
            ;;
        broad_total_count)
            records_response 100 "[$(json_record A1 198.51.100.42 false 3600)]"
            ;;
        ttl60)
            records_response 1 "[$(json_record A1 198.51.100.42 true 120)]"
            ;;
        lowercase)
            records_response 1 "[$(json_record A1 198.51.100.42 false 3600)]"
            ;;
        ipv6_iface)
            records_response 1 "[$(json_record AAAA1 2001:db8::42 false 3600)]"
            ;;
        invalid_provider_fallback)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.43 false 3600)]"
            elif [[ "$type" == AAAA ]]; then
                records_response 1 "[$(json_record AAAA1 2001:db8::43 false 3600)]"
            else
                records_response 0 '[]'
            fi
            ;;
        https_preserve)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.1 false 3600)]"
            elif [[ "$type" == HTTPS ]]; then
                jq -nc --arg value 'alpn="h3,h2" port="8443" ech="abc" ipv4hint=198.51.100.1 ipv6hint=2001:db8::1' \
                    '{success:true, result:[{id:"H1", type:"HTTPS", ttl:3600, data:{priority:2, target:"svc.example.com", value:$value}}], result_info:{count:1, total_count:1, total_pages:1}}'
            else
                records_response 0 '[]'
            fi
            ;;
        *)
            printf 'unknown TEST_SCENARIO: %s\n' "${TEST_SCENARIO:-}" >&2
            exit 64
            ;;
    esac
    exit 0
fi

if [[ "$method" == POST || "$method" == PATCH || "$method" == PUT ]]; then
    printf '{"success":true,"result":{"id":"mutated"}}\n'
    exit 0
fi

printf 'unhandled curl fixture: %s\n' "$raw" >&2
exit 65
EOF

cat >"$MOCKBIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_IP_LOG"
cat <<'IPADDR'
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
    inet6 2001:db8::dead/64 scope global temporary dynamic
   valid_lft 3600sec preferred_lft 1800sec
    inet6 2001:db8::bad/64 scope global deprecated dynamic
   valid_lft 3600sec preferred_lft 0sec
    inet6 2001:db8::42/64 scope global dynamic
   valid_lft 3600sec preferred_lft 1800sec
IPADDR
EOF

cat >"$MOCKBIN/sendmail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >>"$TEST_SENDMAIL_LOG"
EOF

chmod +x "$MOCKBIN/curl" "$MOCKBIN/ip" "$MOCKBIN/sendmail"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1" needle="$2"
    grep -F -- "$needle" "$file" >/dev/null || fail "expected '$needle' in $file"
}

assert_not_contains() {
    local file="$1" needle="$2"
    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "did not expect '$needle' in $file"
    fi
}

reset_logs() {
    : >"$CURL_LOG"
    : >"$IP_LOG"
    : >"$SENDMAIL_LOG"
}

run_script() {
    local scenario="$1" output="$2"
    shift 2
    local runtime_dir="$TEST_TMP/runtime-$scenario"
    local ipv6_iface=""
    mkdir -p "$runtime_dir"
    [[ "$scenario" == ipv6_iface ]] && ipv6_iface="eth0"
    PATH="$MOCKBIN:$PATH" \
    TEST_SCENARIO="$scenario" \
    TEST_CURL_LOG="$CURL_LOG" \
    TEST_IP_LOG="$IP_LOG" \
    TEST_SENDMAIL_LOG="$SENDMAIL_LOG" \
    CLOUDFLARE_API_TOKEN="test-token" \
    CLOUDFLARE_ZONE_ID="test-zone" \
    CLOUDFLARE_DDNS_AAAA_IFACE="$ipv6_iface" \
    RUNTIME_DIRECTORY="$runtime_dir" \
        "$SCRIPT" "$@" >"$output" 2>&1
}

expect_success() {
    local name="$1" scenario="$2"
    shift 2
    local output="$TEST_TMP/$name.out"
    reset_logs
    if ! run_script "$scenario" "$output" "$@"; then
        cat "$output" >&2
        fail "$name failed"
    fi
    printf 'ok - %s\n' "$name"
}

expect_failure() {
    local name="$1" scenario="$2"
    shift 2
    local output="$TEST_TMP/$name.out"
    reset_logs
    if run_script "$scenario" "$output" "$@"; then
        cat "$output" >&2
        fail "$name unexpectedly succeeded"
    fi
    printf 'ok - %s\n' "$name"
}

expect_success "create A does not retry POST" create_a -4 example.com
post_line=$(grep 'method=POST' "$CURL_LOG")
[[ $(grep -c 'method=POST' "$CURL_LOG") -eq 1 ]] || fail "expected exactly one POST"
[[ "$post_line" != *"--retry"* ]] || fail "POST curl command included --retry"
assert_contains "$CURL_LOG" "raw=-q"

expect_failure "GET failure prints response body" get_failure -4 example.com
assert_contains "$TEST_TMP/GET failure prints response body.out" "Cloudflare API request failed while listing A records:"
assert_contains "$TEST_TMP/GET failure prints response body.out" "bad token fixture"

expect_failure "duplicate count uses filtered result length" duplicate -4 example.com
assert_contains "$TEST_TMP/duplicate count uses filtered result length.out" "Found 2 A records"
assert_not_contains "$CURL_LOG" "method=PATCH"
assert_not_contains "$CURL_LOG" "method=POST"

expect_failure "multi-page exact record query is refused" multi_page -4 example.com
assert_contains "$TEST_TMP/multi-page exact record query is refused.out" "Found more than one page of A records"
assert_not_contains "$CURL_LOG" "method=PATCH"
assert_not_contains "$CURL_LOG" "method=POST"

expect_success "broad total_count does not cause duplicate failure" broad_total_count -4 example.com
assert_not_contains "$CURL_LOG" "method=PATCH"
assert_not_contains "$CURL_LOG" "method=POST"

expect_success "TTL 60 is accepted and patched" ttl60 -4 -t 60 example.com
patch_line=$(grep 'method=PATCH' "$CURL_LOG")
[[ "$patch_line" == *'"ttl":60'* ]] || fail "PATCH payload did not set ttl 60"
[[ "$patch_line" == *'"proxied":true'* ]] || fail "PATCH payload did not preserve proxied"

expect_success "invalid provider output falls back" invalid_provider_fallback -4 example.com
assert_contains "$TEST_TMP/invalid provider output falls back.out" "Current IPv4 is 198.51.100.43"

expect_success "invalid IPv6 provider output falls back" invalid_provider_fallback -6 example.com
assert_contains "$TEST_TMP/invalid IPv6 provider output falls back.out" "Current IPv6 is 2001:db8::43"

expect_success "record is lowercased and queried exactly" lowercase -4 Example.COM.
assert_contains "$CURL_LOG" "name_exact=example.com"

expect_success "interface IPv6 skips unstable addresses" ipv6_iface -6 example.com
assert_contains "$TEST_TMP/interface IPv6 skips unstable addresses.out" "Current IPv6 is 2001:db8::42"
assert_contains "$IP_LOG" "-6 addr show dev eth0 scope global"

expect_success "HTTPS update preserves unrelated SvcParams" https_preserve -4 -s example.com
https_patch=$(grep 'method=PATCH' "$CURL_LOG" | tail -n 1)
[[ "$https_patch" == *'port=\"8443\"'* ]] || fail "HTTPS payload did not preserve port"
[[ "$https_patch" == *'ech=\"abc\"'* ]] || fail "HTTPS payload did not preserve ech"
[[ "$https_patch" == *'ipv4hint=\"198.51.100.42\"'* ]] || fail "HTTPS payload did not refresh ipv4hint"
[[ "$https_patch" == *'ipv6hint=\"2001:db8::1\"'* ]] || fail "HTTPS payload did not preserve ipv6hint"
[[ "$https_patch" == *'"priority":2'* ]] || fail "HTTPS payload did not preserve priority"
[[ "$https_patch" == *'"target":"svc.example.com"'* ]] || fail "HTTPS payload did not preserve target"

printf 'All tests passed.\n'
