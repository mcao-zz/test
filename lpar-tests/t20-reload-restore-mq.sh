#!/bin/bash
# T20 — module reload restores MQ (P09/open path)
# Reloads ibmveth (affects all ibmveth netdevs on the LPAR).
# Quiet-phase test: does NOT need lp7 iperf / under-traffic.
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t20-reload-restore-mq.sh
#   sudo IFACE=env9 PEER=... IBMVETH_KO=/home/ming/ibmveth-build ./t20-reload-restore-mq.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RELOAD_RX:=8}"
: "${DYNDBG:=1}"

need_root
need_peer
save_dmesg_mark

if [[ "${EXTERNAL_IPERF:-0}" = 1 ]]; then
	log "=== T20 module reload restores MQ on $IFACE (EXTERNAL_IPERF — leave lab iperf alone) ==="
else
	log "=== T20 module reload restores MQ on $IFACE (quiet — no iperf) ==="
fi

iface_up
ethtool_rx "$RELOAD_RX" || die "pre-reload ethtool -L rx $RELOAD_RX failed"
assert_rx_geometry "$RELOAD_RX"
max_before=$(max_rx)
[[ "$max_before" -ge 2 ]] || die "MQ not available before reload (max_rx=$max_before)"
ok "pre-reload MQ max_rx=$max_before RX=$RELOAD_RX"

saved_ip=$(save_iface_ipv4)
log "saved IPv4: ${saved_ip:-none}"

log "bringing down $IFACE and reloading ibmveth (IBMVETH_KO=${IBMVETH_KO:-modprobe})..."
iface_down
sleep 1
rmmod ibmveth 2>/dev/null || log "WARN: rmmod ibmveth (may already be unloaded)"
sleep 2
if [[ "$DYNDBG" = 1 ]]; then
	load_ibmveth "+p"
else
	load_ibmveth
fi
sleep 3

ip link show "$IFACE" >/dev/null || die "netdev $IFACE missing after reload"
iface_up
restore_iface_ipv4 "$saved_ip"
sleep 2

max_after=$(max_rx)
[[ "$max_after" -ge 2 ]] || die "MQ not available after reload (max_rx=$max_after)"
ok "post-reload MQ max_rx=$max_after"

ethtool_rx "$RELOAD_RX" || die "post-reload ethtool -L rx $RELOAD_RX failed"
sleep 1
assert_rx_geometry "$RELOAD_RX"

# Stats reset on rmmod — do NOT compare to pre-reload absolute values.
# v6 has no hcall_* on ethtool -S; MQ open must post buffers (replenish_ok grows).
rep_base=$(stat_val replenish_add_buff_success); rep_base=${rep_base:-0}
log "post-reload baseline replenish_add_buff_success=$rep_base — measuring open Δ via ifdown/up"
iface_down
sleep 1
iface_up
sleep 2
ethtool_rx "$RELOAD_RX" || true
sleep 1
assert_rx_geometry "$RELOAD_RX"

rep_after=$(stat_val replenish_add_buff_success); rep_after=${rep_after:-0}
rep_delta=$((rep_after - rep_base))
log "replenish_add_buff_success after reopen: $rep_base → $rep_after (Δ=$rep_delta)"
[[ "$rep_delta" -ge 1 ]] || \
	die "expected replenish_add_buff_success to increase on post-reload MQ open (Δ=$rep_delta)"
ok "replenish_add_buff_success grew on post-reload open (Δ=$rep_delta)"

ping_ok
check_no_lockup
check_no_oops
log "T20 PASS (reload restored MQ)"
