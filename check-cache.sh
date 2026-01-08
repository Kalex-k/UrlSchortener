#!/bin/bash

# Script to check URL cache status in Redis and application metrics

echo "=== URL Cache Checker ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if Redis is accessible
echo "1. Checking Redis connection..."
REDIS_HOST="${SPRING_DATA_REDIS_HOST:-localhost}"
REDIS_PORT="${SPRING_DATA_REDIS_PORT:-6379}"

if command -v redis-cli &> /dev/null; then
    if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping &> /dev/null; then
        echo -e "${GREEN}✓${NC} Redis is accessible"
    else
        echo -e "${RED}✗${NC} Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠${NC} redis-cli not found, using Docker exec instead"
    REDIS_HOST="redis"
fi

echo ""
echo "2. Checking URL cache keys in Redis..."

# Get count of URL cache keys
URL_CACHE_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --scan --pattern "url:*" 2>/dev/null | wc -l)
REVERSE_CACHE_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --scan --pattern "url_to_hash:*" 2>/dev/null | wc -l)

echo "   URL cache keys (hash -> url): $URL_CACHE_COUNT"
echo "   Reverse cache keys (url -> hash): $REVERSE_CACHE_COUNT"

if [ "$URL_CACHE_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Cache contains data"
else
    echo -e "${YELLOW}⚠${NC} Cache is empty (this is normal on first run)"
fi

echo ""
echo "3. Sample cache entries (first 5):"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --scan --pattern "url:*" 2>/dev/null | head -5 | while read key; do
    if [ -n "$key" ]; then
        value=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$key" 2>/dev/null)
        ttl=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" TTL "$key" 2>/dev/null)
        echo "   Key: $key"
        echo "   Value: $value"
        echo "   TTL: ${ttl}s ($(($ttl / 3600))h)"
        echo ""
    fi
done

echo ""
echo "4. Checking application metrics (Prometheus)..."
APP_URL="${APP_BASE_URL:-http://localhost:8080}"

# Get cache metrics
if command -v curl &> /dev/null; then
    HIT_TOTAL=$(curl -s "$APP_URL/actuator/prometheus" 2>/dev/null | grep "url_cache_hit_total" | awk '{print $2}' | head -1)
    MISS_TOTAL=$(curl -s "$APP_URL/actuator/prometheus" 2>/dev/null | grep "url_cache_miss_total" | awk '{print $2}' | head -1)
    
    if [ -n "$HIT_TOTAL" ] && [ -n "$MISS_TOTAL" ]; then
        echo "   Cache hits: $HIT_TOTAL"
        echo "   Cache misses: $MISS_TOTAL"
        
        if [ "$HIT_TOTAL" != "0" ] || [ "$MISS_TOTAL" != "0" ]; then
            TOTAL=$((HIT_TOTAL + MISS_TOTAL))
            HIT_RATE=$(awk "BEGIN {printf \"%.2f\", ($HIT_TOTAL / $TOTAL) * 100}")
            echo "   Hit rate: ${HIT_RATE}%"
            
            if (( $(echo "$HIT_RATE > 50" | bc -l) )); then
                echo -e "${GREEN}✓${NC} Cache is working well"
            elif (( $(echo "$HIT_RATE > 0" | bc -l) )); then
                echo -e "${YELLOW}⚠${NC} Low hit rate - cache may be warming up"
            else
                echo -e "${RED}✗${NC} No cache hits - check if cache is being used"
            fi
        else
            echo -e "${YELLOW}⚠${NC} No metrics yet - run some requests first"
        fi
    else
        echo -e "${YELLOW}⚠${NC} Could not fetch metrics from $APP_URL/actuator/prometheus"
    fi
else
    echo -e "${YELLOW}⚠${NC} curl not found, skipping metrics check"
fi

echo ""
echo "5. Redis memory usage for cache:"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO memory 2>/dev/null | grep -E "used_memory_human|used_memory_peak_human" || echo "   Could not get memory info"

echo ""
echo "=== Check Complete ==="


