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
rows_down=$(grep -cE '^[[:space:]]*rx[0-9]+_packets:' "$LOGDIR/t10-stats-down.txt") || true
rows_down=${rows_down:-0}
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

# v5: adapter rx_no_buffer must stay monotonic across reopen / -L reuse
# (rx_no_buffer_retired carries PHYP page-absolute decreases).
nobuf_a=$(stat_val rx_no_buffer); nobuf_a=${nobuf_a:-0}
log "rx_no_buffer after reopen=$nobuf_a (baseline while DOWN was checked parseable)"
nobuf_down=$(awk '$1 == "rx_no_buffer:" { print $2; exit }' "$LOGDIR/t10-stats-down.txt")
nobuf_down=${nobuf_down:-0}
[[ "$nobuf_a" -ge "$nobuf_down" ]] || \
	die "rx_no_buffer went backwards on reopen: down=$nobuf_down reup=$nobuf_a"

# Shrink then grow: adapter sum must not drop when queue slots are reused.
shrink=1
[[ "$RX" -gt 1 ]] || shrink=1
ethtool_rx "$shrink" || die "ethtool -L rx $shrink (shrink) failed"
sleep 1
nobuf_b=$(stat_val rx_no_buffer); nobuf_b=${nobuf_b:-0}
log "rx_no_buffer after -L rx $shrink: $nobuf_a → $nobuf_b"
[[ "$nobuf_b" -ge "$nobuf_a" ]] || \
	die "rx_no_buffer went backwards on -L shrink: $nobuf_a → $nobuf_b"

ethtool_rx "$RX" || die "ethtool -L rx $RX (restore) failed"
sleep 1
nobuf_c=$(stat_val rx_no_buffer); nobuf_c=${nobuf_c:-0}
log "rx_no_buffer after -L rx $RX restore: $nobuf_b → $nobuf_c"
[[ "$nobuf_c" -ge "$nobuf_b" ]] || \
	die "rx_no_buffer went backwards on -L grow: $nobuf_b → $nobuf_c"
ok "rx_no_buffer monotonic across reopen + -L ($nobuf_down → $nobuf_a → $nobuf_b → $nobuf_c)"

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
