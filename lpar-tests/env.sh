# Source from other scripts:  . "$(dirname "$0")/env.sh"
# Override on command line:  IFACE=env9 PEER=192.168.100.2 ./smoke.sh

: "${IFACE:=env9}"
: "${PEER:=}"                          # required for ping/iperf tests
: "${DUT_IP:=}"                        # this LPAR's test IP (optional)
: "${IPERF_TIME:=60}"
: "${IPERF_PARALLEL:=4}"
: "${CYCLE_SLEEP:=0.5}"
: "${LOGDIR:=/tmp/ibmveth-mq-tests}"

# Typical MQ cycle pattern from cover letter (clamped later)
: "${RX_CYCLE:=16 1 8 11 1 3 16 8 1}"

# Repo root (parent of lpar-tests/) — lab monoliths live here
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

mkdir -p "$LOGDIR"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "FAIL: $*"; exit 1; }
ok()  { log "OK: $*"; }

need_root() {
	[[ $(id -u) -eq 0 ]] || die "run as root"
}

need_peer() {
	[[ -n "$PEER" ]] || die "set PEER= (ping/iperf peer IPv4, no CIDR)"
	PEER="${PEER%%/*}"
}

iface_up() {
	ip link set "$IFACE" up || die "ip link set $IFACE up"
	sleep 1
}

iface_down() {
	ip link set "$IFACE" down || die "ip link set $IFACE down"
}

ping_ok() {
	need_peer
	ping -c 3 -W 2 "$PEER" >/dev/null || die "ping $PEER failed"
	ok "ping $PEER"
}

ethtool_rx() {
	local n=$1
	ethtool -L "$IFACE" rx "$n"
}

current_rx() {
	ethtool -l "$IFACE" 2>/dev/null | awk '
		/^Current hardware settings:/ { cur=1; next }
		cur && /^[[:space:]]*RX:/ { print $2; exit }
	'
}

max_rx() {
	local m
	m=$(ethtool -l "$IFACE" 2>/dev/null | awk '
		/^Pre-set maximums:/ { p=1; next }
		/^Current hardware settings:/ { p=0 }
		p && /^[[:space:]]*RX:/ { print $2; exit }
	')
	[[ -n "$m" && "$m" -ge 1 ]] || m=8
	[[ "$m" -gt 16 ]] && m=16
	echo "$m"
}

count_rx_stat_rows() {
	ethtool -S "$IFACE" 2>/dev/null | grep -cE '^[[:space:]]*rx[0-9]+_packets:' || echo 0
}

count_iface_irqs() {
	grep -c "${IFACE}" /proc/interrupts 2>/dev/null || echo 0
}

stat_val() {
	local name=$1
	ethtool -S "$IFACE" 2>/dev/null | awk -v n="$name" '$1 == n":" { print $2; exit }'
}

# Fail unless published RX / -S rows / IRQ lines all match N
assert_rx_geometry() {
	local n=$1
	local got stats irqs
	got=$(current_rx)
	stats=$(count_rx_stat_rows)
	irqs=$(count_iface_irqs)
	[[ "$got" == "$n" ]] || die "ethtool -l RX=$got want $n"
	[[ "$stats" == "$n" ]] || die "ethtool -S rx*_packets rows=$stats want $n"
	[[ "$irqs" == "$n" ]] || die "/proc/interrupts $IFACE lines=$irqs want $n"
	ok "geometry RX=$n (ethtool -l / -S / irqs)"
}

clamp_rx_list() {
	local max n
	max=$(max_rx)
	for n in $RX_CYCLE; do
		[[ "$n" -gt "$max" ]] && n=$max
		[[ "$n" -lt 1 ]] && n=1
		echo "$n"
	done
}

save_dmesg_mark() {
	DMESG_MARK=$(dmesg | wc -l)
	echo "$DMESG_MARK" > "$LOGDIR/dmesg.mark"
}

dmesg_delta() {
	local out=${1:-$LOGDIR/dmesg-delta.txt}
	local cur mark delta
	mark=$(cat "$LOGDIR/dmesg.mark" 2>/dev/null || echo 0)
	cur=$(dmesg | wc -l)
	delta=$((cur - mark))
	if [[ "$delta" -gt 0 ]]; then
		dmesg | tail -n "$delta" > "$out"
	else
		: > "$out"
	fi
	echo "$cur" > "$LOGDIR/dmesg.mark"
}

check_no_lockup() {
	if dmesg | tail -200 | grep -Eiq 'soft lockup|hard LOCKUP|hung_task|Blocking RCU'; then
		dmesg_delta "$LOGDIR/dmesg-LOCKUP.txt"
		die "lockup / hung task seen in dmesg"
	fi
}

check_no_oops() {
	local f
	f=$(mktemp)
	dmesg_delta "$f"
	if grep -qiE 'Oops|BUG:|Call Trace' "$f"; then
		cp "$f" "$LOGDIR/dmesg-OOPS.txt"
		die "Oops/BUG/Call Trace in dmesg delta"
	fi
	rm -f "$f"
}
