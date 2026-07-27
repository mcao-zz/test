#!/bin/bash

# IBM Virtual Ethernet (ibmveth) Multi-Queue Driver Test Script
# Tests multi-queue operation and dynamic queue resizing (net-next MQ v4)
#
# Usage: ./test-veth-mq.sh [-d interface] [-t test_host] [-D]
# Example: ./test-veth-mq.sh -d net0 -t 10.48.34.150
#          ./test-veth-mq.sh -d net0 -t 10.48.34.150 -D

set -u  # Exit on undefined variables

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
INTERFACE="net0"
TEST_HOST="9.3.20.62"
DEBUG_MODE=0  # 0=off, 1=on - enables dynamic debug during module reload
RESULTS_DIR="/tmp/ibmveth-mq-test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=0   # incremented per scored check (not a hardcoded target)
TEST_RESULTS=()

# Dmesg tracking (line count at suite start; leak checks use delta only)
DMESG_MARKER=0
DMESG_START=0

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  -d DEVICE           Network device to test (default: net0)
  -t HOST             Test host for connectivity (default: 9.3.20.62)
  -D                  Enable debug mode (modprobe with dyndbg=+p)
  -h                  Show this help message

Examples:
  # Basic test
  $0 -d net0 -t 10.48.34.150

  # With debug mode
  $0 -d net0 -t 10.48.34.150 -D

  # Use defaults
  $0

EOF
    exit 1
}

# Parse command line arguments
while getopts "d:t:Dh" opt; do
    case $opt in
        d) INTERFACE="$OPTARG" ;;
        t) TEST_HOST="$OPTARG" ;;
        D) DEBUG_MODE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Set file paths AFTER parsing arguments so INTERFACE is correct
LOG_FILE="$RESULTS_DIR/test_${INTERFACE}_${TIMESTAMP}.log"
STATS_BEFORE="$RESULTS_DIR/stats_before_${INTERFACE}_${TIMESTAMP}.txt"
STATS_AFTER_TRAFFIC="$RESULTS_DIR/stats_after_traffic_${INTERFACE}_${TIMESTAMP}.txt"
STATS_AFTER_RESIZE="$RESULTS_DIR/stats_after_resize_${INTERFACE}_${TIMESTAMP}.txt"
STATS_FINAL="$RESULTS_DIR/stats_final_${INTERFACE}_${TIMESTAMP}.txt"
SYSINFO="$RESULTS_DIR/sysinfo_${INTERFACE}_${TIMESTAMP}.txt"
DMESG_LOG="$RESULTS_DIR/dmesg_${INTERFACE}_${TIMESTAMP}.log"
DMESG_DELTA_DIR="$RESULTS_DIR/dmesg_deltas"
STATS_DELTA_DIR="$RESULTS_DIR/stats_deltas"
INTERRUPTS_LOG="$RESULTS_DIR/interrupts_${INTERFACE}_${TIMESTAMP}.log"
MEMORY_LOG="$RESULTS_DIR/memory_${INTERFACE}_${TIMESTAMP}.log"
VERIFICATION_LOG="$RESULTS_DIR/verification_${INTERFACE}_${TIMESTAMP}.log"

# Create results directories
mkdir -p "$RESULTS_DIR" "$DMESG_DELTA_DIR" "$STATS_DELTA_DIR"

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Function to capture dmesg delta
capture_dmesg_delta() {
    local test_name=$1
    local output_file="$DMESG_DELTA_DIR/${test_name// /_}.txt"

    log "${CYAN}[Capturing dmesg delta: $test_name]${NC}"

    # Get new dmesg lines since last marker
    local new_lines=$(dmesg | wc -l)
    local delta=$((new_lines - DMESG_MARKER))

    if [ $delta -gt 0 ]; then
        dmesg | tail -$delta > "$output_file"
        log "  ✓ Captured $delta new dmesg lines → $output_file"

        # Show ibmveth-related messages (filter by interface name if possible)
        local veth_lines=$(grep -iE "ibmveth|${INTERFACE}" "$output_file" | wc -l)
        if [ $veth_lines -gt 0 ]; then
            log "  ${YELLOW}Relevant messages (ibmveth/${INTERFACE}):${NC}"
            grep -iE "ibmveth|${INTERFACE}" "$output_file" | tail -20 | sed 's/^/    /' | tee -a "$LOG_FILE"
        fi
    else
        log "  No new dmesg messages"
        echo "No new messages" > "$output_file"
    fi

    # Update marker
    DMESG_MARKER=$new_lines
    log ""
}

