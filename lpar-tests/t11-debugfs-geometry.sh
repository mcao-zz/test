#!/bin/bash
# T11 / P11 — debugfs buffer_pools geometry tracks RX queue count
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t11-debugfs-geometry.sh
#
# Checks:
#   1. Column header matches v8 format exactly
#   2. Per-queue: debugfs queue rows = RX count, pool rows = RX×5
#   3. rx*_interrupts ethtool -S rows match RX count
#   4. While down: "# down:" comment lines present
#   5. Geometry (Count/BuffSize) preserved while down
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX_LIST:=1 4 8}"
# v8 buffer_pools header: two lines (header + separator)
V8_HEADER="Queue  Pool  Count  BuffSize  Active  Available"
V8_SEPARATOR="-----  ----  -----  --------  ------  ---------"

need_root
save_dmesg_mark
iface_up

bp=$(iface_buffer_pools) || die "missing buffer_pools under /sys/kernel/debug (IFACE=$IFACE; expect /sys/kernel/debug/ibmveth/<vio>/buffer_pools — try: find /sys/kernel/debug -name buffer_pools)"
ok "buffer_pools at $bp"
if [[ "$bp" == */ibmveth/*/buffer_pools ]]; then
	log "NOTE: nested ibmveth/<vio>/ path (J11-3) — OK"
elif [[ "$bp" != "/sys/kernel/debug/${IFACE}/buffer_pools" ]]; then
	log "NOTE: debugfs path is not IFACE name — OK after rename / nesting"
fi

# Check v8 column header format exactly.
got_hdr=$(head -1 "$bp")
got_sep=$(sed -n '2p' "$bp")
[[ "$got_hdr" == "$V8_HEADER" ]] || \
	die "buffer_pools header mismatch: got='$got_hdr' want='$V8_HEADER'"
[[ "$got_sep" == "$V8_SEPARATOR" ]] || \
	die "buffer_pools separator mismatch: got='$got_sep' want='$V8_SEPARATOR'"
ok "buffer_pools column header matches v8 format"

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
	# v8: IBMVETH_NUM_BUFF_POOLS=5 pools per queue → total data rows = n×5
	pool_lines=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ { c++ } END { print c+0 }' "$bp")
	expect_pools=$((n * 5))
	log "ethtool -l RX=$got_l  rx*_interrupts rows=$rows_s  debugfs queues=$rows_d  pool_rows=$pool_lines (want $expect_pools)"
	[[ "$got_l" == "$n" ]] || die "ethtool -l RX=$got_l want $n"
	[[ "$rows_s" == "$n" ]] || die "rx*_interrupts rows=$rows_s want $n"
	[[ "$rows_d" == "$n" ]] || die "debugfs buffer_pools queue rows=$rows_d want $n"
	[[ "$pool_lines" == "$expect_pools" ]] || \
		die "debugfs pool data rows=$pool_lines want $expect_pools (${n}×5)"
	assert_buffer_pools_up "T11-rx$n"
	cp "$bp" "$LOGDIR/t11-buffer_pools-rx${n}.txt"
	ok "RX=$n: -l / -S / debugfs queue rows and pool rows (${n}×5) match"
done

saved_ip=$(save_iface_ipv4)
iface_down

# v8 while-down: "# down:" comment lines must appear.
bp_down_content=$(cat "$bp")
if ! echo "$bp_down_content" | grep -q '^# down:'; then
	die "T11-down: missing '# down:' comment lines in buffer_pools while down"
fi
ok "T11-down: '# down:' comment lines present while interface is down"

assert_buffer_pools_down "T11-down"
iface_up
restore_iface_ipv4 "$saved_ip"

# After reopen, "# down:" comment lines must be gone.
if grep -q '^# down:' "$bp" 2>/dev/null; then
	die "T11-reopen: '# down:' comment still present after iface_up"
fi
assert_buffer_pools_up "T11-reopen"

[[ -n "${PEER:-}" ]] && assert_rx_alive_after_up "T11-final" "$saved_ip" || true
check_no_oops
log "T11/P11 PASS"
