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

: "${IPERF_PORTS:=5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5211 5212 5213 5214 5215 5216}"
: "${IPERF_STARTED_BY_US:=0}"

sum_rx_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx[0-9]+_packets:/ { s += $2 }
		END { print s+0 }
	'
}

# Start iperf3 -s on DUT (RX sink). Records IPERF_STARTED_BY_US=1.
start_iperf_servers() {
	local p n=0
	command -v iperf3 >/dev/null || die "iperf3 not installed on DUT"
	for p in $IPERF_PORTS; do
		if ss -ltn 2>/dev/null | grep -q ":${p} "; then
			log "iperf3 already listening on :$p"
		else
			iperf3 -s -p "$p" -D || die "failed to start iperf3 -s -p $p"
			n=$((n + 1))
		fi
	done
	IPERF_STARTED_BY_US=1
	sleep 1
	n=$(ss -ltnp 2>/dev/null | grep -c iperf3 || echo 0)
	[[ "$n" -ge 1 ]] || die "no iperf3 listeners after start"
	ok "iperf3 servers: $n listener(s) on DUT"
	ss -ltnp 2>/dev/null | grep iperf3 | head -5 | while read -r line; do log "  $line"; done
}

stop_iperf_servers() {
	if [[ "${IPERF_STARTED_BY_US:-0}" = 1 ]]; then
		log "stopping iperf3 processes started for this run"
		killall iperf3 2>/dev/null || true
		sleep 1
	fi
}

# Return 0 if RX packet counters advance within ~wait seconds
inbound_rx_flowing() {
	local wait=${1:-5}
	local a b
	a=$(sum_rx_packets)
	sleep "$wait"
	b=$(sum_rx_packets)
	log "RX packets: $a → $b (Δ=$((b - a)) over ${wait}s)"
	[[ "$b" -gt "$a" ]]
}

# Interactive: print lp7 commands, wait for Enter, verify inbound RX.
# NONINTERACTIVE=1 skips prompts (still requires traffic already running).
prompt_start_inbound_iperf() {
	local dut_ip tries=0

	dut_ip=${DUT_IP:-}
	if [[ -z "$dut_ip" ]]; then
		dut_ip=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null \
			| awk '{print $4}' | cut -d/ -f1 | head -1)
	fi
	[[ -n "$dut_ip" ]] || die "set DUT_IP= (this LPAR address on $IFACE)"

	start_iperf_servers

	cat <<EOF

========== HEAVY PHASE: inbound iperf (lp7 → DUT) ==========
On PEER ($PEER), run:

  export DUT_IP=$dut_ip
  for p in $IPERF_PORTS; do
    iperf3 -c \$DUT_IP -t 600 -P 4 -p \$p &
  done

Then return here.
============================================================

EOF

	if [[ "${NONINTERACTIVE:-0}" = 1 ]]; then
		log "NONINTERACTIVE=1 — checking for existing inbound RX (no prompt)"
	else
		read -r -p "Press Enter when iperf clients are running on $PEER... "
	fi

	while true; do
		if inbound_rx_flowing 4; then
			ok "inbound RX traffic detected on $IFACE"
			return 0
		fi
		tries=$((tries + 1))
		log "WARN: no RX packet increase (try $tries)"
		if [[ "${NONINTERACTIVE:-0}" = 1 ]]; then
			die "inbound RX not detected (start lp7 clients first, or unset NONINTERACTIVE)"
		fi
		read -r -p "[R]etry check, [A]bort heavy phase, [C]ontinue anyway? " ans
		case "${ans:-R}" in
			A|a) die "aborted: inbound iperf not confirmed" ;;
			C|c) log "WARN: continuing without confirmed inbound RX"; return 0 ;;
			*) ;;
		esac
	done
}
