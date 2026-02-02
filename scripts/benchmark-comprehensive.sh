#!/bin/bash
# Comprehensive benchmark comparing Rift vs Mountebank
# Tests: health check, JSONPath, XPath, complex AND/OR, last-stub-match (50 stubs)
# Usage: ./benchmark-comprehensive.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

RIFT_ADMIN="http://127.0.0.1:2525"
MB_ADMIN="http://127.0.0.1:3525"

REQUESTS=${REQUESTS:-1000}
CONCURRENCY=${CONCURRENCY:-200}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
    local p50=$(echo "$result" | grep "50%" | awk '{print $2}')
    local p99=$(echo "$result" | grep "99%" | awk '{print $2}')

    echo "$rps|$failed|$mean_latency|$p50|$p99"
}

setup_imposters() {
    echo "Setting up benchmark imposters..."

    # ========== 1. Simple Health Check (port 6001/16001) ==========
    echo -n "  Creating health check imposter... "

    # Rift
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6001,
        "protocol": "http",
        "name": "Health Check",
        "stubs": [{
            "predicates": [{"equals": {"path": "/health"}}],
            "responses": [{"is": {"statusCode": 200, "body": "{\"status\":\"ok\"}"}}]
        }]
    }' > /dev/null

    # Mountebank
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6001,
        "protocol": "http",
        "name": "Health Check",
        "stubs": [{
            "predicates": [{"equals": {"path": "/health"}}],
            "responses": [{"is": {"statusCode": 200, "body": "{\"status\":\"ok\"}"}}]
        }]
    }' > /dev/null
    echo -e "${GREEN}OK${NC}"

    # ========== 2. JSONPath Predicate (port 6002/16002) ==========
    echo -n "  Creating JSONPath imposter... "

    # Rift
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6002,
        "protocol": "http",
        "name": "JSONPath Benchmark",
        "stubs": [{
            "predicates": [{
                "equals": {"body": "premium"},
                "jsonpath": {"selector": "$.user.subscription.plan"}
            }],
            "responses": [{"is": {"statusCode": 200, "body": "{\"access\":\"granted\"}"}}]
        }, {
            "responses": [{"is": {"statusCode": 403, "body": "{\"access\":\"denied\"}"}}]
        }]
    }' > /dev/null

    # Mountebank
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6002,
        "protocol": "http",
        "name": "JSONPath Benchmark",
        "stubs": [{
            "predicates": [{
                "equals": {"body": "premium"},
                "jsonpath": {"selector": "$.user.subscription.plan"}
            }],
            "responses": [{"is": {"statusCode": 200, "body": "{\"access\":\"granted\"}"}}]
        }, {
            "responses": [{"is": {"statusCode": 403, "body": "{\"access\":\"denied\"}"}}]
        }]
    }' > /dev/null
    echo -e "${GREEN}OK${NC}"

    # ========== 3. XPath Predicate (port 6003/16003) ==========
    echo -n "  Creating XPath imposter... "

    # Rift
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6003,
        "protocol": "http",
        "name": "XPath Benchmark",
        "stubs": [{
            "predicates": [{
                "equals": {"body": "active"},
                "xpath": {"selector": "//user/status"}
            }],
            "responses": [{"is": {"statusCode": 200, "body": "<response><result>success</result></response>"}}]
        }, {
            "responses": [{"is": {"statusCode": 400, "body": "<response><result>invalid</result></response>"}}]
        }]
    }' > /dev/null

    # Mountebank
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6003,
        "protocol": "http",
        "name": "XPath Benchmark",
        "stubs": [{
            "predicates": [{
                "equals": {"body": "active"},
                "xpath": {"selector": "//user/status"}
            }],
            "responses": [{"is": {"statusCode": 200, "body": "<response><result>success</result></response>"}}]
        }, {
            "responses": [{"is": {"statusCode": 400, "body": "<response><result>invalid</result></response>"}}]
        }]
    }' > /dev/null
    echo -e "${GREEN}OK${NC}"

    # ========== 4. Complex AND/OR Predicate (port 6004/16004) ==========
    echo -n "  Creating complex AND/OR imposter... "

    # Rift
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6004,
        "protocol": "http",
        "name": "Complex AND/OR",
        "stubs": [{
            "predicates": [{
                "and": [
                    {"equals": {"method": "POST"}},
                    {"or": [
                        {"contains": {"path": "/api/v1"}},
                        {"contains": {"path": "/api/v2"}}
                    ]},
                    {"or": [
                        {"contains": {"body": "\"type\":\"premium\""}},
                        {"contains": {"body": "\"type\":\"enterprise\""}}
                    ]},
                    {"exists": {"headers": {"Authorization": true}}}
                ]
            }],
            "responses": [{"is": {"statusCode": 200, "body": "{\"matched\":\"complex\"}"}}]
        }, {
            "responses": [{"is": {"statusCode": 400, "body": "{\"matched\":\"fallback\"}"}}]
        }]
    }' > /dev/null

    # Mountebank
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 6004,
        "protocol": "http",
        "name": "Complex AND/OR",
        "stubs": [{
            "predicates": [{
                "and": [
                    {"equals": {"method": "POST"}},
                    {"or": [
                        {"contains": {"path": "/api/v1"}},
                        {"contains": {"path": "/api/v2"}}
                    ]},
                    {"or": [
                        {"contains": {"body": "\"type\":\"premium\""}},
                        {"contains": {"body": "\"type\":\"enterprise\""}}
                    ]},
                    {"exists": {"headers": {"Authorization": true}}}
                ]
            }],
            "responses": [{"is": {"statusCode": 200, "body": "{\"matched\":\"complex\"}"}}]
        }, {
            "responses": [{"is": {"statusCode": 400, "body": "{\"matched\":\"fallback\"}"}}]
        }]
    }' > /dev/null
    echo -e "${GREEN}OK${NC}"

    # ========== 5. Last Stub Match - 50 Stubs (port 6005/16005) ==========
    echo -n "  Creating 50-stub imposter (last match)... "

    # Generate 50 stubs - only the last one will match our test request
    local stubs=""
    for i in $(seq 1 49); do
        stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/stub-$i\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"stub-$i\"}}]},"
    done
    # Last stub matches our test path
    stubs="$stubs{\"predicates\":[{\"equals\":{\"path\":\"/last-stub\"}}],\"responses\":[{\"is\":{\"statusCode\":200,\"body\":\"last-stub-matched\"}}]}"

    # Rift
    curl -s -X POST "$RIFT_ADMIN/imposters" -H "Content-Type: application/json" -d "{
        \"port\": 6005,
        \"protocol\": \"http\",
        \"name\": \"50 Stubs - Last Match\",
        \"stubs\": [$stubs]
    }" > /dev/null

    # Mountebank
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d "{
        \"port\": 6005,
        \"protocol\": \"http\",
        \"name\": \"50 Stubs - Last Match\",
        \"stubs\": [$stubs]
    }" > /dev/null
    echo -e "${GREEN}OK${NC}"

    echo -e "${GREEN}All imposters created${NC}"
}

