#!/bin/bash
# T20 — module reload restores MQ (P09/open path)
# Reloads ibmveth (affects all ibmveth netdevs on the LPAR).
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t20-reload-restore-mq.sh
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

log "=== T20 module reload restores MQ on $IFACE ==="

iface_up
ethtool_rx "$RELOAD_RX" || die "pre-reload ethtool -L rx $RELOAD_RX failed"
assert_rx_geometry "$RELOAD_RX"
max_before=$(max_rx)
[[ "$max_before" -ge 2 ]] || die "MQ not available before reload (max_rx=$max_before)"
ok "pre-reload MQ max_rx=$max_before RX=$RELOAD_RX"

saved_ip=$(save_iface_ipv4)
log "saved IPv4: ${saved_ip:-none}"
reg_before=$(stat_val hcall_reg_lan_queue); reg_before=${reg_before:-0}

log "bringing down $IFACE and reloading ibmveth..."
iface_down
sleep 1
rmmod ibmveth 2>/dev/null || log "WARN: rmmod ibmveth (may already be unloaded)"
sleep 2
if [[ "$DYNDBG" = 1 ]]; then
	modprobe ibmveth dyndbg=+p || die "modprobe ibmveth dyndbg=+p failed"
else
	modprobe ibmveth || die "modprobe ibmveth failed"
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

reg_after=$(stat_val hcall_reg_lan_queue); reg_after=${reg_after:-0}
reg_delta=$((reg_after - reg_before))
log "hcall_reg_lan_queue: $reg_before → $reg_after (Δ=$reg_delta)"
# Open/reload with MQ should register subordinate queues at some point
[[ "$reg_delta" -ge 1 ]] || log "WARN: hcall_reg_lan_queue Δ=$reg_delta (expected growth on MQ open)"

ping_ok
check_no_lockup
check_no_oops
log "T20 PASS (reload restored MQ)"
