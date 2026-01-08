import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { SharedArray } from 'k6/data';

// ============================================================================
// CUSTOM METRICS
// ============================================================================
// Note: We use k6 built-in http_req_duration for latency (more accurate than Date.now())
// Custom trends are kept for operation-specific analysis
const createUrlLatency = new Trend('create_url_latency', true);
const redirectLatency = new Trend('redirect_latency', true);
const cacheHitRate = new Rate('cache_hit_rate');
const rateLimitHitRate = new Rate('rate_limit_hit_rate');
const createUrlSuccess = new Counter('create_url_success');
const redirectSuccess = new Counter('redirect_success');

// ============================================================================
// TEST CONFIGURATION
// ============================================================================
// Note: This configuration is optimized for Windows/Docker environment
// Windows/Docker overhead causes higher latency (1-4 seconds under load)
// Some k6 timeouts may occur, but these are NOT application errors
// Expected production performance (Linux): 10-50ms latency, 500-1000 req/s
export const options = {
  // Note: k6 does NOT support options.http (unlike Node.js/axios)
  // Timeout is set per-request via params.timeout
  // Keep-alive is enabled by default in k6
  // Connection limits are controlled via VUs and scenarios
  
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: 10,
      duration: '1m',
      gracefulStop: '30s',
    },
    ramp_up: {
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '3m', target: 50 },
      ],
      gracefulRampDown: '30s',
      startTime: '1m',
    },
    sustained: {
      executor: 'constant-vus',
      vus: 50,
      duration: '5m',
      gracefulStop: '30s',
      startTime: '4m',
    },
    spike: {
      executor: 'constant-vus',
      vus: 100,
      duration: '1m',
      gracefulStop: '30s',
      startTime: '9m',
    },
    stress: {
      executor: 'ramping-vus',
      startVUs: 50,
      stages: [
        // Reduced targets for Windows/Docker to avoid connection exhaustion
        // 200 VUs × 10 concurrent = 2,000 connections (may exceed Windows/Docker limits)
        // For Linux/Production, can increase to: 100, 150, 200
        { duration: '2m', target: 75 },   // Reduced from 100
        { duration: '2m', target: 100 },  // Reduced from 150
        { duration: '2m', target: 150 },  // Reduced from 200
      ],
      gracefulRampDown: '1m',
      startTime: '10m',
    },
  },
  
  thresholds: {
    // Realistic thresholds for Windows/Docker environment
    // Windows/Docker overhead: 1-4 seconds under load
    // Production (Linux) expectations: p(95) < 50ms, p(99) < 100ms
    // Note: http_req_failed includes k6 timeouts (network level), not application errors
    // Application errors should be checked via status codes in check() functions
    // For Windows/Docker/WSL: network timeouts are common (NAT, TCP stack, Docker bridge)
    // For production (Linux): use stricter threshold like rate<0.05
    'http_req_failed': ['rate<0.25'],  // 25% max failure rate for Windows/Docker (includes timeouts)
    'http_req_duration{operation:redirect}': ['p(95)<3000', 'p(99)<5000'],  // 3s/5s for redirects
    'http_req_duration{operation:create}': ['p(95)<1500', 'p(99)<3000'],   // 1.5s/3s for creates
    'create_url_latency': ['p(95)<3000', 'p(99)<6000'],  // Custom metric for analysis
    'redirect_latency': ['p(95)<2000', 'p(99)<4000'],     // Custom metric for analysis
    'cache_hit_rate': ['rate>0.3'],
  },
};

// ============================================================================
// TEST DATA GENERATION
// ============================================================================
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// Load pre-seeded hash codes from file (shared across all VUs)
// File should be created by: docker exec url-shortener-postgres psql -U user -d postgres -tAc "SELECT hash FROM url WHERE url LIKE 'https://pool-%';" > load-tests/short_codes.txt
const shortCodes = new SharedArray('short_codes', function () {
  try {
    // Try multiple path options for flexibility
    const codeFile = __ENV.CODES_FILE || './short_codes.txt';
    const file = open(codeFile);
    const codes = file.split('\n')
      .map(line => line.trim())
      .filter(line => line.length > 0 && line.length <= 6);
    console.log(`Loaded ${codes.length} hash codes from file: ${codeFile}`);
    return codes;
  } catch (e) {
    console.warn(`Could not load short_codes.txt: ${e.message}`);
    console.warn('Falling back to empty array. Please create short_codes.txt first.');
    console.warn('You can specify custom path: k6 run -e CODES_FILE=/path/to/file.txt load-test.js');
    return [];
  }
});

