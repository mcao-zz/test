#!/bin/bash
# D13 / T19 — set_channels RX (+ optional TX) while up and stash while down
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t19-set-channels.sh
#   sudo IFACE=env9 PEER=192.168.100.2 TX_SET=2 ./t19-set-channels.sh
#
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
assert_rx_geometry "$RX_UP"

# v6 get_channels: TX-only ethtool -L is read-modify-write of rx_count.
# Capping max_rx (not clamping rx_count) must not shrink live RX.
saved_rx=$(current_rx)
saved_tx=$(current_tx)
[[ -n "$saved_tx" ]] || die "ethtool -l TX not parseable"
log "TX-only -L tx $saved_tx (must keep RX=$saved_rx)"
ethtool -L "$IFACE" tx "$saved_tx" || die "TX-only ethtool -L tx $saved_tx failed"
got_rx=$(current_rx)
[[ "$got_rx" == "$saved_rx" ]] || \
	die "TX-only -L silently shrank RX ($saved_rx → $got_rx)"
ok "TX-only -L kept RX=$got_rx"

if [[ -n "$TX_SET" ]]; then
	log "up: ethtool -L tx $TX_SET"
	ethtool -L "$IFACE" tx "$TX_SET" || die "ethtool -L tx $TX_SET failed"
	sleep 1
	assert_tx_geometry "$TX_SET"
	if [[ "${EXTERNAL_IPERF:-0}" = 1 ]]; then
		log "EXTERNAL_IPERF=1 — skip short outbound iperf (lab owns traffic)"
	elif have_iperf3; then
		log "short outbound iperf to exercise TX=$TX_SET"
		"$IPERF3" -c "$PEER" -t 5 -P 2 >"$LOGDIR/t19-iperf-tx.log" 2>&1 || \
			log "WARN: outbound iperf failed (peer iperf3 -s listening?); TX geometry still asserted"
	fi
fi
ping_ok

log "down-stash: ethtool -L rx $RX_STASH"
iface_down
ethtool_rx "$RX_STASH" || die "stash -L failed"
iface_up
sleep 2
assert_rx_geometry "$RX_STASH"
if [[ -n "$TX_SET" ]]; then
	# TX may reset on reopen depending on driver; assert current is parseable
	got_tx=$(current_tx)
	log "after reopen TX=$got_tx (requested TX_SET=$TX_SET)"
	[[ -n "$got_tx" ]] || die "TX not parseable after reopen"
fi
ping_ok

check_no_lockup
check_no_oops
log "D13/T19 PASS"
