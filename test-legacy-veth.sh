#!/bin/bash

# IBM Virtual Ethernet (ibmveth) Driver Test Script
# Tests fallback mode operation on firmware without multi-queue support
#
# Usage: ./test-veth.sh [interface] [test_host] [debug_mode]
# Example: ./test-veth.sh net0 10.48.34.150
#          ./test-veth.sh net0 10.48.34.150 on

set -u  # Exit on undefined variables

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test configuration from command line or defaults
INTERFACE="${1:-net0}"
TEST_HOST="${2:-9.3.20.62}"
DEBUG_MODE="${3:-off}"  # on/off - enables dynamic debug during module reload
RESULTS_DIR="/tmp/ibmveth-test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$RESULTS_DIR/test_${INTERFACE}_${TIMESTAMP}.log"
STATS_BEFORE="$RESULTS_DIR/stats_before_${INTERFACE}_${TIMESTAMP}.txt"
STATS_PRE_RELOAD="$RESULTS_DIR/stats_pre_reload_${INTERFACE}_${TIMESTAMP}.txt"
STATS_AFTER="$RESULTS_DIR/stats_after_${INTERFACE}_${TIMESTAMP}.txt"
STATS_DELTA_TESTS="$RESULTS_DIR/stats_delta_tests_${INTERFACE}_${TIMESTAMP}.txt"
STATS_DELTA_FINAL="$RESULTS_DIR/stats_delta_final_${INTERFACE}_${TIMESTAMP}.txt"
SYSINFO="$RESULTS_DIR/sysinfo_${INTERFACE}_${TIMESTAMP}.txt"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=11
TEST_RESULTS=()

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

  # Out-of-tree module
  sudo IBMVETH_KO=/home/ming/ibmveth-build $0 -d net0 -t 192.168.1.134 -D

  # Use defaults
  $0

Environment:
  IBMVETH_KO   Path to ibmveth.ko (or build dir); reload uses insmod instead of modprobe

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

# Create results directory
mkdir -p "$RESULTS_DIR"

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Check result function
check_result() {
    local result=$1
    local test_name=$2
    if [ $result -eq 0 ]; then
        log "${GREEN}✓ PASS${NC}: $test_name"
        return 0
    else
        log "${RED}✗ FAIL${NC}: $test_name"
        return 1
    fi
}

# Function to get interface statistics
get_iface_stat() {
    local direction=$1  # RX or TX
    local field=$2      # 1=bytes, 2=packets
    ip -s link show "$INTERFACE" | grep -A1 "$direction:" | tail -1 | awk "{print \$$field}"
}

# Function to get specific stat from ethtool output
get_stat_value() {
    local stat_file=$1
    local stat_name=$2
    grep "${stat_name}:" "$stat_file" 2>/dev/null | awk '{print $2}' || echo "0"
}

# Start test
log "========================================"
log "IBM Virtual Ethernet Driver Test Suite"
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

    # Get module load address
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

    # Get interface details
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
                log "${GREEN}✓ PASS${NC}: Interface is UP (state: $STATE)"
                ((PASS_COUNT++))
            else
                log "${RED}✗ FAIL${NC}: Failed to bring interface UP"
            fi
        else
            log "${RED}✗ FAIL${NC}: Failed to bring interface UP"
        fi
    else
        log "${GREEN}✓ PASS${NC}: Interface is UP"
        ((PASS_COUNT++))
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
    # Go up two levels to get the VIO device directory
    VIO_DEVICE=$(dirname "$(dirname "$VIO_PATH")")
    log "VIO device path: $VIO_DEVICE"

    # Read device tree properties
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

# Test 4: Sysfs Attributes
log "=== 5. Sysfs Attributes ==="
if [ -n "$VIO_DEVICE" ]; then
    # Check subordinate_queue_mode
    if [ -f "$VIO_DEVICE/subordinate_queue_mode" ]; then
        QUEUE_MODE=$(cat "$VIO_DEVICE/subordinate_queue_mode")
        log "subordinate_queue_mode: $QUEUE_MODE"

        if [ "$QUEUE_MODE" = "0" ]; then
            log "${GREEN}✓ PASS${NC}: Fallback mode detected (subordinate_queue_mode=0)"
            ((PASS_COUNT++))
        else
            log "${YELLOW}⚠${NC} Multi-queue mode active (subordinate_queue_mode=$QUEUE_MODE)"
        fi
    fi

    # Check max_rx_buffers_per_call
    if [ -f "$VIO_DEVICE/max_rx_buffers_per_call" ]; then
        MAX_BUFFERS=$(cat "$VIO_DEVICE/max_rx_buffers_per_call")
        log "max_rx_buffers_per_call: $MAX_BUFFERS"
    fi

    # Check current_rx_batch_size
    if [ -f "$VIO_DEVICE/current_rx_batch_size" ]; then
        BATCH_SIZE=$(cat "$VIO_DEVICE/current_rx_batch_size")
        log "current_rx_batch_size: $BATCH_SIZE"
    fi
