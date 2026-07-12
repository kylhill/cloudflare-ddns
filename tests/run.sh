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
source_ip=""
data=""
type=""
name_exact=""
url=""
config_file=""

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
        --config)
            config_file="$2"
            shift 2
            ;;
        -4|-6)
            family="$1"
            shift
            ;;
        --interface)
            source_ip="${2#host!}"
            shift 2
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

config_mode=""
[[ -n "$config_file" ]] && config_mode=$(stat -c '%a' "$config_file")
printf 'method=%s family=%s type=%s name_exact=%s url=%s data=%s config=%s mode=%s raw=%s\n' \
    "$method" "$family" "$type" "$name_exact" "$url" "$data" "$config_file" "$config_mode" "$raw" >>"$TEST_CURL_LOG"

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

if [[ "$url" == *cdn-cgi/trace ]]; then
    if [[ -n "$source_ip" ]]; then
        if [[ "${TEST_SCENARIO:-}" == ipv4_mismatch ]]; then
            printf 'ip=1.1.1.1\n'
            exit 0
        fi
        printf 'ip=%s\n' "$source_ip"
        exit 0
    fi
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
    [[ "${TEST_SCENARIO:-}" == no_change_hc_fail ]] && exit 7
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
        api_envelope_failure)
            printf '{"success":false,"errors":[{"code":1000,"message":"HTTP 200 failure fixture"}]}\n'
            ;;
        malformed_api)
            printf '{not-json\n'
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
        proxied_only)
            records_response 1 "[$(json_record A1 198.51.100.42 true 3600)]"
            ;;
        lowercase)
            records_response 1 "[$(json_record A1 198.51.100.42 false 3600)]"
            ;;
        ipv6_iface)
            records_response 1 "[$(json_record AAAA1 2001:db8::42 false 3600)]"
            ;;
        ipv6_equivalent)
            records_response 1 "[$(json_record AAAA1 2001:0DB8:0:0:0:0:0:42 false 3600)]"
            ;;
        ipv6_tie|ipv6_longest)
            records_response 1 "[$(json_record AAAA1 2001:db8::99 false 3600)]"
            ;;
        ipv6_published)
            records_response 1 "[$(json_record AAAA1 2001:db8::42 false 3600)]"
            ;;
        ipv4_iface|ipv4_mismatch|ipv4_ambiguous)
            records_response 1 "[$(json_record A1 8.8.4.4 false 3600)]"
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
        https_preserve_v6)
            if [[ "$type" == AAAA ]]; then
                records_response 1 "[$(json_record AAAA1 2001:db8::1 false 3600)]"
            elif [[ "$type" == HTTPS ]]; then
                jq -nc --arg value 'alpn="h3,h2" port="8443" ipv4hint=198.51.100.9 ipv6hint=2001:db8::1' \
                    '{success:true, result:[{id:"H1", type:"HTTPS", ttl:3600, data:{priority:3, target:"svc6.example.com", value:$value}}], result_info:{count:1, total_count:1, total_pages:1}}'
            else
                records_response 0 '[]'
            fi
            ;;
        https_ttl_only)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.42 false 3600)]"
            else
                records_response 1 "[$(json_https_record H1 'alpn="h3,h2" ipv4hint=198.51.100.42 ipv6hint=2001:db8::1' 120)]"
            fi
            ;;
        https_escape)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.1 false 3600)]"
            else
                records_response 1 "[$(json_https_record H1 'alpn="h3,h2" key654="a\\b" ipv4hint=198.51.100.1' 3600)]"
            fi
            ;;
        batch_all|batch_failure|batch_timeout|batch_count_mismatch|batch_success_errors)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.1 false 3600)]"
            elif [[ "$type" == AAAA ]]; then
                records_response 1 "[$(json_record AAAA1 2001:db8::1 false 3600)]"
            else
                records_response 1 "[$(json_https_record H1 'alpn="h3,h2" ipv4hint=198.51.100.1 ipv6hint=2001:db8::1' 3600)]"
            fi
            ;;
        only_aaaa)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.42 false 3600)]"
            elif [[ "$type" == AAAA ]]; then
                records_response 1 "[$(json_record AAAA1 2001:db8::1 false 3600)]"
            else
                records_response 1 "[$(json_https_record H1 'alpn="h3,h2" ipv4hint=198.51.100.42 ipv6hint=2001:db8::42' 3600)]"
            fi
            ;;
        no_change|no_change_hc_fail)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.42 false 3600)]"
            elif [[ "$type" == AAAA ]]; then
                records_response 1 "[$(json_record AAAA1 2001:db8::42 false 3600)]"
            else
                records_response 1 "[$(json_https_record H1 'alpn="h3,h2" ipv4hint=198.51.100.42 ipv6hint=2001:db8::42' 3600)]"
            fi
            ;;
        mixed_create_update)
            if [[ "$type" == A ]]; then
                records_response 0 '[]'
            else
                records_response 1 "[$(json_record AAAA1 2001:db8::1 false 3600)]"
            fi
            ;;
        duplicate_https)
            if [[ "$type" == A ]]; then
                records_response 1 "[$(json_record A1 198.51.100.42 false 3600)]"
            else
                records_response 2 "[$(json_https_record H1 'alpn="h3"' 3600),$(json_https_record H2 'alpn="h2"' 3600)]"
            fi
            ;;
        *)
            printf 'unknown TEST_SCENARIO: %s\n' "${TEST_SCENARIO:-}" >&2
            exit 64
            ;;
    esac
    exit 0
