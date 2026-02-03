#!/usr/bin/env bash
# Extreme Comprehensive Benchmark - All scenarios with 300+ stubs
# Shows the dramatic performance difference when many stubs must be traversed
# Usage: ./benchmark-extreme-comprehensive.sh [--no-color]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEMO_DIR"

RIFT_ADMIN="http://127.0.0.1:2525"
MB_ADMIN="http://127.0.0.1:3525"

STUBS=${STUBS:-300}
REQUESTS=${REQUESTS:-2000}
CONCURRENCY=${CONCURRENCY:-200}
# MB_REQUESTS: Mountebank requests (defaults to CONCURRENCY, must be >= CONCURRENCY)
# Override with: MB_REQUESTS=500 ./benchmark-extreme-comprehensive.sh
MB_REQUESTS=${MB_REQUESTS:-$CONCURRENCY}
if [ "$MB_REQUESTS" -lt "$CONCURRENCY" ]; then
    MB_REQUESTS=$CONCURRENCY
fi

# Check for --no-color flag
NO_COLOR=false
for arg in "$@"; do
    if [ "$arg" = "--no-color" ]; then
        NO_COLOR=true
    fi
done

# Colors (disabled with --no-color flag)
if [ "$NO_COLOR" = true ]; then
    RED='' GREEN='' BLUE='' YELLOW='' CYAN='' BOLD='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# Results storage
SIMPLE_RIFT="" SIMPLE_MB="" SIMPLE_SPEEDUP=""
JSONPATH_RIFT="" JSONPATH_MB="" JSONPATH_SPEEDUP=""
XPATH_RIFT="" XPATH_MB="" XPATH_SPEEDUP=""
COMPLEX_RIFT="" COMPLEX_MB="" COMPLEX_SPEEDUP=""
REGEX_RIFT="" REGEX_MB="" REGEX_SPEEDUP=""

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

check_ab() {
    if ! command -v ab &> /dev/null; then
        echo -e "${RED}Error: Apache Bench (ab) is not installed${NC}"
        echo "Install with: brew install httpd (macOS) or apt install apache2-utils (Linux)"
        exit 1
    fi
}

generate_stubs_simple() {
    local count=$1
    local match_path=$2
    local stubs=""

    for i in $(seq 1 $((count - 1))); do
        stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/nomatch-$i\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"$match_path\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"matched\"}}]}"
    echo "$stubs"
}

