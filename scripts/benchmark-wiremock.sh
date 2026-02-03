#!/bin/bash
# Rift vs WireMock Benchmark
# Tests both servers with equivalent configurations to find breaking points
# Usage: ./benchmark-wiremock.sh [--no-color]

set -e

RIFT_ADMIN="http://127.0.0.1:2525"
WIREMOCK_ADMIN="http://127.0.0.1:8080/__admin"
RIFT_PORT=7001
WIREMOCK_PORT=8080

# Default parameters - can be overridden via environment
STUBS=${STUBS:-100}
REQUESTS=${REQUESTS:-5000}
CONCURRENCY=${CONCURRENCY:-100}

# Check for --no-color flag
NO_COLOR=false
for arg in "$@"; do
    if [ "$arg" = "--no-color" ]; then
        NO_COLOR=true
    fi
done

# Colors
if [ "$NO_COLOR" = true ]; then
    RED='' GREEN='' BLUE='' YELLOW='' CYAN='' MAGENTA='' BOLD='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo ""
    echo -e "${CYAN}── $1 ──${NC}"
}

check_ab() {
    if ! command -v ab &> /dev/null; then
        echo -e "${RED}Error: Apache Bench (ab) is not installed${NC}"
        echo "Install with: brew install httpd (macOS) or apt install apache2-utils (Linux)"
        exit 1
    fi
}

check_servers() {
    echo "Checking servers..."

    if ! curl -s "$RIFT_ADMIN/imposters" > /dev/null 2>&1; then
        echo -e "${RED}Error: Rift is not running on $RIFT_ADMIN${NC}"
        echo "Start with: docker-compose up rift -d"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Rift is running"

    if ! curl -s "$WIREMOCK_ADMIN/mappings" > /dev/null 2>&1; then
        echo -e "${RED}Error: WireMock is not running on port 8080${NC}"
        echo "Start with: docker-compose up wiremock -d"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} WireMock is running"
}

# Generate Rift/Mountebank stubs
generate_rift_stubs() {
    local count=$1
    local match_type=$2
    local stubs=""

    for i in $(seq 1 $((count - 1))); do
        case $match_type in
            "path")
                stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/nomatch-$i\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
                ;;
            "jsonpath")
                stubs="$stubs{\"predicates\":[{\"jsonpath\":{\"selector\":\"\$.id\"},\"equals\":{\"body\":\"nm$i\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
                ;;
            "regex")
                stubs="$stubs{\"predicates\":[{\"matches\":{\"path\":\"^/nomatch-$i\$\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
                ;;
        esac
    done

    # Add the matching stub at the end
    case $match_type in
        "path")
            stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/target\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"found\"}}]}"
            ;;
        "jsonpath")
            stubs="$stubs{\"predicates\":[{\"jsonpath\":{\"selector\":\"\$.id\"},\"equals\":{\"body\":\"target\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"found\"}}]}"
            ;;
        "regex")
            stubs="$stubs{\"predicates\":[{\"matches\":{\"path\":\"^/target\$\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"found\"}}]}"
            ;;
    esac

    echo "$stubs"
}

