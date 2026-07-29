#!/bin/bash
# T22 — stats coherence: ethtool -S per-queue vs ip/proc, optional sar
#
# Checks that reports "make sense":
#   - sum(rxN_packets) ≈ ip -s link / /proc/net/dev RX packets
#   - sum(txN_packets) ≈ TX packets (when txN rows exist)
#   - counters are monotonic over a short sample
#   - under traffic (UNDER_RX=1 or EXTERNAL_IPERF): Δ aligns across sources
#   - optional sar -n DEV sample if sar is installed
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t22-stats-coherence.sh
#   sudo IFACE=env9 UNDER_RX=1 ./t22-stats-coherence.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${UNDER_RX:=0}"
: "${STATS_SAMPLE_SECS:=${RX_SAMPLE_SECS:-5}}"
# Absolute slack for non-atomic multi-reader (packets).
: "${STATS_TOLERANCE:=200}"
# Relative slack (percent) when totals are large.
: "${STATS_TOL_PCT:=1}"

need_root
save_dmesg_mark
iface_up

log "=== T22 stats coherence on $IFACE (UNDER_RX=$UNDER_RX EXTERNAL_IPERF=${EXTERNAL_IPERF:-0}) ==="

# --- helpers ---
sum_ethtool_rx_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx[0-9]+_packets:/ { s += $2 }
		END { print s+0 }
	'
}

sum_ethtool_tx_packets() {
	ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*tx[0-9]+_packets:/ { s += $2 }
		END { print s+0 }
	'
}

# ip -s link (iproute2): after "RX:" / "TX:" header, columns are
#   bytes packets errors ...  — packets is $2, not $1 (bytes).
# Older style: "RX packets:N errors:..."
ip_link_rx_packets() {
	ip -s link show "$IFACE" 2>/dev/null | awk '
		/RX packets:/ {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^packets:/) {
					split($i, a, ":")
					print a[2] + 0
					exit
				}
			}
		}
		/^[ \t]*RX:/ {
			getline
			print $2 + 0
			exit
		}
	'
}

ip_link_tx_packets() {
	ip -s link show "$IFACE" 2>/dev/null | awk '
		/TX packets:/ {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^packets:/) {
					split($i, a, ":")
					print a[2] + 0
					exit
				}
			}
		}
		/^[ \t]*TX:/ {
			getline
			print $2 + 0
			exit
		}
	'
}

proc_netdev_rx_packets() {
	# /proc/net/dev: iface: rx_bytes rx_packets ...
	awk -v ifc="$IFACE" '
		$1 ~ ("^" ifc ":") {
			gsub(/:/, "", $1)
			print $3+0
			exit
		}
	' /proc/net/dev
}

proc_netdev_tx_packets() {
	awk -v ifc="$IFACE" '
		$1 ~ ("^" ifc ":") {
			gsub(/:/, "", $1)
			print $11+0
			exit
		}
	' /proc/net/dev
}

within_tol() {
	local a=$1 b=$2
	local diff pct_lim abs_lim
	diff=$((a > b ? a - b : b - a))
	abs_lim=$STATS_TOLERANCE
	# percent of the larger value
	if [[ "$a" -gt "$b" ]]; then
		pct_lim=$((a * STATS_TOL_PCT / 100))
	else
		pct_lim=$((b * STATS_TOL_PCT / 100))
	fi
	[[ "$pct_lim" -lt "$abs_lim" ]] && pct_lim=$abs_lim
	[[ "$diff" -le "$pct_lim" ]]
}

compare_pair() {
	local name=$1 a=$2 b=$3 soft=${4:-0}
	local diff
	diff=$((a > b ? a - b : b - a))
	if within_tol "$a" "$b"; then
		ok "$name: $a ≈ $b (Δ=$diff)"
		return 0
	fi
	if [[ "$soft" = 1 ]]; then
		log "WARN: $name mismatch under live traffic (non-atomic): $a vs $b (Δ=$diff) — rely on sample Δ"
		return 0
	fi
	die "$name mismatch: $a vs $b (Δ=$diff; tol abs=$STATS_TOLERANCE pct=${STATS_TOL_PCT}%)"
}

# Absolute multi-source reads race under high pps — soft there; hard when quiet.
snap_soft=0
[[ "$UNDER_RX" = 1 || "${EXTERNAL_IPERF:-0}" = 1 ]] && snap_soft=1

# --- static coherence snapshot ---
rx_q=$(sum_ethtool_rx_packets)
rx_ip=$(ip_link_rx_packets)
rx_proc=$(proc_netdev_rx_packets)
rx_q=${rx_q:-0}; rx_ip=${rx_ip:-0}; rx_proc=${rx_proc:-0}

log "snapshot RX: ethtool_sum(rxN)=$rx_q  ip_link=$rx_ip  proc_net_dev=$rx_proc"
[[ "$rx_q" -gt 0 || "$rx_ip" -gt 0 ]] || log "WARN: all RX totals 0 (quiet iface — under-traffic checks may soft-skip)"

compare_pair "ethtool_sum(rxN) vs ip -s link RX" "$rx_q" "$rx_ip" "$snap_soft"
compare_pair "ethtool_sum(rxN) vs /proc/net/dev RX" "$rx_q" "$rx_proc" "$snap_soft"
compare_pair "ip -s link RX vs /proc/net/dev RX" "$rx_ip" "$rx_proc" "$snap_soft"

