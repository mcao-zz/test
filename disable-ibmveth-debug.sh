#!/bin/bash
# Disable dynamic debug for ibmveth driver
#
# This disables all netdev_dbg() messages in the ibmveth driver.
# Note: netdev_info() messages will still be visible.

set -e

DEBUGFS="/sys/kernel/debug/dynamic_debug/control"

# Check if debugfs is mounted
if [ ! -f "$DEBUGFS" ]; then
    echo "ERROR: Dynamic debug control file not found: $DEBUGFS"
    echo "Make sure CONFIG_DYNAMIC_DEBUG=y and debugfs is mounted"
    exit 1
fi

echo "=== Disabling ibmveth dynamic debug ==="

# Disable all ibmveth debug messages
echo 'module ibmveth -p' > "$DEBUGFS"

echo "✓ Dynamic debug disabled for ibmveth"
echo ""

# Show current status
echo "=== Current ibmveth debug status ==="
ENABLED=$(grep ibmveth "$DEBUGFS" | grep -c '=p' || true)
DISABLED=$(grep ibmveth "$DEBUGFS" | grep -c '=_' || true)
TOTAL=$((ENABLED + DISABLED))

echo "Enabled:  $ENABLED / $TOTAL"
echo "Disabled: $DISABLED / $TOTAL"
echo ""

if [ "$ENABLED" -eq 0 ]; then
    echo "✓ All ibmveth debug statements are now disabled"
else
    echo "⚠ Warning: $ENABLED debug statements still enabled"
fi

echo ""
echo "Note: To reload module without debug, use:"
echo "  ./reload-ibmveth-module.sh"
echo ""
echo "To reload module WITH debug enabled:"
echo "  ./reload-ibmveth-module.sh debug"
echo ""
echo "For more info, see: ../docs/DYNAMIC-DEBUG-GUIDE.md"

# Made with Bob