generate_stubs_jsonpath() {
    local count=$1
    local stubs=""

    for i in $(seq 1 $((count - 1))); do
        stubs="$stubs{\"predicates\":[{\"equals\":{\"body\":\"nomatch-$i\"},\"jsonpath\":{\"selector\":\"\$.user.id\"}},{\"equals\":{\"body\":\"extra-$i\"},\"jsonpath\":{\"selector\":\"\$.user.name\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    stubs="$stubs{\"predicates\":[{\"equals\":{\"body\":\"premium\"},\"jsonpath\":{\"selector\":\"\$.subscription.plan\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"matched\"}}]}"
    echo "$stubs"
}

generate_stubs_xpath() {
    local count=$1
    local stubs=""

    for i in $(seq 1 $((count - 1))); do
        stubs="$stubs{\"predicates\":[{\"equals\":{\"body\":\"nomatch-$i\"},\"xpath\":{\"selector\":\"//user/id\"}},{\"equals\":{\"body\":\"extra-$i\"},\"xpath\":{\"selector\":\"//user/name\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    stubs="$stubs{\"predicates\":[{\"equals\":{\"body\":\"active\"},\"xpath\":{\"selector\":\"//status\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"matched\"}}]}"
    echo "$stubs"
}

generate_stubs_complex() {
    local count=$1
    local stubs=""

    for i in $(seq 1 $((count - 1))); do
        stubs="$stubs{\"predicates\":[{\"and\":[{\"equals\":{\"method\":\"POST\"}},{\"or\":[{\"contains\":{\"path\":\"/nomatch-$i\"}},{\"contains\":{\"path\":\"/also-no-$i\"}}]},{\"exists\":{\"headers\":{\"X-No-$i\":true}}}]}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    stubs="$stubs{\"predicates\":[{\"and\":[{\"equals\":{\"method\":\"POST\"}},{\"or\":[{\"contains\":{\"path\":\"/api/v1\"}},{\"contains\":{\"path\":\"/api/v2\"}}]},{\"or\":[{\"contains\":{\"body\":\"premium\"}},{\"contains\":{\"body\":\"enterprise\"}}]},{\"exists\":{\"headers\":{\"Authorization\":true}}}]}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"matched\"}}]}"
    echo "$stubs"
}

generate_stubs_regex() {
    local count=$1
    local stubs=""

    for i in $(seq 1 $((count - 1))); do
        stubs="$stubs{\"predicates\":[{\"matches\":{\"path\":\"^/nomatch-$i/[0-9]+\$\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    stubs="$stubs{\"predicates\":[{\"matches\":{\"path\":\"^/api/v[0-9]+/users/[a-f0-9-]+\$\"}},{\"matches\":{\"body\":\"email.*@.*\\\\.com\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"matched\"}}]}"
    echo "$stubs"
}

setup_imposters() {
    echo ""
    echo -e "${CYAN}Cleaning up existing imposters...${NC}"
    for port in 7001 7002 7003 7004 7005; do
        curl -s -X DELETE "$RIFT_ADMIN/imposters/$port" > /dev/null 2>&1 || true
        curl -s -X DELETE "$MB_ADMIN/imposters/$port" > /dev/null 2>&1 || true
    done
    sleep 1

    echo -e "${CYAN}Setting up imposters with $STUBS stubs each...${NC}"
    echo ""

    # Temp file for JSON payloads (avoids shell escaping issues)
    local tmpfile="/tmp/rift_imposter_$$.json"

    # 1. Simple
    echo -n "  1. Simple equals ($STUBS stubs)... "
    local simple_stubs=$(generate_stubs_simple $STUBS "/health")
    echo "{\"port\":7001,\"protocol\":\"http\",\"stubs\":[$simple_stubs]}" > "$tmpfile"
    local rift_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    local mb_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # 2. JSONPath
    echo -n "  2. JSONPath ($STUBS stubs × 2 predicates)... "
    local jsonpath_stubs=$(generate_stubs_jsonpath $STUBS)
    echo "{\"port\":7002,\"protocol\":\"http\",\"stubs\":[$jsonpath_stubs]}" > "$tmpfile"
    rift_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    mb_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # 3. XPath
    echo -n "  3. XPath ($STUBS stubs × 2 predicates)... "
    local xpath_stubs=$(generate_stubs_xpath $STUBS)
    echo "{\"port\":7003,\"protocol\":\"http\",\"stubs\":[$xpath_stubs]}" > "$tmpfile"
    rift_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    mb_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # 4. Complex AND/OR
    echo -n "  4. Complex AND/OR ($STUBS stubs × 3 predicates)... "
    local complex_stubs=$(generate_stubs_complex $STUBS)
    echo "{\"port\":7004,\"protocol\":\"http\",\"stubs\":[$complex_stubs]}" > "$tmpfile"
    rift_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    mb_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # 5. Regex
    echo -n "  5. Regex ($STUBS stubs × 2 predicates)... "
    local regex_stubs=$(generate_stubs_regex $STUBS)
    echo "{\"port\":7005,\"protocol\":\"http\",\"stubs\":[$regex_stubs]}" > "$tmpfile"
    rift_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    mb_resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    echo -e "${GREEN}All imposters created${NC}"

    # Clean up temp file
    rm -f "$tmpfile"

    # Verify imposters are responding
    echo ""
    echo -e "${CYAN}Verifying imposters respond...${NC}"
    sleep 1
    local all_ok=true
    echo -n "  Rift ports 7001-7005: "
    for port in 7001 7002 7003 7004 7005; do
        local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null)
        if [ "$code" != "200" ]; then
            echo -e "${RED}Port $port FAILED (HTTP $code)${NC}"
            all_ok=false
            break
        fi
    done
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}OK${NC}"
    fi

    all_ok=true
    echo -n "  Mountebank ports 17001-17005: "
    for port in 17001 17002 17003 17004 17005; do
        local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null)
        if [ "$code" != "200" ]; then
            echo -e "${RED}Port $port FAILED (HTTP $code)${NC}"
            all_ok=false
            break
        fi
    done
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}OK${NC}"
    fi
}

