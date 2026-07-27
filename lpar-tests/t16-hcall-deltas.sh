#!/bin/bash
# T16 — hcall_* ethtool -S deltas on scale-up / scale-down (v4 names)
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

log "=== T16 hcall counter deltas on $IFACE ==="
iface_up
ethtool_rx 4 || die "set rx 4"
sleep 1
assert_rx_geometry 4
snap before_up

ethtool_rx 8 || die "scale-up 4→8"
sleep 1
assert_rx_geometry 8
snap after_up

reg=$(delta before_up after_up hcall_reg_lan_queue)
add=$(delta before_up after_up hcall_add_bufs_queue)
log "scale-up 4→8: hcall_reg_lan_queue Δ=$reg  hcall_add_bufs_queue Δ=$add"
[[ "$reg" -gt 0 ]] || die "expected hcall_reg_lan_queue to increase on scale-up"
[[ "$add" -gt 0 ]] || log "WARN: hcall_add_bufs_queue Δ=0 (may be ok if pools quiet)"

snap before_down
ethtool_rx 4 || die "scale-down 8→4"
sleep 1
assert_rx_geometry 4
snap after_down

free=$(delta before_down after_down hcall_free_lan_queue)
log "scale-down 8→4: hcall_free_lan_queue Δ=$free"
[[ "$free" -gt 0 ]] || die "expected hcall_free_lan_queue to increase on scale-down"

[[ -n "$PEER" ]] && ping_ok || true
check_no_lockup
check_no_oops
log "T16 PASS"
