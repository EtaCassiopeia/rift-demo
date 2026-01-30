#!/bin/bash
# Extended benchmark comparing Rift vs Mountebank on complex scenarios
# Usage: ./benchmark-extended.sh [jsonpath|deepequals|regex|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

RIFT_ADMIN="http://127.0.0.1:2525"
MB_ADMIN="http://127.0.0.1:3525"

REQUESTS=${REQUESTS:-1000}
CONCURRENCY=${CONCURRENCY:-50}

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

wait_for_server() {
    local url=$1
    local name=$2
    local max_attempts=30
    local attempt=0

    echo -n "Waiting for $name..."
    while ! curl -s "$url" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo -e " ${RED}FAILED${NC}"
            return 1
        fi
        sleep 1
        echo -n "."
    done
    echo -e " ${GREEN}OK${NC}"
}

setup_mountebank_imposters() {
    echo "Setting up Mountebank imposters..."

    # JSONPath imposter (port 14545 = 4545 + 10000 offset)
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 4545,
        "protocol": "http",
        "name": "JSONPath Benchmark",
        "stubs": [
            {
                "predicates": [{
                    "jsonpath": { "selector": "$.user.profile.settings.preferences.theme" },
                    "equals": { "body": "dark" }
                }],
                "responses": [{ "is": { "statusCode": 200, "body": "{\"status\": \"found\"}" } }]
            },
            {
                "responses": [{ "is": { "statusCode": 404, "body": "{\"status\": \"no_match\"}" } }]
            }
        ]
    }' > /dev/null

    # DeepEquals imposter (port 14546)
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 4546,
        "protocol": "http",
        "name": "DeepEquals Benchmark",
        "stubs": [
            {
                "predicates": [{
                    "deepEquals": {
                        "body": {
                            "user": {
                                "id": 12345,
                                "profile": {
                                    "firstName": "John",
                                    "lastName": "Doe",
                                    "email": "john.doe@example.com",
                                    "addresses": [
                                        { "type": "home", "street": "123 Main St", "city": "Springfield", "state": "IL", "zip": "62701" },
                                        { "type": "work", "street": "456 Office Blvd", "city": "Chicago", "state": "IL", "zip": "60601" }
                                    ],
                                    "preferences": { "notifications": true, "theme": "dark", "language": "en-US" }
                                }
                            }
                        }
                    }
                }],
                "responses": [{ "is": { "statusCode": 200, "body": "{\"status\": \"match\"}" } }]
            },
            {
                "responses": [{ "is": { "statusCode": 404, "body": "{\"status\": \"no_match\"}" } }]
            }
        ]
    }' > /dev/null

    # Regex imposter (port 14547)
    curl -s -X POST "$MB_ADMIN/imposters" -H "Content-Type: application/json" -d '{
        "port": 4547,
        "protocol": "http",
        "name": "Regex Benchmark",
        "stubs": [
            {
                "predicates": [
                    { "matches": { "path": "^/api/v[0-9]+/users/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$" } },
                    { "matches": { "body": "\"email\":\\s*\"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}\"" } }
                ],
                "responses": [{ "is": { "statusCode": 200, "body": "{\"status\": \"regex_match\"}" } }]
            },
            {
                "responses": [{ "is": { "statusCode": 404, "body": "{\"status\": \"no_match\"}" } }]
            }
        ]
    }' > /dev/null

    echo -e "${GREEN}Mountebank imposters created${NC}"
}

run_benchmark() {
    local name=$1
    local url=$2
    local body_file=$3

    local result=$(ab -n $REQUESTS -c $CONCURRENCY -p "$body_file" -T "application/json" "$url" 2>&1)
    local rps=$(echo "$result" | grep "Requests per second" | awk '{print $4}' | cut -d. -f1)
    local failed=$(echo "$result" | grep "Failed requests" | awk '{print $3}')
    local latency=$(echo "$result" | grep "Time per request:" | grep "mean)$" | awk '{print $4}')

    echo "$rps|$failed|$latency"
}

benchmark_jsonpath() {
    print_header "JSONPath Predicate Benchmark"
    echo ""
    echo "Testing JSONPath selector: \$.user.profile.settings.preferences.theme"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    # Create test body
    local body_file="/tmp/jsonpath_body.json"
    cat > "$body_file" << 'EOF'
{
    "user": {
        "id": 1,
        "profile": {
            "name": "Test User",
            "settings": {
                "preferences": {
                    "theme": "dark",
                    "fontSize": 14
                }
            }
        }
    }
}
EOF

    echo -n "Benchmarking Rift (port 4545)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:4545/" "$body_file")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    echo -e "${GREEN}$rift_rps req/sec${NC} (failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 4545 via 3525)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:14545/" "$body_file")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$((rift_rps / mb_rps))
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC} on JSONPath predicates"
    fi

    rm -f "$body_file"
}

