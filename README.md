# Rift Demo

This demo showcases Rift - a high-performance, Mountebank-compatible HTTP mock server. You'll see how Rift can be a drop-in replacement for Mountebank with **4-445x better performance**.

## Prerequisites

- Docker and Docker Compose
- curl
- jq (optional, for JSON formatting)
- Apache Bench (`ab`) for benchmarks
  - macOS: `brew install httpd`
  - Linux: `apt install apache2-utils`

## Quick Start

```bash
# Clone the demo repository
git clone https://github.com/EtaCassiopeia/rift-demo.git
cd rift-demo

# Start Rift with sample imposters
docker-compose up rift -d

# Verify it's running
curl -s http://localhost:2525/imposters | jq '.imposters | length'

# Test an endpoint
curl -X POST http://localhost:8114/private/2543228/auto/auto-businesses/foo/appointments \
  -H "Content-Type: application/json" \
  -d '{"leadId": "12345"}'
```

## Demo Scenarios

### 1. Basic Usage - Load Existing Configs

Start Rift with the sample Solo/Mimeo configurations:

```bash
docker-compose up rift -d

# Check loaded imposters
curl -s http://localhost:2525/imposters | jq '{count: .imposters | length}'

# Test the appointment endpoint
curl -X POST http://localhost:8114/private/2543228/auto/auto-businesses/foo/appointments \
  -H "Content-Type: application/json" \
  -d '{"leadId": "12345"}'
# Returns: Appointment created successfully

# Test error case
curl -X POST http://localhost:8114/private/2543228/auto/auto-businesses/foo/appointments \
  -H "Content-Type: application/json" \
  -d '{"leadId": "failedLeadIdCreate"}'
# Returns: 500 error
```

### 2. Side-by-Side Comparison with Mountebank

Run both Rift and Mountebank with the same configuration:

```bash
# Start both servers
docker-compose up rift mountebank -d

# Wait for startup
sleep 5

# Test Rift (port 8114)
curl -s -X POST http://localhost:8114/private/2543228/auto/auto-businesses/foo/appointments \
  -H "Content-Type: application/json" \
  -d '{"leadId": "12345"}'

# Test Mountebank (port 18114 - offset by 10000)
curl -s -X POST http://localhost:18114/private/2543228/auto/auto-businesses/foo/appointments \
  -H "Content-Type: application/json" \
  -d '{"leadId": "12345"}'

# Both return identical responses!
```

Or use the test script:

```bash
./scripts/test-requests.sh both
```

### 3. Performance Benchmark

Compare performance between Rift and Mountebank:

```bash
# Make sure both are running
docker-compose up rift mountebank -d
sleep 5

# Run benchmark
./scripts/benchmark.sh both
```


Customize the benchmark:

```bash
REQUESTS=5000 CONCURRENCY=100 ./scripts/benchmark.sh both
```

#### Comprehensive Benchmarks

Test various predicate types with 200 concurrent connections:

```bash
# Run comprehensive benchmark suite
./scripts/benchmark-comprehensive.sh
```

**Results (200 concurrent connections, 1000 requests):**

| Scenario | Rift | Mountebank | Speedup |
|----------|------|------------|---------|
| Health Check (simple equals) | 10,344 req/s | 2,552 req/s | **4x** |
| JSONPath predicate | 14,264 req/s | 2,705 req/s | **5x** |
| XPath predicate | 15,060 req/s | 2,921 req/s | **5x** |
| Complex AND/OR | 15,638 req/s | 3,859 req/s | **4x** |
| Last stub match (50 stubs) | 15,234 req/s | 2,423 req/s | **6x** |

#### Extended Benchmarks

Test specific predicate types:

```bash
# Run all extended benchmarks
./scripts/benchmark-extended.sh all

# Or test specific scenarios
./scripts/benchmark-extended.sh jsonpath    # JSONPath predicates
./scripts/benchmark-extended.sh deepequals  # Deep object comparison
./scripts/benchmark-extended.sh regex       # Complex regex matching
```

