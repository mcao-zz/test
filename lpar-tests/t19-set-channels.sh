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

if [[ -n "$TX_SET" ]]; then
	log "up: ethtool -L tx $TX_SET"
	ethtool -L "$IFACE" tx "$TX_SET" || die "ethtool -L tx $TX_SET failed"
	sleep 1
	assert_tx_geometry "$TX_SET"
	if have_iperf3; then
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
