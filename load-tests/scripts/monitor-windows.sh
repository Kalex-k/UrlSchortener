#!/bin/bash

################################################################################
# WINDOWS-COMPATIBLE SYSTEM MONITOR FOR LOAD TESTING
# 
# Works in Git Bash on Windows using PowerShell for system metrics
#
# Usage:
#   ./monitor-windows.sh [duration_seconds]
#
# Example:
#   ./monitor-windows.sh 600  # Monitor for 10 minutes
################################################################################

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

# Auto-detect duration from stress-test.js if not provided
if [ -z "$1" ]; then
    # Try to calculate from stress-test.js
    if [ -f "stress-test.js" ]; then
        # Extract total duration from stages (sum all durations)
        # stages: [{ duration: '2m', ...}, { duration: '3m', ...}, ...]
        TOTAL_MINUTES=$(grep -oP "duration: '\K\d+(?=m)" stress-test.js 2>/dev/null | awk '{sum+=$1} END {print sum}')
        if [ -n "$TOTAL_MINUTES" ] && [ "$TOTAL_MINUTES" -gt 0 ]; then
            DURATION=$((TOTAL_MINUTES * 60 + 60))  # Add 1 minute buffer
            AUTO_DETECTED=true
        else
            DURATION=1200  # Default 20 minutes
            AUTO_DETECTED=false
        fi
    else
        DURATION=1200  # Default 20 minutes
        AUTO_DETECTED=false
    fi
else
    DURATION=$1
    AUTO_DETECTED=false
fi

INTERVAL=2
OUTPUT_DIR="./monitoring-results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${OUTPUT_DIR}/monitor_${TIMESTAMP}.log"
STATS_FILE="${OUTPUT_DIR}/stats_${TIMESTAMP}.txt"

# Docker containers (updated for your setup)
DB_CONTAINER="url-shortener-postgres"
REDIS_CONTAINER="url-shortener-redis"
APP_CONTAINER="url-shortener-app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

