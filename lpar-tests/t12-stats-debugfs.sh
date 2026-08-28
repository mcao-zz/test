#!/bin/bash
# D11 / T12 — debugfs buffer_pools + v6 ethtool -S name smoke
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
for s in replenish_add_buff_success replenish_add_buff_failure \
	rx_invalid_buffer rx_no_buffer tx_send_failed; do
	v=$(stat_val "$s")
	[[ -n "$v" ]] || die "missing ethtool -S counter: $s"
	log "  $s=$v"
done
ok "v6 adapter counters present"

if ethtool -S "$IFACE" 2>/dev/null | grep -qE '^[[:space:]]*hcall_'; then
	warn "ethtool -S still has hcall_* keys (v6 dropped them — wrong .ko?)"
fi

n=$(current_rx)
rows=$(count_rx_stat_rows)
[[ "$rows" == "$n" ]] || die "rx*_interrupts rows=$rows want $n"
ok "per-queue rx*_interrupts rows=$rows"
[[ -n "$(stat_val rx0_interrupts)" ]] || die "missing rx0_interrupts"
[[ -n "$(stat_val rx0_polls)" ]] || die "missing rx0_polls"
[[ -n "$(stat_val rx0_no_buffer_drops)" ]] || die "missing rx0_no_buffer_drops"

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