#### Extreme Benchmark (8-445x faster)

For scenarios with many stubs and complex predicates (common in large service virtualization setups):

```bash
./scripts/benchmark-extreme-comprehensive.sh
```

This benchmark creates 300 stubs per scenario, with the matching stub always at the END (worst case for linear scan). Tests all predicate types:

**Results (300 stubs × multiple predicates, 200 concurrent connections):**

| Scenario | Rift | Mountebank | Speedup |
|----------|------|------------|---------|
| Simple Equals | 15,433 req/s | 618 req/s | **24x** |
| JSONPath (×2 predicates) | 13,377 req/s | 30 req/s | **445x** |
| XPath (×2 predicates) | 2,834 req/s | 65 req/s | **43x** |
| Complex AND/OR (×3 predicates) | 14,233 req/s | 172 req/s | **82x** |
| Regex (×2 predicates) | 336 req/s | 40 req/s | **8x** |

> **Why the difference?** Mountebank uses linear O(n) stub scanning, evaluating all predicates sequentially. Rift uses hybrid indexing (HashMap + Radix Trie + Aho-Corasick) for O(1) lookup regardless of stub count.

### 4. Proxy Recording (proxyOnce)

Record real API responses and replay them:

```bash
# Start Rift and Echo server
docker-compose up rift echo -d
sleep 3

# Create a recording proxy imposter
curl -X POST http://localhost:2525/imposters -H "Content-Type: application/json" -d '{
  "port": 5555,
  "protocol": "http",
  "name": "Recording Proxy",
  "stubs": [{
    "responses": [{
      "proxy": {
        "to": "http://echo:9090",
        "mode": "proxyOnce",
        "predicateGenerators": [
          {"matches": {"method": true, "path": true}}
        ]
      }
    }]
  }]
}'

# Send requests to record them
curl http://localhost:5555/api/users
curl -X POST http://localhost:5555/api/users -H "Content-Type: application/json" -d '{"name":"Alice"}'
curl http://localhost:5555/api/users/123

# Check recorded stubs
curl -s http://localhost:2525/imposters/5555 | jq '{stubs: .stubs | length}'
# Returns: 4 (3 recorded + 1 proxy)

# Stop the echo server
docker-compose stop echo

# Requests still work - using recorded responses!
curl http://localhost:5555/api/users
curl http://localhost:5555/api/users/123

# New endpoints fail (not recorded)
curl http://localhost:5555/api/new-endpoint
# Returns: proxy error
```

### 5. Configuration Linting

Validate imposter configurations:

```bash
# Using Docker
docker run --rm -v $(pwd)/imposters:/imposters zainalpour/rift-lint /imposters

# Check problematic config
docker run --rm -v $(pwd)/lint-examples:/configs zainalpour/rift-lint /configs/problematic-config.json

# Expected output shows errors:
# - Invalid regex pattern
# - Invalid HTTP status code
# - Unknown predicate operator
```

### 6. Interactive TUI

Browse and manage imposters interactively with rift-tui.

**Installation via Homebrew (recommended):**
```bash
# Add the Rift tap
brew tap EtaCassiopeia/rift

# Install Rift (includes rift, rift-lint, and rift-tui)
brew install rift
```

**Or build from source:**
```bash
git clone https://github.com/EtaCassiopeia/rift.git
cd rift
cargo build --release --bin rift-tui
```

**Usage:**
```bash
# Make sure Rift is running first
docker-compose up rift -d

# Launch TUI (connects to localhost:2525 by default)
rift-tui

# Or specify a different admin URL
rift-tui --admin-url http://localhost:2525
```

## Cleanup

```bash
# Stop all services
docker-compose down

# Remove volumes
docker-compose down -v
```


## Resources

- [Rift Documentation](https://etacassiopeia.github.io/rift/)
- [Rift GitHub](https://github.com/EtaCassiopeia/rift)
- [Mountebank Docs](http://www.mbtest.org/)
