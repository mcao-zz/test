#!/bin/bash
# rx_queue_size.sh — cycle RX queue counts via ethtool -L with post-resize checks
#
# Default pattern (max from ethtool -l, capped at 16):
#   T14_CYCLE=full (default standalone): baseline → max → 1 → 2…max → (max-1)…1
#   T14_CYCLE=quick (run-all / t14 default): max → 1 → mid → max → 1
#     covers scale-down, scale-up, mid geometry without every integer step
#   Note: env.sh RX_CYCLE is a separate numeric list for ethtool-L-cycle.sh
#
# After each successful -L, validates:
#   - ethtool -l RX count
#   - ethtool -S rxN_packets rows
#   - /proc/interrupts lines for this iface
#   - sysfs queues/rx-* count (if present)
#   - iface still UP / LOWER_UP
#   - dmesg delta: resize success; no oops/BUG/Call Trace for ibmveth
#   - error counter *deltas* (invalid / no_buffer / replenish_fail) ≈ 0
#   - optional ping to PEER (env PEER=192.168.100.2)
#
# Under load (UNDER_RX=1 — keep lp7→DUT iperf running):
#   - bulk rx*_packets Δ >= MIN_RX_DELTA over RX_SAMPLE_SECS
#   - scale-down: surviving queues still receive; no error Δ spike
#   - scale-up: at least one *new* queue (qid >= previous RX) sees packets
#
# Usage:
#   sudo ./rx_queue_size.sh [iface] [delay_seconds]
#   sudo PEER=192.168.100.2 ./rx_queue_size.sh env9 2
#   sudo PEER=… UNDER_RX=1 MIN_RX_DELTA=10000 ./rx_queue_size.sh env9 2
#   sudo RX_CYCLE=quick UNDER_RX=1 ./rx_queue_size.sh env9 1   # compat alias
#   sudo T14_CYCLE=quick UNDER_RX=1 ./rx_queue_size.sh env9 1
#   sudo T14_CYCLE=full  …              # exhaustive (every integer)
#
# Logs: /tmp/ibmveth-rx-cycle-<iface>-<timestamp>/

set -u

IFACE="${1:-env9}"
DELAY="${2:-2}"
PEER="${PEER:-}"
UNDER_RX="${UNDER_RX:-0}"
# Prefer T14_CYCLE; accept RX_CYCLE=quick|full for compat (not the L-cycle number list).
T14_CYCLE="${T14_CYCLE:-}"
if [ -z "$T14_CYCLE" ]; then
	case "${RX_CYCLE:-}" in
		quick|full) T14_CYCLE=$RX_CYCLE ;;
		*) T14_CYCLE=full ;;
	esac
fi
RX_SAMPLE_SECS="${RX_SAMPLE_SECS:-5}"
MIN_RX_DELTA="${MIN_RX_DELTA:-10000}"
MIN_ACTIVE_RX_QUEUES="${MIN_ACTIVE_RX_QUEUES:-2}"
MIN_NEW_QUEUE_DELTA="${MIN_NEW_QUEUE_DELTA:-1}"
MAX_ERR_DELTA="${MAX_ERR_DELTA:-0}"
# Scale-up extra sample seconds (full cycle default 5; quick uses 2).
RX_SCALEUP_EXTRA="${RX_SCALEUP_EXTRA:-}"

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

# Pre-resize snapshots (set by set_rx)
PREV_RX=0
SNAP_INV=0
SNAP_NOBUF=0
SNAP_REPFAIL=0

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

# Print "qid count" lines
snapshot_rx_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx([0-9]+)_packets:/ {
			if (match($1, /[0-9]+/))
				print substr($1, RSTART, RLENGTH), $2 + 0
		}
	'
}