benchmark_health_check() {
    print_header "1. Simple Health Check (GET /health)"
    echo ""
    echo "Testing: Simple equals predicate on path"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    echo -n "Benchmarking Rift (port 6001)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:6001/health" "GET" "")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    local rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "${GREEN}$rift_rps req/sec${NC} (latency: ${rift_latency}ms, failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 16001)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:16001/health" "GET" "")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    local mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (latency: ${mb_latency}ms, failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$(echo "scale=1; $rift_rps / $mb_rps" | bc)
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC}"
    fi
}

benchmark_jsonpath() {
    print_header "2. JSONPath Predicate"
    echo ""
    echo "Testing: JSONPath selector \$.user.subscription.plan"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    # Create test body
    local body_file="/tmp/jsonpath_bench.json"
    cat > "$body_file" << 'EOF'
{
    "user": {
        "id": 12345,
        "name": "Test User",
        "subscription": {
            "plan": "premium",
            "expires": "2026-12-31"
        }
    }
}
EOF

    echo -n "Benchmarking Rift (port 6002)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:6002/" "POST" "$body_file")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    local rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "${GREEN}$rift_rps req/sec${NC} (latency: ${rift_latency}ms, failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 16002)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:16002/" "POST" "$body_file")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    local mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (latency: ${mb_latency}ms, failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$(echo "scale=1; $rift_rps / $mb_rps" | bc)
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC}"
    fi

    rm -f "$body_file"
}

benchmark_xpath() {
    print_header "3. XPath Predicate"
    echo ""
    echo "Testing: XPath selector //user/status"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    # Create test body
    local body_file="/tmp/xpath_bench.xml"
    cat > "$body_file" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<request>
    <user>
        <id>12345</id>
        <name>Test User</name>
        <status>active</status>
    </user>
</request>
EOF

    echo -n "Benchmarking Rift (port 6003)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:6003/" "POST" "$body_file" "application/xml")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    local rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "${GREEN}$rift_rps req/sec${NC} (latency: ${rift_latency}ms, failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 16003)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:16003/" "POST" "$body_file" "application/xml")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    local mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (latency: ${mb_latency}ms, failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$(echo "scale=1; $rift_rps / $mb_rps" | bc)
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC}"
    fi

    rm -f "$body_file"
}