tx_rows=$(count_tx_stat_rows)
tx_q=$(sum_ethtool_tx_packets)
tx_ip=$(ip_link_tx_packets)
tx_proc=$(proc_netdev_tx_packets)
tx_q=${tx_q:-0}; tx_ip=${tx_ip:-0}; tx_proc=${tx_proc:-0}
if [[ "${tx_rows:-0}" -ge 1 ]]; then
	log "snapshot TX: ethtool_sum(txN)=$tx_q  ip_link=$tx_ip  proc_net_dev=$tx_proc (rows=$tx_rows)"
	compare_pair "ethtool_sum(txN) vs ip -s link TX" "$tx_q" "$tx_ip" "$snap_soft"
	compare_pair "ethtool_sum(txN) vs /proc/net/dev TX" "$tx_q" "$tx_proc" "$snap_soft"
else
	log "no txN_packets rows — skip TX per-queue coherence"
fi

# Aggregate invalid: sum(rxN_invalid_buffers) vs rx_invalid_buffer if present
inv_agg=$(stat_val rx_invalid_buffer)
inv_agg=${inv_agg:-}
if [[ -n "$inv_agg" ]]; then
	inv_sum=$(ethtool -S "$IFACE" 2>/dev/null | awk '
		/^[[:space:]]*rx[0-9]+_invalid_buffers:/ { s += $2 }
		END { print s+0 }
	')
	inv_sum=${inv_sum:-0}
	compare_pair "sum(rxN_invalid_buffers) vs rx_invalid_buffer" "$inv_sum" "$inv_agg" "$snap_soft"
fi

# --- monotonic sample ---
log "monotonic sample ${STATS_SAMPLE_SECS}s..."
a_q=$(sum_ethtool_rx_packets)
a_ip=$(ip_link_rx_packets)
sleep "$STATS_SAMPLE_SECS"
b_q=$(sum_ethtool_rx_packets)
b_ip=$(ip_link_rx_packets)
d_q=$((b_q - a_q))
d_ip=$((b_ip - a_ip))
log "RX Δ over ${STATS_SAMPLE_SECS}s: ethtool_sum=$d_q  ip_link=$d_ip"
[[ "$d_q" -ge 0 && "$d_ip" -ge 0 ]] || die "RX counters went backwards (ethtool Δ=$d_q ip Δ=$d_ip)"
ok "RX counters monotonic"

# Bulk Δ only when UNDER_RX=1 (heavy phase). EXTERNAL_IPERF alone does not
# force it — phase-1 may run before the inbound gate.
if [[ "$UNDER_RX" = 1 ]]; then
	min_d=${MIN_RX_DELTA:-100}
	[[ "$d_q" -ge "$min_d" || "$d_ip" -ge "$min_d" ]] || \
		die "under-traffic expected Δ>=$min_d over ${STATS_SAMPLE_SECS}s (ethtool=$d_q ip=$d_ip)"
	compare_pair "RX Δ ethtool_sum vs ip -s link" "$d_q" "$d_ip"
	ok "under-traffic Δ coherent (min $min_d)"
else
	# Still compare Δ when both moved (quiet can see stray packets).
	if [[ "$d_q" -gt 0 || "$d_ip" -gt 0 ]]; then
		compare_pair "RX Δ ethtool_sum vs ip -s link" "$d_q" "$d_ip"
	fi
	log "UNDER_RX=0 — not requiring bulk Δ (static coherence only)"
fi

# --- optional sar ---
if command -v sar >/dev/null 2>&1; then
	sar_secs=$((STATS_SAMPLE_SECS < 3 ? 3 : STATS_SAMPLE_SECS))
	log "sar -n DEV $sar_secs 1 (iface $IFACE)..."
	# Capture before/after via ethtool for comparison; sar average rxpck/s
	a_q=$(sum_ethtool_rx_packets)
	sar_out=$(sar -n DEV "$sar_secs" 1 2>/dev/null | tee "$LOGDIR/t22-sar.txt" || true)
	b_q=$(sum_ethtool_rx_packets)
	d_q=$((b_q - a_q))
	# Average rxpck/s for IFACE from sar (Average line or last matching)
	rxpck=$(awk -v ifc="$IFACE" '
		$0 ~ ifc && $3 ~ /^[0-9.]+$/ { v=$3 }
		END { print v+0 }
	' <<<"$sar_out")
	# Expected packets ≈ rxpck/s * secs (rough)
	expect=$(awk -v r="$rxpck" -v s="$sar_secs" 'BEGIN { printf "%d", r*s + 0.5 }')
	log "sar rxpck/s≈$rxpck → expect≈$expect pkts; ethtool Δ=$d_q"
	if [[ "$UNDER_RX" = 1 && "$(awk -v r="$rxpck" 'BEGIN{print (r>0)?1:0}')" = 1 ]]; then
		compare_pair "sar-implied RX vs ethtool Δ" "$expect" "$d_q"
		ok "sar -n DEV coherent with ethtool Δ"
	else
		ok "sar ran (soft compare; rxpck/s=$rxpck ethtoolΔ=$d_q)"
	fi
else
	log "sar not installed — skip sar coherence (optional)"
fi

# Geometry still matches row count
assert_rx_geometry "$(current_rx)"
check_no_oops
[[ -n "${PEER:-}" ]] && ping_ok || true
log "T22 PASS"
