#!/bin/bash
# Reload ibmveth module with optional dynamic debug
#
# Usage:
#   ./reload-ibmveth-module.sh           # Normal reload (no debug)
#   ./reload-ibmveth-module.sh debug     # Reload with dynamic debug enabled

set -e

ENABLE_DEBUG=0

# Check for debug argument
if [ "$1" = "debug" ]; then
    ENABLE_DEBUG=1
    echo "=== Reloading ibmveth module WITH dynamic debug ==="
else
    echo "=== Reloading ibmveth module (no debug) ==="
fi

# Bring down interfaces
echo "Bringing down interfaces..."
ip link set env8 down 2>/dev/null || true
ip link set net0 down 2>/dev/null || true

# Unload module
echo "Unloading ibmveth module..."
rmmod ibmveth 2>/dev/null || true

# Wait a moment
sleep 1

# Reload module with or without debug
if [ "$ENABLE_DEBUG" -eq 1 ]; then
    echo "Loading ibmveth with dynamic debug enabled..."
    modprobe ibmveth dyndbg=+pmf
    echo "✓ Module loaded with dynamic debug"
else
    echo "Loading ibmveth (normal mode)..."
    modprobe ibmveth
    echo "✓ Module loaded"
fi

# Wait for module to initialize
sleep 1

# Bring up interfaces
echo "Bringing up interfaces..."
ip link set env8 up 2>/dev/null || true
ip link set net0 up 2>/dev/null || true

echo ""
echo "=== Module reload complete ==="
echo ""

# Show debug status if enabled
if [ "$ENABLE_DEBUG" -eq 1 ]; then
    DEBUGFS="/sys/kernel/debug/dynamic_debug/control"
    if [ -f "$DEBUGFS" ]; then
        ENABLED=$(grep ibmveth "$DEBUGFS" | grep -c '=p' || true)
        TOTAL=$(grep ibmveth "$DEBUGFS" | wc -l || true)
        echo "Dynamic debug status: $ENABLED / $TOTAL statements enabled"
        echo ""
    fi
fi

# Show adapter boot messages
echo "=== Adapter Boot Messages ==="

# Show renamed messages (proof of reload)
echo ""
echo "--- Interface Rename (proof of reload) ---"
dmesg | grep "ibmveth.*renamed from" | tail -5

# Show adapter mode detection
echo ""
echo "--- Adapter Mode Detection ---"
dmesg | grep -E "ibmveth.*(single-queue mode|RX multi queue mode)" | tail -5

# Show recent dmesg per interface
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

echo ""
echo "Usage tips:"
echo "  - To enable debug later:  echo 'module ibmveth +p' > /sys/kernel/debug/dynamic_debug/control"
echo "  - To disable debug:       echo 'module ibmveth -p' > /sys/kernel/debug/dynamic_debug/control"
echo "  - To check debug status:  grep ibmveth /sys/kernel/debug/dynamic_debug/control | grep '=p' | wc -l"

# Made with Bob