benchmark_complex_and_or() {
    print_header "4. Complex AND/OR Predicates"
    echo ""
    echo "Testing: AND(method, OR(path), OR(body), exists(header))"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    # Create test body
    local body_file="/tmp/complex_bench.json"
    cat > "$body_file" << 'EOF'
{
    "type": "premium",
    "data": "test payload"
}
EOF

    echo -n "Benchmarking Rift (port 6004)... "
    local rift_result=$(ab -n $REQUESTS -c $CONCURRENCY -p "$body_file" -T "application/json" -H "Authorization: Bearer token123" "http://127.0.0.1:6004/api/v1/resource" 2>&1)
    local rift_rps=$(echo "$rift_result" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local rift_failed=$(echo "$rift_result" | grep "Failed requests" | awk '{print $3}')
    local rift_latency=$(echo "$rift_result" | grep "Time per request:" | head -1 | awk '{print $4}')
    echo -e "${GREEN}$rift_rps req/sec${NC} (latency: ${rift_latency}ms, failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 16004)... "
    local mb_result=$(ab -n $REQUESTS -c $CONCURRENCY -p "$body_file" -T "application/json" -H "Authorization: Bearer token123" "http://127.0.0.1:16004/api/v1/resource" 2>&1)
    local mb_rps=$(echo "$mb_result" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local mb_failed=$(echo "$mb_result" | grep "Failed requests" | awk '{print $3}')
    local mb_latency=$(echo "$mb_result" | grep "Time per request:" | head -1 | awk '{print $4}')
    echo -e "${YELLOW}$mb_rps req/sec${NC} (latency: ${mb_latency}ms, failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$(echo "scale=1; $rift_rps / $mb_rps" | bc)
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC}"
    fi

    rm -f "$body_file"
}

benchmark_last_stub() {
    print_header "5. Last Stub Match (50 Stubs)"
    echo ""
    echo "Testing: Request matches stub #50 out of 50 (worst case)"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    echo -n "Benchmarking Rift (port 6005)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:6005/last-stub" "GET" "")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    local rift_latency=$(echo "$rift_result" | cut -d'|' -f3)
    echo -e "${GREEN}$rift_rps req/sec${NC} (latency: ${rift_latency}ms, failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 16005)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:16005/last-stub" "GET" "")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    local mb_latency=$(echo "$mb_result" | cut -d'|' -f3)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (latency: ${mb_latency}ms, failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$(echo "scale=1; $rift_rps / $mb_rps" | bc)
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC}"
    fi
}

print_summary() {
    print_header "BENCHMARK SUMMARY"
    echo ""
    echo "Configuration: $REQUESTS requests, $CONCURRENCY concurrent connections"
    echo ""
    echo "┌────────────────────────────┬────────────┬────────────┬──────────┐"
    echo "│ Scenario                   │ Rift       │ Mountebank │ Speedup  │"
    echo "├────────────────────────────┼────────────┼────────────┼──────────┤"
    printf "│ %-26s │ %10s │ %10s │ %8s │\n" "1. Health Check" "$HEALTH_RIFT" "$HEALTH_MB" "${HEALTH_SPEEDUP}x"
    printf "│ %-26s │ %10s │ %10s │ %8s │\n" "2. JSONPath" "$JSONPATH_RIFT" "$JSONPATH_MB" "${JSONPATH_SPEEDUP}x"
    printf "│ %-26s │ %10s │ %10s │ %8s │\n" "3. XPath" "$XPATH_RIFT" "$XPATH_MB" "${XPATH_SPEEDUP}x"
    printf "│ %-26s │ %10s │ %10s │ %8s │\n" "4. Complex AND/OR" "$COMPLEX_RIFT" "$COMPLEX_MB" "${COMPLEX_SPEEDUP}x"
    printf "│ %-26s │ %10s │ %10s │ %8s │\n" "5. Last Stub (50)" "$LASTSTUB_RIFT" "$LASTSTUB_MB" "${LASTSTUB_SPEEDUP}x"
    echo "└────────────────────────────┴────────────┴────────────┴──────────┘"
    echo ""
}

cleanup_imposters() {
    echo ""
    echo "Cleaning up benchmark imposters..."
    for port in 6001 6002 6003 6004 6005; do
        curl -s -X DELETE "$RIFT_ADMIN/imposters/$port" > /dev/null 2>&1 || true
        curl -s -X DELETE "$MB_ADMIN/imposters/$port" > /dev/null 2>&1 || true
    done
    echo "Done."
}

# Main
check_ab

# Check servers
if ! curl -s "$RIFT_ADMIN/imposters" > /dev/null 2>&1; then
    echo -e "${RED}Error: Rift is not running on port 2525${NC}"
    echo "Start with: docker-compose up rift -d"
    exit 1
fi

if ! curl -s "$MB_ADMIN/" > /dev/null 2>&1; then
    echo -e "${RED}Error: Mountebank is not running on port 3525${NC}"
    echo "Start with: docker-compose up mountebank -d"
    exit 1
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     COMPREHENSIVE RIFT vs MOUNTEBANK BENCHMARK               ║${NC}"
echo -e "${CYAN}║     Requests: $REQUESTS | Concurrency: $CONCURRENCY                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

setup_imposters

# Run benchmarks and capture results
benchmark_health_check
benchmark_jsonpath
benchmark_xpath
benchmark_complex_and_or
benchmark_last_stub

cleanup_imposters

echo ""
echo -e "${GREEN}Benchmarks complete!${NC}"