# Function to capture ethtool stats delta
capture_stats_delta() {
    local test_name=$1
    local before_file=$2
    local after_file="$RESULTS_DIR/stats_temp_${TIMESTAMP}.txt"
    local delta_file="$STATS_DELTA_DIR/${test_name// /_}.txt"

    log "${CYAN}[Capturing stats delta: $test_name]${NC}"

    # Capture current stats
    ethtool -S "$INTERFACE" > "$after_file"

    # Calculate deltas
    {
        echo "=== Statistics Delta: $test_name ==="
        echo "Time: $(date)"
        echo ""

        # Key stats to track
        # Names match drivers/net/ethernet/ibm/ibmveth.c ibmveth_stats[]
        local stats=(
            "hcall_reg_lan_queue"
            "hcall_reg_lan"
            "hcall_add_bufs_queue"
            "hcall_add_bufs"
            "hcall_add_buf"
            "hcall_free_lan_queue"
            "hcall_free_lan"
            "hcall_send_lan"
            "replenish_add_buff_success"
            "replenish_add_buff_failure"
            "replenish_no_mem"
            "tx_send_failed"
            "rx_invalid_buffer"
        )

        echo "Hypercall & Error Counters:"
        for stat in "${stats[@]}"; do
            local before=$(get_stat_value "$before_file" "$stat")
            local after=$(get_stat_value "$after_file" "$stat")
            before=${before:-0}
            after=${after:-0}
            local delta=$((after - before))

            if [ $delta -ne 0 ]; then
                printf "  %-30s: %10d → %10d (+%d)\n" "$stat" "$before" "$after" "$delta"
            fi
        done

        echo ""
        echo "Per-Queue RX Packets:"
        for i in {0..15}; do
            local stat="rx${i}_packets"
            local before=$(get_stat_value "$before_file" "$stat")
            local after=$(get_stat_value "$after_file" "$stat")
            before=${before:-0}
            after=${after:-0}
            local delta=$((after - before))

            if [ $delta -ne 0 ]; then
                printf "  Queue %2d: %10d → %10d (+%d)\n" "$i" "$before" "$after" "$delta"
            fi
        done

    } > "$delta_file"

    # Show summary
    log "  ✓ Stats delta saved → $delta_file"
    grep -E "→.*\(\+[0-9]" "$delta_file" | head -10 | sed 's/^/    /' | tee -a "$LOG_FILE"

    # Copy after to before for next delta
    cp "$after_file" "$before_file"
    log ""
}

# Function to capture interrupt counts
capture_interrupts() {
    local label=$1

    log "${CYAN}[Capturing interrupt counts: $label]${NC}" | tee -a "$INTERRUPTS_LOG"
    echo "=== Interrupts: $label ===" >> "$INTERRUPTS_LOG"
    echo "Time: $(date)" >> "$INTERRUPTS_LOG"

    # Get IRQs for this interface (interrupts are named with interface name, not driver name)
    local irqs=$(grep "$INTERFACE" /proc/interrupts | awk '{print $1}' | tr -d ':')

    if [ -n "$irqs" ]; then
        echo "" >> "$INTERRUPTS_LOG"
        grep "$INTERFACE" /proc/interrupts >> "$INTERRUPTS_LOG"

        # Calculate total
        local total=0
        for irq in $irqs; do
            local count=$(grep "^ *${irq}:" /proc/interrupts | awk '{sum=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) sum+=$i; print sum}')
            total=$((total + count))
        done

        log "  ✓ Total interrupts: $total across $(echo "$irqs" | wc -w) IRQs"
        echo "Total: $total" >> "$INTERRUPTS_LOG"
    else
        log "  ${YELLOW}⚠${NC} No ibmveth interrupts found"
        echo "No ibmveth interrupts found" >> "$INTERRUPTS_LOG"
    fi

    echo "" >> "$INTERRUPTS_LOG"
    log ""
}

# Function to check memory leaks
check_memory_leaks() {
    local label=$1

    log "${CYAN}[Checking memory: $label]${NC}" | tee -a "$MEMORY_LOG"
    echo "=== Memory Check: $label ===" >> "$MEMORY_LOG"
    echo "Time: $(date)" >> "$MEMORY_LOG"
    echo "" >> "$MEMORY_LOG"

    # Check slab allocations for ibmveth
    if [ -f /proc/slabinfo ]; then
        echo "Slab allocations:" >> "$MEMORY_LOG"
        grep -E "^(kmalloc|dma)" /proc/slabinfo | head -20 >> "$MEMORY_LOG"

        # Get memory usage
        local mem_used=$(grep -E "^(kmalloc|dma)" /proc/slabinfo | awk '{sum+=$3*$4} END {print sum/1024/1024}')
        log "  ✓ Slab memory: ${mem_used} MB"
    fi

    # Check for ibmveth in /proc/meminfo or similar
    echo "" >> "$MEMORY_LOG"
    echo "System memory:" >> "$MEMORY_LOG"
    grep -E "^(MemTotal|MemFree|MemAvailable|Slab):" /proc/meminfo >> "$MEMORY_LOG"

    # Only scan dmesg lines since suite marker (avoid stale boot noise)
    local leak_count=0
    local cur_lines delta
    cur_lines=$(dmesg | wc -l)
    delta=$((cur_lines - DMESG_MARKER))
    if [ "$delta" -gt 0 ]; then
        leak_count=$(dmesg | tail -"$delta" | grep -ciE "memory leak|memleak|kmemleak" || true)
    fi
    if [ "${leak_count:-0}" -gt 0 ]; then
        log "  ${RED}✗${NC} Potential memory leaks in this run: $leak_count messages"
        dmesg | tail -"$delta" | grep -iE "memory leak|memleak|kmemleak" | tail -5 >> "$MEMORY_LOG"
    else
        log "  ✓ No new memory leak warnings since test start"
    fi

    echo "" >> "$MEMORY_LOG"
    log ""
}

