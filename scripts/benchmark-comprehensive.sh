#!/bin/bash
# Comprehensive benchmark comparing Rift vs Mountebank
# Tests: health check, JSONPath, XPath, complex AND/OR, last-stub-match (50 stubs)
# Usage: ./benchmark-comprehensive.sh [--no-color]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

RIFT_ADMIN="http://127.0.0.1:2525"
MB_ADMIN="http://127.0.0.1:3525"

REQUESTS=${REQUESTS:-1000}
CONCURRENCY=${CONCURRENCY:-200}

# Check for --no-color flag
NO_COLOR=false
for arg in "$@"; do
    if [ "$arg" = "--no-color" ]; then
        NO_COLOR=true
    fi
done

# Colors
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

# Helper to create imposter using temp file (avoids shell escaping issues)
create_imposter() {
    local admin_url=$1
    local json=$2
    local tmpfile="/tmp/imposter_$$.json"
    echo "$json" > "$tmpfile"
    local resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$admin_url/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    rm -f "$tmpfile"
    echo "$resp"
}

run_benchmark() {
    local name=$1
    local url=$2
    local method=$3
    local body_file=$4
    local content_type=${5:-"application/json"}

    local ab_args="-n $REQUESTS -c $CONCURRENCY"

    if [ "$method" = "POST" ] && [ -n "$body_file" ]; then
        ab_args="$ab_args -p $body_file -T $content_type"
    fi

    local result=$(ab $ab_args "$url" 2>&1)
    local rps=$(echo "$result" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local failed=$(echo "$result" | grep "Failed requests" | awk '{print $3}')
    local mean_latency=$(echo "$result" | grep "Time per request:" | head -1 | awk '{print $4}')

    echo "$rps|$failed|$mean_latency"
}

cleanup_imposters() {
    echo "Cleaning up existing imposters..."
    for port in 6001 6002 6003 6004 6005; do
        curl -s -X DELETE "$RIFT_ADMIN/imposters/$port" > /dev/null 2>&1 || true
        curl -s -X DELETE "$MB_ADMIN/imposters/$port" > /dev/null 2>&1 || true
    done
    sleep 1
}

setup_imposters() {
    echo "Setting up benchmark imposters..."

    # ========== 1. Simple Health Check (port 6001/16001) ==========
    echo -n "  Creating health check imposter... "
    local json='{"port":6001,"protocol":"http","name":"Health Check","stubs":[{"predicates":[{"equals":{"path":"/health"}}],"responses":[{"is":{"statusCode":200,"body":"{\"status\":\"ok\"}"}}]}]}'
    local rift_resp=$(create_imposter "$RIFT_ADMIN" "$json")
    local mb_resp=$(create_imposter "$MB_ADMIN" "$json")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # ========== 2. JSONPath Predicate (port 6002/16002) ==========
    echo -n "  Creating JSONPath imposter... "
    json='{"port":6002,"protocol":"http","name":"JSONPath Benchmark","stubs":[{"predicates":[{"equals":{"body":"premium"},"jsonpath":{"selector":"$.user.subscription.plan"}}],"responses":[{"is":{"statusCode":200,"body":"{\"access\":\"granted\"}"}}]},{"responses":[{"is":{"statusCode":403,"body":"{\"access\":\"denied\"}"}}]}]}'
    rift_resp=$(create_imposter "$RIFT_ADMIN" "$json")
    mb_resp=$(create_imposter "$MB_ADMIN" "$json")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # ========== 3. XPath Predicate (port 6003/16003) ==========
    echo -n "  Creating XPath imposter... "
    json='{"port":6003,"protocol":"http","name":"XPath Benchmark","stubs":[{"predicates":[{"equals":{"body":"active"},"xpath":{"selector":"//user/status"}}],"responses":[{"is":{"statusCode":200,"body":"<response><result>success</result></response>"}}]},{"responses":[{"is":{"statusCode":400,"body":"<response><result>invalid</result></response>"}}]}]}'
    rift_resp=$(create_imposter "$RIFT_ADMIN" "$json")
    mb_resp=$(create_imposter "$MB_ADMIN" "$json")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # ========== 4. Complex AND/OR Predicate (port 6004/16004) ==========
    echo -n "  Creating complex AND/OR imposter... "
    json='{"port":6004,"protocol":"http","name":"Complex AND/OR","stubs":[{"predicates":[{"and":[{"equals":{"method":"POST"}},{"or":[{"contains":{"path":"/api/v1"}},{"contains":{"path":"/api/v2"}}]},{"or":[{"contains":{"body":"premium"}},{"contains":{"body":"enterprise"}}]},{"exists":{"headers":{"Authorization":true}}}]}],"responses":[{"is":{"statusCode":200,"body":"{\"matched\":\"complex\"}"}}]},{"responses":[{"is":{"statusCode":400,"body":"{\"matched\":\"fallback\"}"}}]}]}'
    rift_resp=$(create_imposter "$RIFT_ADMIN" "$json")
    mb_resp=$(create_imposter "$MB_ADMIN" "$json")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    # ========== 5. Last Stub Match - 50 stubs (port 6005/16005) ==========
    echo -n "  Creating 50-stub imposter (last match)... "
    local stubs=""
    for i in $(seq 1 49); do
        stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/nomatch-$i\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/target\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"matched-last\"}}]}"
    json="{\"port\":6005,\"protocol\":\"http\",\"name\":\"Last Stub Match\",\"stubs\":[$stubs]}"
    rift_resp=$(create_imposter "$RIFT_ADMIN" "$json")
    mb_resp=$(create_imposter "$MB_ADMIN" "$json")
    if [ "$rift_resp" = "201" ] && [ "$mb_resp" = "201" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED (Rift: $rift_resp, MB: $mb_resp)${NC}"
    fi

    echo -e "${GREEN}All imposters created${NC}"
}

run_all_benchmarks() {
    # Create test body files
    local jsonpath_body="/tmp/bench_jsonpath.json"
    echo '{"user":{"name":"Test","subscription":{"plan":"premium"}}}' > "$jsonpath_body"

    local xpath_body="/tmp/bench_xpath.xml"
    echo '<?xml version="1.0"?><root><user><name>Test</name><status>active</status></user></root>' > "$xpath_body"

    local complex_body="/tmp/bench_complex.json"
    echo '{"type":"premium","data":"test"}' > "$complex_body"

    # Results storage
    local results=""

    # 1. Health Check
    print_header "1. HEALTH CHECK (Simple Equals)"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    local rift_result=$(run_benchmark "health" "http://127.0.0.1:6001/health" "GET" "")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${GREEN}${BOLD}$rift_rps${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    local mb_result=$(run_benchmark "health" "http://127.0.0.1:16001/health" "GET" "")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${YELLOW}$mb_rps${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC}"
    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$((rift_rps / mb_rps))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${speedup}x faster${NC}"
        results="$results|health:$rift_rps:$mb_rps:$speedup"
    fi

    # 2. JSONPath
    print_header "2. JSONPATH PREDICATE"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_result=$(run_benchmark "jsonpath" "http://127.0.0.1:6002/" "POST" "$jsonpath_body")
    rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${GREEN}${BOLD}$rift_rps${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    mb_result=$(run_benchmark "jsonpath" "http://127.0.0.1:16002/" "POST" "$jsonpath_body")
    mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${YELLOW}$mb_rps${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC}"
    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        speedup=$((rift_rps / mb_rps))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${speedup}x faster${NC}"
        results="$results|jsonpath:$rift_rps:$mb_rps:$speedup"
    fi

    # 3. XPath
    print_header "3. XPATH PREDICATE"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_result=$(run_benchmark "xpath" "http://127.0.0.1:6003/" "POST" "$xpath_body" "application/xml")
    rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${GREEN}${BOLD}$rift_rps${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    mb_result=$(run_benchmark "xpath" "http://127.0.0.1:16003/" "POST" "$xpath_body" "application/xml")
    mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${YELLOW}$mb_rps${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC}"
    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        speedup=$((rift_rps / mb_rps))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${speedup}x faster${NC}"
        results="$results|xpath:$rift_rps:$mb_rps:$speedup"
    fi

    # 4. Complex AND/OR
    print_header "4. COMPLEX AND/OR"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_result=$(run_benchmark "complex" "http://127.0.0.1:6004/api/v1/test" "POST" "$complex_body")
    rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${GREEN}${BOLD}$rift_rps${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    mb_result=$(run_benchmark "complex" "http://127.0.0.1:16004/api/v1/test" "POST" "$complex_body")
    mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${YELLOW}$mb_rps${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC}"
    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        speedup=$((rift_rps / mb_rps))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${speedup}x faster${NC}"
        results="$results|complex:$rift_rps:$mb_rps:$speedup"
    fi

    # 5. Last Stub Match (50 stubs)
    print_header "5. LAST STUB MATCH (50 stubs)"
    echo ""
    echo -e "  ${BOLD}Rift${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    rift_result=$(run_benchmark "laststub" "http://127.0.0.1:6005/target" "GET" "")
    rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${GREEN}${BOLD}$rift_rps${NC}"
    echo -e "    Latency:      ${GREEN}${rift_latency}ms${NC}"
    echo ""
    echo -e "  ${BOLD}Mountebank${NC} ($REQUESTS requests, $CONCURRENCY concurrent):"
    mb_result=$(run_benchmark "laststub" "http://127.0.0.1:16005/target" "GET" "")
    mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "    Requests/sec: ${YELLOW}$mb_rps${NC}"
    echo -e "    Latency:      ${YELLOW}${mb_latency}ms${NC}"
    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        speedup=$((rift_rps / mb_rps))
        echo -e "  ${CYAN}>>> Speedup: ${GREEN}${BOLD}${speedup}x faster${NC}"
        results="$results|laststub:$rift_rps:$mb_rps:$speedup"
    fi

    # Cleanup temp files
    rm -f "$jsonpath_body" "$xpath_body" "$complex_body"

    # Print summary
    print_header "SUMMARY"
    echo ""
    echo "┌─────────────────────────┬────────────┬────────────┬──────────┐"
    echo "│ Scenario                │ Rift       │ Mountebank │ Speedup  │"
    echo "├─────────────────────────┼────────────┼────────────┼──────────┤"

    # Parse results
    IFS='|' read -ra PARTS <<< "$results"
    for part in "${PARTS[@]}"; do
        if [ -n "$part" ]; then
            IFS=':' read -ra DATA <<< "$part"
            name="${DATA[0]}"
            rift="${DATA[1]}"
            mb="${DATA[2]}"
            spd="${DATA[3]}"
            case "$name" in
                health) printf "│ 1. Health Check         │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$rift" "$mb" "$spd" ;;
                jsonpath) printf "│ 2. JSONPath             │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$rift" "$mb" "$spd" ;;
                xpath) printf "│ 3. XPath                │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$rift" "$mb" "$spd" ;;
                complex) printf "│ 4. Complex AND/OR       │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$rift" "$mb" "$spd" ;;
                laststub) printf "│ 5. Last Stub (50)       │ %7s/s  │ %7s/s  │  ${GREEN}%5sx${NC}   │\n" "$rift" "$mb" "$spd" ;;
            esac
        fi
    done
    echo "└─────────────────────────┴────────────┴────────────┴──────────┘"
}

final_cleanup() {
    echo ""
    echo "Cleaning up..."
    for port in 6001 6002 6003 6004 6005; do
        curl -s -X DELETE "$RIFT_ADMIN/imposters/$port" > /dev/null 2>&1 || true
        curl -s -X DELETE "$MB_ADMIN/imposters/$port" > /dev/null 2>&1 || true
    done
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
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ${BOLD}COMPREHENSIVE BENCHMARK${NC}${CYAN}                                   ║${NC}"
echo -e "${CYAN}║                                                              ║${NC}"
echo -e "${CYAN}║     Requests: $REQUESTS | Concurrency: $CONCURRENCY                        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

cleanup_imposters
setup_imposters
run_all_benchmarks
final_cleanup

echo ""
echo -e "${GREEN}Benchmarks complete!${NC}"