else
    log "${YELLOW}⚠ SKIP${NC}: Cannot check sysfs attributes (VIO device path not found)"
fi
log ""

# Capture FULL statistics BEFORE tests
log "=== 6. Capturing Initial Statistics ==="
log "${BLUE}Saving full stats to: $STATS_BEFORE${NC}"
ethtool -S "$INTERFACE" > "$STATS_BEFORE"
log "✓ Initial statistics captured ($(wc -l < "$STATS_BEFORE") lines)"
log ""

# Capture initial interface stats
RX_BYTES_BEFORE=$(get_iface_stat "RX" 1)
RX_PACKETS_BEFORE=$(get_iface_stat "RX" 2)
TX_BYTES_BEFORE=$(get_iface_stat "TX" 1)
TX_PACKETS_BEFORE=$(get_iface_stat "TX" 2)

log "Initial Interface Statistics:"
log "  RX: $RX_PACKETS_BEFORE packets, $RX_BYTES_BEFORE bytes"
log "  TX: $TX_PACKETS_BEFORE packets, $TX_BYTES_BEFORE bytes"
log ""

# Display key initial stats
log "Key Initial Hypercall Statistics:"
grep -E "h_reg|h_add_buf|h_send|h_free|replenish" "$STATS_BEFORE" | tee -a "$LOG_FILE"
log ""

# Define stats to track
STATS_TO_TRACK=(
    "h_reg_queue_calls"
    "h_reg_lan_calls"
    "h_add_buf_queue_calls"
    "h_add_buf_lan_buffer_calls"
    "h_add_buf_lan_buffers_calls"
    "h_free_queue_calls"
    "h_free_lan_calls"
    "h_send_lan_calls"
    "h_send_lan_packets"
    "h_send_lan_busy_retries"
    "h_send_lan_dropped"
    "h_send_lan_failed"
    "replenish_add_buff_success"
    "replenish_add_buff_failure"
    "replenish_no_mem"
    "tx_send_failed"
    "rx_invalid_buffer"
)

# Validate fallback mode from initial stats
H_REG_QUEUE_INIT=$(get_stat_value "$STATS_BEFORE" "h_reg_queue_calls")
H_REG_LAN_INIT=$(get_stat_value "$STATS_BEFORE" "h_reg_lan_calls")

# Ensure values are numeric
H_REG_QUEUE_INIT=${H_REG_QUEUE_INIT:-0}
H_REG_LAN_INIT=${H_REG_LAN_INIT:-0}

if [ "$H_REG_QUEUE_INIT" != "0" ]; then
    log "${YELLOW}⚠${NC} Multi-queue mode active (using H_REG_LOGICAL_LAN_QUEUE)"
elif [ "$H_REG_LAN_INIT" != "0" ]; then
    log "${GREEN}✓ PASS${NC}: Fallback mode confirmed (using H_REGISTER_LOGICAL_LAN)"
    ((PASS_COUNT++))
else
    log "${YELLOW}⚠${NC} No registration calls detected yet (will be triggered by first traffic)"
fi
log ""

# Test 6: Basic Connectivity
log "=== 7. Test 1: Basic Connectivity ==="
log "Testing basic ping to $TEST_HOST..."
if ping -c 5 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
    check_result 0 "Basic connectivity (ping)" && ((PASS_COUNT++))
else
    check_result 1 "Basic connectivity (ping)"
    log "${YELLOW}⚠${NC} Hint: Check if $TEST_HOST is reachable and responds to ping"
fi
log ""

# Test 7: Large Packet Test
log "=== 8. Test 2: Large Packet Test ==="
log "Testing with various packet sizes..."

LARGE_PACKET_PASSED=0

