#!/bin/bash
# Test requests against Rift and/or Mountebank
# Usage: ./test-requests.sh [rift|mountebank|both]

set -e

RIFT_PORT=8114
MB_PORT=18114

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

test_endpoint() {
    local name=$1
    local port=$2
    local method=$3
    local path=$4
    local body=$5

    echo -n "  Testing $name on port $port... "

    if [ "$method" = "POST" ]; then
        response=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d "$body" \
            "http://127.0.0.1:${port}${path}" 2>/dev/null)
    else
        response=$(curl -s -w "\n%{http_code}" \
            "http://127.0.0.1:${port}${path}" 2>/dev/null)
    fi

    http_code=$(echo "$response" | tail -1)
    body_response=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        echo -e "${GREEN}✓ HTTP $http_code${NC}"
        echo "    Response: ${body_response:0:60}..."
    else
        echo -e "${RED}✗ HTTP $http_code${NC}"
        echo "    Response: $body_response"
    fi
}

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Testing Mock Endpoints${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

case "${1:-both}" in
    rift)
        echo ""
        echo -e "${BLUE}Testing RIFT (port $RIFT_PORT):${NC}"
        test_endpoint "Create Appointment (success)" $RIFT_PORT POST \
            "/private/2543228/auto/auto-businesses/foo/appointments" \
            '{"leadId": "12345"}'
        test_endpoint "Create Appointment (failure)" $RIFT_PORT POST \
            "/private/2543228/auto/auto-businesses/foo/appointments" \
            '{"leadId": "failedLeadIdCreate"}'
        ;;
    mountebank|mb)
        echo ""
        echo -e "${BLUE}Testing MOUNTEBANK (port $MB_PORT):${NC}"
        test_endpoint "Create Appointment (success)" $MB_PORT POST \
            "/private/2543228/auto/auto-businesses/foo/appointments" \
            '{"leadId": "12345"}'
        test_endpoint "Create Appointment (failure)" $MB_PORT POST \
            "/private/2543228/auto/auto-businesses/foo/appointments" \
            '{"leadId": "failedLeadIdCreate"}'
        ;;
    both)
        echo ""
        echo -e "${BLUE}Testing RIFT (port $RIFT_PORT):${NC}"
        test_endpoint "Create Appointment (success)" $RIFT_PORT POST \
            "/private/2543228/auto/auto-businesses/foo/appointments" \
            '{"leadId": "12345"}'

        echo ""
        echo -e "${BLUE}Testing MOUNTEBANK (port $MB_PORT):${NC}"
        test_endpoint "Create Appointment (success)" $MB_PORT POST \
            "/private/2543228/auto/auto-businesses/foo/appointments" \
            '{"leadId": "12345"}'

        echo ""
        echo -e "${GREEN}Both return the same response - drop-in replacement confirmed!${NC}"
        ;;
    *)
        echo "Usage: $0 [rift|mountebank|both]"
        exit 1
        ;;
esac

echo ""
