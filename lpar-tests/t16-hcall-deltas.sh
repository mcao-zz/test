#!/bin/bash
# T16 — scale-up / scale-down side effects (v6: no hcall_* on ethtool -S)
#
# Geometry + replenish_add_buff_success replace the old hcall_reg/add/free
# counters. New queues must be filled. Per-queue leftover -S keys are gone
# in s2; live IRQ count from /proc/interrupts is the geometry check.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark

snap() {
	local tag=$1
	ethtool -S "$IFACE" > "$LOGDIR/t16-$tag.txt"
}

delta() {
	local before=$1 after=$2 name=$3
	local b a
	b=$(awk -v n="$name" '$1 == n":" { print $2; exit }' "$LOGDIR/t16-$before.txt")
	a=$(awk -v n="$name" '$1 == n":" { print $2; exit }' "$LOGDIR/t16-$after.txt")
	b=${b:-0}; a=${a:-0}
	echo $((a - b))
}

log "=== T16 scale-up/down side effects on $IFACE ==="
iface_up
ethtool_rx 4 || die "set rx 4"
sleep 1
assert_rx_geometry 4
snap before_up
[[ "$(count_iface_irqs)" -eq 4 ]] || die "IRQs at RX=4: $(count_iface_irqs)"

ethtool_rx 8 || die "scale-up 4→8"
sleep 1
assert_rx_geometry 8
snap after_up

rep=$(delta before_up after_up replenish_add_buff_success)
log "scale-up 4→8: replenish_add_buff_success Δ=$rep"
[[ "$rep" -gt 0 ]] || die "expected replenish_add_buff_success to increase on scale-up (new queues need buffers)"
[[ "$(count_iface_irqs)" -eq 8 ]] || die "IRQs after scale-up: $(count_iface_irqs) want 8"
ok "scale-up: replenish Δ=$rep geometry RX=8 irqs=8"

snap before_down
ethtool_rx 4 || die "scale-down 8→4"
sleep 1
assert_rx_geometry 4
snap after_down

[[ "$(count_iface_irqs)" -eq 4 ]] || die "IRQs after scale-down: $(count_iface_irqs) want 4"
ok "scale-down: geometry RX=4 irqs=4"

[[ -n "$PEER" ]] && ping_ok || true
check_no_lockup
check_no_oops
log "T16 PASS"