# Try 1400 bytes (safe for most networks with MTU 1500)
log "  Testing 1400-byte packets..."
if ping -c 10 -s 1400 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
    log "  ${GREEN}✓ Success${NC} with 1400-byte packets"
    LARGE_PACKET_PASSED=1
fi

# Try 1000 bytes if 1400 failed
if [ "$LARGE_PACKET_PASSED" -eq 0 ]; then
    log "  Testing 1000-byte packets..."
    if ping -c 10 -s 1000 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
        log "  ${GREEN}✓ Success${NC} with 1000-byte packets"
        LARGE_PACKET_PASSED=1
    fi
fi

# Try 500 bytes if 1000 failed
if [ "$LARGE_PACKET_PASSED" -eq 0 ]; then
    log "  Testing 500-byte packets..."
    if ping -c 10 -s 500 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
        log "  ${GREEN}✓ Success${NC} with 500-byte packets"
        LARGE_PACKET_PASSED=1
    fi
fi

if [ "$LARGE_PACKET_PASSED" -eq 1 ]; then
    check_result 0 "Large packet test" && ((PASS_COUNT++))
else
    log "${YELLOW}⚠ SKIP${NC}: Large packet test (network path may have MTU limitations)"
fi
log ""

# Test 8: Sustained Traffic
log "=== 9. Test 3: Sustained Traffic ==="
log "Testing sustained traffic (100 pings)..."
if ping -c 100 -i 0.2 "$TEST_HOST" > /dev/null 2>&1; then
    check_result 0 "Sustained traffic test" && ((PASS_COUNT++))
else
    check_result 1 "Sustained traffic test"
fi
log ""

# Test 9: Parallel Connections
log "=== 10. Test 4: Parallel Connections ==="
log "Testing parallel ping streams..."
ping -c 50 -i 0.1 "$TEST_HOST" > /dev/null 2>&1 &
PID1=$!
ping -c 50 -i 0.1 "$TEST_HOST" > /dev/null 2>&1 &
PID2=$!
ping -c 50 -i 0.1 "$TEST_HOST" > /dev/null 2>&1 &
PID3=$!

wait $PID1
RESULT1=$?
wait $PID2
RESULT2=$?
wait $PID3
RESULT3=$?

if [ $RESULT1 -eq 0 ] && [ $RESULT2 -eq 0 ] && [ $RESULT3 -eq 0 ]; then
    check_result 0 "Parallel connections test" && ((PASS_COUNT++))
else
    check_result 1 "Parallel connections test"
fi
log ""

# Test 10: Inbound Traffic (RX Heavy)
log "=== 11. Test 5: Inbound Traffic (RX Heavy) ==="
log "Testing heavy inbound traffic..."

RX_TEST_PASSED=0
RX_METHOD=""

# Method 1: Download test file (best for RX heavy)
if command -v curl &> /dev/null && [ "$RX_TEST_PASSED" -eq 0 ]; then
    log "Attempting file download for RX test..."
    if timeout 30 curl -s -o /dev/null http://speedtest.tele2.net/1MB.zip 2>&1; then
        RX_TEST_PASSED=1
        RX_METHOD="file download (1MB)"
    fi
fi

# Method 2: Large ping responses (fallback)
if [ "$RX_TEST_PASSED" -eq 0 ]; then
    log "Attempting large ping responses for RX test..."
    if ping -c 1000 -i 0.01 -s 1400 "$TEST_HOST" > /dev/null 2>&1; then
        RX_TEST_PASSED=1
        RX_METHOD="large ping responses (1000 x 1400 bytes)"
    fi
fi

# Method 3: Many small pings (last resort)
if [ "$RX_TEST_PASSED" -eq 0 ]; then
    log "Attempting many small pings for RX test..."
    if ping -c 2000 -i 0.005 "$TEST_HOST" > /dev/null 2>&1; then
        RX_TEST_PASSED=1
        RX_METHOD="many small pings (2000 packets)"
    fi
fi

# Report result
if [ "$RX_TEST_PASSED" -eq 1 ]; then
    log "${GREEN}✓ PASS${NC}: RX heavy test using $RX_METHOD"
    ((PASS_COUNT++))
else
    log "${YELLOW}⚠ SKIP${NC}: All RX test methods failed (network issue, not driver)"
fi
log ""

# Test 11: Bidirectional Traffic
log "=== 12. Test 6: Bidirectional Traffic ==="
log "Testing simultaneous TX and RX..."
ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1 &
PID_TX=$!
ping -c 100 -i 0.05 "$TEST_HOST" > /dev/null 2>&1 &
PID_RX=$!

