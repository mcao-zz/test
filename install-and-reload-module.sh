#!/bin/bash
# Install newly built ibmveth module and reload
#
# Usage:
#   ./install-and-reload-module.sh           # Normal reload
#   ./install-and-reload-module.sh debug     # Reload with dynamic debug

set -e

MODULE_DIR="/lib/modules/$(uname -r)/kernel/drivers/net/ethernet/ibm"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if we're in the kernel build directory
if [ ! -f "drivers/net/ethernet/ibm/ibmveth.ko" ]; then
    echo "ERROR: ibmveth.ko not found in drivers/net/ethernet/ibm/"
    echo "Please run this script from the kernel build directory"
    exit 1
fi

echo "=== Installing new ibmveth module ==="

# Save new module with timestamp name
cp drivers/net/ethernet/ibm/ibmveth.ko "$MODULE_DIR/ibmveth.ko.new_$TIMESTAMP"
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
    "$SCRIPT_DIR/reload-ibmveth-module.sh" "$@"
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
    if [ "$1" = "debug" ]; then
        modprobe ibmveth dyndbg=+pmf
        echo "✓ Module loaded with dynamic debug"
    else
        modprobe ibmveth
        echo "✓ Module loaded"
    fi

    sleep 1

    # Bring up interfaces
    ip link set env8 up 2>/dev/null || true
    ip link set net0 up 2>/dev/null || true

    echo ""
    echo "=== Recent ibmveth messages ==="
    dmesg | grep -i ibmveth | tail -20
fi

echo ""
echo "=== Installation complete ==="
echo "Module location: $MODULE_DIR/ibmveth.ko"
echo "Backup: $MODULE_DIR/ibmveth.ko.backup_$TIMESTAMP"

# Made with Bob