benchmark_deepequals() {
    print_header "DeepEquals Predicate Benchmark"
    echo ""
    echo "Testing deep comparison of nested JSON object"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    # Create test body (must exactly match the predicate - key order matters for deepEquals!)
    local body_file="/tmp/deepequals_body.json"
    cat > "$body_file" << 'EOF'
{"user":{"id":12345,"profile":{"addresses":[{"city":"Springfield","state":"IL","street":"123 Main St","type":"home","zip":"62701"},{"city":"Chicago","state":"IL","street":"456 Office Blvd","type":"work","zip":"60601"}],"email":"john.doe@example.com","firstName":"John","lastName":"Doe","preferences":{"language":"en-US","notifications":true,"theme":"dark"}}}}
EOF

    echo -n "Benchmarking Rift (port 4546)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:4546/" "$body_file")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    echo -e "${GREEN}$rift_rps req/sec${NC} (failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 14546)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:14546/" "$body_file")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$((rift_rps / mb_rps))
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC} on deepEquals predicates"
    fi

    rm -f "$body_file"
}

benchmark_regex() {
    print_header "Regex Predicate Benchmark"
    echo ""
    echo "Testing complex regex patterns (UUID path + email in body)"
    echo "Requests: $REQUESTS | Concurrency: $CONCURRENCY"
    echo ""

    # Create test body
    local body_file="/tmp/regex_body.json"
    cat > "$body_file" << 'EOF'
{
    "email": "john.doe@example.com",
    "name": "John Doe"
}
EOF

    # Use a path that matches the UUID regex
    local test_path="/api/v1/users/550e8400-e29b-41d4-a716-446655440000"

    echo -n "Benchmarking Rift (port 4547)... "
    local rift_result=$(run_benchmark "rift" "http://127.0.0.1:4547${test_path}" "$body_file")
    local rift_rps=$(echo "$rift_result" | cut -d'|' -f1)
    local rift_failed=$(echo "$rift_result" | cut -d'|' -f2)
    echo -e "${GREEN}$rift_rps req/sec${NC} (failed: $rift_failed)"

    echo -n "Benchmarking Mountebank (port 14547)... "
    local mb_result=$(run_benchmark "mb" "http://127.0.0.1:14547${test_path}" "$body_file")
    local mb_rps=$(echo "$mb_result" | cut -d'|' -f1)
    local mb_failed=$(echo "$mb_result" | cut -d'|' -f2)
    echo -e "${YELLOW}$mb_rps req/sec${NC} (failed: $mb_failed)"

    if [ -n "$rift_rps" ] && [ -n "$mb_rps" ] && [ "$mb_rps" -gt 0 ] 2>/dev/null; then
        local speedup=$((rift_rps / mb_rps))
        echo ""
        echo -e "  ${CYAN}Rift is ${GREEN}${speedup}x faster${NC} on regex predicates"
    fi

    rm -f "$body_file"
}

print_summary() {
    print_header "BENCHMARK SUMMARY"
    echo -e "${YELLOW}TIP: Run ./scripts/benchmark-extreme.sh for 300-400x results${NC}"
    echo "     with many stubs + JSONPath predicates"
    echo ""
}

# Main
check_ab

# Check servers
if ! curl -s "$RIFT_ADMIN/imposters" > /dev/null 2>&1; then
    echo -e "${RED}Error: Rift is not running${NC}"
    echo "Start with: docker-compose up rift -d"
    exit 1
fi

if ! curl -s "$MB_ADMIN/imposters" > /dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Mountebank is not running${NC}"
    echo "Start with: docker-compose up mountebank -d"
    echo "Or run: $0 rift-only"

    if [ "${1:-}" != "rift-only" ]; then
        exit 1
    fi
fi

case "${1:-all}" in
    jsonpath)
        setup_mountebank_imposters
        benchmark_jsonpath
        ;;
    deepequals)
        setup_mountebank_imposters
        benchmark_deepequals
        ;;
    regex)
        setup_mountebank_imposters
        benchmark_regex
        ;;
    all)
        setup_mountebank_imposters
        benchmark_jsonpath
        benchmark_deepequals
        benchmark_regex
        print_summary
        ;;
    rift-only)
        echo "Running Rift-only benchmarks..."
        benchmark_jsonpath 2>/dev/null || true
        benchmark_deepequals 2>/dev/null || true
        benchmark_regex 2>/dev/null || true
        ;;
    *)
        echo "Usage: $0 [jsonpath|deepequals|regex|all|rift-only]"
        echo ""
        echo "Environment variables:"
        echo "  REQUESTS=1000      Number of requests (default: 1000)"
        echo "  CONCURRENCY=50     Concurrent connections (default: 50)"
        exit 1
        ;;
esac
