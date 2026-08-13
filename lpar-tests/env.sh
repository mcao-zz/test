# Source from other scripts:  . "$(dirname "$0")/env.sh"
# Override on command line:  IFACE=env9 PEER=192.168.1.153 ./smoke.sh
# Optional lab defaults: copy lab.conf.example → lab.conf (or LAB_CONF=path)

# sudo's secure_path often omits /usr/local/bin (where iperf3 commonly lives).
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

# Apply lab.conf only for variables not already set (sudo IFACE=… wins).
_load_lab_conf() {
	local f conf_dir line key val
	conf_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	f="${LAB_CONF:-$conf_dir/lab.conf}"
	[[ -f "$f" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line//[[:space:]]/}" ]] && continue
		if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
			key="${BASH_REMATCH[1]}"
			val="${BASH_REMATCH[2]}"
			val="${val#\"}"
			val="${val%\"}"
			val="${val#\'}"
			val="${val%\'}"
			# Skip if already set in the environment (including empty intentional?).
			if [[ -z "${!key+x}" ]]; then
				printf -v "$key" '%s' "$val"
				export "$key"
			fi
		fi
	done <"$f"
	# Visible once per shell that sources env.sh
	if [[ -z "${_LAB_CONF_LOADED:-}" ]]; then
		export _LAB_CONF_LOADED=1
		printf '[%s] lab.conf loaded: %s (CLI/sudo env overrides)\n' \
			"$(date '+%H:%M:%S')" "$f"
	fi
}
_load_lab_conf

: "${IFACE:=env9}"
: "${PEER:=}"                          # required for ping/iperf tests
: "${DUT_IP:=}"                        # this LPAR's test IP (optional)
: "${IPERF3:=}"                        # optional absolute path to iperf3
: "${IBMVETH_KO:=}"                    # optional path to ibmveth.ko (or its directory)
: "${EXTERNAL_IPERF:=0}"               # 1 = lab owns iperf; never start/stop/restart
: "${IPERF_TIME:=60}"
: "${IPERF_PARALLEL:=4}"
: "${IPERF_PORT_FIRST:=5201}"
: "${IPERF_PORT_LAST:=5216}"
: "${CYCLE_SLEEP:=0.5}"
: "${LOGDIR:=/tmp/ibmveth-mq-tests}"

# Typical MQ cycle pattern from cover letter (clamped later)
: "${RX_CYCLE:=16 1 8 11 1 3 16 8 1}"

# Repo root (parent of lpar-tests/) — lab monoliths live here
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

mkdir -p "$LOGDIR"

# Color when stdout is a TTY (NO_COLOR=1 disables).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	_C_RED=$'\033[1;31m'
	_C_YEL=$'\033[1;33m'
	_C_GRN=$'\033[1;32m'
	_C_BOLD=$'\033[1m'
	_C_RST=$'\033[0m'
else
	_C_RED=; _C_YEL=; _C_GRN=; _C_BOLD=; _C_RST=
fi

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] %sFAIL: %s%s\n' "$(date '+%H:%M:%S')" "$_C_RED" "$*" "$_C_RST" >&2; exit 1; }
ok()  { printf '[%s] %sOK: %s%s\n' "$(date '+%H:%M:%S')" "$_C_GRN" "$*" "$_C_RST"; }
warn() { printf '[%s] %sWARN: %s%s\n' "$(date '+%H:%M:%S')" "$_C_YEL" "$*" "$_C_RST"; }
alert() { printf '[%s] %s*** ALERT: %s ***%s\n' "$(date '+%H:%M:%S')" "$_C_RED" "$*" "$_C_RST"; }

need_root() {
	[[ $(id -u) -eq 0 ]] || die "run as root"
}

need_peer() {
	[[ -n "$PEER" ]] || die "set PEER= on the sudo line (sudo clears exports), e.g. sudo IFACE=env9 PEER=192.168.1.153 $0"
	PEER="${PEER%%/*}"
}

# PEER must answer on $IFACE (same L2 / on-link). Bare ping can PASS via
# another NIC (lab: PEER=10.48.36.153 while env9 is 192.168.1.x).
# Retries: under UNDER_RX a single ICMP is often lost even when L2 is fine
# (lab: assert_peer OK then rx_queue_size -c 1 died on the next probe).
peer_reachable_via_iface() {
	local tries=${1:-8}
	local i

	need_peer
	for i in $(seq 1 "$tries"); do
		if ping -I "$IFACE" -c 1 -W 1 "$PEER" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.25
	done
	return 1
}

assert_peer_on_iface() {
	local addr

	need_peer
	addr=$(save_iface_ipv4 2>/dev/null || true)
	if ! peer_reachable_via_iface 8; then
		die "PEER=$PEER not reachable via ping -I $IFACE (addr=${addr:-none}). Use a peer on the same L2 as $IFACE (lab env9: PEER=192.168.1.153), not a mgmt/other-NIC address"
	fi
	# Skip the duplicate probe inside rx_queue_size.sh when T14 already checked.
	export PEER_ON_IFACE_OK=1
	ok "PEER=$PEER on-link via -I $IFACE${addr:+ ($addr)}"
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

# Always bind to IFACE so a working net0/default route cannot fake env9 RX.
ping_ok() {
	need_peer
	ping -I "$IFACE" -c 3 -W 2 "$PEER" >/dev/null 2>&1 || \
		die "ping -I $IFACE $PEER failed (TX-only / wrong iface / RX dead)"
	ok "ping -I $IFACE $PEER"
}

# Sum of per-queue + legacy rx packets (works SQ and MQ).
sum_rx_packets() {
	local s
	s=$(ethtool -S "$IFACE" 2>/dev/null | awk '
		$1 ~ /^rx[0-9]*_packets:$/ { t += $2 }
		$1 == "rx_packets:" { t += $2 }
		END { print t+0 }
	')
	echo "${s:-0}"
}

# After ifdown/up: ping on IFACE must work AND RX counters must move.
# Catches false PASS where bare `ping $PEER` uses another iface while
# $IFACE RX is wedged. Optional $2 = CIDR to restore (or set RESTORE_IP=).
assert_rx_alive_after_up() {
	local label=${1:-after-up}
	local cidr=${2:-${RESTORE_IP:-}}
	local before after

	need_peer
	iface_up
	[[ -n "$cidr" ]] && restore_iface_ipv4 "$cidr"
	sleep 1

	assert_buffer_pools_up "$label"

	before=$(sum_rx_packets)
	if ! ping -I "$IFACE" -c 5 -W 2 "$PEER" >/dev/null 2>&1; then
		die "$label: ping -I $IFACE $PEER failed"
	fi
	after=$(sum_rx_packets)
	if [[ "$after" -le "$before" ]]; then
		die "$label: RX packets flat ($before → $after) after ping -I $IFACE — RX wedge / wrong .ko?"
	fi
	ok "$label: ping -I $IFACE OK and RX $before → $after"
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
	local n
	n=$(ethtool -S "$IFACE" 2>/dev/null | grep -cE '^[[:space:]]*rx[0-9]+_packets:') || true
	echo "${n:-0}"
}

count_tx_stat_rows() {
	local n
	n=$(ethtool -S "$IFACE" 2>/dev/null | grep -cE '^[[:space:]]*tx[0-9]+_packets:') || true
	echo "${n:-0}"
}

count_iface_irqs() {
	# grep -c exits 1 when count is 0 — must not also echo 0 (would print "0\n0").
	local n
	n=$(grep -c "${IFACE}" /proc/interrupts 2>/dev/null) || true
	echo "${n:-0}"
}

stat_val() {
	local name=$1
	ethtool -S "$IFACE" 2>/dev/null | awk -v n="$name" '$1 == n":" { print $2; exit }'
}

current_tx() {
	ethtool -l "$IFACE" 2>/dev/null | awk '
		/^Current hardware settings:/ { cur=1; next }
		cur && /^[[:space:]]*TX:/ { print $2; exit }
	'
}

# Parse active RSS hash function from `ethtool -x` (P15 aliases: crc32|xor).
# Prints one of: crc32, xor, toeplitz, or empty if unparseable.
current_rss_hfunc() {
	ethtool -x "$IFACE" 2>/dev/null | awk '
		BEGIN { IGNORECASE = 1 }
		/RSS hash function:/ { inhf = 1; next }
		inhf && /^[[:space:]]*$/ { exit }
		inhf && /:/ {
			name = $1
			sub(/:$/, "", name)
			on = 0
			if ($0 ~ /\yon\y/) on = 1
			if ($NF == "on" || $NF == "1") on = 1
			if (on) { print name; exit }
		}
	'
}

# Decode noisy `ethtool -x` into a short ibmveth-oriented summary.
# Ethtool always prints indir/key sections and the full toeplitz/xor/crc32
# menu; for ibmveth those "Operation not supported" / toeplitz:off lines are
# expected (PHYP-managed key/indir; only crc32|xor aliases are used).
explain_rss_rxfh() {
	local out=${1:-}
	local err=${2:-}
	local hfunc rings phyp

	if [[ -z "$out" ]]; then
		out=$(mktemp)
		err=$(mktemp)
		ethtool -x "$IFACE" >"$out" 2>"$err" || true
	fi

	hfunc=$(awk '
		BEGIN { IGNORECASE = 1 }
		/RSS hash function:/ { inhf = 1; next }
		inhf && /^[[:space:]]*$/ { exit }
		inhf && /:/ {
			name = $1
			sub(/:$/, "", name)
			if ($0 ~ /\yon\y/ || $NF == "on" || $NF == "1") {
				print name; exit
			}
		}
	' "$out")
	rings=$(awk '
		/[Ww]ith [0-9]+ RX ring/ {
			for (i = 1; i <= NF; i++)
				if ($(i) ~ /^[0-9]+$/ && $(i+1) ~ /^RX/) {
					print $i; exit
				}
		}
	' "$out")

	case "$hfunc" in
		crc32) phyp="Murmur (ethtool alias crc32)" ;;
		xor)   phyp="Additive (ethtool alias xor)" ;;
		*)     phyp="unknown/unset" ;;
	esac

	log "RSS decode ($IFACE):"
	log "  active hfunc: ${hfunc:-?} → PHYP $phyp"
	log "  RX rings reported: ${rings:-?}"
	log "  indir table / hash key: hypervisor-managed (ethtool prints"
	log "    'Operation not supported' — expected, not a failure)"
	log "  toeplitz listed off: ethtool's generic menu; ibmveth only"
	log "    uses crc32|xor aliases — ignore toeplitz"
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

# Assert ethtool -l TX matches N; optionally tx*_packets row count if present.
assert_tx_geometry() {
	local n=$1
	local got rows
	got=$(current_tx)
	[[ -n "$got" ]] || die "ethtool -l TX not parseable"
	[[ "$got" == "$n" ]] || die "ethtool -l TX=$got want $n"
	rows=$(count_tx_stat_rows)
	if [[ "${rows:-0}" -gt 0 ]]; then
		[[ "$rows" == "$n" ]] || die "ethtool -S tx*_packets rows=$rows want $n"
		ok "geometry TX=$n (ethtool -l / -S)"
	else
		ok "geometry TX=$n (ethtool -l; no tx*_packets rows)"
	fi
}

# Path to this iface's debugfs buffer_pools.
# v4/v5 (J11-3): /sys/kernel/debug/ibmveth/<vio-dev-name>/buffer_pools
# (stable vio name, not netdev->name — survives udev eth0→env9 rename).
# Older trees used /sys/kernel/debug/<netdev>/buffer_pools.
iface_buffer_pools() {
	local f base c vio
	local -a candidates=()

	# Preferred: map netdev → vio device name → nested ibmveth/ path.
	if [[ -e "/sys/class/net/${IFACE}/device" ]]; then
		vio=$(basename "$(readlink -f "/sys/class/net/${IFACE}/device")")
		f="/sys/kernel/debug/ibmveth/${vio}/buffer_pools"
		if [[ -r "$f" ]]; then
			echo "$f"
			return 0
		fi
	fi

	# Legacy flat path (pre-nest).
	f="/sys/kernel/debug/${IFACE}/buffer_pools"
	if [[ -r "$f" ]]; then
		echo "$f"
		return 0
	fi

	mapfile -t candidates < <(
		find /sys/kernel/debug -mindepth 2 -maxdepth 4 -type f -name buffer_pools 2>/dev/null
	)
	[[ ${#candidates[@]} -gt 0 ]] || return 1

	# Prefer nested ibmveth/<vio>/buffer_pools.
	for c in "${candidates[@]}"; do
		if [[ "$c" == */ibmveth/*/buffer_pools && -r "$c" ]]; then
			echo "$c"
			return 0
		fi
	done

	# Prefer a debugfs dir whose basename is not a live netdev (rename leftover).
	for c in "${candidates[@]}"; do
		base=$(basename "$(dirname "$c")")
		if [[ ! -e "/sys/class/net/$base" && -r "$c" ]]; then
			echo "$c"
			return 0
		fi
	done

	# Single candidate: use it (common single-MQ-adapter lab).
	if [[ ${#candidates[@]} -eq 1 && -r "${candidates[0]}" ]]; then
		echo "${candidates[0]}"
		return 0
	fi

	return 1
}

# Count distinct Queue IDs in buffer_pools (skip header/separator).
count_debugfs_queue_rows() {
	local f=${1:-}
	[[ -n "$f" && -r "$f" ]] || { echo 0; return; }
	awk '
		BEGIN { n = 0 }
		/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {
			q = $1
			if (!(q in seen)) { seen[q] = 1; n++ }
		}
		END { print n+0 }
	' "$f"
}

# When UP: live pools must have Size>0 and Active=1; at least one Active pool.
# Catches free_buffer_pool() clearing size/active (ifdown/up RX death).
assert_buffer_pools_up() {
	local label=${1:-up}
	local bp active_n bad
	bp=$(iface_buffer_pools) || die "$label: missing debugfs buffer_pools"
	if grep -q '^# down:' "$bp" 2>/dev/null; then
		die "$label: buffer_pools still shows # down: (iface not opened?)"
	fi
	# Cols: Queue Pool Size BuffSize Active Available
	bad=$(awk '
		/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {
			size = $3 + 0; active = $5 + 0
			if (active == 1 && size == 0) bad++
			if (active == 1) live++
			# Classic regression: pools 0/1/4 cleared to Size=0 Active=0
			# while inactive 2/3 keep Size=256. Flag Size=0 on small/jumbo
			# buff sizes that should stay configured.
			bs = $4 + 0
			if (size == 0 && (bs == 512 || bs == 2048 || bs == 65536))
				cleared++
		}
		END {
			if (live + 0 < 1) print "no-active-pools"
			else if (bad + 0 > 0) print "active-with-size-0"
			else if (cleared + 0 > 0) print "geometry-cleared-" cleared
			else print ""
		}
	' "$bp")
	if [[ -n "$bad" ]]; then
		head -12 "$bp" | tee "$LOGDIR/buffer_pools-fail-${label}.txt" >&2 || true
		die "$label: buffer_pools unhealthy ($bad) — see $LOGDIR/buffer_pools-fail-${label}.txt"
	fi
	active_n=$(awk '/^[[:space:]]*[0-9]+/ && $5+0==1 { c++ } END { print c+0 }' "$bp")
	ok "$label: buffer_pools live (Active=1 rows=$active_n) at $bp"
}

# When DOWN: Size must remain (probe/sysfs geometry); Active/Available show 0.
assert_buffer_pools_down() {
	local label=${1:-down}
	local bp bad
	bp=$(iface_buffer_pools) || die "$label: missing debugfs buffer_pools"
	bad=$(awk '
		/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {
			size = $3 + 0; bs = $4 + 0; active = $5 + 0
			if (active != 0) live++
			if (size == 0 && (bs == 512 || bs == 2048 || bs == 65536))
				cleared++
		}
		END {
			if (cleared + 0 > 0) print "geometry-cleared-" cleared
			else if (live + 0 > 0) print "still-active-" live
			else print ""
		}
	' "$bp")
	if [[ -n "$bad" ]]; then
		head -12 "$bp" | tee "$LOGDIR/buffer_pools-fail-${label}.txt" >&2 || true
		die "$label: buffer_pools bad while down ($bad)"
	fi
	ok "$label: buffer_pools geometry kept while down"
}

# When IBMVETH_KO is set, loaded module must match that .ko (modprobe often lies).
assert_ibmveth_ko_loaded() {
	local ko build loaded
	[[ -n "${IBMVETH_KO:-}" ]] || return 0
	ko=$(resolve_ibmveth_ko) || die "IBMVETH_KO set but not resolvable: $IBMVETH_KO"
	build=$(modinfo -F srcversion "$ko" 2>/dev/null || true)
	loaded=$(cat /sys/module/ibmveth/srcversion 2>/dev/null || true)
	[[ -n "$build" ]] || die "modinfo srcversion empty for $ko"
	[[ -n "$loaded" ]] || die "ibmveth not loaded (/sys/module/ibmveth/srcversion)"
	if [[ "$build" != "$loaded" ]]; then
		die "wrong ibmveth loaded: build=$build loaded=$loaded (use insmod $ko; modprobe may pick backup)"
	fi
	ok "ibmveth srcversion matches IBMVETH_KO ($loaded)"
}

# Bounded ping recovery after stress (default 30s). Uses -I IFACE.
ping_recover() {
	local secs=${1:-${PING_RECOVER_SECS:-30}}
	local i
	need_peer
	iface_up
	if [[ -n "${RESTORE_IP:-}" ]]; then
		restore_iface_ipv4 "$RESTORE_IP"
	fi
	for ((i = 1; i <= secs; i++)); do
		if ping -I "$IFACE" -c 1 -W 1 "$PEER" >/dev/null 2>&1; then
			ok "ping -I $IFACE $PEER recovered in ${i}s"
			# One reply is not enough — prove RX counters move.
			assert_rx_alive_after_up "ping_recover"
			return 0
		fi
		sleep 1
	done
	die "ping -I $IFACE $PEER did not recover within ${secs}s"
}

# Snapshot / compare core error counters (absolute Δ since snap).
: "${SNAP_INV:=0}"
: "${SNAP_NOBUF:=0}"
: "${SNAP_REPFAIL:=0}"
: "${MAX_ERR_DELTA:=0}"

snap_core_errors() {
	SNAP_INV=$(stat_val rx_invalid_buffer); SNAP_INV=${SNAP_INV:-0}
	SNAP_NOBUF=$(stat_val rx_no_buffer); SNAP_NOBUF=${SNAP_NOBUF:-0}
	SNAP_REPFAIL=$(stat_val replenish_add_buff_failure); SNAP_REPFAIL=${SNAP_REPFAIL:-0}
}

check_core_error_deltas() {
	local label=${1:-errors}
	local inv nobuf repfail d_inv d_nobuf d_rep
	inv=$(stat_val rx_invalid_buffer); inv=${inv:-0}
	nobuf=$(stat_val rx_no_buffer); nobuf=${nobuf:-0}
	repfail=$(stat_val replenish_add_buff_failure); repfail=${repfail:-0}
	d_inv=$((inv - SNAP_INV))
	d_nobuf=$((nobuf - SNAP_NOBUF))
	d_rep=$((repfail - SNAP_REPFAIL))
	log "$label: error Δ invalid=$d_inv no_buffer=$d_nobuf replenish_fail=$d_rep"
	[[ "$d_inv" -le "$MAX_ERR_DELTA" ]] || die "$label: rx_invalid_buffer Δ=$d_inv > $MAX_ERR_DELTA"
	[[ "$d_nobuf" -le "$MAX_ERR_DELTA" ]] || die "$label: rx_no_buffer Δ=$d_nobuf > $MAX_ERR_DELTA"
	[[ "$d_rep" -le "$MAX_ERR_DELTA" ]] || die "$label: replenish_add_buff_failure Δ=$d_rep > $MAX_ERR_DELTA"
	ok "$label: error deltas within $MAX_ERR_DELTA"
}

# Save/restore IPv4 on IFACE (module reload recreates netdev).
save_iface_ipv4() {
	ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1
}

# Resolve IBMVETH_KO to an absolute .ko path (file, or dir containing ibmveth.ko).
resolve_ibmveth_ko() {
	local p
	# shellcheck source=../ibmveth-ko-load.sh
	. "$ROOT/ibmveth-ko-load.sh"
	p=$(ibmveth_resolve_ko) || return 1
	printf '%s\n' "$p"
}

# Load ibmveth: IBMVETH_KO=... uses insmod; otherwise modprobe.
# Optional arg: dyndbg param string (e.g. +p). Empty = no dyndbg.
load_ibmveth() {
	local dyndbg=${1:-}

	# shellcheck source=../ibmveth-ko-load.sh
	. "$ROOT/ibmveth-ko-load.sh"
	ibmveth_module_load "$dyndbg" || die "ibmveth module load failed (IBMVETH_KO=${IBMVETH_KO:-modprobe})"
}

# Reload ibmveth with dyndbg=+p; save/restore IPv4 on $IFACE.
# Sets IBMVETH_DYNDBG=1 on success.
# Override module: IBMVETH_KO=/path/to/ibmveth.ko (or directory containing it).
ensure_ibmveth_dyndbg() {
	local saved_ip

	need_root
	log "=== ensure ibmveth dyndbg=+p (IFACE=$IFACE IBMVETH_KO=${IBMVETH_KO:-modprobe}) ==="
	saved_ip=$(save_iface_ipv4)
	log "saved IPv4: ${saved_ip:-none}"

	iface_up 2>/dev/null || true
	iface_down 2>/dev/null || true
	sleep 1
	rmmod ibmveth 2>/dev/null || log "WARN: rmmod ibmveth (may already be unloaded)"
	sleep 2
	load_ibmveth "+p"
	sleep 3

	ip link show "$IFACE" >/dev/null || die "netdev $IFACE missing after dyndbg reload"
	assert_ibmveth_ko_loaded
	iface_up
	restore_iface_ipv4 "$saved_ip"
	sleep 2
	IBMVETH_DYNDBG=1
	export IBMVETH_DYNDBG
	ok "ibmveth loaded with dyndbg=+p${IBMVETH_KO:+ (IBMVETH_KO)}"
	if [[ -n "${PEER:-}" ]]; then
		RESTORE_IP=$saved_ip assert_rx_alive_after_up "dyndbg-load" "$saved_ip"
	fi
}

restore_iface_ipv4() {
	local cidr=$1
	[[ -n "$cidr" ]] || return 0
	if ! ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q "$cidr"; then
		ip addr add "$cidr" dev "$IFACE" 2>/dev/null || \
			log "WARN: could not restore $cidr on $IFACE (configure manually if ping fails)"
	fi
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
	# Include WARNING: WARN_ON stacks often have Call Trace, but match
	# ibmveth WARN explicitly (scale-down IRQ race @ ibmveth_interrupt).
	if grep -qiE 'Oops|BUG:|WARNING:|hard LOCKUP|soft lockup' "$f" ||
	   grep -qiE 'ibmveth_interrupt|WARN_ON' "$f"; then
		cp "$f" "$LOGDIR/dmesg-OOPS.txt"
		die "Oops/BUG/WARNING/ibmveth WARN in dmesg delta (see $LOGDIR/dmesg-OOPS.txt)"
	fi
	rm -f "$f"
}

# Optional driver-update health (CHECK_HEALTH=1 by default in run-all).
# After each test + suite-end summary: MemAvailable/Slab Δ, dmesg kmemleak/WARN,
# softnet drops, IRQ vs RX geometry. HEALTH_FAIL=1 makes growth/WARN fatal.
# CHECK_MEM=1 is an alias for CHECK_HEALTH=1; CHECK_HEALTH=0 disables.
: "${CHECK_HEALTH:=1}"
: "${CHECK_MEM:=0}"
: "${MEM_GROW_MB:=64}"            # MemAvailable drop / Slab rise warn threshold (MB)
: "${HEALTH_FAIL:=0}"
: "${MEM_FAIL:=0}"                # alias → HEALTH_FAIL
: "${HEALTH_ERR_DELTA:=100}"      # soft ALERT if adapter error counters grow this much per test
: "${HEALTH_LOAD_MULT:=4}"        # soft ALERT if loadavg1 > nproc * this
: "${HEALTH_STEAL_PCT:=25}"       # soft ALERT if %steal over end-of-suite 1s sample
: "${HEALTH_CPU:=0}"              # 1 = also 1s CPU sample after each test (slower)
HEALTH_LOG="${HEALTH_LOG:-$LOGDIR/health-check.log}"
_MEM_PREV_AVAIL=
_MEM_PREV_SLAB=
_MEM_BASE_AVAIL=
_MEM_BASE_SLAB=
_SOFTNET_BASE=
_HEALTH_IRQ_BASE=
_HEALTH_ALERTS=0
_HEALTH_ALERT_MSGS=()
_HEALTH_ERR_INV=
_HEALTH_ERR_NOBUF=
_HEALTH_ERR_REP=
_HEALTH_HCALL_REG=
_HEALTH_HCALL_FREE=

_health_note_alert() {
	_HEALTH_ALERTS=$((_HEALTH_ALERTS + 1))
	_HEALTH_ALERT_MSGS+=("$1")
	alert "$1"
}

_nproc() {
	nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
}

_loadavg1() {
	awk '{ print $1 }' /proc/loadavg 2>/dev/null || echo 0
}

# Print "user nice system idle iowait irq softirq steal" jiffies from /proc/stat cpu line.
_cpu_jiffies() {
	awk '/^cpu / {
		print $2+0, $3+0, $4+0, $5+0, $6+0, $7+0, $8+0, $9+0
		exit
	}' /proc/stat 2>/dev/null || echo "0 0 0 0 0 0 0 0"
}

# 1s sample → sets _CPU_IDLE_PCT _CPU_STEAL_PCT _CPU_SOFTIRQ_PCT (integers).
_cpu_sample_1s() {
	local a b
	local au an as ai aw aq asf ast
	local bu bn bs bi bw bq bsf bst
	local du dn ds di dw dq dsf dst tot

	a=$(_cpu_jiffies)
	sleep 1
	b=$(_cpu_jiffies)
	read -r au an as ai aw aq asf ast <<<"$a"
	read -r bu bn bs bi bw bq bsf bst <<<"$b"
	du=$((bu - au)); dn=$((bn - an)); ds=$((bs - as)); di=$((bi - ai))
	dw=$((bw - aw)); dq=$((bq - aq)); dsf=$((bsf - asf)); dst=$((bst - ast))
	tot=$((du + dn + ds + di + dw + dq + dsf + dst))
	[[ "$tot" -gt 0 ]] || tot=1
	_CPU_IDLE_PCT=$((di * 100 / tot))
	_CPU_STEAL_PCT=$((dst * 100 / tot))
	_CPU_SOFTIRQ_PCT=$((dsf * 100 / tot))
}

_health_snap_adapter_stats() {
	_HEALTH_ERR_INV=$(stat_val rx_invalid_buffer); _HEALTH_ERR_INV=${_HEALTH_ERR_INV:-0}
	_HEALTH_ERR_NOBUF=$(stat_val rx_no_buffer); _HEALTH_ERR_NOBUF=${_HEALTH_ERR_NOBUF:-0}
	_HEALTH_ERR_REP=$(stat_val replenish_add_buff_failure); _HEALTH_ERR_REP=${_HEALTH_ERR_REP:-0}
	_HEALTH_HCALL_REG=$(stat_val hcall_reg_lan_queue); _HEALTH_HCALL_REG=${_HEALTH_HCALL_REG:-0}
	_HEALTH_HCALL_FREE=$(stat_val hcall_free_lan_queue); _HEALTH_HCALL_FREE=${_HEALTH_HCALL_FREE:-0}
}

_health_enabled() {
	[[ "${CHECK_HEALTH:-0}" = 1 || "${CHECK_MEM:-0}" = 1 ]]
}

_health_fail_mode() {
	[[ "${HEALTH_FAIL:-0}" = 1 || "${MEM_FAIL:-0}" = 1 ]]
}

_mem_read_kb() {
	awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo
}

_mem_slab_approx_kb() {
	[[ -r /proc/slabinfo ]] || { echo 0; return 0; }
	awk '
		/^#/ { next }
		$1 ~ /^(kmalloc|dma-kmalloc)/ {
			sum += $3 * $4
		}
		END { printf "%d\n", sum / 1024 }
	' /proc/slabinfo 2>/dev/null || echo 0
}

_softnet_totals() {
	# sum dropped + time_squeeze across CPUs (hex cols 2 and 3)
	[[ -r /proc/net/softnet_stat ]] || { echo "0 0"; return 0; }
	awk '{
		d += ("0x"$2)+0
		t += ("0x"$3)+0
	}
	END { print d+0, t+0 }' /proc/net/softnet_stat 2>/dev/null || echo "0 0"
}

mem_snapshot() {
	local label=$1
	local avail slab sunr kmal soft
	avail=$(_mem_read_kb MemAvailable)
	slab=$(_mem_read_kb Slab)
	sunr=$(_mem_read_kb SUnreclaim)
	kmal=$(_mem_slab_approx_kb)
	soft=$(_softnet_totals)
	avail=${avail:-0}; slab=${slab:-0}; sunr=${sunr:-0}; kmal=${kmal:-0}
	mkdir -p "$LOGDIR"
	{
		echo "=== health $label $(date '+%F %T') ==="
		echo "MemAvailable_kB=$avail Slab_kB=$slab SUnreclaim_kB=$sunr kmallocish_kB=$kmal"
		echo "softnet_dropped_squeeze=$soft"
		echo "iface_irqs=$(count_iface_irqs) rx_queues=$(current_rx)"
		grep -E '^(MemTotal|MemFree|MemAvailable|Slab|SUnreclaim|SReclaimable):' /proc/meminfo
		echo
	} >>"$HEALTH_LOG"
	printf '%s %s %s %s %s\n' "$avail" "$slab" "$sunr" "$kmal" "${soft// /_}"
}

# Init baselines for CHECK_HEALTH (memory + softnet + IRQs + adapter stats).
health_baseline_init() {
	local v soft irqs load n

	_health_enabled || return 0
	CHECK_HEALTH=1
	export CHECK_HEALTH
	HEALTH_LOG="$LOGDIR/health-check.log"
	: >"$HEALTH_LOG"
	save_dmesg_mark
	v=$(mem_snapshot "baseline")
	_MEM_BASE_AVAIL=$(awk '{print $1}' <<<"$v")
	_MEM_BASE_SLAB=$(awk '{print $2}' <<<"$v")
	_MEM_PREV_AVAIL=$_MEM_BASE_AVAIL
	_MEM_PREV_SLAB=$_MEM_BASE_SLAB
	_SOFTNET_BASE=$(_softnet_totals)
	_HEALTH_IRQ_BASE=$(count_iface_irqs)
	_HEALTH_ALERTS=0
	_HEALTH_ALERT_MSGS=()
	_health_snap_adapter_stats
	load=$(_loadavg1)
	n=$(_nproc)
	ok "CHECK_HEALTH baseline Avail=$((_MEM_BASE_AVAIL / 1024))MB Slab=$((_MEM_BASE_SLAB / 1024))MB softnet=$_SOFTNET_BASE irqs=$_HEALTH_IRQ_BASE load=$load/${n}cpu err(inv/nobuf/rep)=$_HEALTH_ERR_INV/$_HEALTH_ERR_NOBUF/$_HEALTH_ERR_REP (log $HEALTH_LOG)"
}

# Backward-compatible name.
mem_baseline_init() { health_baseline_init; }

# Full health check after a test step.
health_check_after() {
	local label=$1
	local v avail slab sunr kmal
	local d_avail d_slab d_base_avail d_base_slab
	local soft soft_d soft_t base_d base_t dd dt
	local irqs rxn leak_count=0 warn_count=0 cur mark delta
	local fail=0

	_health_enabled || return 0

	v=$(mem_snapshot "after:$label")
	avail=$(awk '{print $1}' <<<"$v")
	slab=$(awk '{print $2}' <<<"$v")
	sunr=$(awk '{print $3}' <<<"$v")
	kmal=$(awk '{print $4}' <<<"$v")

	d_avail=$((_MEM_PREV_AVAIL - avail))
	d_slab=$((slab - _MEM_PREV_SLAB))
	d_base_avail=$((_MEM_BASE_AVAIL - avail))
	d_base_slab=$((slab - _MEM_BASE_SLAB))

	log "health[$label]: Avail $((_MEM_PREV_AVAIL / 1024))→$((avail / 1024))MB (Δ=$((-d_avail / 1024))MB)  Slab $((_MEM_PREV_SLAB / 1024))→$((slab / 1024))MB (Δ=$((d_slab / 1024))MB)  vs base AvailΔ=$((-d_base_avail / 1024))MB SlabΔ=$((d_base_slab / 1024))MB"

	# --- memory growth ---
	if [[ "$d_avail" -gt $((MEM_GROW_MB * 1024)) ]]; then
		_health_note_alert "MemAvailable dropped $((d_avail / 1024))MB after $label (threshold ${MEM_GROW_MB}MB)"
		_health_fail_mode && fail=1
	fi
	if [[ "$d_slab" -gt $((MEM_GROW_MB * 1024)) ]]; then
		_health_note_alert "Slab grew $((d_slab / 1024))MB after $label (threshold ${MEM_GROW_MB}MB)"
		_health_fail_mode && fail=1
	fi

	# --- softnet ---
	soft=$(_softnet_totals)
	soft_d=$(awk '{print $1}' <<<"$soft")
	soft_t=$(awk '{print $2}' <<<"$soft")
	base_d=$(awk '{print $1}' <<<"$_SOFTNET_BASE")
	base_t=$(awk '{print $2}' <<<"$_SOFTNET_BASE")
	dd=$((soft_d - base_d))
	dt=$((soft_t - base_t))
	log "health[$label]: softnet dropped Δ=$dd time_squeeze Δ=$dt (since baseline)"
	if [[ "$dd" -gt 1000 || "$dt" -gt 1000 ]]; then
		_health_note_alert "softnet pressure high after $label (droppedΔ=$dd squeezeΔ=$dt)"
		_health_fail_mode && fail=1
	fi

	# --- IRQ vs RX geometry (when iface present) ---
	if ip link show "$IFACE" &>/dev/null; then
		irqs=$(count_iface_irqs)
		rxn=$(current_rx)
		rxn=${rxn:-0}
		log "health[$label]: irqs=$irqs rx_queues=$rxn"
		if [[ "$rxn" -ge 1 && "$irqs" -gt 0 && "$irqs" -ne "$rxn" ]]; then
			# Allow minor mismatch right after resize; warn only if far off
			if [[ "$irqs" -lt "$rxn" || "$irqs" -gt $((rxn + 2)) ]]; then
				_health_note_alert "IRQ count $irqs vs RX queues $rxn after $label"
				_health_fail_mode && fail=1
			fi
		fi
	fi

	# --- adapter error stats + hcall counters (healthiness) ---
	if ip link show "$IFACE" &>/dev/null; then
		local inv nobuf rep reg free
		local d_inv d_nobuf d_rep d_reg d_free
		local load n load_lim

		inv=$(stat_val rx_invalid_buffer); inv=${inv:-0}
		nobuf=$(stat_val rx_no_buffer); nobuf=${nobuf:-0}
		rep=$(stat_val replenish_add_buff_failure); rep=${rep:-0}
		reg=$(stat_val hcall_reg_lan_queue); reg=${reg:-0}
		free=$(stat_val hcall_free_lan_queue); free=${free:-0}
		d_inv=$((inv - ${_HEALTH_ERR_INV:-0}))
		d_nobuf=$((nobuf - ${_HEALTH_ERR_NOBUF:-0}))
		d_rep=$((rep - ${_HEALTH_ERR_REP:-0}))
		d_reg=$((reg - ${_HEALTH_HCALL_REG:-0}))
		d_free=$((free - ${_HEALTH_HCALL_FREE:-0}))
		log "health[$label]: stats Δ invalid=$d_inv no_buffer=$d_nobuf replenish_fail=$d_rep  hcall_reg_q Δ=$d_reg free_q Δ=$d_free"
		{
			echo "adapter_stats_after_$label inv=$inv nobuf=$nobuf rep=$rep reg=$reg free=$free"
			echo "adapter_delta_after_$label d_inv=$d_inv d_nobuf=$d_nobuf d_rep=$d_rep d_reg=$d_reg d_free=$d_free"
		} >>"$HEALTH_LOG"
		if [[ "$d_inv" -gt "$HEALTH_ERR_DELTA" || "$d_nobuf" -gt "$HEALTH_ERR_DELTA" || \
		      "$d_rep" -gt "$HEALTH_ERR_DELTA" ]]; then
			_health_note_alert "adapter error stats after $label: invalidΔ=$d_inv no_bufferΔ=$d_nobuf replenishΔ=$d_rep (lim $HEALTH_ERR_DELTA)"
			_health_fail_mode && fail=1
		fi
		# hcall_* growth is expected on resize/open — log only; T16 asserts directionality.
		_HEALTH_ERR_INV=$inv
		_HEALTH_ERR_NOBUF=$nobuf
		_HEALTH_ERR_REP=$rep
		_HEALTH_HCALL_REG=$reg
		_HEALTH_HCALL_FREE=$free

		# --- load / optional CPU ---
		load=$(_loadavg1)
		n=$(_nproc)
		# bash arithmetic needs integer load*100
		load_lim=$((n * HEALTH_LOAD_MULT * 100))
		log "health[$label]: loadavg1=$load nproc=$n"
		if awk -v L="$load" -v lim="$load_lim" 'BEGIN { exit !((L * 100) > lim) }'; then
			_health_note_alert "loadavg1=$load high after $label (nproc=$n ×${HEALTH_LOAD_MULT})"
			_health_fail_mode && fail=1
		fi
		if [[ "${HEALTH_CPU:-0}" = 1 ]]; then
			_cpu_sample_1s
			log "health[$label]: CPU 1s idle=${_CPU_IDLE_PCT}% softirq=${_CPU_SOFTIRQ_PCT}% steal=${_CPU_STEAL_PCT}%"
			if [[ "${_CPU_STEAL_PCT:-0}" -gt "$HEALTH_STEAL_PCT" ]]; then
				_health_note_alert "CPU steal=${_CPU_STEAL_PCT}% after $label (lim ${HEALTH_STEAL_PCT}%)"
				_health_fail_mode && fail=1
			fi
		fi
	fi

	# --- dmesg: kmemleak + ibmveth WARN (since mark; do not advance) ---
	mark=$(cat "$LOGDIR/dmesg.mark" 2>/dev/null || echo 0)
	cur=$(dmesg | wc -l)
	delta=$((cur - mark))
	if [[ "$delta" -gt 0 ]]; then
		leak_count=$(dmesg | tail -n "$delta" | grep -ciE 'kmemleak|memory leak|memleak' || true)
		warn_count=$(dmesg | tail -n "$delta" | grep -ciE 'ibmveth.*(WARN|WARNING)|WARNING:.*ibmveth|WARN_ON' || true)
	fi
	if [[ "${leak_count:-0}" -gt 0 ]]; then
		_health_note_alert "dmesg $leak_count new kmemleak/memory-leak line(s) after $label"
		dmesg | tail -n "$delta" | grep -iE 'kmemleak|memory leak|memleak' | tail -10 | \
			while read -r line; do log "  $line"; done
		fail=1
	fi
	if [[ "${warn_count:-0}" -gt 0 ]]; then
		_health_note_alert "dmesg $warn_count ibmveth/WARN-related line(s) after $label"
		dmesg | tail -n "$delta" | grep -iE 'ibmveth.*(WARN|WARNING)|WARNING:.*ibmveth|WARN_ON' | tail -8 | \
			while read -r line; do log "  $line"; done
		_health_fail_mode && fail=1
	fi

	_MEM_PREV_AVAIL=$avail
	_MEM_PREV_SLAB=$slab

	if [[ "$fail" -eq 1 ]]; then
		die "CHECK_HEALTH failed after $label (see $HEALTH_LOG)"
	fi
	ok "health check after $label"
}

# Backward-compatible alias.
mem_check_after() { health_check_after "$@"; }

# End-of-suite summary vs baseline (always when CHECK_HEALTH on).
health_summary() {
	local avail slab soft soft_d soft_t base_d base_t dd dt irqs msg
	local load n inv nobuf rep

	_health_enabled || return 0
	avail=$(_mem_read_kb MemAvailable)
	slab=$(_mem_read_kb Slab)
	avail=${avail:-0}; slab=${slab:-0}
	soft=$(_softnet_totals)
	soft_d=$(awk '{print $1}' <<<"$soft")
	soft_t=$(awk '{print $2}' <<<"$soft")
	base_d=$(awk '{print $1}' <<<"${_SOFTNET_BASE:-0 0}")
	base_t=$(awk '{print $2}' <<<"${_SOFTNET_BASE:-0 0}")
	dd=$((soft_d - base_d))
	dt=$((soft_t - base_t))
	irqs=$(count_iface_irqs 2>/dev/null || echo 0)
	load=$(_loadavg1)
	n=$(_nproc)
	inv=$(stat_val rx_invalid_buffer 2>/dev/null || echo 0); inv=${inv:-0}
	nobuf=$(stat_val rx_no_buffer 2>/dev/null || echo 0); nobuf=${nobuf:-0}
	rep=$(stat_val replenish_add_buff_failure 2>/dev/null || echo 0); rep=${rep:-0}

	log "========== HEALTH SUMMARY (suite vs baseline) =========="
	log "  MemAvailable: $((_MEM_BASE_AVAIL / 1024)) → $((avail / 1024)) MB  (Δ=$(( (avail - _MEM_BASE_AVAIL) / 1024 )) MB)"
	log "  Slab:         $((_MEM_BASE_SLAB / 1024)) → $((slab / 1024)) MB  (Δ=$(( (slab - _MEM_BASE_SLAB) / 1024 )) MB)"
	log "  softnet:      dropped Δ=$dd  time_squeeze Δ=$dt"
	log "  irqs now:     $irqs  (baseline $_HEALTH_IRQ_BASE)  rx=$(current_rx 2>/dev/null || echo ?)"
	log "  loadavg1:     $load  (nproc=$n)"
	log "  adapter err:  invalid=$inv no_buffer=$nobuf replenish_fail=$rep"
	log "  hcall:        reg_lan_queue=${_HEALTH_HCALL_REG:-?} free_lan_queue=${_HEALTH_HCALL_FREE:-?}"
	log "  detail log:   $HEALTH_LOG"

	# End-of-suite 1s CPU sample (cheap once).
	_cpu_sample_1s
	log "  CPU 1s:       idle=${_CPU_IDLE_PCT}% softirq=${_CPU_SOFTIRQ_PCT}% steal=${_CPU_STEAL_PCT}%"
	if [[ "${_CPU_STEAL_PCT:-0}" -gt "$HEALTH_STEAL_PCT" ]]; then
		_health_note_alert "end-suite CPU steal=${_CPU_STEAL_PCT}% (lim ${HEALTH_STEAL_PCT}%)"
	fi

	if [[ "${_HEALTH_ALERTS:-0}" -eq 0 ]]; then
		ok "HEALTH PASS — no alerts this suite"
	else
		alert "HEALTH ALERTS: ${_HEALTH_ALERTS} during suite (soft unless HEALTH_FAIL=1)"
		for msg in "${_HEALTH_ALERT_MSGS[@]+"${_HEALTH_ALERT_MSGS[@]}"}"; do
			log "  • $msg"
		done
	fi

	{
		echo "=== HEALTH SUMMARY $(date '+%F %T') ==="
		echo "Avail_MB ${_MEM_BASE_AVAIL}->${avail} Slab_MB ${_MEM_BASE_SLAB}->${slab}"
		echo "softnet_dropped_delta=$dd softnet_squeeze_delta=$dt irqs=$irqs load=$load"
		echo "err_inv=$inv err_nobuf=$nobuf err_rep=$rep"
		echo "cpu_idle=${_CPU_IDLE_PCT} softirq=${_CPU_SOFTIRQ_PCT} steal=${_CPU_STEAL_PCT}"
		echo "alerts=${_HEALTH_ALERTS:-0}"
		echo
	} >>"$HEALTH_LOG"
}

# End-of-suite: try a clean unload/reload probe only if HEALTH_UNLOAD=1.
# Skipped by default under EXTERNAL_IPERF (would kill lab traffic).
health_unload_probe() {
	local saved_ip

	_health_enabled || return 0
	[[ "${HEALTH_UNLOAD:-0}" = 1 ]] || return 0
	[[ "${EXTERNAL_IPERF:-0}" = 1 ]] && {
		log "HEALTH_UNLOAD skipped under EXTERNAL_IPERF (would kill lab iperf)"
		return 0
	}

	log "=== health unload probe ==="
	saved_ip=$(save_iface_ipv4)
	iface_down 2>/dev/null || true
	sleep 1
	if ! rmmod ibmveth 2>/dev/null; then
		log "WARN: rmmod ibmveth failed (module busy? holders=$(ls /sys/module/ibmveth/holders 2>/dev/null | tr '\n' ' '))"
		_health_fail_mode && die "CHECK_HEALTH: rmmod failed"
		iface_up 2>/dev/null || true
		return 0
	fi
	ok "rmmod ibmveth succeeded"
	sleep 1
	if [[ "${IBMVETH_DYNDBG:-0}" = 1 || "${DYNDBG:-0}" = 1 ]]; then
		load_ibmveth "+p"
	else
		load_ibmveth
	fi
	sleep 2
	ip link show "$IFACE" >/dev/null || die "netdev $IFACE missing after health reload"
	iface_up
	restore_iface_ipv4 "$saved_ip"
	[[ -n "${PEER:-}" ]] && ping_ok || true
	ok "health unload/reload probe passed"
}


: "${IPERF_PORTS:=5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5211 5212 5213 5214 5215 5216}"
# Space-separated PIDs of iperf3 -s we started (do not killall — may kill user clients).
: "${IPERF_SERVER_PIDS:=}"

# Proof thresholds for real bulk inbound (not ping/ARP noise).
# Override: MIN_RX_DELTA=5000 RX_SAMPLE_SECS=5 MIN_ACTIVE_RX_QUEUES=2
: "${RX_SAMPLE_SECS:=5}"
: "${MIN_RX_DELTA:=10000}"          # total rx*_packets increase over sample
: "${MIN_ACTIVE_RX_QUEUES:=2}"      # distinct queues that must see Δ>0 when MQ
: "${MQ_PROOF_RX:=8}"               # RX queue count used for MQ spread proof

sum_rx_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx[0-9]+_packets:/ { s += $2 }
		END { print s+0 }
	'
}

count_rx_queue_rows() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx[0-9]+_packets:/ { n++ }
		END { print n+0 }
	'
}

# Print "qid count" lines for each rxN_packets counter.
snapshot_rx_queue_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx([0-9]+)_packets:/ {
			if (match($1, /[0-9]+/))
				print substr($1, RSTART, RLENGTH), $2 + 0
		}
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
# If RESTART_IPERF=1 (default for heavy gate), kill existing listeners on
# IPERF_PORTS first — stale -s after module reload often looks "up" but
# clients never produce RX Δ.
# EXTERNAL_IPERF=1: lab already runs server+client — do not touch iperf.
start_iperf_servers() {
	local p n=0 pid

	if [[ "${EXTERNAL_IPERF:-0}" = 1 ]]; then
		log "EXTERNAL_IPERF=1 — not starting/restarting iperf3 (lab-owned)"
		n=$(ss -ltnp 2>/dev/null | grep -c iperf3) || true
		n=${n:-0}
		log "iperf3 listeners currently: $n (left untouched)"
		return 0
	fi

	need_iperf3

	if [[ "${RESTART_IPERF:-1}" = 1 ]]; then
		log "RESTART_IPERF=1 — clearing listeners on: $IPERF_PORTS"
		for p in $IPERF_PORTS; do
			while read -r pid; do
				[[ -n "$pid" ]] || continue
				kill "$pid" 2>/dev/null || true
			done < <(ss -ltnp 2>/dev/null | awk -v p=":$p" '
				$0 ~ p {
					while (match($0, /pid=[0-9]+/)) {
						print substr($0, RSTART+4, RLENGTH-4)
						$0 = substr($0, RSTART+RLENGTH)
					}
				}')
		done
		sleep 1
		IPERF_SERVER_PIDS=
	fi

	for p in $IPERF_PORTS; do
		if ss -ltn 2>/dev/null | grep -qE ":${p}([[:space:]]|$)"; then
			log "iperf3 still listening on :$p (left in place)"
			pid=$(ss -ltnp 2>/dev/null | awk -v p=":$p" '
				$0 ~ p {
					if (match($0, /pid=[0-9]+/)) {
						print substr($0, RSTART+4, RLENGTH-4)
						exit
					}
				}')
			[[ -n "$pid" ]] && IPERF_SERVER_PIDS+=" $pid"
		else
			"$IPERF3" -s -p "$p" -D || die "failed to start $IPERF3 -s -p $p"
			n=$((n + 1))
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
	n=$(ss -ltnp 2>/dev/null | grep -c iperf3) || true
	n=${n:-0}
	[[ "$n" -ge 1 ]] || die "no iperf3 listeners after start"
	ok "iperf3 servers: $n listener(s) on DUT ($IPERF3)"
	ss -ltnp 2>/dev/null | grep iperf3 | head -5 | while read -r line; do log "  $line"; done
}

stop_iperf_servers() {
	local pid

	if [[ "${EXTERNAL_IPERF:-0}" = 1 ]]; then
		log "EXTERNAL_IPERF=1 — not stopping iperf3 (lab-owned)"
		IPERF_SERVER_PIDS=
		return 0
	fi

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

# Print DUT-side clues when inbound gate fails (Δ=0 or below threshold).
diagnose_inbound_fail() {
	local a b link_rx
	log "=== inbound gate diagnostics ==="
	log "IFACE=$IFACE PEER=$PEER current_rx=$(current_rx) addr=$(save_iface_ipv4)"
	log "thresholds: MIN_RX_DELTA=$MIN_RX_DELTA RX_SAMPLE_SECS=$RX_SAMPLE_SECS EXTERNAL_IPERF=${EXTERNAL_IPERF:-0}"
	if ping -I "$IFACE" -c 2 -W 1 "$PEER" >/dev/null 2>&1; then
		ok "ping -I $IFACE $PEER OK"
	else
		log "WARN: ping -I $IFACE $PEER failed — wrong PEER/L2 or RX dead (bare ping can lie via another NIC)"
	fi
	a=$(sum_rx_packets)
	sleep 2
	b=$(sum_rx_packets)
	log "rx*_packets sum: $a → $b (Δ=$((b - a)) over 2s)"
	link_rx=$(ip -s link show "$IFACE" 2>/dev/null | awk '/RX:/{getline; print $1; exit}')
	log "ip -s link $IFACE RX packets field≈${link_rx:-?}"
	log "iperf3 listeners: $(ss -ltnp 2>/dev/null | grep -c iperf3 || echo 0)"
	ethtool -S "$IFACE" 2>/dev/null | grep -E '^[[:space:]]*rx([0-9]+_)?packets:' | head -12 | \
		while read -r line; do log "  $line"; done

	if [[ "${EXTERNAL_IPERF:-0}" = 1 ]]; then
		cat >/dev/tty <<EOF

----------------------------------------------------------------------
EXTERNAL_IPERF=1: harness will not start/stop iperf.
Gate needs total Δ>=$MIN_RX_DELTA over ${RX_SAMPLE_SECS}s on $IFACE.
If Δ is low, raise lab traffic or override: MIN_RX_DELTA=50 RX_SAMPLE_SECS=10
----------------------------------------------------------------------
EOF
		return 0
	fi

	cat >/dev/tty <<EOF

----------------------------------------------------------------------
Low/zero RX Δ on $IFACE. Do this on peer BEFORE typing R:

  pkill iperf3 2>/dev/null
  export DUT_IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  ping -c 3 \$DUT_IP
  # ONE port — must print Mbits/sec (if this fails, paste the error):
  iperf3 -c \$DUT_IP -t 15 -p 5201 -P 1
  # then full:
  for p in $IPERF_PORTS; do iperf3 -c \$DUT_IP -t 3600 -P 4 -p \$p & done

On DUT, watch:  watch -n1 "ethtool -S $IFACE | grep rx0_packets"
Only type R when that counter is climbing.
----------------------------------------------------------------------
EOF
}

# Soft check: any RX counter increase (legacy / ping-level). Prefer prove_*.
inbound_rx_flowing() {
	local wait=${1:-5}
	local a b
	a=$(sum_rx_packets)
	sleep "$wait"
	b=$(sum_rx_packets)
	log "RX packets: $a → $b (Δ=$((b - a)) over ${wait}s)"
	[[ "$b" -gt "$a" ]]
}

# Hard proof: bulk inbound RX (rejects ping/ARP-sized Δ).
# Returns 0 on success. Logs per-queue Δ. Does not require MQ spread.
prove_bulk_inbound_rx() {
	local label=${1:-bulk-rx}
	local wait=${2:-$RX_SAMPLE_SECS}
	local min_delta=${3:-$MIN_RX_DELTA}
	local q c before_file after_file total=0 active=0 d nq b

	before_file=$(mktemp)
	after_file=$(mktemp)
	snapshot_rx_queue_packets >"$before_file"
	nq=$(wc -l <"$before_file" | tr -d ' ')
	sleep "$wait"
	snapshot_rx_queue_packets >"$after_file"

	log "=== $label: ${wait}s sample on $IFACE (need total Δ>=$min_delta; queues=$nq) ==="
	while read -r q c; do
		b=$(awk -v q="$q" '$1 == q { print $2; exit }' "$before_file")
		b=${b:-0}
		d=$((c - b))
		total=$((total + d))
		if [[ "$d" -gt 0 ]]; then
			active=$((active + 1))
			log "  rx${q}_packets Δ=$d"
		fi
	done <"$after_file"
	rm -f "$before_file" "$after_file"

	log "$label: total Δ=$total over ${wait}s across $active queue(s)"
	[[ "$total" -ge "$min_delta" ]] || return 1
	ok "$label: bulk inbound proven (Δ=$total >= $min_delta)"
	return 0
}

# Hard proof: MQ RX under load — bulk + packets on multiple queues.
# Sets RX to MQ_PROOF_RX first (unless SKIP_SET_RX=1).
prove_mq_rx_under_load() {
	local label=${1:-mq-rx-under-load}
	local wait=${RX_SAMPLE_SECS}
	local min_delta=${MIN_RX_DELTA}
	local min_q=${MIN_ACTIVE_RX_QUEUES}
	local q c before_file after_file total=0 active=0 d nq want_rx b

	want_rx=${MQ_PROOF_RX}
	if [[ "${SKIP_SET_RX:-0}" != 1 ]]; then
		iface_up
		ethtool_rx "$want_rx" || die "$label: ethtool -L rx $want_rx failed"
		sleep 1
		nq=$(count_rx_queue_rows)
		[[ "$nq" -eq "$want_rx" ]] || die "$label: expected $want_rx rx*_packets rows, got $nq"
	fi

	before_file=$(mktemp)
	after_file=$(mktemp)
	snapshot_rx_queue_packets >"$before_file"
	nq=$(wc -l <"$before_file" | tr -d ' ')
	sleep "$wait"
	snapshot_rx_queue_packets >"$after_file"

	log "=== $label: ${wait}s MQ sample (need Δ>=$min_delta AND >=$min_q active queues; nq=$nq) ==="
	while read -r q c; do
		b=$(awk -v q="$q" '$1 == q { print $2; exit }' "$before_file")
		b=${b:-0}
		d=$((c - b))
		total=$((total + d))
		if [[ "$d" -gt 0 ]]; then
			active=$((active + 1))
			log "  rx${q}_packets Δ=$d"
		fi
	done <"$after_file"
	rm -f "$before_file" "$after_file"

	log "$label: total Δ=$total active_queues=$active/$nq"
	[[ "$total" -ge "$min_delta" ]] || \
		die "$label FAIL: bulk RX not proven (Δ=$total < $min_delta) — keep lp7 iperf running"
	if [[ "$nq" -ge 4 ]]; then
		[[ "$active" -ge "$min_q" ]] || \
			die "$label FAIL: MQ spread not proven (only $active queue(s) got packets, need >=$min_q). Check lp7 multi-port/multi-P clients."
	fi
	ok "$label: MQ RX under load proven (Δ=$total, $active/$nq queues)"
}

# Interactive: print lp7 commands, wait for "yes", prove bulk + MQ RX.
# NONINTERACTIVE=1 skips prompts (still requires traffic already running).
# EXTERNAL_IPERF=1: lab owns iperf — no start/stop/restart, no peer recipe prompt.
# ALLOW_WEAK_RX=1 restores old "continue anyway" escape hatch (not for evidence).
prompt_start_inbound_iperf() {
	local dut_ip tries=0 ans=

	dut_ip=${DUT_IP:-}
	if [[ -z "$dut_ip" ]]; then
		dut_ip=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null \
			| awk '{print $4}' | cut -d/ -f1 | head -1)
	fi
	[[ -n "$dut_ip" ]] || die "set DUT_IP= (this LPAR address on $IFACE)"

	if [[ "${EXTERNAL_IPERF:-0}" = 1 ]]; then
		log "EXTERNAL_IPERF=1 — skip iperf start/stop/prompt; proving existing inbound RX"
		# Never clear lab-owned listeners.
		RESTART_IPERF=0 start_iperf_servers
		ethtool_rx "$MQ_PROOF_RX" 2>/dev/null || ethtool_rx 4 || true
		sleep 1
		log "pre-gate geometry: RX=$(current_rx) (want $MQ_PROOF_RX for later MQ proof)"
		if ! prove_bulk_inbound_rx "gate-bulk-external" "$RX_SAMPLE_SECS" "$MIN_RX_DELTA"; then
			diagnose_inbound_fail
			die "EXTERNAL_IPERF=1: inbound Δ below MIN_RX_DELTA=$MIN_RX_DELTA / ${RX_SAMPLE_SECS}s (raise lab traffic or lower MIN_RX_DELTA)"
		fi
		prove_mq_rx_under_load "gate-mq-rx-external"
		return 0
	fi

	# Fresh servers after quiet-phase reload/ifdown churn.
	RESTART_IPERF="${RESTART_IPERF:-1}" start_iperf_servers

	# Leave RX at MQ proof geometry so gate sample isn't stuck at RX=1.
	ethtool_rx "$MQ_PROOF_RX" 2>/dev/null || ethtool_rx 4 || true
	sleep 1
	log "pre-gate geometry: RX=$(current_rx) (want $MQ_PROOF_RX for later MQ proof)"

	if [[ "${SIMPLE_IPERF:-0}" = 1 ]]; then
		cat >/dev/tty <<EOF

**********************************************************************
*  HEAVY GATE (SIMPLE_IPERF=1) — one long iperf, soft thresholds     *
*  Not valid for MQ/RSS multi-queue spread claims.                   *
*  Δ=0 is NORMAL until the long client below is running.             *
**********************************************************************
On PEER ($PEER):

  pkill iperf3 2>/dev/null
  export DUT_IP=$dut_ip
  ping -c 3 \$DUT_IP
  # KEEP THIS RUNNING (do not use only a 15s test then stop):
  iperf3 -c \$DUT_IP -t 3600 -P 4 -p 5201 &

On DUT, wait until counters move, then type yes:
  watch -n1 'ethtool -S $IFACE | grep -E "rx[0-9]+_packets" | head'

Need Δ>=$MIN_RX_DELTA / ${RX_SAMPLE_SECS}s (queues>=$MIN_ACTIVE_RX_QUEUES).
DUT listening as $dut_ip on: $IPERF_PORTS
**********************************************************************

EOF
	else
		cat >/dev/tty <<EOF

**********************************************************************
*  HEAVY PHASE GATE — lp7 iperf required from here on                *
*  Quiet tests (T20 reload, T21 get/set, etc.) are already done.     *
*  Δ=0 is NORMAL until you start clients below.                      *
**********************************************************************
On PEER ($PEER), run NOW (old clients died during quiet reload/ifdown):

  pkill iperf3 2>/dev/null
  export DUT_IP=$dut_ip
  ping -c 3 \$DUT_IP
  # smoke (optional), then LONG multi-flow — leave running:
  iperf3 -c \$DUT_IP -t 15 -p 5201 -P 1
  for p in $IPERF_PORTS; do
    iperf3 -c \$DUT_IP -t 3600 -P 4 -p \$p &
  done

On DUT, confirm RX climbing:
  watch -n1 'ethtool -S $IFACE | grep -E "rx[0-9]+_packets" | head'

Then type yes. Need Δ>=$MIN_RX_DELTA / ${RX_SAMPLE_SECS}s and
>=$MIN_ACTIVE_RX_QUEUES queues at RX=$MQ_PROOF_RX.
DUT listening as $dut_ip on: $IPERF_PORTS
**********************************************************************

EOF
	fi

	if [[ "${NONINTERACTIVE:-0}" = 1 ]]; then
		log "NONINTERACTIVE=1 — checking for existing inbound RX (no prompt)"
	else
		while true; do
			if [[ "${SIMPLE_IPERF:-0}" = 1 ]]; then
				tty_read "Type 'yes' AFTER long iperf (-t 3600) is running and RX moves: " ans
			else
				tty_read "Type 'yes' ONLY after lp7 long multi-flow iperf is running: " ans
			fi
			case "$ans" in
				yes|YES|y|Y) break ;;
				*) printf 'Please type yes (or Ctrl-C to abort).\n' >/dev/tty ;;
			esac
		done
	fi

	while true; do
		if prove_bulk_inbound_rx "gate-bulk" "$RX_SAMPLE_SECS" "$MIN_RX_DELTA"; then
			break
		fi
		tries=$((tries + 1))
		log "WAITING: no bulk RX yet (try $tries) — Δ=0 means lp7 clients not flowing"
		log "         (expected if you have not finished the one-port smoke test)"
		diagnose_inbound_fail
		if [[ "${NONINTERACTIVE:-0}" = 1 ]]; then
			die "inbound bulk RX not detected (start lp7 clients first)"
		fi
		if [[ "${ALLOW_WEAK_RX:-0}" = 1 ]]; then
			tty_read "[R]etry, [A]bort, [C]ontinue weak (ALLOW_WEAK_RX)? " ans
			case "${ans:-R}" in
				A|a) die "aborted: inbound iperf not confirmed" ;;
				C|c) log "WARN: weak RX — not valid MQ-under-load evidence"; return 0 ;;
				*) ;;
			esac
		else
			tty_read "[R]etry after fixing lp7, or [A]bort? " ans
			case "${ans:-R}" in
				A|a) die "aborted: inbound iperf not confirmed" ;;
				*) ;;
			esac
		fi
	done

	# Geometry for MQ spread, then prove multi-queue receive.
	prove_mq_rx_under_load "gate-mq-rx"
}
