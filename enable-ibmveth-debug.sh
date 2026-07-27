#!/bin/bash
# Enable dynamic debug for ibmveth driver
#
# This enables all netdev_dbg() messages in the ibmveth driver.
# Note: netdev_info() messages are always visible regardless of this setting.

set -e

DEBUGFS="/sys/kernel/debug/dynamic_debug/control"

# Check if debugfs is mounted
if [ ! -f "$DEBUGFS" ]; then
    echo "ERROR: Dynamic debug control file not found: $DEBUGFS"
    echo "Make sure CONFIG_DYNAMIC_DEBUG=y and debugfs is mounted"
    exit 1
fi

echo "=== Enabling ibmveth dynamic debug ==="

# Enable all ibmveth debug messages
echo 'module ibmveth +p' > "$DEBUGFS"

echo "✓ Dynamic debug enabled for ibmveth"
echo ""

# Show current status
echo "=== Current ibmveth debug status ==="
ENABLED=$(grep ibmveth "$DEBUGFS" | grep -c '=p' || true)
DISABLED=$(grep ibmveth "$DEBUGFS" | grep -c '=_' || true)
TOTAL=$((ENABLED + DISABLED))

echo "Enabled:  $ENABLED / $TOTAL"
echo "Disabled: $DISABLED / $TOTAL"
echo ""

if [ "$ENABLED" -gt 0 ]; then
    echo "Sample enabled debug statements:"
    grep ibmveth "$DEBUGFS" | grep '=p' | head -5
    echo "..."
fi

echo ""
echo "To disable: run disable-ibmveth-debug.sh"
echo "To view logs: dmesg | grep ibmveth"

# Made with Bob