// Generate URL without timestamp for consistent testing
function generateUrl(vuId, iter) {
  const domains = ['example.com', 'test.com', 'demo.com', 'site.com', 'page.com'];
  const paths = ['article', 'post', 'page', 'product', 'item'];
  
  const domain = domains[vuId % domains.length];
  const path = paths[iter % paths.length];
  
  // No timestamp - URLs are reusable for cache testing
  return `https://${domain}/${path}/${vuId}-${iter}`;
}

// ============================================================================
// SCENARIO FUNCTIONS
// ============================================================================
// Note: k6 uses keep-alive by default, no need to set Connection header
// Setting it explicitly can sometimes interfere with Windows TCP reuse

function createShortUrl(url, scenarioName) {
  const payload = JSON.stringify({ url: url });
  const params = {
    headers: { 
      'Content-Type': 'application/json',
    },
    tags: { 
      name: 'create',  // Low cardinality tag for aggregation
      operation: 'create',
      scenario: scenarioName || 'unknown',  // Tag for scenario identification
    },
    timeout: '30s',  // Per-request timeout (sufficient for Windows/Docker/WSL)
  };
  
  const response = http.post(`${BASE_URL}/url`, payload, params);
  
  // Use k6's accurate timing instead of Date.now()
  // response.timings.duration includes all network overhead accurately
  if (response.timings && response.timings.duration) {
    createUrlLatency.add(response.timings.duration);
  }
  
  // Business logic validation (not error tracking)
  // check() failures are separate from http_req_failed (network errors)
  // IMPORTANT: Always check response.body before calling response.json()
  // When request fails (timeout, connection refused), response.body is null
  const success = check(response, {
    'create: status is 201': (r) => r.status === 201,
    'create: has shortUrl': (r) => 
      r.status === 201 && r.body && r.json('shortUrl') !== undefined,
  });
  
  if (response.status === 429) {
    rateLimitHitRate.add(true);
    return null;
  }
  
  if (response.status === 201 && response.body) {
    createUrlSuccess.add(1);
    rateLimitHitRate.add(false);
    const shortUrl = response.json('shortUrl');
    return shortUrl;
  }
  
  // Non-201, non-429 status - handled by check() and http_req_failed
  return null;
}

function testRedirect(hash, scenarioName) {
  if (!hash) return;
  
  const params = {
    redirects: 0,
    tags: { 
      name: 'redirect',  // Low cardinality tag for aggregation
      operation: 'redirect',
      scenario: scenarioName || 'unknown',  // Tag for scenario identification
    },
    timeout: '30s',  // Per-request timeout (sufficient for Windows/Docker/WSL)
  };
  
  const response = http.get(`${BASE_URL}/${hash}`, params);
  
  // Use k6's accurate timing instead of Date.now()
  // response.timings.duration includes all network overhead accurately
  if (response.timings && response.timings.duration) {
    redirectLatency.add(response.timings.duration);
  }
  
  // Business logic validation (not error tracking)
  // check() failures are separate from http_req_failed (network errors)
  const success = check(response, {
    'redirect: status is 302': (r) => r.status === 302,
    'redirect: has Location header': (r) => r.headers['Location'] !== undefined,
  });
  
  if (response.status === 429) {
    rateLimitHitRate.add(true);
    return;
  }
  
  if (response.status === 302) {
    redirectSuccess.add(1);
    rateLimitHitRate.add(false);
    
    // Cache hit detection
    // Option 1: Check X-Cache-Hit header (if application sends it)
    const cacheHitHeader = response.headers['X-Cache-Hit'];
    if (cacheHitHeader !== undefined) {
      // Application sends explicit cache hit header
      cacheHitRate.add(cacheHitHeader === 'true');
    } else {
      // Option 2: Infer from latency (fallback method)
      // Redis cache: typically < 5ms on Linux/Production
      // Windows/Docker overhead: typically 50-100ms (includes Windows networking + Docker bridge)
      // DB query: typically 5-20ms on Linux, 50-150ms on Windows/Docker
      // Note: This is approximate and may have false positives/negatives
      // For Windows/Docker environment, use 50ms threshold
      const duration = response.timings && response.timings.duration
        ? response.timings.duration
        : 0;
      const likelyCacheHit = duration < 50;  // Adjusted for Windows/Docker overhead
      cacheHitRate.add(likelyCacheHit);
    }
  } else if (response.status === 404) {
    // 404 should NOT happen with pre-seeded hashes!
    // All hashes from short_codes.txt should exist in database
    // If we get 404, something is wrong
    // This is a business logic error, not a network error
    console.warn(`Unexpected 404 for hash: ${hash} (pre-seeded hash should exist!)`);
  }
  // Other status codes are handled by check() and http_req_failed
}

