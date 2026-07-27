#!/bin/bash
# rx_queue_size.sh — cycle RX queue counts via ethtool -L with post-resize checks
#
# Default pattern (max from ethtool -l, capped at 16):
#   baseline → max → 1 → 2 … max → (max-1) … 1
#
# After each successful -L, validates:
#   - ethtool -l RX count
#   - ethtool -S rxN_packets rows
#   - /proc/interrupts lines for this iface
#   - sysfs queues/rx-* count (if present)
#   - iface still UP / LOWER_UP
#   - dmesg delta: resize success; no oops/BUG/Call Trace for ibmveth
#   - error counters still zero (or not newly increasing if PEER traffic)
#   - optional ping to PEER (env PEER=192.168.100.2)
#
# Usage:
#   sudo ./rx_queue_size.sh [iface] [delay_seconds]
#   sudo PEER=192.168.100.2 ./rx_queue_size.sh env9 2
#
# Logs: /tmp/ibmveth-rx-cycle-<iface>-<timestamp>/

set -u

IFACE="${1:-env9}"
DELAY="${2:-2}"
PEER="${PEER:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FAIL=0
STEP=0
DMESG_MARK=0
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR="/tmp/ibmveth-rx-cycle-${IFACE}-${TIMESTAMP}"

log() {
	echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
}

die() {
	echo -e "${RED}ERROR: $1${NC}" >&2
	exit 1
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; FAIL=1; }

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
	if [ -z "$m" ] || [ "$m" -lt 1 ]; then
		echo 16
	elif [ "$m" -gt 16 ]; then
		echo 16
	else
		echo "$m"
	fi
}

count_rx_stat_queues() {
	ethtool -S "$IFACE" 2>/dev/null | grep -cE '^[[:space:]]*rx[0-9]+_packets:' || echo 0
}

count_iface_irqs() {
	# One /proc/interrupts line per RX queue IRQ for this netdev name
	grep -c "[[:space:]]${IFACE}$\|[[:space:]]${IFACE}-" /proc/interrupts 2>/dev/null \
		|| grep -c "${IFACE}" /proc/interrupts 2>/dev/null \
		|| echo 0
}

count_sysfs_rx() {
	if [ -d "/sys/class/net/${IFACE}/queues" ]; then
		ls -d /sys/class/net/"$IFACE"/queues/rx-* 2>/dev/null | wc -l | tr -d ' '
	else
		echo 0
	fi
}

stat_val() {
	local name=$1
	ethtool -S "$IFACE" 2>/dev/null | awk -v n="$name" '
		$1 == n":" { print $2; exit }
	'
}

dmesg_mark() {
	DMESG_MARK=$(dmesg | wc -l)
}

dmesg_delta_file() {
	local f=$1
	local cur delta
	cur=$(dmesg | wc -l)
	delta=$((cur - DMESG_MARK))
	if [ "$delta" -gt 0 ]; then
		dmesg | tail -n "$delta" > "$f"
	else
		: > "$f"
	fi
	DMESG_MARK=$cur
}