print_header() {
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================================${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# ============================================================================
# CHECK DEPENDENCIES
# ============================================================================

check_dependencies() {
    print_info "Checking dependencies..."
    
    # Check PowerShell
    if ! command -v powershell.exe &> /dev/null; then
        print_error "PowerShell not found. This script requires PowerShell."
        exit 1
    fi
    print_success "PowerShell found"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_warning "Docker not found or not in PATH"
        print_info "Docker monitoring will be skipped"
    else
        print_success "Docker found"
    fi
}

# ============================================================================
# INITIALIZE
# ============================================================================

initialize() {
    print_header "WINDOWS SYSTEM MONITOR INITIALIZATION"
    
    mkdir -p "$OUTPUT_DIR"
    print_success "Output directory: $OUTPUT_DIR"
    
    check_dependencies
    
    if [ "$AUTO_DETECTED" = true ]; then
        print_success "Auto-detected test duration: ${DURATION}s ($(awk -v d="$DURATION" 'BEGIN{printf "%.1f", d/60}') minutes)"
    else
        echo "Duration: ${DURATION}s ($(awk -v d="$DURATION" 'BEGIN{printf "%.1f", d/60}') minutes)"
    fi
    print_info "Interval: ${INTERVAL}s"
    print_info "Log file: $LOG_FILE"
    print_info "Stats file: $STATS_FILE"
    
    # Initialize arrays
    declare -g -a CPU_USAGE=()
    declare -g -a MEM_USED_MB=()
    declare -g -a MEM_AVAILABLE_MB=()
    declare -g -a MEM_PERCENT=()
    declare -g -a DISK_USAGE=()
    declare -g -a DB_CONNECTIONS=()
    declare -g -a REDIS_MEMORY=()
    declare -g -a REDIS_OPS=()
}

# ============================================================================
# DATA COLLECTION FUNCTIONS (using PowerShell)
# ============================================================================

collect_cpu_stats() {
    local cpu_usage=$(powershell.exe -Command "Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 | Select-Object -ExpandProperty CounterSamples | Select-Object -ExpandProperty CookedValue" 2>/dev/null | tr -d '\r')
    [ -n "$cpu_usage" ] && CPU_USAGE+=($cpu_usage) && echo "CPU: ${cpu_usage}%"
}

collect_memory_stats() {
    # Get Memory stats via PowerShell
    local mem_info=$(powershell.exe -Command '$os = Get-CimInstance Win32_OperatingSystem; $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB); $freeMB = [math]::Round($os.FreePhysicalMemory / 1KB); $usedMB = $totalMB - $freeMB; $percent = [math]::Round(($usedMB / $totalMB) * 100, 2); Write-Output "$usedMB $freeMB $percent"' 2>/dev/null | tr -d '\r')
    
    if [ -n "$mem_info" ]; then
        local used=$(echo $mem_info | awk '{print $1}')
        local available=$(echo $mem_info | awk '{print $2}')
        local percent=$(echo $mem_info | awk '{print $3}')
        
        MEM_USED_MB+=($used)
        MEM_AVAILABLE_MB+=($available)
        MEM_PERCENT+=($percent)
        
        echo "Memory: used=${used}MB available=${available}MB (${percent}%)"
    fi
}

collect_disk_stats() {
    # Get Disk usage for C: drive
    local disk_usage=$(powershell.exe -Command '$disk = Get-PSDrive C | Select-Object Used,Free; $total = $disk.Used + $disk.Free; $percent = [math]::Round(($disk.Used / $total) * 100, 2); Write-Output $percent' 2>/dev/null | tr -d '\r')
    
    if [ -n "$disk_usage" ]; then
        DISK_USAGE+=($disk_usage)
        echo "Disk C: ${disk_usage}% used"
    fi
}

collect_network_stats() {
    # Network stats - simplified for Windows
    # Just show that we're monitoring, actual rates hard to calculate
    echo "Network: monitoring active"
}

collect_database_stats() {
    # Get Database connections
    if command -v docker &> /dev/null; then
        if docker ps 2>/dev/null | grep -q "$DB_CONTAINER"; then
            local conn_count=$(docker exec "$DB_CONTAINER" psql -U postgres -d url_shortener -tAc \
                "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" 2>/dev/null | tr -d '\r\n' | xargs)
            
            if [ -n "$conn_count" ] && [ "$conn_count" -eq "$conn_count" ] 2>/dev/null; then
                DB_CONNECTIONS+=($conn_count)
                echo "Database: active_connections=${conn_count}"
            fi
        fi
    fi
}

collect_redis_stats() {
    # Get Redis stats
    if command -v docker &> /dev/null; then
        if docker ps 2>/dev/null | grep -q "$REDIS_CONTAINER"; then
            local redis_info=$(docker exec "$REDIS_CONTAINER" redis-cli INFO stats 2>/dev/null)
            
            if [ -n "$redis_info" ]; then
                local ops=$(echo "$redis_info" | grep "instantaneous_ops_per_sec" | cut -d: -f2 | tr -d '\r\n' | xargs)
                local mem=$(docker exec "$REDIS_CONTAINER" redis-cli INFO memory 2>/dev/null | \
                    grep "used_memory_human" | cut -d: -f2 | tr -d '\r\nM' | xargs)
                
                if [ -n "$ops" ]; then
                    REDIS_OPS+=($ops)
                fi
                
                if [ -n "$mem" ]; then
                    REDIS_MEMORY+=($mem)
                fi
                
                echo "Redis: ops/sec=${ops:-0} memory=${mem:-0}MB"
            fi
        fi
    fi
}

# ============================================================================
# STATISTICS CALCULATION
# ============================================================================

calculate_stats() {
    local array_name="$1"

    # Safely copy array by name (no nameref)
    eval "local arr=(\"\${${array_name}[@]}\")"

    if [ ${#arr[@]} -eq 0 ]; then
        echo "0 0 0"
        return
    fi

    # Compute min/avg/max with awk (supports floats)
    printf '%s\n' "${arr[@]}" \
      | sed 's/,/./g' \
      | awk '
        NR==1 {min=$1; max=$1; sum=$1; next}
        { if($1<min) min=$1; if($1>max) max=$1; sum+=$1 }
        END { avg=sum/NR; printf "%.2f %.2f %.2f\n", min, avg, max }
      '
}

# ============================================================================
# MAIN MONITORING LOOP
# ============================================================================

monitor() {
    print_header "MONITORING STARTED"
    print_info "Press Ctrl+C to stop early"
    echo ""
    
    local iterations=$((DURATION / INTERVAL))
    local count=0
    
    # Write header to log file
    echo "timestamp,cpu_percent,mem_used_mb,mem_available_mb,mem_percent,disk_usage,db_connections,redis_ops,redis_memory_mb" > "$LOG_FILE"
    
    while [ $count -lt $iterations ]; do
        local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        local progress=$((count * 100 / iterations))
        
        echo -e "${PURPLE}[$timestamp]${NC} Progress: ${progress}%"
        
        # Collect all stats
        collect_cpu_stats
        collect_memory_stats
        collect_disk_stats
        collect_network_stats
        collect_database_stats
        collect_redis_stats
        
        # Write to log file
        local log_line="$timestamp"
        
        # Get last element safely (Git Bash compatible - handle empty arrays)
        local cpu_val=0
        if [ ${#CPU_USAGE[@]} -gt 0 ]; then
            cpu_val="${CPU_USAGE[${#CPU_USAGE[@]}-1]}"
        fi
        
        local mem_used_val=0
        if [ ${#MEM_USED_MB[@]} -gt 0 ]; then
            mem_used_val="${MEM_USED_MB[${#MEM_USED_MB[@]}-1]}"
        fi
        
        local mem_avail_val=0
        if [ ${#MEM_AVAILABLE_MB[@]} -gt 0 ]; then
            mem_avail_val="${MEM_AVAILABLE_MB[${#MEM_AVAILABLE_MB[@]}-1]}"
        fi
        
        local mem_pct_val=0
        if [ ${#MEM_PERCENT[@]} -gt 0 ]; then
            mem_pct_val="${MEM_PERCENT[${#MEM_PERCENT[@]}-1]}"
        fi
        
        local disk_val=0
        if [ ${#DISK_USAGE[@]} -gt 0 ]; then
            disk_val="${DISK_USAGE[${#DISK_USAGE[@]}-1]}"
        fi
        
        local db_val=0
        if [ ${#DB_CONNECTIONS[@]} -gt 0 ]; then
            db_val="${DB_CONNECTIONS[${#DB_CONNECTIONS[@]}-1]}"
        fi
        
        local redis_ops_val=0
        if [ ${#REDIS_OPS[@]} -gt 0 ]; then
            redis_ops_val="${REDIS_OPS[${#REDIS_OPS[@]}-1]}"
        fi
        
        local redis_mem_val=0
        if [ ${#REDIS_MEMORY[@]} -gt 0 ]; then
            redis_mem_val="${REDIS_MEMORY[${#REDIS_MEMORY[@]}-1]}"
        fi
        
        log_line+=",${cpu_val}"
        log_line+=",${mem_used_val}"
        log_line+=",${mem_avail_val}"
        log_line+=",${mem_pct_val}"
        log_line+=",${disk_val}"
        log_line+=",${db_val}"
        log_line+=",${redis_ops_val}"
        log_line+=",${redis_mem_val}"
        
        echo "$log_line" >> "$LOG_FILE"
        
        echo ""
        count=$((count + 1))
        sleep $INTERVAL
    done
}

# ============================================================================
# GENERATE STATISTICS REPORT
# ============================================================================

generate_report() {
    print_header "GENERATING STATISTICS REPORT"
    
    {
        echo "============================================================================"
        echo "SYSTEM MONITORING REPORT (Windows)"
        echo "============================================================================"
        echo "Test Date: $(date)"
        echo "Duration: ${DURATION}s ($(awk -v d="$DURATION" 'BEGIN{printf "%.1f", d/60}') minutes)"
        echo "Samples: ${#CPU_USAGE[@]}"
        echo ""
        
        echo "============================================================================"
        echo "CPU STATISTICS"
        echo "============================================================================"
        local cpu_stats=($(calculate_stats CPU_USAGE))
        
        echo "CPU Usage:"
        echo "  Min: ${cpu_stats[0]}%"
        echo "  Avg: ${cpu_stats[1]}%"
        echo "  Max: ${cpu_stats[2]}%"
        echo ""
        
        local max_cpu=${cpu_stats[2]}
        echo "CPU Health:"
        if [ "$(awk -v v="$max_cpu" 'BEGIN{print (v>80)}')" = "1" ]; then
            echo "    WARNING: CPU usage high (${max_cpu}%) - Consider scaling"
        elif [ "$(awk -v v="$max_cpu" 'BEGIN{print (v>60)}')" = "1" ]; then
            echo "   NOTICE: CPU usage moderate (${max_cpu}%)"
        else
            echo "  GOOD: CPU usage normal (${max_cpu}%)"
        fi
        echo ""
        
        echo "============================================================================"
        echo "MEMORY STATISTICS"
        echo "============================================================================"
        local mem_used_stats=($(calculate_stats MEM_USED_MB))
        local mem_avail_stats=($(calculate_stats MEM_AVAILABLE_MB))
        local mem_percent_stats=($(calculate_stats MEM_PERCENT))
        
        echo "Used Memory:"
        echo "  Min: ${mem_used_stats[0]} MB"
        echo "  Avg: ${mem_used_stats[1]} MB"
        echo "  Max: ${mem_used_stats[2]} MB"
        echo ""
        echo "Available Memory:"
        echo "  Min: ${mem_avail_stats[0]} MB"
        echo "  Avg: ${mem_avail_stats[1]} MB"
        echo "  Max: ${mem_avail_stats[2]} MB"
        echo ""
        echo "Memory Usage %:"
        echo "  Min: ${mem_percent_stats[0]}%"
        echo "  Avg: ${mem_percent_stats[1]}%"
        echo "  Max: ${mem_percent_stats[2]}%"
        echo ""
        
        local max_mem_percent=${mem_percent_stats[2]}
        echo "Memory Health:"
        if [ "$(awk -v v="$max_mem_percent" 'BEGIN{print (v>90)}')" = "1" ]; then
            echo "   WARNING: Memory usage critical (${max_mem_percent}%)"
        elif [ "$(awk -v v="$max_mem_percent" 'BEGIN{print (v>80)}')" = "1" ]; then
            echo "  NOTICE: Memory usage high (${max_mem_percent}%)"
        else
            echo "   GOOD: Memory usage normal (${max_mem_percent}%)"
        fi
        echo ""
        
        echo "============================================================================"
        echo "DISK STATISTICS"
        echo "============================================================================"
        local disk_stats=($(calculate_stats DISK_USAGE))
        
        echo "Disk Usage (C:):"
        echo "  Min: ${disk_stats[0]}%"
        echo "  Avg: ${disk_stats[1]}%"
        echo "  Max: ${disk_stats[2]}%"
        echo ""
        
        echo "============================================================================"
        echo "DATABASE STATISTICS"
        echo "============================================================================"
        if [ ${#DB_CONNECTIONS[@]} -gt 0 ]; then
            local db_conn_stats=($(calculate_stats DB_CONNECTIONS))
            
            echo "Active Connections:"
            echo "  Min: ${db_conn_stats[0]}"
            echo "  Avg: ${db_conn_stats[1]}"
            echo "  Max: ${db_conn_stats[2]}"
            echo ""
        else
            echo "  No database statistics collected"
        fi
        echo ""
        
        echo "============================================================================"
        echo "REDIS STATISTICS"
        echo "============================================================================"
        if [ ${#REDIS_OPS[@]} -gt 0 ]; then
            local redis_ops_stats=($(calculate_stats REDIS_OPS))
            local redis_mem_stats=($(calculate_stats REDIS_MEMORY))
            
            echo "Operations per Second:"
            echo "  Min: ${redis_ops_stats[0]}"
            echo "  Avg: ${redis_ops_stats[1]}"
            echo "  Max: ${redis_ops_stats[2]}"
            echo ""
            echo "Memory Usage:"
            echo "  Min: ${redis_mem_stats[0]} MB"
            echo "  Avg: ${redis_mem_stats[1]} MB"
            echo "  Max: ${redis_mem_stats[2]} MB"
        else
            echo "  No Redis statistics collected"
        fi
        echo ""
        
        echo "============================================================================"
        echo "BOTTLENECK ANALYSIS"
        echo "============================================================================"
        
        local bottlenecks=()
        
        if [ "$(awk -v v="$max_cpu" 'BEGIN{print (v>80)}')" = "1" ]; then
            bottlenecks+=(" CPU (${max_cpu}%)")
        fi
        
        if [ "$(awk -v v="$max_mem_percent" 'BEGIN{print (v>85)}')" = "1" ]; then
            bottlenecks+=(" Memory (${max_mem_percent}%)")
        fi
        
        if [ ${#bottlenecks[@]} -eq 0 ]; then
            echo " No bottlenecks detected - System healthy!"
        else
            echo " Potential bottlenecks detected:"
            for bottleneck in "${bottlenecks[@]}"; do
                echo "  - $bottleneck"
            done
        fi
        echo ""
        
        echo "============================================================================"
        echo "FILES GENERATED"
        echo "============================================================================"
        echo "Log file: $LOG_FILE"
        echo "Stats file: $STATS_FILE"
        echo ""
        
    } | tee "$STATS_FILE"
    
    print_success "Report saved to: $STATS_FILE"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    trap 'echo ""; print_warning "Monitoring interrupted"; generate_report; exit 0' INT
    
    initialize
    echo ""
    
    monitor
    
    echo ""
    generate_report
    
    print_success "Monitoring completed successfully!"
}

main
