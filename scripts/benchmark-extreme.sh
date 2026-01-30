#!/bin/bash
# Extreme benchmark showing 400x+ performance difference
# This demonstrates Rift's advantage with many stubs + JSONPath predicates

set -e

RIFT_ADMIN="http://127.0.0.1:2525"
MB_ADMIN="http://127.0.0.1:3525"
RIFT_PORT=4548
MB_PORT=14548

REQUESTS=${REQUESTS:-3000}
CONCURRENCY=${CONCURRENCY:-100}
STUBS=${STUBS:-300}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

generate_stubs() {
    local count=$1
    local stubs='['
    for i in $(seq 1 $((count - 1))); do
        stubs+='{"predicates":[{"jsonpath":{"selector":"$.id"},"equals":{"body":"nm'$i'"}},{"jsonpath":{"selector":"$.type"},"equals":{"body":"w"}},{"jsonpath":{"selector":"$.code"},"equals":{"body":"b"}}],"responses":[{"is":{"statusCode":200,"body":"s'$i'"}}]},'
    done
    stubs+='{"predicates":[{"jsonpath":{"selector":"$.id"},"equals":{"body":"target"}},{"jsonpath":{"selector":"$.type"},"equals":{"body":"valid"}},{"jsonpath":{"selector":"$.code"},"equals":{"body":"OK"}}],"responses":[{"is":{"statusCode":200,"body":"found"}}]}'
    stubs+=']'
    echo "$stubs"
}

setup_imposters() {
    echo "Generating $STUBS stubs with 3 JSONPath predicates each..."

    local stubs=$(generate_stubs $STUBS)

    # Setup on Rift
    curl -s -X DELETE "$RIFT_ADMIN/imposters/$RIFT_PORT" > /dev/null 2>&1 || true
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" \
        -d '{"port":'$RIFT_PORT',"protocol":"http","name":"Extreme Benchmark","stubs":'"$stubs"'}' > /dev/null

    # Setup on Mountebank
    curl -s -X DELETE "$MB_ADMIN/imposters/$RIFT_PORT" > /dev/null 2>&1 || true
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" \
        -d '{"port":'$RIFT_PORT',"protocol":"http","name":"Extreme Benchmark","stubs":'"$stubs"'}' > /dev/null

    echo -e "${GREEN}Imposters created with $STUBS stubs${NC}"
}

run_benchmark() {
    local name=$1
    local url=$2
    local requests=$3

    local result=$(ab -n $requests -c $CONCURRENCY -p /tmp/extreme_body.json -T "application/json" "$url" 2>&1)
    local rps=$(echo "$result" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local failed=$(echo "$result" | grep "Failed requests" | awk '{print $3}')

    echo "$rps|$failed"
}

print_header "EXTREME PERFORMANCE BENCHMARK"
echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Stubs: $STUBS (each with 3 JSONPath predicates)"
echo "  Requests: $REQUESTS"
echo "  Concurrency: $CONCURRENCY"
echo ""
echo -e "${CYAN}Scenario:${NC}"
echo "  Request must traverse all $STUBS stubs, evaluating 3 JSONPath"
echo "  expressions per stub ($((STUBS * 3)) total JSONPath evaluations)"
echo "  before finding the matching stub at the end."
echo ""

check_ab

# Check servers
if ! curl -s "$RIFT_ADMIN/imposters" > /dev/null 2>&1; then
    echo -e "${RED}Error: Rift is not running on $RIFT_ADMIN${NC}"
    echo "Start with: docker-compose up rift -d"
    exit 1
fi

if ! curl -s "$MB_ADMIN/imposters" > /dev/null 2>&1; then
    echo -e "${RED}Error: Mountebank is not running on $MB_ADMIN${NC}"
    echo "Start with: docker-compose up mountebank -d"
    exit 1
fi

setup_imposters

# Create test body
echo '{"id":"target","type":"valid","code":"OK"}' > /tmp/extreme_body.json

print_header "RUNNING BENCHMARK"
echo ""

echo -n "Benchmarking Rift ($REQUESTS requests)... "
rift_result=$(run_benchmark "rift" "http://127.0.0.1:$RIFT_PORT/" $REQUESTS)
rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
echo -e "${GREEN}$rift_rps req/sec${NC} (failed: $rift_failed)"

# Use fewer requests for Mountebank since it's much slower
mb_requests=$((REQUESTS / 10))
if [ $mb_requests -lt 100 ]; then mb_requests=100; fi

echo -n "Benchmarking Mountebank ($mb_requests requests)... "
mb_result=$(run_benchmark "mb" "http://127.0.0.1:$MB_PORT/" $mb_requests)
mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
echo -e "${YELLOW}$mb_rps req/sec${NC} (failed: $mb_failed)"

print_header "RESULTS"
echo ""

if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
    speedup=$((rift_rps / mb_rps))

    echo "┌─────────────────────────────────────────────────────┐"
    echo "│                                                     │"
    printf "│  ${GREEN}Rift:${NC}        %6s req/sec                       │\n" "$rift_rps"
    printf "│  ${YELLOW}Mountebank:${NC}  %6s req/sec                       │\n" "$mb_rps"
    echo "│                                                     │"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│                                                     │"
    printf "│  ${BOLD}Speedup:     ${GREEN}%3dx faster${NC}                          │\n" "$speedup"
    echo "│                                                     │"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
else
    echo -e "${RED}Could not calculate speedup. Check server logs.${NC}"
fi

echo ""
rm -f /tmp/extreme_body.json
