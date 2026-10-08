#!/bin/bash
# D11 / T12 — debugfs buffer_pools + v8 ethtool -S name smoke
#
# v8 ethtool -S per-queue keys: rx%d_{interrupts,polls,large_packets,invalid_buffers}
#                                tx%d_send_failures
# no_buffer_drops is NOT in ethtool -S; it feeds netdev_stat_ops:
#   get_queue_stats_rx: hw_drop_overruns = no_buffer_pair (live+retired)
#                       hw_drops         = no_buffer_pair + invalid_buffers
#                       alloc_fail       = replenish_no_mem
# Read per-queue hw_drop_overruns via: ip -s link show dev $IFACE  (aggregate)
# or: netdev qstats (netlink netdev-genl, newer iproute2)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark
iface_up

log "=== D11/T12 stats + debugfs on $IFACE ==="

# v6 ethtool -S: adapter keys + per-queue extras. packets/bytes/drops are
# netdev_stat_ops (sysfs / ip -s link), not -S. hcall_* were dropped.
for s in replenish_no_mem replenish_add_buff_failure replenish_add_buff_success \
	rx_invalid_buffer rx_no_buffer tx_send_failed; do
	v=$(stat_val "$s")
	[[ -n "$v" ]] || die "missing ethtool -S counter: $s"
	log "  $s=$v"
done
ok "v6 adapter counters present"

if ethtool -S "$IFACE" 2>/dev/null | grep -qE '^[[:space:]]*hcall_'; then
	warn "ethtool -S still has hcall_* keys (v6 dropped them — wrong .ko?)"
fi

# Per-queue packets/bytes are in qstats only (NETDEV_CMD_QSTATS_GET).
# Upstream reviewer consistently asked for netdev_stat_ops, not private
# ethtool -S strings, for standard counters. Design is settled.
# See t24-qstats-abi.sh for the validation of that path.
if ethtool -S "$IFACE" 2>/dev/null | grep -qE '^[[:space:]]*rx[0-9]+_packets:'; then
	warn "rx%d_packets present in ethtool -S — should be qstats-only; wrong .ko?"
else
	ok "rx%d_packets correctly absent from ethtool -S (per-queue packets via qstats)"
fi

n=$(current_rx)
rows=$(count_rx_stat_rows)
[[ "$rows" == "$n" ]] || die "rx*_interrupts rows=$rows want $n"
ok "per-queue rx*_interrupts rows=$rows"
[[ -n "$(stat_val rx0_interrupts)" ]] || die "missing rx0_interrupts"
[[ -n "$(stat_val rx0_polls)" ]] || die "missing rx0_polls"
# rx0_no_buffer_drops is NOT an ethtool -S key in v8. no_buffer_drops feeds
# netdev_stat_ops get_queue_stats_rx: hw_drop_overruns = no_buffer_pair,
# hw_drops = no_buffer_pair + invalid_buffers, alloc_fail = replenish_no_mem.
# Verify the sysfs aggregate rx_missed_errors path is reachable as a proxy.
sysfs_missed=$(cat "/sys/class/net/${IFACE}/statistics/rx_missed_errors" 2>/dev/null || true)
if [[ -n "$sysfs_missed" ]]; then
	ok "sysfs rx_missed_errors=$sysfs_missed (hw_drop_overruns proxy reachable)"
else
	log "WARN: /sys/class/net/$IFACE/statistics/rx_missed_errors not readable"
fi

# debugfs buffer_pools — must exist and look live while UP
bp=$(iface_buffer_pools) || die "missing debugfs buffer_pools (IFACE=$IFACE)"
ok "buffer_pools at $bp"
head -20 "$bp" | tee "$LOGDIR/buffer_pools.txt" >/dev/null
assert_buffer_pools_up "T12"
grep -qiE 'Count' "$bp" || log "WARN: buffer_pools header missing Count (v6 name)"
grep -qiE 'queue|pool|buff' "$bp" || log "WARN: unexpected buffer_pools format"

# historical pool0 sysfs still there (under netdev)
if [[ -d /sys/class/net/$IFACE/pool0 ]] || \
   [[ -d /sys/class/net/$IFACE/device/pool0 ]] || \
   find /sys/class/net/$IFACE -maxdepth 2 -type d -name 'pool[0-9]' 2>/dev/null | head -1 | grep -q .; then
	ok "pool0 sysfs present (Q0 ABI)"
else
	# path varies; soft
	log "WARN: could not find pool0 sysfs (check: ls /sys/class/net/$IFACE/pool*)"
fi

saved_ip=$(save_iface_ipv4)
iface_down
assert_buffer_pools_down "T12-down"
iface_up
restore_iface_ipv4 "$saved_ip"
assert_rx_alive_after_up "T12-reopen" "$saved_ip"

[[ -n "$PEER" ]] && ping_ok || true
check_no_oops
log "D11/T12 PASS"