# Function to verify resources
verify_resources() {
    local test_name=$1

    log "${CYAN}[Verifying resources: $test_name]${NC}" | tee -a "$VERIFICATION_LOG"
    echo "=== Resource Verification: $test_name ===" >> "$VERIFICATION_LOG"
    echo "Time: $(date)" >> "$VERIFICATION_LOG"
    echo "" >> "$VERIFICATION_LOG"

    local issues=0

    # Check interface exists
    if ! ip link show "$INTERFACE" &> /dev/null; then
        log "  ${RED}✗${NC} Interface $INTERFACE missing!"
        echo "ERROR: Interface missing" >> "$VERIFICATION_LOG"
        ((issues++))
    else
        log "  ✓ Interface exists"
        echo "OK: Interface exists" >> "$VERIFICATION_LOG"
    fi

    # Check module loaded
    if ! lsmod | grep -q ibmveth; then
        log "  ${RED}✗${NC} Module not loaded!"
        echo "ERROR: Module not loaded" >> "$VERIFICATION_LOG"
        ((issues++))
    else
        log "  ✓ Module loaded"
        echo "OK: Module loaded" >> "$VERIFICATION_LOG"
    fi

    # Check queue count
    local queues=$(get_queue_count)
    if [ -z "$queues" ] || [ "$queues" -eq 0 ]; then
        log "  ${RED}✗${NC} Invalid queue count: $queues"
        echo "ERROR: Invalid queue count" >> "$VERIFICATION_LOG"
        ((issues++))
    else
        log "  ✓ Queue count: $queues"
        echo "OK: Queue count: $queues" >> "$VERIFICATION_LOG"
    fi

    # Check for errors in dmesg
    local error_count=$(dmesg | tail -100 | grep -i "error\|fail\|bug\|warn" | grep -i ibmveth | wc -l)
    if [ $error_count -gt 0 ]; then
        log "  ${YELLOW}⚠${NC} Found $error_count error/warning messages"
        echo "WARNING: $error_count error messages" >> "$VERIFICATION_LOG"
        dmesg | tail -100 | grep -i "error\|fail\|bug\|warn" | grep -i ibmveth >> "$VERIFICATION_LOG"
    else
        log "  ✓ No error messages"
        echo "OK: No error messages" >> "$VERIFICATION_LOG"
    fi

    echo "" >> "$VERIFICATION_LOG"

    if [ $issues -eq 0 ]; then
        log "  ${GREEN}✓ All resources verified${NC}"
    else
        log "  ${RED}✗ Found $issues issues${NC}"
    fi

    log ""
    return $issues
}

# Score a named check (always advances TOTAL_TESTS)
score_pass() {
    local test_name=$1
    ((TOTAL_TESTS++)) || true
    ((PASS_COUNT++)) || true
    log "${GREEN}✓ PASS${NC}: $test_name"
    TEST_RESULTS+=("PASS: $test_name")
}

score_fail() {
    local test_name=$1
    ((TOTAL_TESTS++)) || true
    ((FAIL_COUNT++)) || true
    log "${RED}✗ FAIL${NC}: $test_name"
    TEST_RESULTS+=("FAIL: $test_name")
}

# Check result function
check_result() {
    local result=$1
    local test_name=$2
    if [ $result -eq 0 ]; then
        score_pass "$test_name"
        return 0
    else
        score_fail "$test_name"
        return 1
    fi
}

# Function to get interface statistics
get_iface_stat() {
    local direction=$1  # RX or TX
    local field=$2      # 1=bytes, 2=packets
    ip -s link show "$INTERFACE" | grep -A1 "$direction:" | tail -1 | awk "{print \$$field}"
}

# Function to get specific stat from ethtool output (v4 names).
# Exact key match so hcall_reg_lan does not also hit hcall_reg_lan_queue.
get_stat_value() {
    local stat_file=$1
    local stat_name=$2
    local val

    val=$(grep -E "^[[:space:]]*${stat_name}:" "$stat_file" 2>/dev/null \
        | awk '{print $2}' | head -1)
    if [ -z "$val" ]; then
        echo "0"
    else
        echo "$val"
    fi
}

# Function to get queue count from ethtool
get_queue_count() {
    # ibmveth uses separate RX/TX queues, not combined
    # Get current RX queue count
    ethtool -l "$INTERFACE" 2>/dev/null | grep -A 4 "Current" | grep "RX:" | awk '{print $2}'
}

# Function to set queue count with comprehensive validation
set_queue_count() {
    local count=$1
    log "  Setting queue count to $count..."

    if sudo ethtool -L "$INTERFACE" rx "$count" 2>&1 | tee -a "$LOG_FILE"; then
        sleep 2

        # Validation 1: ethtool -l (primary check)
        local new_count=$(get_queue_count)
        log "  Validation 1 - ethtool -l: $new_count queues"

        # Validation 2: Count per-queue statistics
        local stats_count=$(ethtool -S "$INTERFACE" | grep -E "^ *rx[0-9]+_packets:" | wc -l)
        log "  Validation 2 - Per-queue stats: $stats_count rx queues"

        # Validation 3: Count active interrupts
        local irq_count=$(grep "$INTERFACE" /proc/interrupts | wc -l)
        log "  Validation 3 - Active IRQs: $irq_count"

        # Validation 4: sysfs queue count
        if [ -d "/sys/class/net/$INTERFACE/queues" ]; then
            local sysfs_rx=$(ls -d /sys/class/net/$INTERFACE/queues/rx-* 2>/dev/null | wc -l)
            log "  Validation 4 - sysfs rx queues: $sysfs_rx"
        fi

        # Primary validation: ethtool -l must match
        if [ "$new_count" = "$count" ]; then
            log "  ${GREEN}✓${NC} Queue count successfully set to $count"
            log "  ${GREEN}✓${NC} All validations: ethtool=$new_count, stats=$stats_count, irqs=$irq_count"
            return 0
        else
            log "  ${RED}✗${NC} Queue count is $new_count, expected $count"
            log "  ${YELLOW}⚠${NC} Stats show $stats_count queues, IRQs show $irq_count"
            return 1
        fi
    else
        log "  ${RED}✗${NC} Failed to set queue count (ethtool command failed)"
        return 1
    fi
}

