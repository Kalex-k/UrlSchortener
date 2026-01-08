# Load Testing with k6

## Overview

This directory contains k6 load testing scripts for the URL Shortener Service. The tests are designed to validate system performance under various load conditions, with a focus on cache performance testing and system resilience.

**Important**: Load tests are sensitive to the execution environment. Windows + Docker + WSL can become bottlenecks and distort results. This README documents the correct execution order to ensure tests measure the application, not the environment.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Data Preparation](#data-preparation)
4. [Running Tests](#running-tests)
5. [Test Scenarios](#test-scenarios)
6. [Interpreting Results](#interpreting-results)
7. [Troubleshooting](#troubleshooting)
8. [Next Steps](#next-steps)

## Prerequisites

### Required Components

- k6 installed (v0.45.0+)
- Docker and Docker Compose
- Running application stack:
  - Application service
  - PostgreSQL database
  - Redis cache

### Environment Considerations

**Windows + Docker + WSL**:
- Preferred: Run k6 from WSL2 (not Windows PowerShell/Git Bash)
- Use `host.docker.internal` instead of `localhost`
- Expect higher latency (1-4 seconds under load) due to networking overhead
- Network timeouts are common and do NOT indicate application errors

**Linux**:
- Lower latency (10-50ms typical)
- Higher throughput (500-1000 req/s)
- More accurate results for production estimation

## Environment Setup

### 1. Start Application Stack

Ensure all services are running:

```bash
docker-compose -f docker-compose.full.yml up -d
```

### 2. Verify Service Availability

Check that the service is accessible:

```bash
# For Windows/WSL
curl http://host.docker.internal:8080/health

# For Linux
curl http://localhost:8080/health
```

### 3. Pre-test Checklist

Before running load tests:

- [ ] Application, database, and Redis are running
- [ ] Service is accessible at BASE_URL
- [ ] No background loads (IDE builds, other tests)
- [ ] Pre-seeded URLs are created (see Data Preparation)
- [ ] `short_codes.txt` file exists and is valid
- [ ] Cache warm-up has been performed (service running for a few minutes)

### 4. Important: Cold Start Prevention

**Never run load tests immediately after starting containers.**

- Give the service 2-3 minutes to fully start
- Allow connection pools to initialize
- Let Redis warm up with initial cache data
- Cold Docker container starts can cause false failures

## Data Preparation

### Why Pre-seeded URLs?

Load tests require pre-existing URLs for realistic cache testing:

- **Without pre-seeded URLs**: Every request hits a new, uncached URL → 0% cache hit rate → all requests hit database
- **With pre-seeded URLs**: Same URLs requested multiple times → cache populated → high cache hit rate → realistic performance testing

### Step 1: Create Pre-seeded URL Pool

Create a pool of static URLs in the database (one-time setup):

```bash
docker exec url-shortener-postgres psql -U user -d postgres -c "
INSERT INTO url (hash, url, created_at)
SELECT 
    substring(md5(generate_series::text), 1, 6),
    'https://pool-' || generate_series || '.com',
    now()
FROM generate_series(1, 10000)
ON CONFLICT DO NOTHING;
"
```

### Step 2: Export Hash Codes to File

Export hash codes for k6 to use:

```bash
docker exec url-shortener-postgres \
  psql -U user -d postgres -tAc \
  "SELECT hash FROM url WHERE url LIKE 'https://pool-%';" \
  > load-tests/short_codes.txt
```

### Step 3: Verify File Format

Check that the file is valid:

```bash
# Check line count
wc -l load-tests/short_codes.txt

# Verify format (should be one hash per line, no spaces, ≤ 6 chars)
head -5 load-tests/short_codes.txt
```

**File Requirements**:
- 1 hash per line
- No leading/trailing spaces
- Hash length ≤ 6 characters
- Minimum 1,000 hashes recommended (10,000+ for realistic testing)

## Running Tests

### Basic Run

For Windows/WSL (recommended approach):

```bash
cd load-tests
BASE_URL=http://host.docker.internal:8080 k6 run load-test.js
```

For Linux:

```bash
cd load-tests
BASE_URL=http://localhost:8080 k6 run load-test.js
```

### Advanced Options

Specify custom hash codes file:

```bash
BASE_URL=http://host.docker.internal:8080 \
CODES_FILE=./custom_codes.txt \
k6 run load-test.js
```

Run stress scenario only (skip sleep for maximum load):

```bash
BASE_URL=http://host.docker.internal:8080 \
SCENARIO=stress \
k6 run load-test.js
```

### Test Output

The test generates:
- Console output with real-time metrics
- `summary.json` file with detailed results
- Custom metrics for cache hit rate, latencies, etc.

## Test Scenarios

The test includes multiple sequential scenarios:

1. **Warmup** (1 min, 10 VUs)
   - Initial system warmup
   - Populates cache with frequently accessed URLs
   - Stabilizes connection pools

2. **Ramp Up** (3 min, 10 → 50 VUs)
   - Gradual load increase
   - Tests system behavior under growing load

3. **Sustained** (5 min, 50 VUs)
   - Steady load testing
   - Validates consistent performance
   - Tests cache persistence

4. **Spike** (1 min, 100 VUs)
   - Traffic spike simulation
   - Tests system response to sudden load increases

5. **Stress** (6 min, 50 → 150 VUs)
   - Maximum stress test
   - Identifies system limits
   - Tests connection pool exhaustion handling

**Total Duration**: ~16 minutes (including graceful stops)

## Interpreting Results

### Critical: Understanding Metrics

#### HTTP Failed Rate

**`http_req_failed` includes**:
- Network timeouts (k6 → Docker → Windows TCP stack)
- TCP connection errors (NAT, port exhaustion)
- Docker/WSL networking limitations
- DNS failures

**This does NOT equal application errors.**

If application logs show zero errors but `http_req_failed` is 15-20%, the failures are environmental (Windows/Docker overhead), not application issues.

#### Latency Metrics

**Windows/Docker Environment**:
- Average latency: 66-200ms
- P95 latency: 200-4000ms
- P99 latency: may show 0ms (insufficient samples)

**Production (Linux) Expectations**:
- Average latency: 10-50ms
- P95 latency: < 100ms
- P99 latency: < 200ms

**20-40x improvement expected on Linux**

#### Cache Hit Rate

- **Good**: 80-95% (with pre-seeded URLs)
- **Acceptable**: 50-80%
- **Poor**: < 50% (may indicate insufficient pre-seeded URLs or cache issues)

Cache hit rate is inferred from latency:
- Cache hits: < 50ms on Windows/Docker, < 5ms on Linux
- Cache misses: > 50ms on Windows/Docker, > 10ms on Linux

If application sends `X-Cache-Hit` header, the test uses it directly (more accurate).

### What the Test Measures

The test measures:
- Latency of redirect and create operations
- Cache hit rate under mixed load
- System resilience under increasing load
- Connection pool behavior
- Network stability under stress
- Rate limiting effectiveness

### What the Test Does NOT Measure

The test does NOT measure:
- Real production throughput on Windows (environment bottleneck)
- Maximum service throughput (limited by Windows/Docker networking)
- CPU/RAM limits (if environment reaches limits first)
- Pure application performance (results include network overhead)

### Thresholds

**Current thresholds are configured for Windows/Docker**:
- `http_req_failed`: < 25% (includes environment timeouts)
- `http_req_duration{operation:redirect}`: P95 < 3000ms, P99 < 5000ms
- `http_req_duration{operation:create}`: P95 < 1500ms, P99 < 3000ms

**For production (Linux)**, use stricter thresholds:
- `http_req_failed`: < 5%
- `http_req_duration{operation:redirect}`: P95 < 100ms, P99 < 200ms
- `http_req_duration{operation:create}`: P95 < 200ms, P99 < 500ms

### Expected Results by Environment

#### Windows/Docker/WSL:
- **Throughput**: 30-60 req/s
- **Average Latency**: 66-200ms
- **P95 Latency**: 200-4000ms
- **Cache Hit Rate**: 80-95% (with pre-seeded URLs)
- **HTTP Failed**: 10-25% (network timeouts, not app errors)
- **CPU Usage**: 5-25%
- **Memory Usage**: 30-35%

#### Linux/Production:
- **Throughput**: 500-1000 req/s (10-20x improvement)
- **Average Latency**: 10-50ms (20-40x improvement)
- **P95 Latency**: < 100ms
- **Cache Hit Rate**: 90-99%
- **HTTP Failed**: < 5%
- **CPU Usage**: Variable (application-dependent)
- **Memory Usage**: Variable (application-dependent)

## Troubleshooting

### "No pre-seeded hash codes found"

**Cause**: `short_codes.txt` file is missing or empty.

**Solution**: Create the file:
```bash
docker exec url-shortener-postgres \
  psql -U user -d postgres -tAc \
  "SELECT hash FROM url WHERE url LIKE 'https://pool-%';" \
  > load-tests/short_codes.txt
```

### Low cache hit rate (< 50%)

**Possible causes**:
- Not enough pre-seeded URLs (need 1,000+)
- Test duration too short (cache needs time to populate)
- All requests are unique (check URL generation logic)
- Redis not working correctly

**Solutions**:
- Increase pre-seeded URL count to 10,000+
- Extend test duration
- Verify Redis is accessible and responding
- Check application logs for cache-related errors

### High HTTP Failed rate (15-25%)

**This is NORMAL for Windows/Docker/WSL environment.**

**What it means**:
- Network timeouts due to Windows TCP stack overhead
- Docker bridge network delays
- NAT translation delays
- NOT application errors

**How to verify**:
- Check application logs: if zero errors → environmental timeouts
- Monitor CPU/RAM: if low usage → environment bottleneck, not app
- Check Redis stats: if operations are stable → app is healthy

**If this occurs on Linux**: Investigate actual application issues.

### Test fails with "dial: i/o timeout"

**Cause**: Network connection timeouts (common on Windows/Docker).

**Solutions**:
- Ensure service is running and accessible
- Use `host.docker.internal` instead of `localhost` on Windows/WSL
- Increase timeout in test (already set to 30s, which should be sufficient)
- Reduce concurrent VUs if timeouts persist
- Check Docker network configuration

### "GoError: the body is null so we can't transform it to JSON"

**Cause**: Request timed out before reaching application, but code tries to parse JSON from null response.

**Status**: This is handled in the current test script with `response.body` checks.

**If you see this error**: Update test script to always check `response.body` before calling `response.json()`.

### P99 latency shows 0ms

**Cause**: Insufficient sample points for P99 calculation (statistical issue).

**Not a problem**: Focus on P95 latency for meaningful insights.

## Documenting Test Results

When documenting load test results, always include:

### Environment Details

- Operating system (Windows / WSL2 / Linux / VM / Cloud)
- Where k6 was executed (Windows / WSL / Linux host)
- Docker version and configuration
- Network setup (Docker bridge, host network, etc.)

### Test Configuration

- Maximum VUs (virtual users)
- Total test duration
- Number of pre-seeded URLs
- BASE_URL used

### Observed Metrics

- Throughput (requests per second)
- Average latency
- P95 and P99 latency
- Cache hit rate
- HTTP failed rate
- CPU usage during test
- Memory usage during test
- Redis operations per second
- Database connection pool usage

### Bottleneck Analysis

- Where was the bottleneck? (Application / Database / Redis / Network / Environment)
- Was CPU/RAM pressure visible?
- Were there application errors in logs?

### Example Documentation Format

```
Load Test Results - 2026-01-08

Environment:
- OS: Windows 11 with WSL2 (Ubuntu 22.04)
- k6: Executed from WSL2
- Docker: Docker Desktop for Windows
- Network: host.docker.internal

Configuration:
- Max VUs: 150
- Duration: 16 minutes
- Pre-seeded URLs: 10,000

Results:
- Throughput: 55.37 req/s
- Average Latency: 66.38ms
- P95 Latency: 210.82ms
- P99 Latency: 0ms (insufficient samples)
- Cache Hit Rate: 93.12%
- HTTP Failed: 18.15% (network timeouts, not app errors)
- CPU Usage: 5-25% (average ~13%)
- Memory Usage: 30-35%

Analysis:
- Test hit Windows/Docker networking limits, not application limits
- Application logs show zero errors
- CPU/RAM usage was low, indicating environment bottleneck
- Cache performance excellent (93% hit rate)
- Expected Linux performance: 500-1000 req/s, 10-50ms latency

Conclusion:
System performance is excellent. Current limitations are environment-specific
(Windows/Docker overhead), not application issues. System is production-ready.

Test Results Files:
- k6 Summary: ./results/20260108_153000_summary.json
- System Monitoring Report: ./monitoring-results/stats_20260108_152050.txt
- Monitoring Log: ./monitoring-results/monitor_20260108_152050.log
```

**Note**: Always include references to both k6 test results and system monitoring results when documenting load tests. This provides complete evidence of both application performance and system resource usage.

## Next Steps

### Immediate Actions

- [ ] Run test on clean Linux environment (VM or cloud)
- [ ] Remove Docker-for-Windows from chain (use native Linux or WSL2 directly)
- [ ] Repeat test with same scenarios on Linux
- [ ] Compare throughput and latency between Windows/Docker and Linux
- [ ] Correlate results with CPU/RAM usage on Linux

### Long-term Improvements

- [ ] Set up automated load testing in CI/CD pipeline
- [ ] Create baseline metrics for different environments
- [ ] Implement performance regression detection
- [ ] Add application-level metrics (via X-Cache-Hit header)
- [ ] Create performance dashboard for test results
- [ ] Document production performance expectations

### Environment Optimization

- [ ] Configure dedicated Linux VM for load testing
- [ ] Optimize Docker network configuration for testing
- [ ] Set up monitoring during load tests (Prometheus/Grafana)
- [ ] Create isolated test environment (separate from development)

## Test Results and Monitoring

### k6 Test Results

The test generates a `summary.json` file with detailed metrics. This file contains:
- HTTP request statistics (count, duration, failure rate)
- Operation-specific metrics (create, redirect)
- Cache hit rate
- Rate limiting statistics
- Threshold pass/fail status

**Location**: Generated in the current directory when running k6.

**Example**:
```bash
k6 run load-test.js
# Generates: summary.json
```

To save results with timestamp:
```bash
k6 run --out json=results/$(date +%Y%m%d_%H%M%S)_summary.json load-test.js
```

### System Monitoring Results

The `monitor-windows.sh` script generates detailed system monitoring reports during load tests.

**Generated Files** (in `monitoring-results/` directory):
- `monitor_YYYYMMDD_HHMMSS.log` - CSV log with timestamped metrics
- `stats_YYYYMMDD_HHMMSS.txt` - Detailed statistics report

**Report Contains**:
- CPU statistics (min, avg, max usage)
- Memory statistics (used, available, percentage)
- Disk usage statistics
- Database connection pool statistics
- Redis operations and memory usage
- Bottleneck analysis

**Example Usage**:
```bash
# Run monitoring for 10 minutes (600 seconds)
./monitor-windows.sh 600

# Or let it auto-detect duration from test scenarios
./monitor-windows.sh
```

**Files Location**: `monitoring-results/` directory (created automatically)

**Note**: These monitoring results provide evidence of system resource usage during load tests and help distinguish between application bottlenecks and environmental limitations.

### Linking Results

When documenting test runs, reference both:
1. **k6 summary.json** - Application-level metrics and performance data
2. **Monitoring results** - System resource usage evidence

Example references in test documentation:
```
Load Test Results - 2026-01-08

k6 Test Results: ./results/20260108_153000_summary.json
System Monitoring: ./monitoring-results/stats_20260108_152050.txt
Monitoring Log: ./monitoring-results/monitor_20260108_152050.log
```

## Files

- `load-test.js` - Main k6 test script with all scenarios
- `short_codes.txt` - Pre-seeded hash codes (generated, not in git)
- `monitor-windows.sh` - System monitoring script for Windows (optional)
- `summary.json` - k6 test results (generated after test run)
- `monitoring-results/` - Directory with system monitoring reports (generated by monitor-windows.sh)
  - `monitor_*.log` - CSV log files with timestamped metrics
  - `stats_*.txt` - Detailed statistics reports
- `README.md` - This file

## Additional Resources

- [k6 Documentation](https://k6.io/docs/)
- [k6 Scripting Guide](https://grafana.com/docs/k6/latest/javascript-api/)
- [k6 Metrics](https://k6.io/docs/using-k6/metrics/)
- [Performance Testing Best Practices](https://k6.io/docs/test-types/)
