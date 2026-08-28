#!/bin/bash
# T16 — scale-up / scale-down side effects (v6: no hcall_* on ethtool -S)
#
# Geometry + replenish_add_buff_success replace the old hcall_reg/add/free
# counters. New queues must be filled; retired keys must disappear.
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

has_key() {
	local tag=$1 name=$2
	awk -v n="$name" '$1 == n":" { found=1 } END { exit !found }' "$LOGDIR/t16-$tag.txt"
}

log "=== T16 scale-up/down side effects on $IFACE ==="
iface_up
ethtool_rx 4 || die "set rx 4"
sleep 1
assert_rx_geometry 4
snap before_up
[[ -z "$(stat_val rx4_interrupts)" ]] || die "rx4_interrupts present at RX=4"

ethtool_rx 8 || die "scale-up 4→8"
sleep 1
assert_rx_geometry 8
snap after_up

rep=$(delta before_up after_up replenish_add_buff_success)
log "scale-up 4→8: replenish_add_buff_success Δ=$rep"
[[ "$rep" -gt 0 ]] || die "expected replenish_add_buff_success to increase on scale-up (new queues need buffers)"
has_key after_up rx4_interrupts || die "expected rx4_interrupts after scale-up to 8"
has_key after_up rx7_interrupts || die "expected rx7_interrupts after scale-up to 8"
ok "scale-up: replenish Δ=$rep and rx4..rx7_interrupts present"

snap before_down
ethtool_rx 4 || die "scale-down 8→4"
sleep 1
assert_rx_geometry 4
snap after_down

has_key after_down rx4_interrupts && die "rx4_interrupts still present after scale-down to 4"
[[ -z "$(stat_val rx4_interrupts)" ]] || die "rx4_interrupts still readable after scale-down to 4"
ok "scale-down: rx4+_interrupts gone; geometry RX=4"

[[ -n "$PEER" ]] && ping_ok || true
check_no_lockup
check_no_oops
log "T16 PASS"