# Function to capture dmesg with timestamp
capture_dmesg() {
    local label=$1
    log "${CYAN}[DMESG: $label]${NC}" | tee -a "$DMESG_LOG"
    dmesg | tail -50 | tee -a "$DMESG_LOG"
    log "" | tee -a "$DMESG_LOG"
}

# Start test
log "========================================"
log "IBM veth Multi-Queue Test Suite (Phase 3)"
log "========================================"
log "Interface: $INTERFACE"
log "Test Host: $TEST_HOST"
log "Debug Mode: $DEBUG_MODE"
log "Start time: $(date)"
log "Log file: $LOG_FILE"
log "Results directory: $RESULTS_DIR"
log ""

# Test 0: System Information
log "=== 1. System Information ===" | tee "$SYSINFO"
log "Hostname: $(hostname)" | tee -a "$SYSINFO"
log "Kernel: $(uname -r)" | tee -a "$SYSINFO"
log "Architecture: $(uname -m)" | tee -a "$SYSINFO"

# Get system ID and partition name (filter null bytes)
SYSTEM_ID=$(cat /proc/device-tree/system-id 2>/dev/null | tr -d '\0' || echo "Unknown")
PARTITION_NAME=$(cat /proc/device-tree/ibm,partition-name 2>/dev/null | tr -d '\0' || echo "Unknown")
log "System ID: $SYSTEM_ID" | tee -a "$SYSINFO"
log "Partition: $PARTITION_NAME" | tee -a "$SYSINFO"

# Get firmware version
FW_VERSION=$(cat /proc/device-tree/openprom/ibm,fw-vernum_encoded 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo "Unknown")
log "Firmware: $FW_VERSION" | tee -a "$SYSINFO"
log ""

# Test 1: Driver Information
log "=== 2. Driver Information ===" | tee -a "$SYSINFO"
DRIVER_PATH=$(modinfo ibmveth 2>/dev/null | grep filename | awk '{print $2}')
log "Driver path: $DRIVER_PATH" | tee -a "$SYSINFO"

if [ -n "$DRIVER_PATH" ] && [ -f "$DRIVER_PATH" ]; then
    DRIVER_SIZE=$(stat -f%z "$DRIVER_PATH" 2>/dev/null || stat -c%s "$DRIVER_PATH" 2>/dev/null)
    log "Driver size: $((DRIVER_SIZE / 1024)) KB" | tee -a "$SYSINFO"
fi

DRIVER_VERSION=$(modinfo ibmveth 2>/dev/null | grep "^version:" | awk '{print $2}')
log "Driver version: ${DRIVER_VERSION:-Unknown}" | tee -a "$SYSINFO"

# Check if module is loaded
if lsmod | grep -q ibmveth; then
    log "${GREEN}✓${NC} ibmveth module is loaded" | tee -a "$SYSINFO"
    MODULE_ADDR=$(cat /sys/module/ibmveth/sections/.text 2>/dev/null || echo "Unknown")
    log "Module loaded at: $MODULE_ADDR" | tee -a "$SYSINFO"
else
    log "${RED}✗${NC} ibmveth module is NOT loaded"
    exit 1
fi
log ""

# Test 2: Interface Status
log "=== 3. Interface Status ==="
if ip link show "$INTERFACE" &> /dev/null; then
    log "${GREEN}✓${NC} Interface $INTERFACE exists"

    IP_ADDR=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}')
    MAC_ADDR=$(ip link show "$INTERFACE" | grep "link/ether" | awk '{print $2}')
    MTU=$(ip link show "$INTERFACE" | grep -oP 'mtu \K[0-9]+')
    STATE=$(ip link show "$INTERFACE" | grep -oP 'state \K[A-Z]+')

    log "IP Address: $IP_ADDR"
    log "MAC Address: $MAC_ADDR"
    log "MTU: $MTU"
    log "State: $STATE"

    # Bring interface UP if not already
    if [ "$STATE" != "UP" ]; then
        log "${YELLOW}⚠${NC} Interface is $STATE, bringing it UP..."
        if sudo ip link set "$INTERFACE" up; then
            sleep 3
            STATE=$(ip link show "$INTERFACE" | grep -oP 'state \K[A-Z]+')
            log "New state: $STATE"

            if [ "$STATE" = "UP" ] || [ "$STATE" = "UNKNOWN" ]; then
                score_pass "Interface is UP (state: $STATE)"
            else
                score_fail "Failed to bring interface UP"
            fi
        else
            log "${RED}✗ FAIL${NC}: Failed to bring interface UP"
        fi
    else
        score_pass "Interface is UP"
    fi
else
    log "${RED}✗ FAIL${NC}: Interface $INTERFACE does not exist"
    exit 1
fi
log ""

# Test 3: VIO Device Information
log "=== 4. VIO Device Information ==="
VIO_PATH=$(find /sys/devices/vio -name "$INTERFACE" -type d 2>/dev/null | head -1)

if [ -n "$VIO_PATH" ]; then
    VIO_DEVICE=$(dirname "$(dirname "$VIO_PATH")")
    log "VIO device path: $VIO_DEVICE"

    if [ -f "$VIO_DEVICE/devspec" ]; then
        DEVSPEC=$(cat "$VIO_DEVICE/devspec")
        log "Device spec: $DEVSPEC"
    fi

    if [ -f "$VIO_DEVICE/name" ]; then
        DEVICE_NAME=$(cat "$VIO_DEVICE/name")
        log "Device name: $DEVICE_NAME"
    fi
