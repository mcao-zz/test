#!/bin/bash
# Install and reload ibmveth module with backup

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default source tree location
SOURCE_TREE="${SOURCE_TREE:-/root/ming/net-next}"

# Default module installation directory
MODULE_DIR="${MODULE_DIR:-/lib/modules/$(uname -r)/kernel/drivers/net/ethernet/ibm}"

# Parse command line arguments
DEBUG_MODE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source|-s)
            SOURCE_TREE="$2"
            shift 2
            ;;
        debug)
            DEBUG_MODE="debug"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--source /path/to/kernel/tree] [debug]"
            exit 1
            ;;
    esac
done

# Timestamp for backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== IBM veth Module Installation ==="
echo "Source tree: $SOURCE_TREE"
echo "Module directory: $MODULE_DIR"
echo ""

# Check if source tree exists
if [ ! -d "$SOURCE_TREE" ]; then
    echo "Error: Source tree not found: $SOURCE_TREE"
    echo "Use --source option or set SOURCE_TREE environment variable"
    exit 1
fi

# Check if built module exists in source tree
SOURCE_MODULE="$SOURCE_TREE/drivers/net/ethernet/ibm/ibmveth.ko"
if [ ! -f "$SOURCE_MODULE" ]; then
    echo "Error: Built module not found: $SOURCE_MODULE"
    echo "Run 'make M=drivers/net/ethernet/ibm' in the source tree first"
    exit 1
fi

# Check if module directory exists
if [ ! -d "$MODULE_DIR" ]; then
    echo "Error: Module directory not found: $MODULE_DIR"
    exit 1
fi

# Check if current module exists
if [ ! -f "$MODULE_DIR/ibmveth.ko" ]; then
    echo "Error: Current module not found: $MODULE_DIR/ibmveth.ko"
    exit 1
fi

echo "=== Creating backup and installing new module ==="

# Copy new module from source tree with timestamp
cp "$SOURCE_MODULE" "$MODULE_DIR/ibmveth.ko.new_$TIMESTAMP"
echo "✓ Copied from source: $SOURCE_MODULE"
echo "✓ Saved new module as: ibmveth.ko.new_$TIMESTAMP"

# Backup current and install new
cp "$MODULE_DIR/ibmveth.ko" "$MODULE_DIR/ibmveth.ko.backup_$TIMESTAMP"
cp "$MODULE_DIR/ibmveth.ko.new_$TIMESTAMP" "$MODULE_DIR/ibmveth.ko"
echo "✓ Installed new module (backup: ibmveth.ko.backup_$TIMESTAMP)"

echo ""
echo "=== Reloading module ==="

# Call the reload script with optional debug parameter
if [ -f "$SCRIPT_DIR/reload-ibmveth-module.sh" ]; then
    # Use our reload script
    if [ -n "$DEBUG_MODE" ]; then
        "$SCRIPT_DIR/reload-ibmveth-module.sh" debug
    else
        "$SCRIPT_DIR/reload-ibmveth-module.sh"
    fi
else
    # Fallback to inline reload
    echo "Note: reload-ibmveth-module.sh not found, using inline reload"

    # Bring down interfaces
    ip link set env8 down 2>/dev/null || true
    ip link set net0 down 2>/dev/null || true

    # Unload module
    rmmod ibmveth 2>/dev/null || true
    sleep 1

    # Reload with optional debug
    if [ -n "$DEBUG_MODE" ]; then
        modprobe ibmveth dyndbg=+pmf
        echo "✓ Module loaded with dynamic debug"
    else
        modprobe ibmveth
        echo "✓ Module loaded"
    fi

    sleep 1

    # Bring up interfaces and show status
    echo "Bringing up interfaces..."

    if ip link set env8 up 2>&1; then
        echo "✓ env8 brought up"
    else
        echo "✗ env8 failed or not present"
    fi

    if ip link set net0 up 2>&1; then
        echo "✓ net0 brought up"
    else
        echo "✗ net0 failed or not present"
    fi

    sleep 1

    echo ""
    echo "=== Interface status ==="
    ip link show env8 2>/dev/null | head -2 || echo "env8: not found"
    ip link show net0 2>/dev/null | head -2 || echo "net0: not found"

    echo ""
    echo "=== Adapter Boot Messages ==="

    # Show renamed messages (proof of reload)
    echo ""
    echo "--- Interface Rename (proof of reload) ---"
    dmesg | grep "ibmveth.*renamed from" | tail -5

    # Show adapter mode detection
    echo ""
    echo "--- Adapter Mode Detection ---"
    dmesg | grep -E "ibmveth.*(single-queue mode|RX multi queue mode)" | tail -5

    echo ""
    echo "=== Recent ibmveth messages ==="

    # Show messages for each interface separately
    if dmesg | grep -q "ibmveth.*env8"; then
        echo ""
        echo "--- env8 (multi-queue adapter) ---"
        dmesg | grep "ibmveth.*env8" | tail -10
    else
        echo ""
        echo "--- env8: No messages found ---"
    fi

    if dmesg | grep -q "ibmveth.*net0"; then
        echo ""
        echo "--- net0 (legacy adapter) ---"
        dmesg | grep "ibmveth.*net0" | tail -10
    else
        echo ""
        echo "--- net0: No messages found ---"
    fi

    # Show any other ibmveth messages
    echo ""
    echo "--- All recent ibmveth messages ---"
    dmesg | grep -i ibmveth | tail -20
fi

echo ""
echo "=== Installation complete ==="
echo "Source: $SOURCE_MODULE"
echo "Installed: $MODULE_DIR/ibmveth.ko"
echo "Backup: $MODULE_DIR/ibmveth.ko.backup_$TIMESTAMP"
echo ""
if [ -n "$DEBUG_MODE" ]; then
    echo "Debug mode: ENABLED (dyndbg=+pmf)"
else
    echo "Debug mode: disabled"
fi

# Made with Bob
