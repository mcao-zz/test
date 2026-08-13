#!/bin/bash
# D11 / T12 — debugfs buffer_pools + v4 ethtool -S name smoke
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark
iface_up

log "=== D11/T12 stats + debugfs on $IFACE ==="

# v4 ethtool names must exist
for s in hcall_reg_lan hcall_reg_lan_queue hcall_add_bufs_queue \
	hcall_free_lan_queue replenish_add_buff_success rx_invalid_buffer; do
	v=$(stat_val "$s")
	[[ -n "$v" ]] || die "missing ethtool -S counter: $s"
	log "  $s=$v"
done
ok "v4 hcall_*/core counters present"

n=$(current_rx)
rows=$(count_rx_stat_rows)
[[ "$rows" == "$n" ]] || die "rx*_packets rows=$rows want $n"
ok "per-queue rx*_packets rows=$rows"

# debugfs buffer_pools — must exist and look live while UP
bp=$(iface_buffer_pools) || die "missing debugfs buffer_pools (IFACE=$IFACE)"
ok "buffer_pools at $bp"
head -20 "$bp" | tee "$LOGDIR/buffer_pools.txt" >/dev/null
assert_buffer_pools_up "T12"
# Soft format check
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
