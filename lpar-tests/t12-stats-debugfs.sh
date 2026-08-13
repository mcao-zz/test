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

# debugfs buffer_pools
mapfile -t pools < <(find /sys/kernel/debug -name buffer_pools 2>/dev/null | head -5)
if [[ ${#pools[@]} -eq 0 ]]; then
	log "WARN: no debugfs buffer_pools (debugfs mounted? CONFIG?)"
else
	for f in "${pools[@]}"; do
		log "--- $f ---"
		head -40 "$f" | tee "$LOGDIR/buffer_pools.txt" | head -20
		# Expect queue/pool columns somehow
		grep -qiE 'queue|pool|buff' "$f" || log "WARN: unexpected format"
	done
	ok "debugfs buffer_pools readable"
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

[[ -n "$PEER" ]] && ping_ok || true
check_no_oops
log "D11/T12 PASS"