cleanup_imposters() {
    echo ""
    echo "Cleaning up..."
    for port in 7001 7002 7003 7004 7005; do
        curl -s -X DELETE "$RIFT_ADMIN/imposters/$port" > /dev/null 2>&1 || true
        curl -s -X DELETE "$MB_ADMIN/imposters/$port" > /dev/null 2>&1 || true
    done
}

run_all_benchmarks() {
    # Test files
    local jsonpath_body="/tmp/extreme_jsonpath.json"
    echo '{"user":{"id":123,"name":"Test"},"subscription":{"plan":"premium"}}' > "$jsonpath_body"

    local xpath_body="/tmp/extreme_xpath.xml"
    echo '<?xml version="1.0"?><root><user><id>123</id><name>Test</name></user><status>active</status></root>' > "$xpath_body"

    local complex_body="/tmp/extreme_complex.json"
    echo '{"type":"premium","data":"test"}' > "$complex_body"

    local regex_body="/tmp/extreme_regex.json"
    echo '{"email":"john@example.com"}' > "$regex_body"

    # 1. Simple
    print_header "1. SIMPLE EQUALS ($STUBS stubs)"
    echo "Match at stub #$STUBS (worst case linear scan)"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    local rift_out=$(ab -n $REQUESTS -c $CONCURRENCY "http://127.0.0.1:7001/health" 2>&1)
    SIMPLE_RIFT=$(echo "$rift_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local rift_latency=$(echo "$rift_out" | grep "Time per request" | head -1 | awk '{print $4}')
    local rift_failed=$(echo "$rift_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${GREEN}${BOLD}$SIMPLE_RIFT${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${rift_failed:-0}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($MB_REQUESTS requests, $CONCURRENCY concurrent):"
    local mb_out=$(ab -n $MB_REQUESTS -c $CONCURRENCY "http://127.0.0.1:17001/health" 2>&1)
    SIMPLE_MB=$(echo "$mb_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local mb_latency=$(echo "$mb_out" | grep "Time per request" | head -1 | awk '{print $4}')
    local mb_failed=$(echo "$mb_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${YELLOW}$SIMPLE_MB${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${mb_failed:-0}"
    if [ -n "$SIMPLE_RIFT" ] && [ -n "$SIMPLE_MB" ] && [ "$SIMPLE_MB" -gt 0 ] 2>/dev/null; then
        SIMPLE_SPEEDUP=$((SIMPLE_RIFT / SIMPLE_MB))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${SIMPLE_SPEEDUP}x faster${NC}"
    fi

    # 2. JSONPath
    print_header "2. JSONPATH ($STUBS stubs × 2 predicates = $((STUBS * 2)) evals)"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_out=$(ab -n $REQUESTS -c $CONCURRENCY -p "$jsonpath_body" -T "application/json" "http://127.0.0.1:7002/" 2>&1)
    JSONPATH_RIFT=$(echo "$rift_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    rift_latency=$(echo "$rift_out" | grep "Time per request" | head -1 | awk '{print $4}')
    rift_failed=$(echo "$rift_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${GREEN}${BOLD}$JSONPATH_RIFT${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${rift_failed:-0}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($MB_REQUESTS requests, $CONCURRENCY concurrent):"
    mb_out=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$jsonpath_body" -T "application/json" "http://127.0.0.1:17002/" 2>&1)
    JSONPATH_MB=$(echo "$mb_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    mb_latency=$(echo "$mb_out" | grep "Time per request" | head -1 | awk '{print $4}')
    mb_failed=$(echo "$mb_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${YELLOW}$JSONPATH_MB${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${mb_failed:-0}"
    if [ -n "$JSONPATH_RIFT" ] && [ -n "$JSONPATH_MB" ] && [ "$JSONPATH_MB" -gt 0 ] 2>/dev/null; then
        JSONPATH_SPEEDUP=$((JSONPATH_RIFT / JSONPATH_MB))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${JSONPATH_SPEEDUP}x faster${NC}"
    fi

    # 3. XPath
    print_header "3. XPATH ($STUBS stubs × 2 predicates = $((STUBS * 2)) evals)"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_out=$(ab -n $REQUESTS -c $CONCURRENCY -p "$xpath_body" -T "application/xml" "http://127.0.0.1:7003/" 2>&1)
    XPATH_RIFT=$(echo "$rift_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    rift_latency=$(echo "$rift_out" | grep "Time per request" | head -1 | awk '{print $4}')
    rift_failed=$(echo "$rift_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${GREEN}${BOLD}$XPATH_RIFT${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${rift_failed:-0}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($MB_REQUESTS requests, $CONCURRENCY concurrent):"
    mb_out=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$xpath_body" -T "application/xml" "http://127.0.0.1:17003/" 2>&1)
    XPATH_MB=$(echo "$mb_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    mb_latency=$(echo "$mb_out" | grep "Time per request" | head -1 | awk '{print $4}')
    mb_failed=$(echo "$mb_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${YELLOW}$XPATH_MB${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${mb_failed:-0}"
    if [ -n "$XPATH_RIFT" ] && [ -n "$XPATH_MB" ] && [ "$XPATH_MB" -gt 0 ] 2>/dev/null; then
        XPATH_SPEEDUP=$((XPATH_RIFT / XPATH_MB))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${XPATH_SPEEDUP}x faster${NC}"
    fi

    # 4. Complex AND/OR
    print_header "4. COMPLEX AND/OR ($STUBS stubs × 3 predicates)"
    echo "Nested: AND(method, OR(path), OR(body), exists(header))"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_out=$(ab -n $REQUESTS -c $CONCURRENCY -p "$complex_body" -T "application/json" -H "Authorization: Bearer token" "http://127.0.0.1:7004/api/v1/test" 2>&1)
    COMPLEX_RIFT=$(echo "$rift_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    rift_latency=$(echo "$rift_out" | grep "Time per request" | head -1 | awk '{print $4}')
    rift_failed=$(echo "$rift_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${GREEN}${BOLD}$COMPLEX_RIFT${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${rift_failed:-0}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($MB_REQUESTS requests, $CONCURRENCY concurrent):"
    mb_out=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$complex_body" -T "application/json" -H "Authorization: Bearer token" "http://127.0.0.1:17004/api/v1/test" 2>&1)
    COMPLEX_MB=$(echo "$mb_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    mb_latency=$(echo "$mb_out" | grep "Time per request" | head -1 | awk '{print $4}')
    mb_failed=$(echo "$mb_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${YELLOW}$COMPLEX_MB${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${mb_failed:-0}"
    if [ -n "$COMPLEX_RIFT" ] && [ -n "$COMPLEX_MB" ] && [ "$COMPLEX_MB" -gt 0 ] 2>/dev/null; then
        COMPLEX_SPEEDUP=$((COMPLEX_RIFT / COMPLEX_MB))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${COMPLEX_SPEEDUP}x faster${NC}"
    fi

    # 5. Regex
    print_header "5. REGEX ($STUBS stubs × 2 predicates)"
    echo "Complex patterns: UUID path + email body"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_out=$(ab -n $REQUESTS -c $CONCURRENCY -p "$regex_body" -T "application/json" "http://127.0.0.1:7005/api/v1/users/550e8400-e29b-41d4-a716-446655440000" 2>&1)
    REGEX_RIFT=$(echo "$rift_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    rift_latency=$(echo "$rift_out" | grep "Time per request" | head -1 | awk '{print $4}')
    rift_failed=$(echo "$rift_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${GREEN}${BOLD}$REGEX_RIFT${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${rift_failed:-0}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($MB_REQUESTS requests, $CONCURRENCY concurrent):"
    mb_out=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$regex_body" -T "application/json" "http://127.0.0.1:17005/api/v1/users/550e8400-e29b-41d4-a716-446655440000" 2>&1)
    REGEX_MB=$(echo "$mb_out" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    mb_latency=$(echo "$mb_out" | grep "Time per request" | head -1 | awk '{print $4}')
    mb_failed=$(echo "$mb_out" | grep "Failed requests" | awk '{print $3}')
    echo -e "    Requests/sec: ${YELLOW}$REGEX_MB${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC} (mean)"
    echo -e "    Failed:       ${mb_failed:-0}"
    if [ -n "$REGEX_RIFT" ] && [ -n "$REGEX_MB" ] && [ "$REGEX_MB" -gt 0 ] 2>/dev/null; then
        REGEX_SPEEDUP=$((REGEX_RIFT / REGEX_MB))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${REGEX_SPEEDUP}x faster${NC}"
    fi

    rm -f "$jsonpath_body" "$xpath_body" "$complex_body" "$regex_body"
}

print_summary() {
    print_header "SUMMARY - $STUBS STUBS × MULTIPLE PREDICATES"
    echo ""
    echo "┌────────────────────────────┬────────────┬────────────┬──────────┐"
    echo "│ Scenario                   │ Rift       │ Mountebank │ Speedup  │"
    echo "├────────────────────────────┼────────────┼────────────┼──────────┤"
    printf "│ 1. Simple Equals           │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$SIMPLE_RIFT" "$SIMPLE_MB" "$SIMPLE_SPEEDUP"
    printf "│ 2. JSONPath (×2 preds)     │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$JSONPATH_RIFT" "$JSONPATH_MB" "$JSONPATH_SPEEDUP"
    printf "│ 3. XPath (×2 preds)        │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$XPATH_RIFT" "$XPATH_MB" "$XPATH_SPEEDUP"
    printf "│ 4. Complex AND/OR (×3)     │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$COMPLEX_RIFT" "$COMPLEX_MB" "$COMPLEX_SPEEDUP"
    printf "│ 5. Regex (×2 preds)        │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$REGEX_RIFT" "$REGEX_MB" "$REGEX_SPEEDUP"
    echo "└────────────────────────────┴────────────┴────────────┴──────────┘"
    echo ""
    echo -e "${CYAN}Request always matches the LAST stub (worst case for Mountebank)${NC}"
    echo -e "${CYAN}Rift uses hybrid indexing: HashMap + Radix Trie + Aho-Corasick${NC}"
}

# Main
check_ab

if ! curl -s "$RIFT_ADMIN/imposters" > /dev/null 2>&1; then
    echo -e "${RED}Error: Rift not running. Start with: docker-compose up rift -d${NC}"
    exit 1
fi

if ! curl -s "$MB_ADMIN/" > /dev/null 2>&1; then
    echo -e "${RED}Error: Mountebank not running. Start with: docker-compose up mountebank -d${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ${BOLD}EXTREME COMPREHENSIVE BENCHMARK${NC}${CYAN}                               ║${NC}"
echo -e "${CYAN}║                                                                  ║${NC}"
echo -e "${CYAN}║     Stubs: $STUBS per scenario (match at LAST stub)                 ║${NC}"
echo -e "${CYAN}║     Concurrency: $CONCURRENCY connections                                  ║${NC}"
printf "${CYAN}║     Rift: %d requests | Mountebank: %d requests (slower)        ║${NC}\n" "$REQUESTS" "$MB_REQUESTS"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"

setup_imposters
run_all_benchmarks
print_summary
cleanup_imposters

echo ""
echo -e "${GREEN}Benchmarks complete!${NC}"
