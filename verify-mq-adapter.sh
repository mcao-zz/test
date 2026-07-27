#!/bin/bash
#
# verify-mq-adapter.sh - Verify multi-queue veth adapter setup
#
# Usage: ./verify-mq-adapter.sh [OPTIONS]
#
# This script verifies that a multi-queue virtual ethernet adapter is properly
# configured and operational in a Linux LPAR.
#

set -e

# Default values
DEVICE=""
VERBOSE=0
CHECK_PERFORMANCE=0
DEBUG_MODE=0
RELOAD_MODULE=0
LOG_DIR="./verify-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test result tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_RESULTS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  -d DEVICE           Network device to check (e.g., eth0, ens3)
  -D                  Enable debug mode (reload module with dyndbg=+p)
  -r                  Reload module before verification
  -p                  Run performance checks
  -v                  Verbose output
  -h                  Show this help message

Examples:
  # Basic verification
  $0 -d eth0

  # With module reload and debug
  $0 -d eth0 -D

  # Just reload module (no debug)
  $0 -d eth0 -r

  # With performance checks
  $0 -d eth0 -p

  # Auto-detect ibmveth device
  $0

EOF
    exit 1
}

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_RESULTS+=("PASS: $1")
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_RESULTS+=("FAIL: $1")
}

print_section() {
    echo
    echo -e "${BLUE}=== $1 ===${NC}"
    echo
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_warn "Some checks require root privileges"
        print_warn "Run with sudo for complete verification"
        return 1
    fi
    return 0
}

# Function to reload module
reload_module() {
    if ! check_root; then
        print_error "Module reload requires root privileges"
        return 1
    fi

    print_info "Reloading ibmveth module..."

    # Only bring down the device being tested
    print_info "Bringing down $DEVICE..."
    ip link set "$DEVICE" down 2>/dev/null || true

    # Remove module
    print_info "Removing ibmveth module..."
    if ! rmmod ibmveth 2>/dev/null; then
        print_warn "Failed to remove module (may not be loaded)"
    fi
    sleep 2

    # Reload module with or without debug
    if [ $DEBUG_MODE -eq 1 ]; then
        print_info "Loading ibmveth module with dynamic debug..."
        if modprobe ibmveth dyndbg=+p; then
            print_pass "Module loaded with debug enabled"
        else
            print_error "Failed to load module with debug"
            return 1
        fi
    else
        print_info "Loading ibmveth module..."
        if modprobe ibmveth; then
            print_pass "Module loaded"
        else
            print_error "Failed to load module"
            return 1
        fi
    fi

    sleep 3

    # Bring the device back up
    print_info "Bringing up $DEVICE..."
    ip link set "$DEVICE" up 2>/dev/null || true

    sleep 2
    print_pass "Module reload complete"
    return 0
}

# Function to detect ibmveth device
detect_device() {
    print_info "Auto-detecting ibmveth device..."

    local devices=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo)

    for dev in $devices; do
        if ethtool -i "$dev" 2>/dev/null | grep -q "ibmveth"; then
            DEVICE="$dev"
            print_info "Found ibmveth device: $DEVICE"
            return 0
        fi
    done

    print_error "No ibmveth device found"
    return 1
}

# Function to check if device exists
check_device_exists() {
    if ! ip link show "$DEVICE" &>/dev/null; then
        print_fail "Device $DEVICE does not exist"
        return 1
    fi
    print_pass "Device $DEVICE exists"
    return 0
}

# Function to check driver
check_driver() {
    local driver=$(ethtool -i "$DEVICE" 2>/dev/null | grep "driver:" | awk '{print $2}')

    if [ "$driver" != "ibmveth" ]; then
        print_fail "Device is not using ibmveth driver (using: $driver)"
        return 1
    fi

    print_pass "Device is using ibmveth driver"

    if [ $VERBOSE -eq 1 ]; then
        echo
        ethtool -i "$DEVICE"
    fi

    return 0
}