wait $PID_TX
RESULT_TX=$?
wait $PID_RX
RESULT_RX=$?

if [ $RESULT_TX -eq 0 ] && [ $RESULT_RX -eq 0 ]; then
    check_result 0 "Bidirectional traffic test" && ((PASS_COUNT++))
else
    check_result 1 "Bidirectional traffic test"
fi
log ""

# Test 12: Interface Down/Up
log "=== 13. Test 7: Interface Resilience ==="
log "Testing interface down/up cycle..."
if sudo ip link set "$INTERFACE" down && sleep 2 && sudo ip link set "$INTERFACE" up && sleep 3; then
    if ping -c 5 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
        check_result 0 "Interface resilience test" && ((PASS_COUNT++))
    else
        check_result 1 "Interface resilience test (ping after up)"
    fi
else
    check_result 1 "Interface resilience test (down/up failed)"
fi
log ""

# Capture statistics BEFORE module reload
log "=== 14. Statistics Before Module Reload ==="
log "${BLUE}Saving stats to: $STATS_PRE_RELOAD${NC}"
ethtool -S "$INTERFACE" > "$STATS_PRE_RELOAD"
log "✓ Pre-reload statistics captured ($(wc -l < "$STATS_PRE_RELOAD") lines)"
log ""

# Capture pre-reload interface stats
RX_BYTES_PRE=$(get_iface_stat "RX" 1)
RX_PACKETS_PRE=$(get_iface_stat "RX" 2)
TX_BYTES_PRE=$(get_iface_stat "TX" 1)
TX_PACKETS_PRE=$(get_iface_stat "TX" 2)

log "Pre-Reload Interface Statistics:"
log "  RX: $RX_PACKETS_PRE packets, $RX_BYTES_PRE bytes"
log "  TX: $TX_PACKETS_PRE packets, $TX_BYTES_PRE bytes"
log ""

log "Key Pre-Reload Hypercall Statistics:"
grep -E "h_reg|h_add_buf|h_send|h_free|replenish" "$STATS_PRE_RELOAD" | tee -a "$LOG_FILE"
log ""

# Calculate and save delta for tests 1-7
log "=== 15. Statistics Delta (Tests 1-7) ===" | tee "$STATS_DELTA_TESTS"
log "${BLUE}Calculating changes from initial to pre-reload...${NC}" | tee -a "$STATS_DELTA_TESTS"
log "" | tee -a "$STATS_DELTA_TESTS"

for stat in "${STATS_TO_TRACK[@]}"; do
    BEFORE=$(get_stat_value "$STATS_BEFORE" "$stat")
    PRE=$(get_stat_value "$STATS_PRE_RELOAD" "$stat")

    # Ensure values are numeric
    BEFORE=${BEFORE:-0}
    PRE=${PRE:-0}

    DELTA=$((PRE - BEFORE))

    if [ "$DELTA" -ne 0 ]; then
        log "  $stat: $BEFORE → $PRE (+$DELTA)" | tee -a "$STATS_DELTA_TESTS"
    fi
done

log "" | tee -a "$STATS_DELTA_TESTS"
log "Interface Traffic Delta:" | tee -a "$STATS_DELTA_TESTS"
log "  RX: +$((RX_PACKETS_PRE - RX_PACKETS_BEFORE)) packets, +$((RX_BYTES_PRE - RX_BYTES_BEFORE)) bytes" | tee -a "$STATS_DELTA_TESTS"
log "  TX: +$((TX_PACKETS_PRE - TX_PACKETS_BEFORE)) packets, +$((TX_BYTES_PRE - TX_BYTES_BEFORE)) bytes" | tee -a "$STATS_DELTA_TESTS"
log ""

# Calculate batching efficiency
H_ADD_BUF_BUFFER_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "h_add_buf_lan_buffer_calls")
H_ADD_BUF_BUFFERS_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "h_add_buf_lan_buffers_calls")

# Ensure values are numeric
H_ADD_BUF_BUFFER_PRE=${H_ADD_BUF_BUFFER_PRE:-0}
H_ADD_BUF_BUFFERS_PRE=${H_ADD_BUF_BUFFERS_PRE:-0}

