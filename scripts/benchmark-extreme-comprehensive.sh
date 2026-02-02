#!/usr/bin/env bash
# Extreme Comprehensive Benchmark - All scenarios with 300+ stubs
# Shows the dramatic performance difference when many stubs must be traversed
# Usage: ./benchmark-extreme-comprehensive.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEMO_DIR"

RIFT_ADMIN="http://127.0.0.1:2525"
MB_ADMIN="http://127.0.0.1:3525"

STUBS=${STUBS:-300}
REQUESTS=${REQUESTS:-2000}
CONCURRENCY=${CONCURRENCY:-200}
# MB_REQUESTS must be >= CONCURRENCY (ab requirement)
MB_REQUESTS=${MB_REQUESTS:-$CONCURRENCY}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
    echo -e "${CYAN}Setting up imposters with $STUBS stubs each...${NC}"
    echo ""

    # 1. Simple
    echo -n "  1. Simple equals ($STUBS stubs)... "
    local simple_stubs=$(generate_stubs_simple $STUBS "/health")
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7001,\"protocol\":\"http\",\"stubs\":[$simple_stubs]}" > /dev/null
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7001,\"protocol\":\"http\",\"stubs\":[$simple_stubs]}" > /dev/null
    echo -e "${GREEN}OK${NC}"

    # 2. JSONPath
    echo -n "  2. JSONPath ($STUBS stubs × 2 predicates)... "
    local jsonpath_stubs=$(generate_stubs_jsonpath $STUBS)
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7002,\"protocol\":\"http\",\"stubs\":[$jsonpath_stubs]}" > /dev/null
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7002,\"protocol\":\"http\",\"stubs\":[$jsonpath_stubs]}" > /dev/null
    echo -e "${GREEN}OK${NC}"

    # 3. XPath
    echo -n "  3. XPath ($STUBS stubs × 2 predicates)... "
    local xpath_stubs=$(generate_stubs_xpath $STUBS)
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7003,\"protocol\":\"http\",\"stubs\":[$xpath_stubs]}" > /dev/null
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7003,\"protocol\":\"http\",\"stubs\":[$xpath_stubs]}" > /dev/null
    echo -e "${GREEN}OK${NC}"

    # 4. Complex AND/OR
    echo -n "  4. Complex AND/OR ($STUBS stubs × 3 predicates)... "
    local complex_stubs=$(generate_stubs_complex $STUBS)
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7004,\"protocol\":\"http\",\"stubs\":[$complex_stubs]}" > /dev/null
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7004,\"protocol\":\"http\",\"stubs\":[$complex_stubs]}" > /dev/null
    echo -e "${GREEN}OK${NC}"

    # 5. Regex
    echo -n "  5. Regex ($STUBS stubs × 2 predicates)... "
    local regex_stubs=$(generate_stubs_regex $STUBS)
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7005,\"protocol\":\"http\",\"stubs\":[$regex_stubs]}" > /dev/null
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d "{\"port\":7005,\"protocol\":\"http\",\"stubs\":[$regex_stubs]}" > /dev/null
    echo -e "${GREEN}OK${NC}"

    echo -e "${GREEN}All imposters created${NC}"
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
    echo -n "  Rift ($REQUESTS requests)... "
    SIMPLE_RIFT=$(ab -n $REQUESTS -c $CONCURRENCY "http://127.0.0.1:7001/health" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${GREEN}$SIMPLE_RIFT req/sec${NC}"
    echo -n "  Mountebank ($MB_REQUESTS requests)... "
    SIMPLE_MB=$(ab -n $MB_REQUESTS -c $CONCURRENCY "http://127.0.0.1:17001/health" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${YELLOW}$SIMPLE_MB req/sec${NC}"
    if [ -n "$SIMPLE_RIFT" ] && [ -n "$SIMPLE_MB" ] && [ "$SIMPLE_MB" -gt 0 ] 2>/dev/null; then
        SIMPLE_SPEEDUP=$((SIMPLE_RIFT / SIMPLE_MB))
        echo -e "  ${CYAN}Speedup: ${GREEN}${BOLD}${SIMPLE_SPEEDUP}x faster${NC}"
    fi

    # 2. JSONPath
    print_header "2. JSONPATH ($STUBS stubs × 2 predicates = $((STUBS * 2)) evals)"
    echo ""
    echo -n "  Rift ($REQUESTS requests)... "
    JSONPATH_RIFT=$(ab -n $REQUESTS -c $CONCURRENCY -p "$jsonpath_body" -T "application/json" "http://127.0.0.1:7002/" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${GREEN}$JSONPATH_RIFT req/sec${NC}"
    echo -n "  Mountebank ($MB_REQUESTS requests)... "
    JSONPATH_MB=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$jsonpath_body" -T "application/json" "http://127.0.0.1:17002/" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${YELLOW}$JSONPATH_MB req/sec${NC}"
    if [ -n "$JSONPATH_RIFT" ] && [ -n "$JSONPATH_MB" ] && [ "$JSONPATH_MB" -gt 0 ] 2>/dev/null; then
        JSONPATH_SPEEDUP=$((JSONPATH_RIFT / JSONPATH_MB))
        echo -e "  ${CYAN}Speedup: ${GREEN}${BOLD}${JSONPATH_SPEEDUP}x faster${NC}"
    fi

    # 3. XPath
    print_header "3. XPATH ($STUBS stubs × 2 predicates = $((STUBS * 2)) evals)"
    echo ""
    echo -n "  Rift ($REQUESTS requests)... "
    XPATH_RIFT=$(ab -n $REQUESTS -c $CONCURRENCY -p "$xpath_body" -T "application/xml" "http://127.0.0.1:7003/" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${GREEN}$XPATH_RIFT req/sec${NC}"
    echo -n "  Mountebank ($MB_REQUESTS requests)... "
    XPATH_MB=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$xpath_body" -T "application/xml" "http://127.0.0.1:17003/" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${YELLOW}$XPATH_MB req/sec${NC}"
    if [ -n "$XPATH_RIFT" ] && [ -n "$XPATH_MB" ] && [ "$XPATH_MB" -gt 0 ] 2>/dev/null; then
        XPATH_SPEEDUP=$((XPATH_RIFT / XPATH_MB))
        echo -e "  ${CYAN}Speedup: ${GREEN}${BOLD}${XPATH_SPEEDUP}x faster${NC}"
    fi

    # 4. Complex AND/OR
    print_header "4. COMPLEX AND/OR ($STUBS stubs × 3 predicates)"
    echo "Nested: AND(method, OR(path), OR(body), exists(header))"
    echo ""
    echo -n "  Rift ($REQUESTS requests)... "
    COMPLEX_RIFT=$(ab -n $REQUESTS -c $CONCURRENCY -p "$complex_body" -T "application/json" -H "Authorization: Bearer token" "http://127.0.0.1:7004/api/v1/test" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${GREEN}$COMPLEX_RIFT req/sec${NC}"
    echo -n "  Mountebank ($MB_REQUESTS requests)... "
    COMPLEX_MB=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$complex_body" -T "application/json" -H "Authorization: Bearer token" "http://127.0.0.1:17004/api/v1/test" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${YELLOW}$COMPLEX_MB req/sec${NC}"
    if [ -n "$COMPLEX_RIFT" ] && [ -n "$COMPLEX_MB" ] && [ "$COMPLEX_MB" -gt 0 ] 2>/dev/null; then
        COMPLEX_SPEEDUP=$((COMPLEX_RIFT / COMPLEX_MB))
        echo -e "  ${CYAN}Speedup: ${GREEN}${BOLD}${COMPLEX_SPEEDUP}x faster${NC}"
    fi

    # 5. Regex
    print_header "5. REGEX ($STUBS stubs × 2 predicates)"
    echo "Complex patterns: UUID path + email body"
    echo ""
    echo -n "  Rift ($REQUESTS requests)... "
    REGEX_RIFT=$(ab -n $REQUESTS -c $CONCURRENCY -p "$regex_body" -T "application/json" "http://127.0.0.1:7005/api/v1/users/550e8400-e29b-41d4-a716-446655440000" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${GREEN}$REGEX_RIFT req/sec${NC}"
    echo -n "  Mountebank ($MB_REQUESTS requests)... "
    REGEX_MB=$(ab -n $MB_REQUESTS -c $CONCURRENCY -p "$regex_body" -T "application/json" "http://127.0.0.1:17005/api/v1/users/550e8400-e29b-41d4-a716-446655440000" 2>&1 | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    echo -e "${YELLOW}$REGEX_MB req/sec${NC}"
    if [ -n "$REGEX_RIFT" ] && [ -n "$REGEX_MB" ] && [ "$REGEX_MB" -gt 0 ] 2>/dev/null; then
        REGEX_SPEEDUP=$((REGEX_RIFT / REGEX_MB))
        echo -e "  ${CYAN}Speedup: ${GREEN}${BOLD}${REGEX_SPEEDUP}x faster${NC}"
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
