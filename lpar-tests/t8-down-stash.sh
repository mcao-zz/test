#!/bin/bash
# T8 / T17 — ethtool -L while down: stash only, apply on open (P13)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${STASH_RX:=4}"

need_root
need_peer
save_dmesg_mark

log "=== T8/T17 down-state RX stash → $STASH_RX on $IFACE ==="

iface_up
ethtool_rx "$(max_rx)" || true
log "up baseline irqs=$(count_iface_irqs) rx=$(current_rx)"

iface_down
sleep 1
save_dmesg_mark
ethtool_rx "$STASH_RX" || die "ethtool -L rx $STASH_RX while down failed"
dmesg_delta "$LOGDIR/t8-stash-dmesg.txt"

reg=$(grep -cE "Registered queue|Successfully resized" "$LOGDIR/t8-stash-dmesg.txt" || true)
if [[ "${reg:-0}" -gt 0 ]]; then
	log "WARN: $reg resize/register lines while down (review $LOGDIR/t8-stash-dmesg.txt)"
fi

iface_up
sleep 2
got=$(current_rx)
[[ "$got" == "$STASH_RX" ]] || die "after open RX=$got want $STASH_RX"
assert_rx_geometry "$STASH_RX"
ping_ok
check_no_lockup
check_no_oops
log "T8/T17 PASS (stashed $STASH_RX applied on open)"