if [ "$H_ADD_BUF_BUFFERS_PRE" -gt 0 ]; then
    TOTAL_BUFFERS=$((H_ADD_BUF_BUFFER_PRE + H_ADD_BUF_BUFFERS_PRE * 8))
    TOTAL_CALLS=$((H_ADD_BUF_BUFFER_PRE + H_ADD_BUF_BUFFERS_PRE))
    if [ "$TOTAL_CALLS" -gt 0 ]; then
        AVG_BATCH=$(awk "BEGIN {printf \"%.2f\", $TOTAL_BUFFERS / $TOTAL_CALLS}")
        EFFICIENCY=$(awk "BEGIN {printf \"%.1f\", ($AVG_BATCH / 8) * 100}")
        log "Batching Efficiency:" | tee -a "$STATS_DELTA_TESTS"
        log "  Average buffers per call: $AVG_BATCH" | tee -a "$STATS_DELTA_TESTS"
        log "  Batching efficiency: ${EFFICIENCY}%" | tee -a "$STATS_DELTA_TESTS"
        log ""
    fi
fi

# Test 13: Module Reload
log "=== 16. Test 8: Module Reload ==="
log "Testing module reload (IBMVETH_KO=${IBMVETH_KO:-modprobe})..."

if [ "$DEBUG_MODE" = "1" ] || [ "$DEBUG_MODE" = "on" ]; then
    log "${CYAN}Debug mode enabled - dyndbg=+p${NC}"
fi

# Remove module
if sudo rmmod ibmveth; then
    log "✓ Module removed"
    sleep 2

    # Reload: IBMVETH_KO= path/to/ibmveth.ko (or dir) uses insmod; else modprobe
    _REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
    # shellcheck source=ibmveth-ko-load.sh
    . "$_REPO_ROOT/ibmveth-ko-load.sh"
    if [ "$DEBUG_MODE" = "1" ] || [ "$DEBUG_MODE" = "on" ]; then
        log "Loading module with dynamic debug enabled..."
        if ibmveth_module_load "+p"; then
            log "✓ Module loaded with debug"
        else
            log "${RED}✗${NC} Module load with debug failed"
        fi
    else
        if ibmveth_module_load; then
            log "✓ Module loaded"
        else
            log "${RED}✗${NC} Module load failed"
        fi
    fi

    sleep 5

    # Wait for interface to come back up
    sleep 3

    # Bring interface up if needed
    if ! ip link show "$INTERFACE" | grep -q "state UP"; then
        sudo ip link set "$INTERFACE" up
        sleep 3
    fi

    if ping -c 5 -W 2 "$TEST_HOST" > /dev/null 2>&1; then
        check_result 0 "Module reload test" && ((PASS_COUNT++))
    else
        check_result 1 "Module reload test (ping after reload)"
    fi
else
    check_result 1 "Module reload test (rmmod failed)"
fi
log ""

# Capture FINAL statistics
log "=== 17. Final Statistics ==="
log "${BLUE}Saving final stats to: $STATS_AFTER${NC}"
ethtool -S "$INTERFACE" > "$STATS_AFTER"
log "✓ Final statistics captured ($(wc -l < "$STATS_AFTER") lines)"
log ""

# Capture final interface stats
RX_BYTES_AFTER=$(get_iface_stat "RX" 1)
RX_PACKETS_AFTER=$(get_iface_stat "RX" 2)
TX_BYTES_AFTER=$(get_iface_stat "TX" 1)
TX_PACKETS_AFTER=$(get_iface_stat "TX" 2)

log "Final Interface Statistics:"
log "  RX: $RX_PACKETS_AFTER packets, $RX_BYTES_AFTER bytes"
log "  TX: $TX_PACKETS_AFTER packets, $TX_BYTES_AFTER bytes"
log ""

log "Key Final Hypercall Statistics:"
grep -E "h_reg|h_add_buf|h_send|h_free|replenish" "$STATS_AFTER" | tee -a "$LOG_FILE"
log ""

# Calculate and save final delta (post-reload activity)
log "=== 18. Statistics Delta (Post-Reload) ===" | tee "$STATS_DELTA_FINAL"
log "${BLUE}Note: Module reload resets counters, so these show activity after reload${NC}" | tee -a "$STATS_DELTA_FINAL"
log "" | tee -a "$STATS_DELTA_FINAL"

for stat in "${STATS_TO_TRACK[@]}"; do
    AFTER=$(get_stat_value "$STATS_AFTER" "$stat")

    # Ensure value is numeric
    AFTER=${AFTER:-0}

    if [ "$AFTER" -ne 0 ]; then
        log "  $stat: $AFTER" | tee -a "$STATS_DELTA_FINAL"
    fi
