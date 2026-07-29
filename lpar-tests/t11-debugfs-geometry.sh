#!/bin/bash
# T11 / P11 — debugfs buffer_pools geometry tracks RX queue count
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t11-debugfs-geometry.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX_LIST:=1 4 8}"

need_root
save_dmesg_mark
iface_up

bp=$(iface_buffer_pools) || die "missing buffer_pools under /sys/kernel/debug (IFACE=$IFACE; check find /sys/kernel/debug -name buffer_pools — probe name may differ after udev rename)"
ok "buffer_pools at $bp"
if [[ "$bp" != "/sys/kernel/debug/${IFACE}/buffer_pools" ]]; then
	log "NOTE: debugfs path uses probe-time name (not $IFACE) — OK after udev rename"
fi

log "=== T11/P11 debugfs geometry on $IFACE ==="

for n in $RX_LIST; do
	max=$(max_rx)
	if [[ "$n" -gt "$max" ]]; then
		log "skip RX=$n (max_rx=$max)"
		continue
	fi
	log "--- RX=$n ---"
	ethtool_rx "$n" || die "ethtool -L rx $n failed"
	sleep 1
	assert_rx_geometry "$n"

	got_l=$(current_rx)
	rows_s=$(count_rx_stat_rows)
	rows_d=$(count_debugfs_queue_rows "$bp")
	log "ethtool -l RX=$got_l  rx*_packets rows=$rows_s  debugfs queues=$rows_d"
	[[ "$got_l" == "$n" ]] || die "ethtool -l RX=$got_l want $n"
	[[ "$rows_s" == "$n" ]] || die "rx*_packets rows=$rows_s want $n"
	[[ "$rows_d" == "$n" ]] || die "debugfs buffer_pools queue rows=$rows_d want $n"
	# Optional: pool rows = queues * IBMVETH pools (typically 5) — soft check
	pool_lines=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ { c++ } END { print c+0 }' "$bp")
	log "debugfs pool lines=$pool_lines (expect about $((n * 5)) if 5 pools/queue)"
	cp "$bp" "$LOGDIR/t11-buffer_pools-rx${n}.txt"
	ok "RX=$n: -l / -S / debugfs queue rows match"
done

[[ -n "${PEER:-}" ]] && ping_ok || true
check_no_oops
log "T11/P11 PASS"