snap_errors() {
	SNAP_INV=$(stat_val rx_invalid_buffer)
	SNAP_NOBUF=$(stat_val rx_no_buffer)
	SNAP_REPFAIL=$(stat_val replenish_add_buff_failure)
	SNAP_INV=${SNAP_INV:-0}
	SNAP_NOBUF=${SNAP_NOBUF:-0}
	SNAP_REPFAIL=${SNAP_REPFAIL:-0}
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

# Compare error counters to pre-resize snapshot.
check_error_deltas() {
	local inv nobuf repfail d_inv d_nobuf d_rep
	inv=$(stat_val rx_invalid_buffer); inv=${inv:-0}
	nobuf=$(stat_val rx_no_buffer); nobuf=${nobuf:-0}
	repfail=$(stat_val replenish_add_buff_failure); repfail=${repfail:-0}
	d_inv=$((inv - SNAP_INV))
	d_nobuf=$((nobuf - SNAP_NOBUF))
	d_rep=$((repfail - SNAP_REPFAIL))

	if [ "$d_inv" -le "$MAX_ERR_DELTA" ] && \
	   [ "$d_nobuf" -le "$MAX_ERR_DELTA" ] && \
	   [ "$d_rep" -le "$MAX_ERR_DELTA" ]; then
		ok "error Δ: invalid=$d_inv no_buffer=$d_nobuf replenish_fail=$d_rep (max $MAX_ERR_DELTA)"
	else
		bad "error Δ spike: invalid=$d_inv no_buffer=$d_nobuf replenish_fail=$d_rep (abs now inv=$inv nobuf=$nobuf repfail=$repfail)"
	fi
}

# Sample RX under load: bulk + survivor/new-queue checks.
# Args: expect_rx prev_rx stepdir
check_rx_under_load() {
	local expect=$1
	local prev=$2
	local stepdir=$3
	local before_f after_f wait=$RX_SAMPLE_SECS
	local q c b d total=0 active=0 new_hit=0 need_active
	local min_q=$MIN_ACTIVE_RX_QUEUES

	# Scale-up: give the hypervisor hasher a longer window to hit new queues
	if [ "$expect" -gt "$prev" ]; then
		local extra=${RX_SCALEUP_EXTRA:-5}
		[ "$T14_CYCLE" = "quick" ] && extra=${RX_SCALEUP_EXTRA:-2}
		wait=$((RX_SAMPLE_SECS + extra))
	fi

	before_f="$stepdir/rx-before-sample.txt"
	after_f="$stepdir/rx-after-sample.txt"

	snapshot_rx_packets >"$before_f"
	sleep "$wait"
	snapshot_rx_packets >"$after_f"

	echo "  RX sample ${wait}s (UNDER_RX=1, need bulk Δ>=$MIN_RX_DELTA):"
	while read -r q c; do
		b=$(awk -v q="$q" '$1 == q { print $2; exit }' "$before_f")
		b=${b:-0}
		d=$((c - b))
		total=$((total + d))
		if [ "$d" -gt 0 ]; then
			active=$((active + 1))
			echo "    rx${q}_packets Δ=$d"
		fi
		# New queues are qid >= previous RX count
		if [ "$expect" -gt "$prev" ] && [ "$q" -ge "$prev" ] && [ "$d" -ge "$MIN_NEW_QUEUE_DELTA" ]; then
			new_hit=$((new_hit + 1))
		fi
	done <"$after_f"

	echo "    total Δ=$total active_queues=$active new_queue_hits=$new_hit (prev_rx=$prev → $expect)"

	if [ "$total" -ge "$MIN_RX_DELTA" ]; then
		ok "bulk RX after resize (Δ=$total >= $MIN_RX_DELTA)"
	else
		bad "bulk RX missing after resize (Δ=$total < $MIN_RX_DELTA) — keep lp7 iperf running"
	fi

	# Scale-down / steady MQ: survivors should spread when expect >= 4
	if [ "$expect" -ge 4 ]; then
		need_active=$min_q
		if [ "$need_active" -gt "$expect" ]; then
			need_active=$expect
		fi
		if [ "$active" -ge "$need_active" ]; then
			ok "survivor/MQ spread: $active active queues (need >=$need_active)"
		else
			bad "survivor/MQ spread weak: only $active active queues (need >=$need_active)"
		fi
	elif [ "$expect" -ge 1 ] && [ "$total" -ge "$MIN_RX_DELTA" ]; then
		ok "SQ/low-RX: traffic on remaining queue(s) (active=$active)"
	fi

	# Scale-up: at least one newly added queue must see packets
	if [ "$expect" -gt "$prev" ] && [ "$expect" -ge 2 ]; then
		if [ "$new_hit" -ge 1 ]; then
			ok "scale-up: $new_hit new queue(s) (qid>=$prev) got traffic"
		else
			bad "scale-up: no new queue (qid>=$prev) got packets — multi-flow iperf required"
		fi
	fi
}

# Post-resize validation. Expect $1 = target RX queue count. $2 = label. $3 = previous RX.
validate_after_resize() {
	local expect=$1
	local label=$2
	local prev=${3:-0}
	local stepdir dmesg_f stats_f
	local got stats_n irq_n sysfs_n
	local link_flags

	STEP=$((STEP + 1))
	stepdir=$(printf '%s/step-%02d-rx%s' "$LOGDIR" "$STEP" "$expect")
	mkdir -p "$stepdir"
	dmesg_f="$stepdir/dmesg.txt"
	stats_f="$stepdir/ethtool-S.txt"

	echo -e "  ${CYAN}Validation (${label}) prev_rx=${prev} → ${expect}:${NC}"

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

	# --- ethtool -S snapshot + error *deltas* ---
	ethtool -S "$IFACE" > "$stats_f" 2>/dev/null || true
	check_error_deltas

	echo -n "  rx*_packets (abs): "
	awk '/^[[:space:]]*rx[0-9]+_packets:/ { printf "%s=%s ", $1, $2 }' "$stats_f"
	echo ""

	# --- under-load packet proof ---
	if [ "$UNDER_RX" = "1" ]; then
		check_rx_under_load "$expect" "$prev" "$stepdir"
		# Re-check errors after the sample window (drops during traffic)
		check_error_deltas
	fi

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
		local n
		n=$(grep -ciE "ibmveth|${IFACE}" "$dmesg_f" || true)
		warn "dmesg: ${n} ibmveth/${IFACE} lines (no exact 'resized to ${expect}' match)"
		grep -iE "ibmveth|${IFACE}" "$dmesg_f" | tail -5 | sed 's/^/    /'
	else
		warn "dmesg: no new ibmveth lines (enable dyndbg or check loglevel)"
	fi

	if grep -iE "ibmveth.*${IFACE}" "$dmesg_f" | grep -qiE 'error|fail|invalid correlator'; then
		warn "dmesg: ibmveth lines mention error/fail (review $dmesg_f)"
		grep -iE "ibmveth.*${IFACE}" "$dmesg_f" | grep -iE 'error|fail|invalid' | tail -5 | sed 's/^/    /'
	fi

	# --- optional peer ping ---
	if [ -n "$PEER" ]; then
		local ping_n=3
		[ "$T14_CYCLE" = "quick" ] && ping_n=1
		if ping -c "$ping_n" -W 2 "$PEER" > "$stepdir/ping.txt" 2>&1; then
			ok "ping -c $ping_n $PEER ok"
		else
			bad "ping -c $ping_n $PEER failed (see $stepdir/ping.txt)"
		fi
	fi

	grep "${IFACE}" /proc/interrupts > "$stepdir/interrupts.txt" 2>/dev/null || true
	echo ""
}

set_rx() {
	local queues=$1
	local label=$2
	local prev

	prev=$(get_rx_current)
	prev=${prev:-0}
	PREV_RX=$prev

	echo -e "${YELLOW}--- Setting RX = ${queues} (${label}) [from ${prev}] ---${NC}"
	snap_errors
	dmesg_mark
	if ! ethtool -L "$IFACE" rx "$queues"; then
		bad "ethtool -L rx $queues failed"
		return 1
	fi

	sleep 1
	validate_after_resize "$queues" "$label" "$prev"
	sleep "$DELAY"
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
snap_errors

# Mid point for quick cycle (prefer 4 when max>=4 so MQ spread still applies).
MID_RX=$((MAX_RX / 2))
[ "$MID_RX" -lt 1 ] && MID_RX=1
if [ "$MAX_RX" -ge 4 ] && [ "$MID_RX" -lt 4 ]; then
	MID_RX=4
fi
[ "$MID_RX" -ge "$MAX_RX" ] && MID_RX=$((MAX_RX > 1 ? MAX_RX - 1 : 1))

echo "=============================================="
echo "  ibmveth RX Queue Cycle Test"
echo "  Interface: ${IFACE}"
echo "  Current RX: ${CUR:-?}   Max used: ${MAX_RX}"
echo "  T14_CYCLE: ${T14_CYCLE}   Delay: ${DELAY}s"
echo "  Peer ping: ${PEER:-disabled (set PEER=ip)}"
echo "  UNDER_RX: ${UNDER_RX}  (bulk Δ>=${MIN_RX_DELTA}/${RX_SAMPLE_SECS}s)"
echo "  Logs: $LOGDIR"
echo "=============================================="
echo ""
log "Initial ethtool -l:"
ethtool -l "$IFACE" | tee "$LOGDIR/ethtool-l-initial.txt"
echo ""
ethtool -S "$IFACE" > "$LOGDIR/ethtool-S-initial.txt" 2>/dev/null || true

if [ "$T14_CYCLE" = "quick" ]; then
	# Sparse: max → 1 → mid → max → 1  (~5 steps vs ~2*max)
	echo "========================================="
	echo "  QUICK: → RX ${MAX_RX}"
	echo "========================================="
	set_rx "$MAX_RX" "quick baseline max" || true

	if [ "$FAIL" -eq 0 ]; then
		echo "========================================="
		echo "  QUICK: ${MAX_RX} → 1"
		echo "========================================="
		set_rx 1 "quick scale down to 1" || true
	fi

	if [ "$FAIL" -eq 0 ] && [ "$MID_RX" -gt 1 ] && [ "$MID_RX" -lt "$MAX_RX" ]; then
		echo "========================================="
		echo "  QUICK: 1 → ${MID_RX}"
		echo "========================================="
		set_rx "$MID_RX" "quick scale up to mid" || true
	fi

	if [ "$FAIL" -eq 0 ] && [ "$MAX_RX" -gt 1 ]; then
		echo "========================================="
		echo "  QUICK: → RX ${MAX_RX}"
		echo "========================================="
		set_rx "$MAX_RX" "quick scale up to max" || true
	fi

	if [ "$FAIL" -eq 0 ]; then
		echo "========================================="
		echo "  QUICK: ${MAX_RX} → 1"
		echo "========================================="
		set_rx 1 "quick final scale down" || true
	fi
else
	# Full exhaustive cycle (every integer up and down).
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