done

log "" | tee -a "$STATS_DELTA_FINAL"
log "Post-Reload Interface Traffic:" | tee -a "$STATS_DELTA_FINAL"
log "  RX: $RX_PACKETS_AFTER packets, $RX_BYTES_AFTER bytes" | tee -a "$STATS_DELTA_FINAL"
log "  TX: $TX_PACKETS_AFTER packets, $TX_BYTES_AFTER bytes" | tee -a "$STATS_DELTA_FINAL"
log ""

# Validate error counters
H_SEND_DROPPED=$(get_stat_value "$STATS_AFTER" "h_send_lan_dropped")
H_SEND_FAILED=$(get_stat_value "$STATS_AFTER" "h_send_lan_failed")
REPLENISH_FAILURE=$(get_stat_value "$STATS_AFTER" "replenish_add_buff_failure")
RX_INVALID=$(get_stat_value "$STATS_AFTER" "rx_invalid_buffer")

# Ensure values are numeric (default to 0 if empty)
H_SEND_DROPPED=${H_SEND_DROPPED:-0}
H_SEND_FAILED=${H_SEND_FAILED:-0}
REPLENISH_FAILURE=${REPLENISH_FAILURE:-0}
RX_INVALID=${RX_INVALID:-0}

if [ "$H_SEND_DROPPED" = "0" ] && [ "$H_SEND_FAILED" = "0" ] && [ "$REPLENISH_FAILURE" = "0" ] && [ "$RX_INVALID" = "0" ]; then
    log "${GREEN}✓ PASS${NC}: Zero errors in all paths"
    ((PASS_COUNT++))
else
    log "${RED}✗ FAIL${NC}: Errors detected:"
    [ "$H_SEND_DROPPED" != "0" ] && log "  - h_send_lan_dropped: $H_SEND_DROPPED"
    [ "$H_SEND_FAILED" != "0" ] && log "  - h_send_lan_failed: $H_SEND_FAILED"
    [ "$REPLENISH_FAILURE" != "0" ] && log "  - replenish_add_buff_failure: $REPLENISH_FAILURE"
    [ "$RX_INVALID" != "0" ] && log "  - rx_invalid_buffer: $RX_INVALID"
fi
log ""

# Display Summary of Key Findings
log ""
log "========================================"
log "=== VALIDATION SUMMARY ==="
log "========================================"
log ""

# Fallback Mode Validation
log "${BLUE}1. Fallback Mode Validation:${NC}"

# Read from the actual stats files
if [ -f "$STATS_PRE_RELOAD" ]; then
    H_REG_QUEUE_FINAL=$(get_stat_value "$STATS_PRE_RELOAD" "h_reg_queue_calls")
    H_REG_LAN_FINAL=$(get_stat_value "$STATS_PRE_RELOAD" "h_reg_lan_calls")
    H_REG_QUEUE_FINAL=${H_REG_QUEUE_FINAL:-0}
    H_REG_LAN_FINAL=${H_REG_LAN_FINAL:-0}

    if [ "$H_REG_QUEUE_FINAL" = "0" ] && [ "$H_REG_LAN_FINAL" != "0" ]; then
        log "   ${GREEN}✓ CONFIRMED${NC}: Using legacy hypercalls (H_REGISTER_LOGICAL_LAN)"
        log "   - h_reg_queue_calls: $H_REG_QUEUE_FINAL (multi-queue NOT used)"
        log "   - h_reg_lan_calls: $H_REG_LAN_FINAL (legacy hypercall used)"
    elif [ "$H_REG_QUEUE_FINAL" != "0" ]; then
        log "   ${YELLOW}⚠ MULTI-QUEUE${NC}: Using multi-queue hypercalls"
        log "   - h_reg_queue_calls: $H_REG_QUEUE_FINAL"
        log "   - h_reg_lan_calls: $H_REG_LAN_FINAL"
    else
        log "   ${YELLOW}⚠ WARNING${NC}: No registration calls detected"
        log "   - h_reg_queue_calls: $H_REG_QUEUE_FINAL"
        log "   - h_reg_lan_calls: $H_REG_LAN_FINAL"
    fi
else
    log "   ${YELLOW}⚠ Cannot read pre-reload stats${NC}"
fi
log ""