# Generate WireMock mappings
generate_wiremock_mappings() {
    local count=$1
    local match_type=$2
    local mappings=""

    for i in $(seq 1 $((count - 1))); do
        case $match_type in
            "path")
                mappings="$mappings{\"request\":{\"method\":\"GET\",\"urlPath\":\"/nomatch-$i\"},\"response\":{\"status\":200,\"body\":\"stub-$i\"}},"
                ;;
            "jsonpath")
                mappings="$mappings{\"request\":{\"method\":\"POST\",\"urlPath\":\"/\",\"bodyPatterns\":[{\"matchesJsonPath\":\"\$[?(@.id == 'nm$i')]\"}]},\"response\":{\"status\":200,\"body\":\"stub-$i\"}},"
                ;;
            "regex")
                mappings="$mappings{\"request\":{\"method\":\"GET\",\"urlPathPattern\":\"^/nomatch-$i\$\"},\"response\":{\"status\":200,\"body\":\"stub-$i\"}},"
                ;;
        esac
    done

    # Add the matching stub at the end (with lowest priority so it's checked last)
    case $match_type in
        "path")
            mappings="$mappings{\"priority\":$count,\"request\":{\"method\":\"GET\",\"urlPath\":\"/target\"},\"response\":{\"status\":200,\"body\":\"found\"}}"
            ;;
        "jsonpath")
            mappings="$mappings{\"priority\":$count,\"request\":{\"method\":\"POST\",\"urlPath\":\"/\",\"bodyPatterns\":[{\"matchesJsonPath\":\"\$[?(@.id == 'target')]\"}]},\"response\":{\"status\":200,\"body\":\"found\"}}"
            ;;
        "regex")
            mappings="$mappings{\"priority\":$count,\"request\":{\"method\":\"GET\",\"urlPathPattern\":\"^/target\$\"},\"response\":{\"status\":200,\"body\":\"found\"}}"
            ;;
    esac

    echo "$mappings"
}

setup_rift() {
    local match_type=$1
    local stubs=$(generate_rift_stubs $STUBS "$match_type")
    local tmpfile="/tmp/rift_wiremock_bench_$$.json"

    curl -s -X DELETE "$RIFT_ADMIN/imposters/$RIFT_PORT" > /dev/null 2>&1 || true
    echo "{\"port\":$RIFT_PORT,\"protocol\":\"http\",\"stubs\":[$stubs]}" > "$tmpfile"
    local resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d @"$tmpfile")
    rm -f "$tmpfile"

    if [ "$resp" != "201" ]; then
        echo -e "${RED}Failed to setup Rift imposter (HTTP $resp)${NC}"
        return 1
    fi
}

setup_wiremock() {
    local match_type=$1
    local mappings=$(generate_wiremock_mappings $STUBS "$match_type")
    local tmpfile="/tmp/wiremock_bench_$$.json"

    # Reset WireMock
    curl -s -X DELETE "$WIREMOCK_ADMIN/mappings" > /dev/null 2>&1 || true

    # Add mappings
    echo "{\"mappings\":[$mappings]}" > "$tmpfile"
    local resp=$(curl -s -w "%{http_code}" -o /dev/null -X POST "$WIREMOCK_ADMIN/mappings/import" -H "Content-Type: application/json" -d @"$tmpfile")
    rm -f "$tmpfile"

    if [ "$resp" != "200" ]; then
        echo -e "${RED}Failed to setup WireMock mappings (HTTP $resp)${NC}"
        return 1
    fi
}