fi

if [[ "$method" == POST && "$url" == */dns_records/batch ]]; then
    if [[ "${TEST_SCENARIO:-}" == batch_timeout ]]; then
        exit 28
    fi
    if [[ "${TEST_SCENARIO:-}" == batch_failure ]]; then
        printf '{"success":false,"errors":[{"code":1004,"message":"invalid HTTPS fixture"}]}\n'
        exit 0
    fi
    if [[ "${TEST_SCENARIO:-}" == batch_count_mismatch ]]; then
        printf '{"success":true,"errors":[],"result":{"patches":[],"posts":[]}}\n'
        exit 0
    fi
    if [[ "${TEST_SCENARIO:-}" == batch_success_errors ]]; then
        jq -nc --argjson request "$data" \
            '{success:true,errors:[{code:1001,message:"operation warning fixture"}],result:{patches:[$request.patches[]? | {id:.id}],posts:[$request.posts[]? | {id:"created"}]}}'
        exit 0
    fi
    jq -nc --argjson request "$data" \
        '{success:true,result:{patches:[$request.patches[]? | {id:.id}],posts:[$request.posts[]? | {id:"created"}]}}'
    exit 0
fi

printf 'unhandled curl fixture: %s\n' "$raw" >&2
exit 65
EOF

cat >"$MOCKBIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_IP_LOG"
if [[ "${TEST_SCENARIO:-}" == ipv4_ambiguous ]]; then
    printf '[{"addr_info":[{"family":"inet","local":"8.8.4.4","scope":"global","flags":[]},{"family":"inet","local":"1.1.1.1","scope":"global","flags":[]}]}]\n'
elif [[ "$*" == *" -4 "* || "$1" == "-j" && "$2" == "-4" ]]; then
    printf '[{"addr_info":[{"family":"inet","local":"8.8.4.4","scope":"global","flags":[]}]}]\n'
elif [[ "${TEST_SCENARIO:-}" == ipv6_tie ]]; then
    printf '[{"addr_info":[{"family":"inet6","local":"2001:db8::42","scope":"global","flags":[],"preferred_life_time":1800},{"family":"inet6","local":"2001:db8::43","scope":"global","flags":[],"preferred_life_time":1800}]}]\n'
elif [[ "${TEST_SCENARIO:-}" == ipv6_longest || "${TEST_SCENARIO:-}" == ipv6_published ]]; then
    printf '[{"addr_info":[{"family":"inet6","local":"2001:db8::42","scope":"global","flags":[],"preferred_life_time":1800},{"family":"inet6","local":"2001:db8::43","scope":"global","flags":[],"preferred_life_time":3600}]}]\n'
else
    printf '[{"addr_info":[{"family":"inet6","local":"2001:db8::dead","scope":"global","flags":["temporary"],"preferred_life_time":3600},{"family":"inet6","local":"2001:db8::bad","scope":"global","flags":["deprecated"],"preferred_life_time":7200},{"family":"inet6","local":"2001:db8::42","scope":"global","flags":[],"preferred_life_time":1800}]}]\n'