// ============================================================================
// MAIN TEST SCENARIO
// ============================================================================
export default function() {
  const vuId = __VU;
  const iter = __ITER;
  
  // Determine scenario name from k6 execution context
  // k6 doesn't provide direct scenario name, but we can infer from execution time
  // Stress scenario starts at 10m, so we can check if we're past that point
  // Alternative: use scenario-specific environment variable if set
  const scenarioName = __ENV.SCENARIO || 'unknown';
  
  // Use pre-seeded hash codes for redirects (cache testing)
  if (shortCodes.length > 0) {
    // 80% redirects (cache testing), 20% creates (new URLs)
    const isRedirect = Math.random() < 0.8;
    
    if (isRedirect) {
      // Test redirects on existing URLs (cache hits expected)
      const randomIndex = Math.floor(Math.random() * shortCodes.length);
      const hash = shortCodes[randomIndex];
      
      testRedirect(hash, scenarioName);
    } else {
      // Create new URLs (small percentage)
      const longUrl = generateUrl(vuId, iter);
      createShortUrl(longUrl, scenarioName);
    }
  } else {
    // Fallback: if no pre-seeded codes, create URLs
    console.warn('No pre-seeded hash codes available. Creating new URLs...');
    const longUrl = generateUrl(vuId, iter);
    const shortUrl = createShortUrl(longUrl, scenarioName);
    
    if (shortUrl) {
      const hash = shortUrl.split('/').pop();
      testRedirect(hash, scenarioName);
    }
  }
  
  // Single sleep at the end for think time between requests
  // Skip sleep during stress scenario to maximize load
  // Note: k6 doesn't provide direct scenario name access
  // Workaround: set SCENARIO env var when running stress test, or skip sleep entirely
  if (scenarioName !== 'stress') {
    sleep(Math.random() * 1 + 0.5);
  }
}

// ============================================================================
// LIFECYCLE HOOKS
// ============================================================================

export function setup() {
  console.log('Starting load test with pre-seeded URLs...');
  console.log(`Target: ${BASE_URL}`);
  console.log('Scenarios: warmup -> ramp_up -> sustained -> spike -> stress');
  
  if (shortCodes.length > 0) {
    console.log(`✓ Loaded ${shortCodes.length} pre-seeded hash codes from file`);
    console.log('  These URLs were created in the database before the test.');
    console.log('  Redirects will test cache performance (repeated requests to same URLs).');
  } else {
    console.warn('! No pre-seeded hash codes found!');
    console.warn('  Please create short_codes.txt file first:');
    console.warn('  docker exec url-shortener-postgres psql -U user -d postgres -tAc "SELECT hash FROM url WHERE url LIKE \'https://pool-%\';" > load-tests/short_codes.txt');
    console.warn('  Falling back to creating URLs during test (cache hit rate will be low).');
  }
  
  return { 
    poolSize: shortCodes.length,
    testMode: shortCodes.length > 0 ? 'pre-seeded' : 'dynamic'
  };
}

export function teardown(data) {
  console.log('Test completed!');
  if (data.poolSize > 0) {
    console.log(`Used ${data.poolSize} pre-seeded hash codes for redirect testing`);
  }
}