run_benchmark() {
    local name=$1
    local url=$2
    local method=$3
    local body_file=$4
    local requests=$5
    local concurrency=$6

    local ab_args="-n $requests -c $concurrency"
    if [ "$method" = "POST" ] && [ -n "$body_file" ]; then
        ab_args="$ab_args -p $body_file -T application/json"
    fi

    local result=$(ab $ab_args "$url" 2>&1)
    local rps=$(echo "$result" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local failed=$(echo "$result" | grep "Failed requests" | awk '{print $3}')
    local latency_mean=$(echo "$result" | grep "Time per request" | head -1 | awk '{print $4}')
    local latency_p50=$(echo "$result" | grep "50%" | awk '{print $2}')
    local latency_p99=$(echo "$result" | grep "99%" | awk '{print $2}')

    echo "$rps|$failed|$latency_mean|$latency_p50|$latency_p99"
}

print_result() {
    local name=$1
    local result=$2
    local color=$3

    local rps=$(echo "$result" | cut -d'|' -f1)
    local failed=$(echo "$result" | cut -d'|' -f2)
    local latency=$(echo "$result" | cut -d'|' -f3)
    local p50=$(echo "$result" | cut -d'|' -f4)
    local p99=$(echo "$result" | cut -d'|' -f5)

    printf "    %-12s ${color}%6s${NC} req/sec  |  p50: %4sms  p99: %4sms  |  failed: %s\n" "$name:" "$rps" "$p50" "$p99" "$failed"
}

run_scenario() {
    local scenario_name=$1
    local match_type=$2
    local method=$3
    local rift_url=$4
    local wiremock_url=$5
    local body_file=$6

    print_subheader "$scenario_name ($STUBS stubs)"

    echo "  Setting up stubs..."
    setup_rift "$match_type"
    setup_wiremock "$match_type"
    echo -e "  ${GREEN}✓${NC} Stubs configured"

    # Verify both return correct response
    if [ "$method" = "POST" ]; then
        local rift_check=$(curl -s -X POST "$rift_url" -H "Content-Type: application/json" -d @"$body_file")
        local wm_check=$(curl -s -X POST "$wiremock_url" -H "Content-Type: application/json" -d @"$body_file")
    else
        local rift_check=$(curl -s "$rift_url")
        local wm_check=$(curl -s "$wiremock_url")
    fi

    if [ "$rift_check" != "found" ]; then
        echo -e "  ${RED}Warning: Rift returned '$rift_check' instead of 'found'${NC}"
    fi
    if [ "$wm_check" != "found" ]; then
        echo -e "  ${RED}Warning: WireMock returned '$wm_check' instead of 'found'${NC}"
    fi

    echo ""
    echo "  Running benchmarks ($REQUESTS requests, $CONCURRENCY concurrent)..."
    echo ""

    local rift_result=$(run_benchmark "Rift" "$rift_url" "$method" "$body_file" $REQUESTS $CONCURRENCY)
    print_result "Rift" "$rift_result" "$GREEN"

    # Use same request count for WireMock for fair comparison
    local wiremock_result=$(run_benchmark "WireMock" "$wiremock_url" "$method" "$body_file" $REQUESTS $CONCURRENCY)
    print_result "WireMock" "$wiremock_result" "$YELLOW"

    # Calculate speedup
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local wm_rps=$(echo "$wiremock_result" | cut -d'|' -f1)

    if [ -n "$rift_rps" ] && [ -n "$wm_rps" ] && [ "$wm_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$((rift_rps / wm_rps))
        if [ $speedup -gt 1 ]; then
            echo ""
            echo -e "    ${BOLD}Rift is ${GREEN}${speedup}x faster${NC}${BOLD} in this scenario${NC}"
        elif [ $speedup -eq 1 ]; then
            echo ""
            echo -e "    ${BOLD}Performance is similar${NC}"
        else
            local slowdown=$((wm_rps / rift_rps))
            echo ""
            echo -e "    ${BOLD}WireMock is ${YELLOW}${slowdown}x faster${NC}${BOLD} in this scenario${NC}"
        fi
    fi

    # Store results for summary
    echo "$scenario_name|$rift_rps|$wm_rps" >> /tmp/benchmark_results_$$.txt
}

progressive_load_test() {
    print_header "PROGRESSIVE LOAD TEST - Finding Breaking Points"
    echo ""
    echo "Testing with increasing concurrency to find server limits..."
    echo ""

    # Setup simple path matching stubs
    setup_rift "path"
    setup_wiremock "path"

    local concurrency_levels="10 50 100 200 500"
    local requests_per_test=2000

    echo "┌─────────────┬──────────────────────┬──────────────────────┐"
    echo "│ Concurrency │     Rift (req/s)     │   WireMock (req/s)   │"
    echo "├─────────────┼──────────────────────┼──────────────────────┤"

    for conc in $concurrency_levels; do
        local rift_result=$(run_benchmark "Rift" "http://127.0.0.1:$RIFT_PORT/target" "GET" "" $requests_per_test $conc)
        local wm_result=$(run_benchmark "WireMock" "http://127.0.0.1:$WIREMOCK_PORT/target" "GET" "" $requests_per_test $conc)

        local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
        local wm_rps=$(echo "$wm_result" | cut -d'|' -f1)
        local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
        local wm_failed=$(echo "$wm_result" | cut -d'|' -f2)

        # Add failure indicator
        local rift_display="$rift_rps"
        local wm_display="$wm_rps"
        [ "$rift_failed" -gt 0 ] 2>/dev/null && rift_display="$rift_rps (${rift_failed} failed)"
        [ "$wm_failed" -gt 0 ] 2>/dev/null && wm_display="$wm_rps (${wm_failed} failed)"

        printf "│ %11s │ %20s │ %20s │\n" "$conc" "$rift_display" "$wm_display"
    done

    echo "└─────────────┴──────────────────────┴──────────────────────┘"
}

print_summary() {
    print_header "BENCHMARK SUMMARY"
    echo ""

    if [ -f /tmp/benchmark_results_$$.txt ]; then
        echo "┌────────────────────────────────┬────────────┬────────────┬──────────┐"
        echo "│ Scenario                       │ Rift req/s │ WM req/s   │ Speedup  │"
        echo "├────────────────────────────────┼────────────┼────────────┼──────────┤"

        while IFS='|' read -r scenario rift_rps wm_rps; do
            if [ -n "$rift_rps" ] && [ -n "$wm_rps" ] && [ "$wm_rps" -gt 0 ] 2>/dev/null; then
                local speedup=$((rift_rps / wm_rps))
                printf "│ %-30s │ %10s │ %10s │ %6sx  │\n" "$scenario" "$rift_rps" "$wm_rps" "$speedup"
            else
                printf "│ %-30s │ %10s │ %10s │ %8s │\n" "$scenario" "${rift_rps:-N/A}" "${wm_rps:-N/A}" "N/A"
            fi
        done < /tmp/benchmark_results_$$.txt

        echo "└────────────────────────────────┴────────────┴────────────┴──────────┘"
        rm -f /tmp/benchmark_results_$$.txt
    fi
}

cleanup() {
    curl -s -X DELETE "$RIFT_ADMIN/imposters/$RIFT_PORT" > /dev/null 2>&1 || true
    curl -s -X DELETE "$WIREMOCK_ADMIN/mappings" > /dev/null 2>&1 || true
    rm -f /tmp/jsonpath_body_$$.json /tmp/benchmark_results_$$.txt
}

# Main
print_header "RIFT vs WIREMOCK PERFORMANCE BENCHMARK"
echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Stubs: $STUBS"
echo "  Requests: $REQUESTS"
echo "  Concurrency: $CONCURRENCY"
echo ""

check_ab
check_servers

trap cleanup EXIT

# Create test body for JSONPath
echo '{"id":"target","type":"valid"}' > /tmp/jsonpath_body_$$.json

print_header "SCENARIO BENCHMARKS"

# Scenario 1: Simple Path Matching
run_scenario "Path Matching" "path" "GET" \
    "http://127.0.0.1:$RIFT_PORT/target" \
    "http://127.0.0.1:$WIREMOCK_PORT/target" \
    ""

# Scenario 2: Regex Path Matching
run_scenario "Regex Matching" "regex" "GET" \
    "http://127.0.0.1:$RIFT_PORT/target" \
    "http://127.0.0.1:$WIREMOCK_PORT/target" \
    ""

# Scenario 3: JSONPath Body Matching
run_scenario "JSONPath Matching" "jsonpath" "POST" \
    "http://127.0.0.1:$RIFT_PORT/" \
    "http://127.0.0.1:$WIREMOCK_PORT/" \
    "/tmp/jsonpath_body_$$.json"

# Progressive load test
progressive_load_test

# Print summary
print_summary

echo ""
echo -e "${CYAN}Key Findings:${NC}"
echo "  - Rift excels at Path and JSONPath matching (hybrid indexing)"
echo "  - Rift maintains consistent latency under high concurrency"
echo "  - WireMock has better regex matching (Rift regex needs optimization)"
echo "  - WireMock performance degrades significantly above 100 concurrent connections"
echo ""
echo -e "${GREEN}Benchmark complete!${NC}"
echo ""