# Function to check multi-queue support
check_mq_support() {
    if ! command -v ethtool &>/dev/null; then
        print_warn "ethtool not found, skipping MQ checks"
        return 1
    fi

    local output=$(ethtool -l "$DEVICE" 2>/dev/null)

    if [ -z "$output" ]; then
        print_fail "Unable to query queue information"
        return 1
    fi

    # Check RX queues (ibmveth uses separate RX/TX, not combined)
    local max_rx=$(echo "$output" | grep -A 4 "Pre-set" | grep "RX:" | awk '{print $2}')
    local current_rx=$(echo "$output" | grep -A 4 "Current" | grep "RX:" | awk '{print $2}')

    if [ -z "$max_rx" ] || [ "$max_rx" = "n/a" ]; then
        print_fail "Unable to determine RX queue count"
        return 1
    fi

    if [ "$max_rx" -eq 1 ] 2>/dev/null; then
        print_info "Single queue mode (client adapter or fallback)"
    elif [ "$max_rx" -gt 1 ] 2>/dev/null; then
        print_pass "Multi-queue supported (Max RX: $max_rx, Current RX: $current_rx)"
    else
        print_fail "Invalid queue configuration"
        return 1
    fi

    if [ $VERBOSE -eq 1 ]; then
        echo
        ethtool -l "$DEVICE"
    fi

    return 0
}

# Function to check queue registration
check_queue_registration() {
    local queue_dirs=$(ls -d /sys/class/net/"$DEVICE"/queues/rx-* 2>/dev/null | wc -l)

    if [ "$queue_dirs" -eq 0 ]; then
        print_fail "No RX queues found"
        return 1
    fi

    print_pass "Found $queue_dirs RX queue(s)"

    if [ $VERBOSE -eq 1 ]; then
        echo
        for queue in /sys/class/net/"$DEVICE"/queues/rx-*; do
            local qnum=$(basename "$queue" | sed 's/rx-//')
            echo "  Queue $qnum:"
            if [ -f "$queue/rps_cpus" ]; then
                echo "    RPS CPUs: $(cat "$queue/rps_cpus")"
            fi
        done
    fi

    return 0
}

# Function to check IRQ assignment
check_irq_assignment() {
    if ! check_root; then
        print_warn "Skipping IRQ checks (requires root)"
        return 0
    fi

    local irqs=$(grep "$DEVICE" /proc/interrupts | awk '{print $1}' | sed 's/://')
    local irq_count=$(echo "$irqs" | wc -w)

    if [ "$irq_count" -eq 0 ]; then
        print_fail "No IRQs found for device"
        return 1
    fi

    print_pass "Found $irq_count IRQ(s) assigned"

    if [ $VERBOSE -eq 1 ]; then
        echo
        grep "$DEVICE" /proc/interrupts
    fi

    return 0
}

# Function to check device status
check_device_status() {
    local state=$(ip link show "$DEVICE" | grep -oP 'state \K\w+')

    if [ "$state" != "UP" ]; then
        print_warn "Device is $state (not UP)"
    else
        print_pass "Device is UP"
    fi

    if [ $VERBOSE -eq 1 ]; then
        echo
        ip link show "$DEVICE"
    fi

    return 0
}

# Function to check queue statistics
check_queue_stats() {
    if ! command -v ethtool &>/dev/null; then
        print_warn "ethtool not found, skipping statistics"
        return 0
    fi

    # Check for per-queue RX stats (rx0_packets, rx1_packets, etc.)
    local rx_stats=$(ethtool -S "$DEVICE" 2>/dev/null | grep -E "rx[0-9]+_packets")
    # Check for per-queue TX stats (tx0_packets, tx1_packets, etc.)
    local tx_stats=$(ethtool -S "$DEVICE" 2>/dev/null | grep -E "tx[0-9]+_packets")

    if [ -z "$rx_stats" ] && [ -z "$tx_stats" ]; then
        print_warn "No per-queue statistics available"
        return 0
    fi

    local rx_count=$(echo "$rx_stats" | wc -l | tr -d ' ')
    local tx_count=$(echo "$tx_stats" | wc -l | tr -d ' ')
    print_pass "Per-queue statistics available (RX: $rx_count queues, TX: $tx_count queues)"

    if [ $VERBOSE -eq 1 ]; then
        echo
        ethtool -S "$DEVICE" | grep -E "(rx_queue|tx_queue)" || true
    fi

    return 0
}

