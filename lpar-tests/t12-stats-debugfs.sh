#!/bin/bash
# D11 / T12 — debugfs buffer_pools + adapter ethtool -S name smoke
#
# s2 ethtool -S is the 13 adapter keys only. Per-queue packets/bytes/drops
# are netdev_stat_ops (t24). Leftover v8 rxN_interrupts / rxN_polls are gone.
# s2 v9 has no debugfs: the buffer_pools part is skipped when the file is
# absent (EXPECT_DEBUGFS=1 makes it required again, for v8 kernels).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark
iface_up

log "=== D11/T12 stats + debugfs on $IFACE ==="

# Adapter ethtool -S keys. packets/bytes/drops are netdev_stat_ops
# (sysfs / ip -s link / qstats), not -S. hcall_* were dropped.
for s in replenish_no_mem replenish_add_buff_failure replenish_add_buff_success \
	rx_invalid_buffer rx_no_buffer tx_send_failed; do
	v=$(stat_val "$s")
	[[ -n "$v" ]] || die "missing ethtool -S counter: $s"
	log "  $s=$v"
done
ok "adapter counters present"

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

assert_rx_geometry "$(current_rx)"
if ethtool -S "$IFACE" 2>/dev/null | grep -qE '^[[:space:]]*rx[0-9]+_interrupts:'; then
	warn "rx%d_interrupts present in ethtool -S — s2 leftover keys are qstats /proc/interrupts"
else
	ok "rx%d_interrupts correctly absent from ethtool -S"
fi
# no_buffer feeds netdev_stat_ops get_queue_stats_rx (s2 v9):
# hw_drops = hw_drop_overruns = the queue's rx_no_buffer total,
# alloc_fail = replenish_no_mem + copybreak allocation failures.
# sysfs rx_missed_errors is the aggregate proxy.
sysfs_missed=$(cat "/sys/class/net/${IFACE}/statistics/rx_missed_errors" 2>/dev/null || true)
if [[ -n "$sysfs_missed" ]]; then
	ok "sysfs rx_missed_errors=$sysfs_missed (hw_drop_overruns proxy reachable)"
else
	log "WARN: /sys/class/net/$IFACE/statistics/rx_missed_errors not readable"
fi

# debugfs buffer_pools (v8 only) — must exist and look live while UP
if bp=$(iface_buffer_pools); then
	ok "buffer_pools at $bp"
	head -20 "$bp" | tee "$LOGDIR/buffer_pools.txt" >/dev/null
	assert_buffer_pools_up "T12"
	grep -qiE 'Count' "$bp" || log "WARN: buffer_pools header missing Count (v6 name)"
	grep -qiE 'queue|pool|buff' "$bp" || log "WARN: unexpected buffer_pools format"
elif [[ "${EXPECT_DEBUGFS:-0}" = 1 ]]; then
	die "missing debugfs buffer_pools (IFACE=$IFACE, EXPECT_DEBUGFS=1)"
else
	ok "skip buffer_pools (no debugfs in s2 v9)"
fi

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