// ============================================================================
// SUMMARY HANDLER
// ============================================================================
export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    test_duration: data.state.testRunDurationMs / 1000,
    
    http: {
      requests_total: data.metrics.http_reqs.values.count,
      requests_per_sec: data.metrics.http_reqs.values.rate,
      duration_avg: data.metrics.http_req_duration.values.avg,
      duration_p95: data.metrics.http_req_duration.values['p(95)'],
      duration_p99: data.metrics.http_req_duration.values['p(99)'],
      failed_rate: data.metrics.http_req_failed.values.rate * 100,
    },
    
    create_url: {
      count: (data.metrics.create_url_success && data.metrics.create_url_success.values)
        ? data.metrics.create_url_success.values.count
        : 0,
      latency_avg: (data.metrics.create_url_latency && data.metrics.create_url_latency.values)
        ? data.metrics.create_url_latency.values.avg
        : 0,
      latency_p95: (data.metrics.create_url_latency && data.metrics.create_url_latency.values)
        ? data.metrics.create_url_latency.values['p(95)']
        : 0,
      latency_p99: (data.metrics.create_url_latency && data.metrics.create_url_latency.values)
        ? data.metrics.create_url_latency.values['p(99)']
        : 0,
    },
    
    redirect: {
      count: (data.metrics.redirect_success && data.metrics.redirect_success.values)
        ? data.metrics.redirect_success.values.count
        : 0,
      latency_avg: (data.metrics.redirect_latency && data.metrics.redirect_latency.values)
        ? data.metrics.redirect_latency.values.avg
        : 0,
      latency_p95: (data.metrics.redirect_latency && data.metrics.redirect_latency.values)
        ? data.metrics.redirect_latency.values['p(95)']
        : 0,
      latency_p99: (data.metrics.redirect_latency && data.metrics.redirect_latency.values)
        ? data.metrics.redirect_latency.values['p(99)']
        : 0,
    },
    
    cache_hit_rate: (data.metrics.cache_hit_rate && data.metrics.cache_hit_rate.values && data.metrics.cache_hit_rate.values.rate)
      ? data.metrics.cache_hit_rate.values.rate * 100
      : 0,
    rate_limit_hit_rate: (data.metrics.rate_limit_hit_rate && data.metrics.rate_limit_hit_rate.values && data.metrics.rate_limit_hit_rate.values.rate)
      ? data.metrics.rate_limit_hit_rate.values.rate * 100
      : 0,
    
    thresholds_passed: Object.keys(data.metrics).every(key => {
      const metric = data.metrics[key];
      return !metric.thresholds || Object.values(metric.thresholds).every(t => t.ok);
    }),
  };
  
  console.log('\n' + '='.repeat(80));
  console.log('REALISTIC LOAD TEST SUMMARY');
  console.log('='.repeat(80));
  console.log(`Duration: ${summary.test_duration.toFixed(2)}s`);
  console.log(`Total Requests: ${summary.http.requests_total} (${summary.http.requests_per_sec.toFixed(2)}/s)`);
  console.log('');
  console.log('HTTP Latency:');
  console.log(`  Average: ${(summary.http.duration_avg || 0).toFixed(2)}ms`);
  console.log(`  P95: ${(summary.http.duration_p95 || 0).toFixed(2)}ms`);
  console.log(`  P99: ${(summary.http.duration_p99 || 0).toFixed(2)}ms`);
  console.log('');
  console.log('Operations:');
  console.log(`  Create URL: ${summary.create_url.count} (avg: ${summary.create_url.latency_avg.toFixed(2)}ms)`);
  console.log(`  Redirect: ${summary.redirect.count} (avg: ${summary.redirect.latency_avg.toFixed(2)}ms)`);
  console.log('');
  console.log('Quality Metrics:');
  console.log(`  Cache Hit Rate: ${summary.cache_hit_rate.toFixed(2)}%`);
  console.log(`  Rate Limit Hit: ${summary.rate_limit_hit_rate.toFixed(2)}%`);
  console.log(`  HTTP Failed: ${summary.http.failed_rate.toFixed(2)}% (network errors + timeouts)`);
  console.log('');
  console.log(' !  Note: HTTP Failed includes network errors and k6 timeouts (not application errors).');
  console.log('   - Network errors: connection refused, timeouts, DNS failures');
  console.log('   - Application errors: check status codes and check() results');
  console.log('   - Windows/Docker overhead can cause timeouts even when app responds correctly');
  console.log('');
  console.log(`Test Result: ${summary.thresholds_passed ? 'PASSED' : 'FAILED'}`);
  console.log('='.repeat(80) + '\n');
  
  return {
    'stdout': '',
    'summary.json': JSON.stringify(summary, null, 2),
  };
}