fi
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
    local ipv6_iface="" ipv4_iface=""
    local a_hc="" aaaa_hc=""
    local zone_id="${RUN_ZONE_ID:-0123456789abcdef0123456789abcdef}"
    local api_token="${RUN_API_TOKEN:-test-token}"
    mkdir -p "$runtime_dir"
    [[ "$scenario" == ipv6_iface || "$scenario" == ipv6_tie || "$scenario" == ipv6_longest || "$scenario" == ipv6_published ]] && ipv6_iface="eth0"
    [[ "$scenario" == ipv4_iface || "$scenario" == ipv4_mismatch || "$scenario" == ipv4_ambiguous ]] && ipv4_iface="wan"
    [[ "$scenario" == no_change || "$scenario" == no_change_hc_fail ]] && { a_hc="http://hc.example/a-secret"; aaaa_hc="http://hc.example/aaaa-secret"; }
    PATH="$MOCKBIN:$PATH" \
    TEST_SCENARIO="$scenario" \
    TEST_CURL_LOG="$CURL_LOG" \
    TEST_IP_LOG="$IP_LOG" \
    TEST_SENDMAIL_LOG="$SENDMAIL_LOG" \
    CLOUDFLARE_API_TOKEN="$api_token" \
    CLOUDFLARE_ZONE_ID="$zone_id" \
    A_HC="$a_hc" \
    AAAA_HC="$aaaa_hc" \
    CLOUDFLARE_DDNS_A_SOURCE="${ipv4_iface:+interface:$ipv4_iface}" \
    CLOUDFLARE_DDNS_AAAA_SOURCE="${ipv6_iface:+interface:$ipv6_iface}" \
    RUNTIME_DIRECTORY="$runtime_dir" \
        "$SCRIPT" "$@" >"$output" 2>&1
}