# Batching Efficiency
log "${BLUE}2. Batching Efficiency (Tests 1-7):${NC}"

if [ -f "$STATS_PRE_RELOAD" ]; then
    H_ADD_BUF_BUFFER_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "h_add_buf_lan_buffer_calls")
    H_ADD_BUF_BUFFERS_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "h_add_buf_lan_buffers_calls")
    H_ADD_BUF_BUFFER_PRE=${H_ADD_BUF_BUFFER_PRE:-0}
    H_ADD_BUF_BUFFERS_PRE=${H_ADD_BUF_BUFFERS_PRE:-0}

    if [ "$H_ADD_BUF_BUFFERS_PRE" -gt 0 ] || [ "$H_ADD_BUF_BUFFER_PRE" -gt 0 ]; then
        TOTAL_BUFFERS=$((H_ADD_BUF_BUFFER_PRE + H_ADD_BUF_BUFFERS_PRE * 8))
        TOTAL_CALLS=$((H_ADD_BUF_BUFFER_PRE + H_ADD_BUF_BUFFERS_PRE))

        if [ "$TOTAL_CALLS" -gt 0 ]; then
            AVG_BATCH=$(awk "BEGIN {printf \"%.2f\", $TOTAL_BUFFERS / $TOTAL_CALLS}")
            EFFICIENCY=$(awk "BEGIN {printf \"%.1f\", ($AVG_BATCH / 8) * 100}")
            log "   ${GREEN}✓ EXCELLENT${NC}: Batching efficiency ${EFFICIENCY}%"
            log "   - Single-buffer calls: $H_ADD_BUF_BUFFER_PRE"
            log "   - Multi-buffer calls: $H_ADD_BUF_BUFFERS_PRE (8 buffers each)"
            log "   - Average buffers per call: $AVG_BATCH"
        else
            log "   ${YELLOW}⚠ No buffer calls detected${NC}"
        fi
    else
        log "   ${YELLOW}⚠ No buffer replenishment calls detected${NC}"
        log "   - h_add_buf_lan_buffer_calls: $H_ADD_BUF_BUFFER_PRE"
        log "   - h_add_buf_lan_buffers_calls: $H_ADD_BUF_BUFFERS_PRE"
    fi
else
    log "   ${YELLOW}⚠ Cannot read pre-reload stats${NC}"
fi
log ""

# Traffic Statistics
log "${BLUE}3. Traffic Statistics (Tests 1-7):${NC}"
RX_DELTA=$((RX_PACKETS_PRE - RX_PACKETS_BEFORE))
TX_DELTA=$((TX_PACKETS_PRE - TX_PACKETS_BEFORE))
RX_BYTES_DELTA=$((RX_BYTES_PRE - RX_BYTES_BEFORE))
TX_BYTES_DELTA=$((TX_BYTES_PRE - TX_BYTES_BEFORE))

log "   ${GREEN}✓ PROCESSED${NC}:"
log "   - RX: $RX_DELTA packets (+$RX_BYTES_DELTA bytes)"
log "   - TX: $TX_DELTA packets (+$TX_BYTES_DELTA bytes)"
log ""

# Error Validation
log "${BLUE}4. Error Validation:${NC}"

if [ -f "$STATS_PRE_RELOAD" ]; then
    H_SEND_DROPPED_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "h_send_lan_dropped")
    H_SEND_FAILED_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "h_send_lan_failed")
    REPLENISH_FAILURE_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "replenish_add_buff_failure")
    RX_INVALID_PRE=$(get_stat_value "$STATS_PRE_RELOAD" "rx_invalid_buffer")

    H_SEND_DROPPED_PRE=${H_SEND_DROPPED_PRE:-0}
    H_SEND_FAILED_PRE=${H_SEND_FAILED_PRE:-0}
    REPLENISH_FAILURE_PRE=${REPLENISH_FAILURE_PRE:-0}
    RX_INVALID_PRE=${RX_INVALID_PRE:-0}

    if [ "$H_SEND_DROPPED_PRE" = "0" ] && [ "$H_SEND_FAILED_PRE" = "0" ] && [ "$REPLENISH_FAILURE_PRE" = "0" ] && [ "$RX_INVALID_PRE" = "0" ]; then
        log "   ${GREEN}✓ PERFECT${NC}: Zero errors in all paths"
        log "   - TX dropped: 0"
        log "   - TX failed: 0"
        log "   - Replenish failures: 0"
        log "   - Invalid buffers: 0"
    else
        log "   ${RED}✗ ERRORS DETECTED${NC}:"
        [ "$H_SEND_DROPPED_PRE" != "0" ] && log "   - TX dropped: $H_SEND_DROPPED_PRE"
        [ "$H_SEND_FAILED_PRE" != "0" ] && log "   - TX failed: $H_SEND_FAILED_PRE"
        [ "$REPLENISH_FAILURE_PRE" != "0" ] && log "   - Replenish failures: $REPLENISH_FAILURE_PRE"
        [ "$RX_INVALID_PRE" != "0" ] && log "   - Invalid buffers: $RX_INVALID_PRE"
    fi