else
    log "${YELLOW}⚠${NC} Could not find VIO device path"
    VIO_DEVICE=""
fi
log ""

# Test 4: Multi-Queue Capability Check
log "=== 5. Multi-Queue Capability ==="
if [ -n "$VIO_DEVICE" ]; then
    if [ -f "$VIO_DEVICE/subordinate_queue_mode" ]; then
        QUEUE_MODE=$(cat "$VIO_DEVICE/subordinate_queue_mode")
        log "subordinate_queue_mode: $QUEUE_MODE"

        if [ "$QUEUE_MODE" != "0" ]; then
            score_pass "Multi-queue mode active (subordinate_queue_mode=$QUEUE_MODE)"
        else
            log "${YELLOW}⚠${NC} Fallback mode detected (subordinate_queue_mode=0)"
            log "${YELLOW}⚠${NC} This test suite requires multi-queue firmware support"
        fi
    fi

    if [ -f "$VIO_DEVICE/max_rx_buffers_per_call" ]; then
        MAX_BUFFERS=$(cat "$VIO_DEVICE/max_rx_buffers_per_call")
        log "max_rx_buffers_per_call: $MAX_BUFFERS"
    fi

    if [ -f "$VIO_DEVICE/current_rx_batch_size" ]; then
        BATCH_SIZE=$(cat "$VIO_DEVICE/current_rx_batch_size")
        log "current_rx_batch_size: $BATCH_SIZE"
    fi
else
    log "${YELLOW}⚠ SKIP${NC}: Cannot check sysfs attributes (VIO device path not found)"
fi
log ""

# Test 5: Initial Queue Configuration
log "=== 6. Initial Queue Configuration ==="
INITIAL_QUEUES=$(get_queue_count)
log "Current queue count: $INITIAL_QUEUES"

if [ -n "$INITIAL_QUEUES" ] && [ "$INITIAL_QUEUES" -gt 1 ]; then
    score_pass "Multi-queue configured ($INITIAL_QUEUES queues)"
else
    log "${YELLOW}⚠${NC} Single queue mode ($INITIAL_QUEUES queue)"
fi
log ""

# Capture initial statistics
log "=== 7. Capturing Initial Statistics ==="
log "${BLUE}Saving full stats to: $STATS_BEFORE${NC}"
ethtool -S "$INTERFACE" > "$STATS_BEFORE"
log "✓ Initial statistics captured ($(wc -l < "$STATS_BEFORE") lines)"
log ""

# Display initial queue stats
log "Initial Per-Queue Statistics:"
grep -E "^rx[0-9]+_packets:" "$STATS_BEFORE" | head -10 | tee -a "$LOG_FILE"
log ""

# Initialize dmesg marker and capture baseline
DMESG_MARKER=$(dmesg | wc -l)
DMESG_START=$DMESG_MARKER
log "Dmesg marker initialized at line $DMESG_MARKER"
log ""

capture_interrupts "Initial"
check_memory_leaks "Initial"
verify_resources "Initial"

# Test 6: Basic Connectivity
log "=== 8. Test 1: Basic Connectivity ==="
log "Testing basic ping to $TEST_HOST..."
if ping -c 5 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
    check_result 0 "Basic connectivity (ping)"
else
    check_result 1 "Basic connectivity (ping)"
fi
log ""

# Test 7: Multi-Stream Traffic (RSS validation)
log "=== 9. Test 2: Multi-Stream Traffic (RSS) ==="
log "Testing parallel streams to validate RSS distribution..."

# Get local IP address for this interface
LOCAL_IP=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
if [ -z "$LOCAL_IP" ]; then
    log "${RED}✗ FAIL${NC}: Cannot determine local IP for $INTERFACE"
    check_result 1 "Multi-stream traffic test"
else
    log "Local IP: $LOCAL_IP, Remote host: $TEST_HOST"

    # Try to generate inbound traffic from remote host for true RX RSS testing
    log "Attempting to generate inbound traffic from $TEST_HOST..."

    # Check if sshpass is available
    if command -v sshpass >/dev/null 2>&1; then
        log "Using SSH to generate inbound traffic (4 parallel streams)..."

        # Run 4 parallel ping streams FROM remote host TO this interface
        sshpass -p 'LparPassw0rd123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            root@"$TEST_HOST" "ping -c 100 -i 0.05 $LOCAL_IP" > /dev/null 2>&1 &
        PID1=$!
        sshpass -p 'LparPassw0rd123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            root@"$TEST_HOST" "ping -c 100 -i 0.05 $LOCAL_IP" > /dev/null 2>&1 &
        PID2=$!
        sshpass -p 'LparPassw0rd123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            root@"$TEST_HOST" "ping -c 100 -i 0.05 $LOCAL_IP" > /dev/null 2>&1 &
        PID3=$!
        sshpass -p 'LparPassw0rd123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            root@"$TEST_HOST" "ping -c 100 -i 0.05 $LOCAL_IP" > /dev/null 2>&1 &
        PID4=$!

        wait $PID1 $PID2 $PID3 $PID4
        if [ $? -eq 0 ]; then
            log "${GREEN}✓${NC} Inbound traffic test successful (true RX RSS validation)"
            check_result 0 "Multi-stream traffic test"
        else
            log "${YELLOW}⚠${NC} Inbound traffic test had issues, falling back to outbound"
            # Fallback to outbound traffic
            ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1
            check_result $? "Multi-stream traffic test (outbound fallback)"
        fi
    else
        log "${YELLOW}⚠${NC} sshpass not available, using outbound ping (tests TX queues only)"
        log "      Install sshpass for true RX RSS testing: yum install sshpass"

        # Run 4 parallel ping streams (outbound traffic)
        ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1 &
        PID1=$!
        ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1 &
        PID2=$!
        ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1 &
        PID3=$!
        ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1 &
        PID4=$!

        wait $PID1 $PID2 $PID3 $PID4
        check_result $? "Multi-stream traffic test (outbound)"
    fi