run_script_with_systemd_credentials() {
    local scenario="$1" output="$2"
    shift 2
    local runtime_dir="$TEST_TMP/runtime-$scenario"
    local credentials_dir="$TEST_TMP/credentials-$scenario"
    mkdir -p "$runtime_dir" "$credentials_dir"
    printf 'test-token\n' >"$credentials_dir/cloudflare_api_token"
    printf '0123456789abcdef0123456789abcdef\n' >"$credentials_dir/cloudflare_zone_id"
    PATH="$MOCKBIN:$PATH" \
    TEST_SCENARIO="$scenario" \
    TEST_CURL_LOG="$CURL_LOG" \
    TEST_IP_LOG="$IP_LOG" \
    TEST_SENDMAIL_LOG="$SENDMAIL_LOG" \
    CLOUDFLARE_DDNS_A_SOURCE="external" \
    CLOUDFLARE_DDNS_AAAA_SOURCE="external" \
    CREDENTIALS_DIRECTORY="$credentials_dir" \
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
[[ "$post_line" == *'/dns_records/batch'* ]] || fail "creation did not use batch endpoint"
assert_contains "$CURL_LOG" "raw=-q"
assert_not_contains "$CURL_LOG" "Authorization: Bearer test-token"

reset_logs
credentials_output="$TEST_TMP/systemd credentials are supported.out"
if ! run_script_with_systemd_credentials create_a "$credentials_output" -4 example.com; then
    cat "$credentials_output" >&2
    fail "systemd credentials are supported failed"
fi
assert_contains "$CURL_LOG" "--config"
assert_not_contains "$CURL_LOG" "Authorization: Bearer test-token"
printf 'ok - systemd credentials are supported\n'

expect_failure "GET failure prints response body" get_failure -4 example.com
assert_contains "$TEST_TMP/GET failure prints response body.out" "Cloudflare API request failed while listing A records:"
assert_contains "$TEST_TMP/GET failure prints response body.out" "bad token fixture"

expect_failure "HTTP 200 API failure is rejected" api_envelope_failure -4 example.com
assert_contains "$TEST_TMP/HTTP 200 API failure is rejected.out" "HTTP 200 failure fixture"
assert_not_contains "$CURL_LOG" "/dns_records/batch"

expect_failure "malformed API JSON is rejected" malformed_api -4 example.com
assert_contains "$TEST_TMP/malformed API JSON is rejected.out" "Cloudflare API error"

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
patch_line=$(grep '/dns_records/batch' "$CURL_LOG")
[[ "$patch_line" == *'"ttl":60'* ]] || fail "PATCH payload did not set ttl 60"
[[ "$patch_line" == *'"proxied":false'* ]] || fail "PATCH payload did not disable proxying"
assert_not_contains "$CURL_LOG" '"content":"198.51.100.42"'

expect_success "proxied-only drift patches only proxy state" proxied_only -4 example.com
patch_line=$(grep '/dns_records/batch' "$CURL_LOG")
[[ "$patch_line" == *'"patches":[{"id":"A1","proxied":false}]'* ]] || fail "proxied-only patch was not minimal"

expect_success "invalid provider output falls back" invalid_provider_fallback -4 example.com
assert_contains "$TEST_TMP/invalid provider output falls back.out" "Current IPv4 is 198.51.100.43"

expect_success "invalid IPv6 provider output falls back" invalid_provider_fallback -6 example.com
assert_contains "$TEST_TMP/invalid IPv6 provider output falls back.out" "Current IPv6 is 2001:db8::43"

expect_success "record is lowercased and queried exactly" lowercase -4 Example.COM.
assert_contains "$CURL_LOG" "name_exact=example.com"

expect_success "interface IPv6 skips unstable addresses" ipv6_iface -6 example.com
assert_contains "$TEST_TMP/interface IPv6 skips unstable addresses.out" "Current IPv6 is 2001:db8::42"
assert_contains "$IP_LOG" "-j -6 addr show dev eth0"

expect_success "interface IPv4 is selected and source-bound verified" ipv4_iface -4 example.com
assert_contains "$TEST_TMP/interface IPv4 is selected and source-bound verified.out" "Current IPv4 is 8.8.4.4"
assert_contains "$CURL_LOG" "--interface host!8.8.4.4"

expect_failure "interface IPv4 mismatch fails closed" ipv4_mismatch -4 example.com
assert_contains "$TEST_TMP/interface IPv4 mismatch fails closed.out" "does not match externally observed address"
assert_not_contains "$CURL_LOG" "/dns_records/batch"

expect_failure "ambiguous interface IPv4 fails closed" ipv4_ambiguous -4 example.com
assert_contains "$TEST_TMP/ambiguous interface IPv4 fails closed.out" "found 2"

expect_success "equivalent IPv6 forms do not cause drift" ipv6_equivalent -6 example.com
assert_not_contains "$CURL_LOG" "/dns_records/batch"

expect_failure "equal-lifetime IPv6 candidates fail closed" ipv6_tie -6 example.com
assert_contains "$TEST_TMP/equal-lifetime IPv6 candidates fail closed.out" "equally preferred"

expect_success "longest-lived IPv6 candidate is selected" ipv6_longest -6 example.com
assert_contains "$TEST_TMP/longest-lived IPv6 candidate is selected.out" "Current IPv6 is 2001:db8::43"

expect_success "published preferred IPv6 wins over longer lifetime" ipv6_published -6 example.com
assert_contains "$TEST_TMP/published preferred IPv6 wins over longer lifetime.out" "Current IPv6 is 2001:db8::42"
assert_not_contains "$CURL_LOG" "/dns_records/batch"

expect_success "HTTPS update preserves unrelated SvcParams" https_preserve -4 -s example.com
https_patch=$(grep '/dns_records/batch' "$CURL_LOG" | tail -n 1)
[[ "$https_patch" == *'port=\"8443\"'* ]] || fail "HTTPS payload did not preserve port"
[[ "$https_patch" == *'ech=\"abc\"'* ]] || fail "HTTPS payload did not preserve ech"
[[ "$https_patch" == *'ipv4hint=\"198.51.100.42\"'* ]] || fail "HTTPS payload did not refresh ipv4hint"
[[ "$https_patch" == *'ipv6hint=\"2001:db8::1\"'* ]] || fail "HTTPS payload did not preserve ipv6hint"
[[ "$https_patch" == *'"priority":2'* ]] || fail "HTTPS payload did not preserve priority"
[[ "$https_patch" == *'"target":"svc.example.com"'* ]] || fail "HTTPS payload did not preserve target"

expect_success "IPv6-only HTTPS update preserves IPv4 hint" https_preserve_v6 -6 -s example.com
https_patch=$(grep '/dns_records/batch' "$CURL_LOG" | tail -n 1)
[[ "$https_patch" == *'ipv4hint=\"198.51.100.9\"'* ]] || fail "HTTPS payload did not preserve ipv4hint"
[[ "$https_patch" == *'ipv6hint=\"2001:db8::42\"'* ]] || fail "HTTPS payload did not refresh ipv6hint"

expect_success "HTTPS TTL-only patch omits data" https_ttl_only -4 -s example.com
https_patch=$(grep '/dns_records/batch' "$CURL_LOG")
[[ "$https_patch" == *'"id":"H1","ttl":3600'* ]] || fail "HTTPS TTL patch missing"
[[ "$https_patch" != *'"id":"H1","data"'* ]] || fail "HTTPS TTL-only patch resent data"

expect_failure "HTTPS escapes fail closed" https_escape -4 -s example.com
assert_contains "$TEST_TMP/HTTPS escapes fail closed.out" "escape sequences"
assert_not_contains "$CURL_LOG" "/dns_records/batch"

expect_success "A AAAA and HTTPS changes use one batch" batch_all -s example.com
[[ $(grep -c '/dns_records/batch' "$CURL_LOG") -eq 1 ]] || fail "expected one batch request"
batch_line=$(grep '/dns_records/batch' "$CURL_LOG")
[[ "$batch_line" == *'"id":"A1"'* && "$batch_line" == *'"id":"AAAA1"'* && "$batch_line" == *'"id":"H1"'* ]] || fail "batch omitted a planned record"

expect_success "only AAAA drift produces one patch" only_aaaa -s example.com
batch_line=$(grep '/dns_records/batch' "$CURL_LOG")
[[ "$batch_line" == *'"id":"AAAA1"'* ]] || fail "AAAA patch missing"
[[ "$batch_line" != *'"id":"A1"'* && "$batch_line" != *'"id":"H1"'* ]] || fail "unchanged record was included"

expect_success "no changes skips batch and pings healthchecks" no_change -s example.com
assert_not_contains "$CURL_LOG" "/dns_records/batch"
assert_contains "$CURL_LOG" "http://hc.example/a"
assert_contains "$CURL_LOG" "http://hc.example/aaaa"

expect_success "missing A and changed AAAA share one batch" mixed_create_update example.com
batch_line=$(grep '/dns_records/batch' "$CURL_LOG")
[[ "$batch_line" == *'"posts":[{"type":"A"'* ]] || fail "A post missing from mixed batch"
[[ "$batch_line" == *'"patches":[{"id":"AAAA1"'* ]] || fail "AAAA patch missing from mixed batch"

expect_failure "duplicate HTTPS prevents batch" duplicate_https -4 -s example.com
assert_contains "$TEST_TMP/duplicate HTTPS prevents batch.out" "Found 2 HTTPS records"
assert_not_contains "$CURL_LOG" "/dns_records/batch"

expect_failure "batch operation error reports no completed changes" batch_failure -s example.com
assert_contains "$TEST_TMP/batch operation error reports no completed changes.out" "invalid HTTPS fixture"
assert_not_contains "$TEST_TMP/batch operation error reports no completed changes.out" "Updated A record"
assert_contains "$SENDMAIL_LOG" "Family status: A=attempted, AAAA=attempted"
assert_contains "$SENDMAIL_LOG" "Inspect the systemd journal for detailed errors."

expect_failure "batch timeout is not retried" batch_timeout -s example.com
[[ $(grep -c '/dns_records/batch' "$CURL_LOG") -eq 1 ]] || fail "timed-out batch was retried"
assert_contains "$TEST_TMP/batch timeout is not retried.out" "outcome may be ambiguous"

expect_failure "batch count mismatch is rejected" batch_count_mismatch -s example.com
assert_contains "$TEST_TMP/batch count mismatch is rejected.out" "did not account for every planned operation"

expect_failure "batch success with errors is rejected" batch_success_errors -s example.com
assert_contains "$TEST_TMP/batch success with errors is rejected.out" "operation warning fixture"

expect_success "healthcheck delivery failure is nonfatal and redacted" no_change_hc_fail -s example.com
assert_contains "$TEST_TMP/healthcheck delivery failure is nonfatal and redacted.out" "A healthcheck ping failed"
assert_not_contains "$TEST_TMP/healthcheck delivery failure is nonfatal and redacted.out" "a-secret"

invalid_credential_output="$TEST_TMP/invalid zone id.out"
reset_logs
if RUN_ZONE_ID=not-a-zone-id run_script create_a "$invalid_credential_output" -4 example.com; then
    fail "invalid zone id unexpectedly succeeded"
fi
assert_contains "$invalid_credential_output" "32-character hexadecimal"
assert_not_contains "$CURL_LOG" "https://api.cloudflare.com"
printf 'ok - invalid zone id is rejected before API calls\n'

unsafe_token_output="$TEST_TMP/unsafe token.out"
reset_logs
if RUN_API_TOKEN=$'bad\ntoken' run_script create_a "$unsafe_token_output" -4 example.com; then
    fail "unsafe token unexpectedly succeeded"
fi
assert_contains "$unsafe_token_output" "unsafe for curl configuration"
printf 'ok - unsafe curl-config token is rejected\n'

expect_success "auth config is private and removed" create_a -4 example.com
assert_contains "$CURL_LOG" "mode=600"
auth_path=$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^config=/) {sub(/^config=/,"",$i); print $i; exit}}' "$CURL_LOG")
[[ -n "$auth_path" && ! -e "$auth_path" ]] || fail "temporary auth config was not removed"

printf 'All tests passed.\n'