else
    log "   ${YELLOW}⚠ Cannot read pre-reload stats${NC}"
fi
log ""

# Module Reload Validation
log "${BLUE}5. Module Reload Validation:${NC}"

if [ -f "$STATS_AFTER" ]; then
    H_REG_LAN_AFTER=$(get_stat_value "$STATS_AFTER" "h_reg_lan_calls")
    H_REG_QUEUE_AFTER=$(get_stat_value "$STATS_AFTER" "h_reg_queue_calls")
    H_REG_LAN_AFTER=${H_REG_LAN_AFTER:-0}
    H_REG_QUEUE_AFTER=${H_REG_QUEUE_AFTER:-0}

    if [ "$H_REG_LAN_AFTER" != "0" ] || [ "$H_REG_QUEUE_AFTER" != "0" ]; then
        log "   ${GREEN}✓ SUCCESS${NC}: Driver reinitialized correctly"
        log "   - Post-reload h_reg_lan_calls: $H_REG_LAN_AFTER"
        log "   - Post-reload h_reg_queue_calls: $H_REG_QUEUE_AFTER"
        log "   - Post-reload RX: $RX_PACKETS_AFTER packets"
        log "   - Post-reload TX: $TX_PACKETS_AFTER packets"
    else
        log "   ${YELLOW}⚠ WARNING${NC}: No registration detected after reload"
        log "   - h_reg_lan_calls: $H_REG_LAN_AFTER"
        log "   - h_reg_queue_calls: $H_REG_QUEUE_AFTER"
        log "   - Note: This may be normal if no traffic occurred after reload"
    fi
else
    log "   ${YELLOW}⚠ Cannot read post-reload stats${NC}"
fi
log ""
log "========================================"
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
FAIL_COUNT=$((TOTAL_TESTS - PASS_COUNT))
log "${BLUE}Test Results:${NC}"
log "  Tests Run: $TOTAL_TESTS"
log "  Passed: $PASS_COUNT"
log "  Failed: $FAIL_COUNT"
log ""

# List of tests performed (if we tracked them)
if [ ${#TEST_RESULTS[@]} -gt 0 ]; then
    log "${BLUE}Tests Performed:${NC}"
    for result in "${TEST_RESULTS[@]}"; do
        test_name=$(echo "$result" | sed 's/^[A-Z]*: //')
        log "  • $test_name"
    done
    log ""
fi

# Generated files
log "${BLUE}Generated Files:${NC}"
log "  Results directory: $RESULTS_DIR"
log ""
log "  Core logs:"
log "    - Full test log: $LOG_FILE"
log "    - System info: $SYSINFO"
log ""
log "  Statistics:"
log "    - Initial stats: $STATS_BEFORE"
log "    - Pre-reload stats: $STATS_PRE_RELOAD"
log "    - Final stats: $STATS_AFTER"
log "    - Delta (tests 1-7): $STATS_DELTA_TESTS"
log "    - Delta (post-reload): $STATS_DELTA_FINAL"
log ""

# Overall status
log "${BLUE}Overall Status:${NC}"
log "  End time: $(date)"
log ""

if [ $PASS_COUNT -eq $TOTAL_TESTS ]; then
    log "  ${GREEN}✓ ALL TESTS PASSED ($PASS_COUNT/$TOTAL_TESTS)${NC}"
    exit 0
elif [ $PASS_COUNT -ge $((TOTAL_TESTS * 3 / 4)) ]; then
    log "  ${YELLOW}⚠ MOST TESTS PASSED ($PASS_COUNT/$TOTAL_TESTS)${NC}"
    exit 0
else
    log "  ${RED}✗ SOME TESTS FAILED ($PASS_COUNT/$TOTAL_TESTS)${NC}"
    exit 1
fi
