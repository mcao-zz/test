# Source from other scripts:  . "$(dirname "$0")/env.sh"
# Override on command line:  IFACE=env9 PEER=192.168.100.2 ./smoke.sh

# sudo's secure_path often omits /usr/local/bin (where iperf3 commonly lives).
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

: "${IFACE:=env9}"
: "${PEER:=}"                          # required for ping/iperf tests
: "${DUT_IP:=}"                        # this LPAR's test IP (optional)
: "${IPERF3:=}"                        # optional absolute path to iperf3
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
	[[ -n "$PEER" ]] || die "set PEER= on the sudo line (sudo clears exports), e.g. sudo IFACE=env9 PEER=192.168.100.2 $0"
	PEER="${PEER%%/*}"
}

# Resolve iperf3 into IPERF3 (handles sudo secure_path).
# Returns 0 if found. Override with IPERF3=/full/path/iperf3.
find_iperf3() {
	local c
	if [[ -n "${IPERF3:-}" ]]; then
		[[ -x "$IPERF3" ]] || die "IPERF3=$IPERF3 is not executable"
		return 0
	fi
	IPERF3=$(command -v iperf3 2>/dev/null || true)
	if [[ -n "$IPERF3" && -x "$IPERF3" ]]; then
		return 0
	fi
	for c in /usr/local/bin/iperf3 /usr/bin/iperf3 /bin/iperf3; do
		if [[ -x "$c" ]]; then
			IPERF3=$c
			return 0
		fi
	done
	IPERF3=
	return 1
}

need_iperf3() {
	find_iperf3 || die "iperf3 not found (install it, or set IPERF3=/path/to/iperf3). PATH=$PATH"
	ok "using iperf3 at $IPERF3"
}

have_iperf3() {
	find_iperf3
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
# Space-separated PIDs of iperf3 -s we started (do not killall — may kill user clients).
: "${IPERF_SERVER_PIDS:=}"

sum_rx_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx[0-9]+_packets:/ { s += $2 }
		END { print s+0 }
	'
}

# Read a line from the controlling terminal (works under sudo).
tty_read() {
	local prompt=$1
	local __var=$2
	local line
	if [[ ! -r /dev/tty ]]; then
		die "no /dev/tty — run from an interactive shell (or NONINTERACTIVE=1)"
	fi
	# Print prompt to stderr so it shows even if stdout is redirected
	printf '%s' "$prompt" >/dev/tty
	IFS= read -r line </dev/tty || die "failed reading from /dev/tty"
	printf '\n' >/dev/tty
	printf -v "$__var" '%s' "$line"
}

# Start iperf3 -s on DUT (RX sink). Tracks only PIDs we spawn.
start_iperf_servers() {
	local p n=0 pid
	need_iperf3
	for p in $IPERF_PORTS; do
		if ss -ltn 2>/dev/null | grep -q ":${p} "; then
			log "iperf3 already listening on :$p"
		else
			"$IPERF3" -s -p "$p" -D || die "failed to start $IPERF3 -s -p $p"
			n=$((n + 1))
			# Best-effort PID capture for later cleanup
			pid=$(ss -ltnp 2>/dev/null | awk -v p=":$p" '
				$0 ~ p {
					if (match($0, /pid=[0-9]+/)) {
						print substr($0, RSTART+4, RLENGTH-4)
						exit
					}
				}')
			[[ -n "$pid" ]] && IPERF_SERVER_PIDS+=" $pid"
		fi
	done
	sleep 1
	n=$(ss -ltnp 2>/dev/null | grep -c iperf3 || echo 0)
	[[ "$n" -ge 1 ]] || die "no iperf3 listeners after start"
	ok "iperf3 servers: $n listener(s) on DUT ($IPERF3)"
	ss -ltnp 2>/dev/null | grep iperf3 | head -5 | while read -r line; do log "  $line"; done
}

stop_iperf_servers() {
	local pid
	if [[ -z "${IPERF_SERVER_PIDS:-}" ]]; then
		return 0
	fi
	log "stopping iperf3 servers we started:$IPERF_SERVER_PIDS"
	for pid in $IPERF_SERVER_PIDS; do
		kill "$pid" 2>/dev/null || true
	done
	IPERF_SERVER_PIDS=
	sleep 1
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

# Interactive: print lp7 commands, wait for "yes", verify inbound RX.
# NONINTERACTIVE=1 skips prompts (still requires traffic already running).
prompt_start_inbound_iperf() {
	local dut_ip tries=0 ans=

	dut_ip=${DUT_IP:-}
	if [[ -z "$dut_ip" ]]; then
		dut_ip=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null \
			| awk '{print $4}' | cut -d/ -f1 | head -1)
	fi
	[[ -n "$dut_ip" ]] || die "set DUT_IP= (this LPAR address on $IFACE)"

	start_iperf_servers

	# Force visibility even if someone scrolls past quiet-phase noise
	cat >/dev/tty <<EOF

**********************************************************************
*  STOP — start inbound iperf on lp7 ($PEER) before heavy tests     *
**********************************************************************
On PEER ($PEER), run:

  export DUT_IP=$dut_ip
  for p in $IPERF_PORTS; do
    iperf3 -c \$DUT_IP -t 600 -P 4 -p \$p &
  done

DUT is listening as $dut_ip on ports: $IPERF_PORTS
**********************************************************************

EOF

	if [[ "${NONINTERACTIVE:-0}" = 1 ]]; then
		log "NONINTERACTIVE=1 — checking for existing inbound RX (no prompt)"
	else
		while true; do
			tty_read "Type 'yes' when lp7 iperf clients are running: " ans
			case "$ans" in
				yes|YES|y|Y) break ;;
				*) printf 'Please type yes (or Ctrl-C to abort).\n' >/dev/tty ;;
			esac
		done
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
		tty_read "[R]etry check, [A]bort heavy phase, [C]ontinue anyway? " ans
		case "${ans:-R}" in
			A|a) die "aborted: inbound iperf not confirmed" ;;
			C|c) log "WARN: continuing without confirmed inbound RX"; return 0 ;;
			*) ;;
		esac
	done
}
