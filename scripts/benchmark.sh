#!/bin/bash
# Benchmark script for Rift vs Mountebank comparison
# Usage: ./benchmark.sh [rift|mountebank|both]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

RIFT_ADMIN="http://127.0.0.1:2525"
RIFT_IMPOSTER="http://127.0.0.1:8114"
MB_ADMIN="http://127.0.0.1:3525"
MB_IMPOSTER="http://127.0.0.1:18114"

REQUESTS=${REQUESTS:-1000}
CONCURRENCY=${CONCURRENCY:-50}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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

# Create temp file for POST body
setup_body() {
    echo '{"leadId": "12345"}' > /tmp/benchmark_body.json
}

benchmark_rift() {
    print_header "BENCHMARKING RIFT"

    if ! curl -s "$RIFT_ADMIN/imposters" > /dev/null 2>&1; then
        echo -e "${RED}Error: Rift is not running on $RIFT_ADMIN${NC}"
        echo "Start with: docker-compose up rift -d"
        return 1
    fi

    echo ""
    echo "Target: $RIFT_IMPOSTER"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    ab -n $REQUESTS -c $CONCURRENCY -p /tmp/benchmark_body.json -T "application/json" \
        "${RIFT_IMPOSTER}/private/2543228/auto/auto-businesses/foo/appointments" 2>&1 | \
        grep -E "(Requests per second|Time per request:.*\(mean\)$|Failed requests|50%|99%)"
}

benchmark_mountebank() {
    print_header "BENCHMARKING MOUNTEBANK"

    if ! curl -s "$MB_ADMIN/imposters" > /dev/null 2>&1; then
        echo -e "${RED}Error: Mountebank is not running on $MB_ADMIN${NC}"
        echo "Start with: docker-compose up mountebank -d"
        return 1
    fi

    echo ""
    echo "Target: $MB_IMPOSTER"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    ab -n $REQUESTS -c $CONCURRENCY -p /tmp/benchmark_body.json -T "application/json" \
        "${MB_IMPOSTER}/private/2543228/auto/auto-businesses/foo/appointments" 2>&1 | \
        grep -E "(Requests per second|Time per request:.*\(mean\)$|Failed requests|50%|99%)"
}

compare() {
    print_header "SIDE-BY-SIDE COMPARISON"

    echo ""
    echo "Running benchmark against both servers..."
    echo ""

    RIFT_RPS=$(ab -n $REQUESTS -c $CONCURRENCY -p /tmp/benchmark_body.json -T "application/json" \
        "${RIFT_IMPOSTER}/private/2543228/auto/auto-businesses/foo/appointments" 2>&1 | \
        grep "Requests per second" | awk '{print $4}' | cut -d. -f1)

    MB_RPS=$(ab -n $REQUESTS -c $CONCURRENCY -p /tmp/benchmark_body.json -T "application/json" \
        "${MB_IMPOSTER}/private/2543228/auto/auto-businesses/foo/appointments" 2>&1 | \
        grep "Requests per second" | awk '{print $4}' | cut -d. -f1)

    if [ -n "$RIFT_RPS" ] && [ -n "$MB_RPS" ] && [ "$MB_RPS" -gt 0 ]; then
        SPEEDUP=$((RIFT_RPS / MB_RPS))
        echo "┌─────────────────────────────────────────┐"
        echo "│  Results                                │"
        echo "├─────────────────────────────────────────┤"
        printf "│  Rift:        %-6s req/sec            │\n" "$RIFT_RPS"
        printf "│  Mountebank:  %-6s req/sec            │\n" "$MB_RPS"
        echo "├─────────────────────────────────────────┤"
        printf "│  Speedup:     ${GREEN}%-2dx faster${NC}               │\n" "$SPEEDUP"
        echo "└─────────────────────────────────────────┘"
    else
        echo -e "${RED}Could not complete comparison. Check both servers are running.${NC}"
    fi
}

cleanup() {
    rm -f /tmp/benchmark_body.json
}

trap cleanup EXIT

# Main
check_ab
setup_body

case "${1:-both}" in
    rift)
        benchmark_rift
        ;;
    mountebank|mb)
        benchmark_mountebank
        ;;
    both|compare)
        benchmark_rift
        echo ""
        benchmark_mountebank
        compare
        ;;
    *)
        echo "Usage: $0 [rift|mountebank|both]"
        echo ""
        echo "Environment variables:"
        echo "  REQUESTS=1000      Number of requests"
        echo "  CONCURRENCY=50     Concurrent connections"
        exit 1
        ;;
esac