fi
log ""

capture_dmesg_delta "Multi-stream traffic"
capture_stats_delta "Multi-stream traffic" "$STATS_BEFORE"
capture_interrupts "After traffic"

# Capture stats after traffic
log "=== 10. Statistics After Traffic ==="
ethtool -S "$INTERFACE" > "$STATS_AFTER_TRAFFIC"

# Show both TX and RX distribution
log "Per-Queue TX Distribution:"
grep -E "^ *tx[0-9]+_packets:" "$STATS_AFTER_TRAFFIC" | tee -a "$LOG_FILE"
log ""
log "Per-Queue RX Distribution:"
grep -E "^ *rx[0-9]+_packets:" "$STATS_AFTER_TRAFFIC" | tee -a "$LOG_FILE"
log ""

# Validate RX traffic distribution across queues
ACTIVE_RX_QUEUES=$(grep -E "^ *rx[0-9]+_packets:" "$STATS_AFTER_TRAFFIC" | awk '$2 > 0 {count++} END {print count}')
ACTIVE_RX_QUEUES=${ACTIVE_RX_QUEUES:-0}
log "Active RX queues: $ACTIVE_RX_QUEUES"

# If we used inbound traffic (sshpass available), expect multi-queue distribution
if command -v sshpass >/dev/null 2>&1 && [ -n "$LOCAL_IP" ]; then
    if [ "$ACTIVE_RX_QUEUES" -gt 1 ] 2>/dev/null; then
        score_pass "Inbound traffic distributed across $ACTIVE_RX_QUEUES RX queues (RSS working)"
    else
        log "${YELLOW}⚠ WARNING${NC}: Inbound traffic on single RX queue (RSS may not be working)"
    fi
else
    # Outbound traffic - ping replies expected on single queue
    if [ "$ACTIVE_RX_QUEUES" -gt 0 ]; then
        log "${CYAN}ℹ${NC} Outbound test: RX traffic on $ACTIVE_RX_QUEUES queue(s) (ping replies)"
        log "    Install sshpass for true RX RSS testing with inbound traffic"
    fi
fi
log ""

# Test 8: Queue Resize - Scale Down
log "=== 11. Test 3: Queue Resize - Scale Down ==="
if [ "$INITIAL_QUEUES" -gt 4 ]; then
    TARGET_QUEUES=$((INITIAL_QUEUES / 2))
    log "Scaling down from $INITIAL_QUEUES to $TARGET_QUEUES queues..."

    if set_queue_count "$TARGET_QUEUES"; then
        # Test connectivity after resize
        if ping -c 10 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
            check_result 0 "Scale down ($INITIAL_QUEUES→$TARGET_QUEUES)"
        else
            check_result 1 "Scale down - connectivity lost"
        fi
    else
        check_result 1 "Scale down - resize failed"
    fi

    capture_dmesg_delta "Scale down to $TARGET_QUEUES"
    capture_stats_delta "Scale down" "$STATS_AFTER_TRAFFIC"
    verify_resources "After scale down"
else
    log "${YELLOW}⚠ SKIP${NC}: Not enough queues for scale-down test"
fi
log ""

# Test 9: Queue Resize - Scale Up
log "=== 12. Test 4: Queue Resize - Scale Up ==="
CURRENT_QUEUES=$(get_queue_count)
if [ "$CURRENT_QUEUES" -lt "$INITIAL_QUEUES" ]; then
    log "Scaling up from $CURRENT_QUEUES to $INITIAL_QUEUES queues..."

    if set_queue_count "$INITIAL_QUEUES"; then
        # Test connectivity after resize
        if ping -c 10 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
            check_result 0 "Scale up ($CURRENT_QUEUES→$INITIAL_QUEUES)"
        else
            check_result 1 "Scale up - connectivity lost"
        fi
    else
        check_result 1 "Scale up - resize failed"
    fi

    capture_dmesg_delta "Scale up to $INITIAL_QUEUES"
    capture_stats_delta "Scale up" "$STATS_AFTER_TRAFFIC"
    verify_resources "After scale up"
else
    log "${YELLOW}⚠ SKIP${NC}: Already at maximum queues"
fi
log ""

# Test 10: Traffic During Resize
log "=== 13. Test 5: Traffic During Resize ==="
log "Testing resize under load..."

# Start background traffic
ping -c 200 -i 0.1 "$TEST_HOST" > /dev/null 2>&1 &
PING_PID=$!
sleep 2

