#!/bin/bash
# T26 / N1 — ethtool -L TX shrink under traffic (RX unchanged)
#
# Cover claim: TX shrink under traffic. s1 set_channels is TX-only;
# net-fixes N1 is the NULL LTB drop on a removed queue.
#
#   sudo IFACE=env9 PEER=192.168.1.153 ./t26-tx-shrink.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${TX_SHRINK:=1}"

need_root
need_peer
save_dmesg_mark

log "=== T26 TX shrink under traffic on $IFACE ==="
iface_up
ping_ok

orig_rx=$(current_rx)
orig_tx=$(current_tx)
[[ -n "$orig_rx" ]] || die "ethtool -l RX not parseable"
[[ -n "$orig_tx" ]] || die "ethtool -l TX not parseable"
[[ "$orig_tx" -ge 1 ]] || die "current TX=$orig_tx"

if [[ "$orig_tx" -le "$TX_SHRINK" ]]; then
	grow=$((TX_SHRINK + 1))
	log "TX=$orig_tx already <= shrink target $TX_SHRINK; grow to $grow first"
	ethtool -L "$IFACE" tx "$grow" || die "ethtool -L tx $grow failed"
	sleep 1
	assert_tx_geometry "$grow"
	orig_tx=$grow
fi

got_rx=$(current_rx)
[[ "$got_rx" == "$orig_rx" ]] || die "TX grow changed RX ($orig_rx → $got_rx)"

# Outbound traffic so a live xmit can sit on a queue we are about to remove.
# EXTERNAL_IPERF is inbound RX; ping -I still generates TX.
ping -I "$IFACE" -f "$PEER" >/dev/null 2>&1 &
flood_pid=$!
sleep 1

log "ethtool -L tx $TX_SHRINK under ping flood (was TX=$orig_tx RX=$orig_rx)"
if ! ethtool -L "$IFACE" tx "$TX_SHRINK"; then
	kill "$flood_pid" 2>/dev/null || true
	wait "$flood_pid" 2>/dev/null || true
	die "ethtool -L tx $TX_SHRINK failed under traffic"
fi
sleep 1
kill "$flood_pid" 2>/dev/null || true
wait "$flood_pid" 2>/dev/null || true

assert_tx_geometry "$TX_SHRINK"
got_rx=$(current_rx)
[[ "$got_rx" == "$orig_rx" ]] || die "TX shrink changed RX ($orig_rx → $got_rx)"
ok "TX-only -L kept RX=$got_rx"

ping_ok
check_no_oops

log "restore TX=$orig_tx"
ethtool -L "$IFACE" tx "$orig_tx" || die "restore ethtool -L tx $orig_tx failed"
sleep 1
assert_tx_geometry "$orig_tx"
got_rx=$(current_rx)
[[ "$got_rx" == "$orig_rx" ]] || die "TX restore changed RX ($orig_rx → $got_rx)"
ping_ok
check_no_oops
ok "T26 PASS (TX $orig_tx → $TX_SHRINK → $orig_tx under traffic, RX=$orig_rx)"