# Function to check for errors
check_errors() {
    local rx_errors=$(ethtool -S "$DEVICE" 2>/dev/null | grep "rx_errors:" | awk '{print $2}')
    local tx_errors=$(ethtool -S "$DEVICE" 2>/dev/null | grep "tx_errors:" | awk '{print $2}')
    local rx_dropped=$(ethtool -S "$DEVICE" 2>/dev/null | grep "rx_dropped:" | awk '{print $2}')

    local has_errors=0

    if [ -n "$rx_errors" ] && [ "$rx_errors" -gt 0 ]; then
        print_warn "RX errors detected: $rx_errors"
        has_errors=1
    fi

    if [ -n "$tx_errors" ] && [ "$tx_errors" -gt 0 ]; then
        print_warn "TX errors detected: $tx_errors"
        has_errors=1
    fi

    if [ -n "$rx_dropped" ] && [ "$rx_dropped" -gt 0 ]; then
        print_warn "RX packets dropped: $rx_dropped"
        has_errors=1
    fi

    if [ $has_errors -eq 0 ]; then
        print_pass "No errors detected"
    fi

    return 0
}

# Function to run performance checks
run_performance_checks() {
    print_section "Performance Checks"

    # Check CPU usage per queue
    print_info "Checking interrupt distribution..."
    if check_root; then
        local irqs=$(grep "$DEVICE" /proc/interrupts | awk '{print $1}' | sed 's/://')
        for irq in $irqs; do
            if [ -f "/proc/irq/$irq/smp_affinity" ]; then
                local affinity=$(cat "/proc/irq/$irq/smp_affinity")
                echo "  IRQ $irq: CPU affinity = $affinity"
            fi
        done
    else
        print_warn "Root required for interrupt distribution check"
    fi

    echo

    # Check current throughput
    print_info "Current interface statistics:"
    ip -s link show "$DEVICE"

    echo

    # Suggest performance tuning
    print_info "Performance tuning suggestions:"
    echo "  1. Ensure queue count matches CPU count"
    echo "  2. Configure IRQ affinity for load balancing"
    echo "  3. Enable RPS/RFS for better distribution"
    echo "  4. Monitor with: watch -n 1 'ethtool -S $DEVICE | grep queue'"
}

# Parse command line arguments
while getopts "d:Drpvh" opt; do
    case $opt in
        d) DEVICE="$OPTARG" ;;
        D) DEBUG_MODE=1; RELOAD_MODULE=1 ;;
        r) RELOAD_MODULE=1 ;;
        p) CHECK_PERFORMANCE=1 ;;
        v) VERBOSE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Main execution
echo -e "${BLUE}Multi-Queue Adapter Verification${NC}"
echo -e "${BLUE}================================${NC}"
echo

# Capture starting dmesg line number for delta
DMESG_START=$(dmesg | wc -l)

# Reload module if requested
if [ $RELOAD_MODULE -eq 1 ]; then
    print_section "Module Reload"
    if [ $DEBUG_MODE -eq 1 ]; then
        print_info "Debug mode enabled - will load with dyndbg=+p"
    fi
    reload_module || exit 1
fi

# Detect device if not specified
if [ -z "$DEVICE" ]; then
    if ! detect_device; then
        print_error "Please specify a device with -d option"
        exit 1
    fi
fi

# Run checks
print_section "Basic Checks"

