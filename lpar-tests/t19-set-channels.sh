#!/bin/bash
# D13 / T19 — set_channels RX (+ optional TX) while up and stash while down
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX_UP:=4}"
: "${RX_STASH:=8}"
: "${TX_SET:=}"   # optional e.g. TX_SET=2

need_root
need_peer
save_dmesg_mark

log "=== D13/T19 set_channels on $IFACE ==="
iface_up

log "up: ethtool -L rx $RX_UP"
ethtool_rx "$RX_UP" || die "ethtool -L rx $RX_UP failed"
if [[ -n "$TX_SET" ]]; then
	ethtool -L "$IFACE" tx "$TX_SET" || die "ethtool -L tx $TX_SET failed"
fi
sleep 1
assert_rx_geometry "$RX_UP"
ping_ok

log "down-stash: ethtool -L rx $RX_STASH"
iface_down
ethtool_rx "$RX_STASH" || die "stash -L failed"
iface_up
sleep 2
assert_rx_geometry "$RX_STASH"
ping_ok

check_no_lockup
check_no_oops
log "D13/T19 PASS"