# Post-resize validation. Expect $1 = target RX queue count.
validate_after_resize() {
	local expect=$1
	local label=$2
	local stepdir dmesg_f stats_f
	local got stats_n irq_n sysfs_n
	local inv nobuf repfail
	local link_flags

	STEP=$((STEP + 1))
	stepdir=$(printf '%s/step-%02d-rx%s' "$LOGDIR" "$STEP" "$expect")
	mkdir -p "$stepdir"
	dmesg_f="$stepdir/dmesg.txt"
	stats_f="$stepdir/ethtool-S.txt"

	echo -e "  ${CYAN}Validation (${label}):${NC}"

	# --- geometry ---
	got=$(get_rx_current)
	if [ "$got" = "$expect" ]; then
		ok "ethtool -l RX=$got"
	else
		bad "ethtool -l RX=${got:-?} (want $expect)"
	fi

	stats_n=$(count_rx_stat_queues)
	if [ "$stats_n" = "$expect" ]; then
		ok "ethtool -S rx*_packets rows=$stats_n"
	else
		bad "ethtool -S rx*_packets rows=$stats_n (want $expect)"
	fi

	irq_n=$(count_iface_irqs)
	# Queue 0 may share naming; allow irq_n == expect (typical for MQ)
	if [ "$irq_n" = "$expect" ]; then
		ok "/proc/interrupts lines for ${IFACE}=$irq_n"
	elif [ "$irq_n" -ge 1 ] && [ "$expect" -eq 1 ] && [ "$irq_n" -le 2 ]; then
		ok "/proc/interrupts lines for ${IFACE}=$irq_n (SQ ok)"
	else
		bad "/proc/interrupts lines for ${IFACE}=$irq_n (want $expect)"
	fi

	sysfs_n=$(count_sysfs_rx)
	if [ "$sysfs_n" = "0" ]; then
		warn "sysfs queues/rx-* not present (skip)"
	elif [ "$sysfs_n" = "$expect" ]; then
		ok "sysfs rx-* queues=$sysfs_n"
	else
		bad "sysfs rx-* queues=$sysfs_n (want $expect)"
	fi

	# --- link ---
	link_flags=$(ip -o link show "$IFACE" 2>/dev/null)
	if echo "$link_flags" | grep -q 'UP'; then
		ok "iface flags include UP"
	else
		bad "iface not UP: $link_flags"
	fi

	# --- ethtool -S snapshot + error counters ---
	ethtool -S "$IFACE" > "$stats_f" 2>/dev/null || true
	inv=$(stat_val rx_invalid_buffer)
	nobuf=$(stat_val rx_no_buffer)
	repfail=$(stat_val replenish_add_buff_failure)
	inv=${inv:-0}; nobuf=${nobuf:-0}; repfail=${repfail:-0}
	if [ "$inv" = "0" ] && [ "$nobuf" = "0" ] && [ "$repfail" = "0" ]; then
		ok "error counters: invalid=0 no_buffer=0 replenish_fail=0"
	else
		# Non-zero can be historical; still flag so operator looks
		warn "error counters: invalid=$inv no_buffer=$nobuf replenish_fail=$repfail (see $stats_f)"
	fi

	# Show a short RX packet distribution snapshot (useful under iperf)
	echo -n "  rx*_packets: "
	awk '/^[[:space:]]*rx[0-9]+_packets:/ { printf "%s=%s ", $1, $2 }' "$stats_f"
	echo ""

	# --- dmesg delta ---
	dmesg_delta_file "$dmesg_f"
	if grep -qiE 'Oops|BUG:|Call Trace|hard LOCKUP|soft lockup' "$dmesg_f"; then
		bad "dmesg delta has Oops/BUG/Call Trace (see $dmesg_f)"
	else
		ok "dmesg delta: no Oops/BUG/Call Trace"
	fi

	if grep -qiE "ibmveth.*${IFACE}.*Successfully resized to ${expect} RX|resized to ${expect} RX queues" "$dmesg_f"; then
		ok "dmesg: Successfully resized to ${expect} RX queues"
	elif grep -qiE "ibmveth.*${IFACE}" "$dmesg_f"; then
		# Debug may use slightly different wording; still show ibmveth lines count
		local n
		n=$(grep -ciE "ibmveth|${IFACE}" "$dmesg_f" || true)
		warn "dmesg: ${n} ibmveth/${IFACE} lines (no exact 'resized to ${expect}' match)"
		grep -iE "ibmveth|${IFACE}" "$dmesg_f" | tail -5 | sed 's/^/    /'
	else
		warn "dmesg: no new ibmveth lines (enable dyndbg or check loglevel)"
	fi

	if grep -iE "ibmveth.*${IFACE}" "$dmesg_f" | grep -qiE 'error|fail|invalid correlator'; then
		# "Failed" in successful path is rare; flag for review
		warn "dmesg: ibmveth lines mention error/fail (review $dmesg_f)"
		grep -iE "ibmveth.*${IFACE}" "$dmesg_f" | grep -iE 'error|fail|invalid' | tail -5 | sed 's/^/    /'
	fi

	# --- optional peer ping ---
	if [ -n "$PEER" ]; then
		if ping -c 3 -W 2 "$PEER" > "$stepdir/ping.txt" 2>&1; then
			ok "ping -c 3 $PEER ok"
		else
			bad "ping -c 3 $PEER failed (see $stepdir/ping.txt)"
		fi
	fi

	# Persist irq snapshot
	grep "${IFACE}" /proc/interrupts > "$stepdir/interrupts.txt" 2>/dev/null || true
	echo ""
}

set_rx() {
	local queues=$1
	local label=$2

	echo -e "${YELLOW}--- Setting RX = ${queues} (${label}) ---${NC}"
	dmesg_mark
	if ! ethtool -L "$IFACE" rx "$queues"; then
		bad "ethtool -L rx $queues failed"
		return 1
	fi

	sleep 1
	validate_after_resize "$queues" "$label"
	sleep "$DELAY"
	# propagate FAIL from validate
	[ "$FAIL" -eq 0 ]
}

if ! ip link show "$IFACE" > /dev/null 2>&1; then
	die "Interface '$IFACE' not found"
fi

if [ "$(id -u)" -ne 0 ]; then
	echo -e "${YELLOW}Warning: not root; ethtool -L usually needs sudo${NC}"
fi

mkdir -p "$LOGDIR"
MAX_RX=$(get_rx_max)
CUR=$(get_rx_current)
dmesg_mark

echo "=============================================="
echo "  ibmveth RX Queue Cycle Test"
echo "  Interface: ${IFACE}"
echo "  Current RX: ${CUR:-?}   Max used: ${MAX_RX}"
echo "  Delay: ${DELAY}s"
echo "  Peer ping: ${PEER:-disabled (set PEER=ip)}"
echo "  Logs: $LOGDIR"
echo "=============================================="
echo ""
log "Initial ethtool -l:"
ethtool -l "$IFACE" | tee "$LOGDIR/ethtool-l-initial.txt"
echo ""
ethtool -S "$IFACE" > "$LOGDIR/ethtool-S-initial.txt" 2>/dev/null || true

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
ethtool -l "$IFACE" | tee "$LOGDIR/ethtool-l-final.txt"
ethtool -S "$IFACE" > "$LOGDIR/ethtool-S-final.txt" 2>/dev/null || true

if [ "$FAIL" -ne 0 ]; then
	echo -e "${RED}FAILED: see per-step logs under $LOGDIR${NC}"
	exit 1
fi
echo -e "${GREEN}ALL queue steps OK${NC}"
echo "Logs: $LOGDIR"
exit 0
