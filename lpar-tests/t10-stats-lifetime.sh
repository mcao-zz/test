#!/bin/bash
# T10 / P10 — per-queue stats lifetime across ifdown/up
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t10-stats-lifetime.sh
#   UNDER_RX=1 ...   # also require counters to climb after reopen
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX:=4}"
: "${UNDER_RX:=0}"

need_root
need_peer
save_dmesg_mark

log "=== T10/P10 stats lifetime on $IFACE (RX=$RX) ==="
iface_up
ethtool_rx "$RX" || die "ethtool -L rx $RX failed"
assert_rx_geometry "$RX"

ethtool -S "$IFACE" >"$LOGDIR/t10-stats-up.txt" || die "ethtool -S failed while UP"
rows_up=$(count_rx_stat_rows)
[[ "$rows_up" == "$RX" ]] || die "UP rx*_packets rows=$rows_up want $RX"
ok "ethtool -S readable while UP (rows=$rows_up)"

iface_down
sleep 1
if ! ethtool -S "$IFACE" >"$LOGDIR/t10-stats-down.txt" 2>"$LOGDIR/t10-stats-down.err"; then
	die "ethtool -S failed while DOWN (see $LOGDIR/t10-stats-down.err)"
fi
# Rows may still reflect last published geometry while adapter alive
rows_down=$(grep -cE '^[[:space:]]*rx[0-9]+_packets:' "$LOGDIR/t10-stats-down.txt" || echo 0)
[[ "$rows_down" -ge 1 ]] || die "DOWN: no rx*_packets rows (corrupt/empty stats)"
ok "ethtool -S readable while DOWN (rx*_packets rows=$rows_down)"

# Spot-check a few named counters remain parseable
for s in rx_invalid_buffer rx_no_buffer replenish_add_buff_success; do
	v=$(awk -v n="$s" '$1 == n":" { print $2; exit }' "$LOGDIR/t10-stats-down.txt")
	[[ -n "$v" ]] || die "DOWN: missing counter $s"
done
ok "core counters present while DOWN"

iface_up
sleep 2
ethtool -S "$IFACE" >"$LOGDIR/t10-stats-reup.txt" || die "ethtool -S failed after UP"
assert_rx_geometry "$RX"
ok "stats + geometry sane after reopen"

if [[ "$UNDER_RX" = 1 ]]; then
	a=$(sum_rx_packets)
	sleep "${RX_SAMPLE_SECS:-5}"
	b=$(sum_rx_packets)
	d=$((b - a))
	log "post-reopen RX packets Δ=$d over ${RX_SAMPLE_SECS:-5}s"
	[[ "$d" -ge "${MIN_RX_DELTA:-10000}" ]] || \
		die "post-reopen counters not increasing under traffic (Δ=$d)"
	ok "counters continue increasing after reopen"
fi

ping_ok
check_no_oops
log "T10/P10 PASS"