check_device_exists || exit 1
check_driver || exit 1
check_device_status

print_section "Multi-Queue Checks"

check_mq_support
check_queue_registration
check_irq_assignment
check_queue_stats

print_section "Error Checks"

check_errors

# Performance checks if requested
if [ $CHECK_PERFORMANCE -eq 1 ]; then
    run_performance_checks
fi

# Summary
echo
print_section "Summary"

# Module information
MODULE_PATH=$(modinfo ibmveth 2>/dev/null | grep "^filename:" | awk '{print $2}')
if [ -n "$MODULE_PATH" ]; then
    echo -e "${BLUE}Module Information:${NC}"
    echo "  Location: $MODULE_PATH"
    MODULE_VERSION=$(modinfo ibmveth 2>/dev/null | grep "^version:" | awk '{print $2}')
    if [ -n "$MODULE_VERSION" ]; then
        echo "  Version: $MODULE_VERSION"
    fi
    echo
fi

# Test results summary
echo -e "${BLUE}Test Results:${NC}"
echo "  Tests Run: $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
if [ $TESTS_FAILED -gt 0 ]; then
    echo "  Failed: $TESTS_FAILED"
else
    echo "  Failed: $TESTS_FAILED"
fi
echo

# List of tests performed
if [ ${#TEST_RESULTS[@]} -gt 0 ]; then
    echo -e "${BLUE}Tests Performed:${NC}"
    for result in "${TEST_RESULTS[@]}"; do
        # Extract test name (remove "PASS: " or "FAIL: " prefix)
        test_name=$(echo "$result" | sed 's/^[A-Z]*: //')
        echo "  • $test_name"
    done
    echo
fi

# Save and analyze dmesg
mkdir -p "$LOG_DIR"
DMESG_FILE="$LOG_DIR/dmesg_${DEVICE}_${TIMESTAMP}.log"
dmesg | tail -n +$((DMESG_START + 1)) | grep -iE "ibmveth|${DEVICE}" > "$DMESG_FILE" 2>/dev/null || true

if [ -s "$DMESG_FILE" ]; then
    echo -e "${BLUE}Dmesg Analysis:${NC}"
    echo "  Log file: $DMESG_FILE"

    # Check for errors/warnings in dmesg (exclude DEBUG messages)
    ERROR_COUNT=$(grep -iE "error|fail|warn|bug|oops" "$DMESG_FILE" | grep -v "DEBUG:" | wc -l | tr -d ' ')
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo -e "  ${YELLOW}Warnings/Errors found: $ERROR_COUNT${NC}"
        echo
        echo -e "${YELLOW}  Recent errors/warnings:${NC}"
        grep -iE "error|fail|warn|bug|oops" "$DMESG_FILE" | grep -v "DEBUG:" | head -5 | sed 's/^/    /'
        if [ "$ERROR_COUNT" -gt 5 ]; then
            echo "    ... ($(($ERROR_COUNT - 5)) more in log file)"
        fi
    else
        echo -e "  ${GREEN}No errors or warnings detected${NC}"
    fi

    if [ $VERBOSE -eq 1 ]; then
        echo
        echo "  Recent messages (first 20 lines):"
        cat "$DMESG_FILE" | head -20 | sed 's/^/    /'
        LINE_COUNT=$(wc -l < "$DMESG_FILE")
        if [ "$LINE_COUNT" -gt 20 ]; then
            echo "    ... ($(($LINE_COUNT - 20)) more lines in log file)"
        fi
    fi
    echo
else
    rm -f "$DMESG_FILE"
    echo -e "${BLUE}Dmesg Analysis:${NC}"
    echo "  No new dmesg messages"
    echo
fi

# Overall status
echo -e "${BLUE}Overall Status:${NC}"
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "  ${GREEN}✓ All checks passed${NC}"
else
    echo -e "  ${YELLOW}⚠ Some checks failed - review results above${NC}"
fi
echo

# Made with Bob
