#!/bin/bash
# D13 / T19 — set_channels RX (+ optional TX) while up and stash while down
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t19-set-channels.sh
#   sudo IFACE=env9 PEER=192.168.100.2 TX_SET=2 ./t19-set-channels.sh
#
# TX_STASH: TX count to stash while down alongside RX_STASH (default: 2).
# Set TX_STASH=0 to skip the while-down TX stash section.
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX_UP:=4}"
: "${RX_STASH:=8}"
: "${TX_SET:=}"    # optional e.g. TX_SET=2
: "${TX_STASH:=2}" # TX to stash while down alongside RX_STASH (0=skip)

need_root
need_peer
save_dmesg_mark

log "=== D13/T19 set_channels on $IFACE ==="
iface_up

log "up: ethtool -L rx $RX_UP"
ethtool_rx "$RX_UP" || die "ethtool -L rx $RX_UP failed"
assert_rx_geometry "$RX_UP"

# v8 get_channels: max_tx is floored at live tx count so TX-only -L is never
# rejected due to max_tx < current tx after CPU offline. Verify:
#   (a) max_tx reported by ethtool -l >= current TX
#   (b) TX-only -L (same count) does not shrink live RX (read-modify-write guard)
saved_rx=$(current_rx)
saved_tx=$(current_tx)
[[ -n "$saved_tx" ]] || die "ethtool -l TX not parseable"

# (a) max_tx floor
max_tx=$(ethtool -l "$IFACE" 2>/dev/null | awk '/^Pre-set maximums:/{p=1} p && /^[[:space:]]*TX:/{print $2; exit}')
[[ -n "$max_tx" ]] || die "ethtool -l max TX not parseable"
[[ "$max_tx" -ge "$saved_tx" ]] || \
	die "max_tx=$max_tx < live tx=$saved_tx — max_tx floor missing (get_channels bug)"
ok "max_tx=$max_tx >= live tx=$saved_tx (max_tx floor correct)"

# (b) TX-only -L must not shrink RX
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
ethtool_rx "$RX_STASH" || die "stash RX -L failed"

# v8 set_channels while-down: TX published first, then RX stash.
# Verify that a TX -L while down is also honoured at next open().
if [[ "${TX_STASH:-2}" != "0" ]]; then
	pre_tx=$(current_tx)
	max_tx_down=$(ethtool -l "$IFACE" 2>/dev/null | \
		awk '/^Pre-set maximums:/{p=1} p && /^[[:space:]]*TX:/{print $2; exit}')
	[[ -n "$pre_tx" ]] || die "current_tx not parseable while down"
	[[ -n "$max_tx_down" ]] || die "ethtool -l max TX not parseable while down"
	if [[ "$TX_STASH" -gt "$max_tx_down" ]]; then
		log "WARN: TX_STASH=$TX_STASH > max_tx=$max_tx_down while down; capping to $max_tx_down"
		TX_STASH=$max_tx_down
	fi
	log "down-stash: ethtool -L tx $TX_STASH (pre=$pre_tx max=$max_tx_down)"
	ethtool -L "$IFACE" tx "$TX_STASH" || die "stash TX -L tx $TX_STASH failed while down"
	ok "down-stash TX=$TX_STASH accepted while down"
fi

iface_up
sleep 2
assert_rx_geometry "$RX_STASH"

if [[ "${TX_STASH:-2}" != "0" ]]; then
	# v8: TX stash published at set_channels(while-down); must survive open().
	got_tx=$(current_tx)
	[[ -n "$got_tx" ]] || die "current_tx not parseable after reopen"
	[[ "$got_tx" == "$TX_STASH" ]] || \
		die "TX after reopen=$got_tx want TX_STASH=$TX_STASH — while-down TX stash not honoured"
	ok "TX stash honoured after reopen: TX=$got_tx"
elif [[ -n "$TX_SET" ]]; then
	got_tx=$(current_tx)
	log "after reopen TX=$got_tx (requested TX_SET=$TX_SET)"
	[[ -n "$got_tx" ]] || die "TX not parseable after reopen"
fi
ping_ok

check_no_lockup
check_no_oops
log "D13/T19 PASS"