# Resize while traffic is running
CURRENT_QUEUES=$(get_queue_count)
if [ "$CURRENT_QUEUES" -gt 2 ]; then
    TARGET_QUEUES=$((CURRENT_QUEUES / 2))
    log "Resizing from $CURRENT_QUEUES to $TARGET_QUEUES while traffic is active..."

    if set_queue_count "$TARGET_QUEUES"; then
        # Wait for background traffic to complete
        wait $PING_PID
        if [ $? -eq 0 ]; then
            check_result 0 "Resize under load"
        else
            check_result 1 "Resize under load - traffic interrupted"
        fi
    else
        kill $PING_PID 2>/dev/null
        check_result 1 "Resize under load - resize failed"
    fi

    # Restore original queue count
    set_queue_count "$INITIAL_QUEUES"
    capture_dmesg_delta "Resize under load"
    capture_stats_delta "Resize under load" "$STATS_AFTER_TRAFFIC"
    check_memory_leaks "After resize under load"
else
    kill $PING_PID 2>/dev/null
    log "${YELLOW}⚠ SKIP${NC}: Not enough queues for resize-under-load test"
fi
log ""

# Capture stats after resize tests
ethtool -S "$INTERFACE" > "$STATS_AFTER_RESIZE"

# Test 11: Edge Case - Single Queue
log "=== 14. Test 6: Edge Case - Single Queue ==="
log "Testing operation with single queue..."

if set_queue_count 1; then
    if ping -c 20 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
        check_result 0 "Single queue operation"
    else
        check_result 1 "Single queue operation - connectivity lost"
    fi
    capture_dmesg_delta "Single queue test"
    capture_stats_delta "Single queue" "$STATS_AFTER_RESIZE"
    verify_resources "After single queue"

    # Restore original queue count
    set_queue_count "$INITIAL_QUEUES"
else
    check_result 1 "Single queue operation - resize failed"
fi
log ""

# Test 12: Module Reload with Debug
log "=== 15. Test 7: Module Reload ==="
log "Testing module reload..."

if [ $DEBUG_MODE -eq 1 ]; then
    log "${CYAN}Debug mode enabled - will use 'modprobe ibmveth dyndbg=+p'${NC}"
fi

# Bring interface down
sudo ip link set "$INTERFACE" down
sleep 2

# Remove module
if sudo rmmod ibmveth; then
    log "✓ Module removed"
    sleep 2

    # Reload module with or without debug
    if [ $DEBUG_MODE -eq 1 ]; then
        log "Loading module with dynamic debug enabled..."
        if sudo modprobe ibmveth dyndbg=+p; then
            log "✓ Module loaded with debug"
        else
            log "${RED}✗${NC} Module load with debug failed"
        fi
    else
        if sudo modprobe ibmveth; then
            log "✓ Module loaded"
        else
            log "${RED}✗${NC} Module load failed"
        fi
    fi

    sleep 3

    # Bring interface up
    sudo ip link set "$INTERFACE" up
    sleep 3

    # Test connectivity
    if ping -c 5 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
        check_result 0 "Module reload test"
    else
        check_result 1 "Module reload test - connectivity lost"
    fi

    capture_dmesg_delta "Module reload"
    capture_interrupts "After module reload"
    check_memory_leaks "After module reload"
    verify_resources "After module reload"
else
    check_result 1 "Module reload test - rmmod failed"
fi
log ""

# Capture final statistics
log "=== 16. Final Statistics ==="
ethtool -S "$INTERFACE" > "$STATS_FINAL"
log "Final Per-Queue Statistics:"
grep -E "^rx[0-9]+_packets:" "$STATS_FINAL" | tee -a "$LOG_FILE"
log ""

# Test 13: Hypercall Validation (v4 ethtool names)
log "=== 17. Hypercall Validation ==="
H_REG_QUEUE=$(get_stat_value "$STATS_FINAL" "hcall_reg_lan_queue")
H_REG_LAN=$(get_stat_value "$STATS_FINAL" "hcall_reg_lan")

log "Hypercall usage:"
log "  hcall_reg_lan_queue: $H_REG_QUEUE (subordinate MQ registers)"
log "  hcall_reg_lan: $H_REG_LAN (queue 0 / LAN register)"

if [ "$H_REG_QUEUE" -gt 0 ] 2>/dev/null; then
    score_pass "Using multi-queue hypercalls (hcall_reg_lan_queue=$H_REG_QUEUE)"
elif [ "$H_REG_LAN" -gt 0 ] 2>/dev/null; then
    score_pass "Using LAN register hypercalls (hcall_reg_lan=$H_REG_LAN)"
else
    score_fail "No hcall_reg_lan_queue / hcall_reg_lan activity in ethtool -S"
fi
log ""

# Test 14: Error Validation
log "=== 18. Error Validation ==="
# v4 has no separate h_send_lan_dropped/failed; use adapter counters.
TX_SEND_FAILED=$(get_stat_value "$STATS_FINAL" "tx_send_failed")
REPLENISH_FAILURE=$(get_stat_value "$STATS_FINAL" "replenish_add_buff_failure")
RX_INVALID=$(get_stat_value "$STATS_FINAL" "rx_invalid_buffer")

TX_SEND_FAILED=${TX_SEND_FAILED:-0}
REPLENISH_FAILURE=${REPLENISH_FAILURE:-0}
RX_INVALID=${RX_INVALID:-0}

if [ "$TX_SEND_FAILED" = "0" ] && [ "$REPLENISH_FAILURE" = "0" ] && [ "$RX_INVALID" = "0" ]; then
    score_pass "Zero errors in all paths"
else
    score_fail "Errors detected in ethtool -S"
    [ "$TX_SEND_FAILED" != "0" ] && log "  - tx_send_failed: $TX_SEND_FAILED"
    [ "$REPLENISH_FAILURE" != "0" ] && log "  - replenish_add_buff_failure: $REPLENISH_FAILURE"
    [ "$RX_INVALID" != "0" ] && log "  - rx_invalid_buffer: $RX_INVALID"
