#!/bin/bash
# rx_queue_cycle_test.sh
# Cycles RX queue count on env9:
#   Forward:  16 → 1 → 2 → 3 → ... → 16
#   Reverse:  16 → 15 → 14 → ... → 1

IFACE="${1:-env9}"
DELAY="${2:-2}"   # seconds between each change

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
	echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

set_rx() {
	local queues=$1
	local label=$2

	echo -e "${YELLOW}--- Setting RX = ${queues} (${label}) ---${NC}"
	ethtool -L "$IFACE" rx "$queues"

	if [ $? -eq 0 ]; then
		echo -e "${GREEN}✓ RX set to ${queues} successfully${NC}"
	else
		echo -e "${RED}✗ Failed to set RX to ${queues}${NC}"
	fi

	# Show current queue count
	echo -n "  Current: "
	ethtool -l "$IFACE" | grep -E "^RX:|^Combined:" | head -2

	echo ""
	sleep "$DELAY"
}

verify_interface() {
	if ! ip link show "$IFACE" > /dev/null 2>&1; then
		echo -e "${RED}ERROR: Interface '$IFACE' not found!${NC}"
		echo "Available interfaces:"
		ip link show | grep -E "^[0-9]+" | awk '{print "  "$2}' | tr -d ':'
		exit 1
	fi

	log "Interface: $IFACE"
	log "Delay between changes: ${DELAY}s"
	echo ""

	# Show initial queue config
	echo "=== Initial Queue Configuration ==="
	ethtool -l "$IFACE"
	echo ""
}

# ─── MAIN ───────────────────────────────────────────────────────────────────

echo "=============================================="
echo "  ibmveth RX Queue Cycle Test"
echo "  Interface: ${IFACE}"
echo "=============================================="
echo ""

verify_interface

# ── Phase 1: Set to 16 first ─────────────────────────────────────────────────
echo "========================================="
echo "  PHASE 1: Initial → RX 16"
echo "========================================="
set_rx 16 "initial baseline"

# ── Phase 2: Drop back to 1 ──────────────────────────────────────────────────
echo "========================================="
echo "  PHASE 2: 16 → 1"
echo "========================================="
set_rx 1 "scale down to 1"

# ── Phase 3: Forward ramp 1 → 2 → 3 → ... → 16 ──────────────────────────────
echo "========================================="
echo "  PHASE 3: Forward Ramp  1 → 2 → ... → 16"
echo "========================================="
for q in $(seq 2 16); do
	set_rx "$q" "forward ramp $(( q - 1 )) → ${q}"
done

# ── Phase 4: Reverse ramp 16 → 15 → ... → 1 ─────────────────────────────────
echo "========================================="
echo "  PHASE 4: Reverse Ramp  16 → 15 → ... → 1"
echo "========================================="
for q in $(seq 15 -1 1); do
	set_rx "$q" "reverse ramp $(( q + 1 )) → ${q}"
done

# ── Final state ───────────────────────────────────────────────────────────────
echo "=============================================="
echo "  DONE — Final Queue Configuration"
echo "=============================================="
ethtool -l "$IFACE"

