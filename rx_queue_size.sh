#!/bin/bash
# rx_queue_size.sh — cycle RX queue counts via ethtool -L
#
# Default pattern (max from ethtool -l, capped at 16):
#   baseline → max → 1 → 2 … max → (max-1) … 1
#
# Usage: sudo ./rx_queue_size.sh [iface] [delay_seconds]
# Example: sudo ./rx_queue_size.sh env9 2

set -u

IFACE="${1:-env9}"
DELAY="${2:-2}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FAIL=0

log() {
	echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

die() {
	echo -e "${RED}ERROR: $1${NC}" >&2
	exit 1
}

get_rx_current() {
	ethtool -l "$IFACE" 2>/dev/null | awk '
		/^Current hardware settings:/ { cur=1; next }
		cur && /^[[:space:]]*RX:/ { print $2; exit }
	'
}

get_rx_max() {
	local m
	m=$(ethtool -l "$IFACE" 2>/dev/null | awk '
		/^Pre-set maximums:/ { max=1; next }
		/^Current hardware settings:/ { max=0 }
		max && /^[[:space:]]*RX:/ { print $2; exit }
	')
	# Cap at 16 (IBMVETH_MAX_RX_QUEUES); never exceed firmware/driver max
	if [ -z "$m" ] || [ "$m" -lt 1 ]; then
		echo 16
	elif [ "$m" -gt 16 ]; then
		echo 16
	else
		echo "$m"
	fi
}

set_rx() {
	local queues=$1
	local label=$2
	local got

	echo -e "${YELLOW}--- Setting RX = ${queues} (${label}) ---${NC}"
	if ! ethtool -L "$IFACE" rx "$queues"; then
		echo -e "${RED}✗ ethtool -L failed for RX=${queues}${NC}"
		FAIL=1
		return 1
	fi

	sleep 1
	got=$(get_rx_current)
	if [ "$got" != "$queues" ]; then
		echo -e "${RED}✗ Expected RX=${queues}, ethtool -l shows RX=${got:-?}${NC}"
		FAIL=1
		return 1
	fi

	echo -e "${GREEN}✓ RX set to ${queues}${NC}"
	echo -n "  Current: "
	ethtool -l "$IFACE" | grep -E "^[[:space:]]*RX:" | head -2
	echo ""
	sleep "$DELAY"
	return 0
}

if ! ip link show "$IFACE" > /dev/null 2>&1; then
	die "Interface '$IFACE' not found"
fi

if [ "$(id -u)" -ne 0 ]; then
	echo -e "${YELLOW}Warning: not root; ethtool -L usually needs sudo${NC}"
fi

MAX_RX=$(get_rx_max)
CUR=$(get_rx_current)

echo "=============================================="
echo "  ibmveth RX Queue Cycle Test"
echo "  Interface: ${IFACE}"
echo "  Current RX: ${CUR:-?}   Max used: ${MAX_RX}"
echo "  Delay: ${DELAY}s"
echo "=============================================="
echo ""
log "Initial ethtool -l:"
ethtool -l "$IFACE"
echo ""

echo "========================================="
echo "  PHASE 1: → RX ${MAX_RX}"
echo "========================================="
set_rx "$MAX_RX" "baseline" || true

echo "========================================="
echo "  PHASE 2: ${MAX_RX} → 1"
echo "========================================="
set_rx 1 "scale down to 1" || true

echo "========================================="
echo "  PHASE 3: Forward 2 → … → ${MAX_RX}"
echo "========================================="
for q in $(seq 2 "$MAX_RX"); do
	set_rx "$q" "forward $((q - 1)) → ${q}" || true
	[ "$FAIL" -ne 0 ] && break
done

if [ "$FAIL" -eq 0 ]; then
	echo "========================================="
	echo "  PHASE 4: Reverse $((MAX_RX - 1)) → … → 1"
	echo "========================================="
	for q in $(seq $((MAX_RX - 1)) -1 1); do
		set_rx "$q" "reverse $((q + 1)) → ${q}" || true
		[ "$FAIL" -ne 0 ] && break
	done
fi

echo "=============================================="
echo "  DONE — Final Queue Configuration"
echo "=============================================="
ethtool -l "$IFACE"

if [ "$FAIL" -ne 0 ]; then
	echo -e "${RED}FAILED: one or more queue-count changes did not stick${NC}"
	exit 1
fi
echo -e "${GREEN}ALL queue steps OK${NC}"
exit 0