fi
log ""

# Summary
log "========================================"
log "Test Summary"
log "========================================"
log ""

# Module information
MODULE_PATH=$(modinfo ibmveth 2>/dev/null | grep "^filename:" | awk '{print $2}')
if [ -n "$MODULE_PATH" ]; then
    log "${BLUE}Module Information:${NC}"
    log "  Location: $MODULE_PATH"
    MODULE_VERSION=$(modinfo ibmveth 2>/dev/null | grep "^version:" | awk '{print $2}')
    if [ -n "$MODULE_VERSION" ]; then
        log "  Version: $MODULE_VERSION"
    fi
    log ""
fi

# Test results
log "${BLUE}Test Results:${NC}"
log "  Tests Run: $TOTAL_TESTS"
log "  Passed: $PASS_COUNT"
if [ $FAIL_COUNT -gt 0 ]; then
    log "  Failed: $FAIL_COUNT"
else
    log "  Failed: $FAIL_COUNT"
fi
log ""

# List of tests performed
if [ ${#TEST_RESULTS[@]} -gt 0 ]; then
    log "${BLUE}Tests Performed:${NC}"
    for result in "${TEST_RESULTS[@]}"; do
        # Extract test name (remove "PASS: " or "FAIL: " prefix)
        test_name=$(echo "$result" | sed 's/^[A-Z]*: //')
        log "  • $test_name"
    done
    log ""
fi

# Dmesg error analysis
log "${BLUE}Dmesg Analysis:${NC}"
# Persist full dmesg since suite start for summary analysis
if [ "${DMESG_START:-0}" -gt 0 ]; then
    cur=$(dmesg | wc -l)
    delta=$((cur - DMESG_START))
    if [ "$delta" -gt 0 ]; then
        dmesg | tail -"$delta" > "$DMESG_LOG"
    else
        : > "$DMESG_LOG"
    fi
fi

if [ -f "$DMESG_LOG" ] && [ -s "$DMESG_LOG" ]; then
    ERROR_COUNT=$(grep -iE "error|fail|warn|bug|oops" "$DMESG_LOG" | grep -v "DEBUG:" | wc -l | tr -d ' ')
    if [ "$ERROR_COUNT" -gt 0 ]; then
        log "  ${YELLOW}Warnings/Errors found: $ERROR_COUNT${NC}"
        log ""
        log "  ${YELLOW}Recent errors/warnings:${NC}"
        grep -iE "error|fail|warn|bug|oops" "$DMESG_LOG" | grep -v "DEBUG:" | head -5 | sed 's/^/    /' | tee -a "$LOG_FILE"
        if [ "$ERROR_COUNT" -gt 5 ]; then
            log "    ... ($(($ERROR_COUNT - 5)) more in dmesg log)"
        fi
    else
        log "  ${GREEN}No errors or warnings detected${NC}"
    fi
    log "  Dmesg log: $DMESG_LOG"
else
    log "  ${YELLOW}⚠${NC} Dmesg log empty or not found: $DMESG_LOG"
    log "  (This is normal if no kernel messages were generated during testing)"
fi
log ""

# Generated files
log "${BLUE}Generated Files:${NC}"
log "  Results directory: $RESULTS_DIR"
log ""
log "  Core logs:"
log "    - Full test log: $LOG_FILE"
log "    - Dmesg log: $DMESG_LOG"
log "    - System info: $SYSINFO"
log ""
log "  Statistics:"
log "    - Initial stats: $STATS_BEFORE"
log "    - After traffic: $STATS_AFTER_TRAFFIC"
log "    - After resize: $STATS_AFTER_RESIZE"
log "    - Final stats: $STATS_FINAL"
log "    - Stats deltas: $STATS_DELTA_DIR/"
log ""
log "  Monitoring:"
log "    - Dmesg deltas: $DMESG_DELTA_DIR/"
log "    - Interrupts: $INTERRUPTS_LOG"
log "    - Memory: $MEMORY_LOG"
log "    - Verification: $VERIFICATION_LOG"
log ""

# Overall status
log "${BLUE}Overall Status:${NC}"
log "  End time: $(date)"
log ""

if [ "$FAIL_COUNT" -eq 0 ] && [ "$TOTAL_TESTS" -gt 0 ] && [ "$PASS_COUNT" -eq "$TOTAL_TESTS" ]; then
    log "  ${GREEN}✓ ALL TESTS PASSED${NC} ($PASS_COUNT/$TOTAL_TESTS)"
    exit 0
elif [ "$FAIL_COUNT" -eq 0 ]; then
    log "  ${GREEN}✓ ALL SCORED TESTS PASSED${NC} ($PASS_COUNT/$TOTAL_TESTS)"
    exit 0
elif [ "$PASS_COUNT" -ge $((TOTAL_TESTS * 3 / 4)) ]; then
    log "  ${YELLOW}⚠ MOST TESTS PASSED${NC} ($PASS_COUNT/$TOTAL_TESTS, failed=$FAIL_COUNT)"
    log "  ${YELLOW}Review failed tests above${NC}"
    exit 1
else
    log "  ${RED}✗ MULTIPLE TESTS FAILED${NC} ($PASS_COUNT/$TOTAL_TESTS passed, $FAIL_COUNT failed)"
    log "  ${RED}Review test results and logs${NC}"
    exit 1
fi
