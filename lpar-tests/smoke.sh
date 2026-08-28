#!/bin/bash
# T1 + T3 smoke: SQ churn, then MQ open + ping
#
# Gates (lab regressions):
#   - ping uses -I $IFACE (no fake PASS via another NIC)
#   - after ifdown/up: debugfs Count kept + Active when up
#   - RX counters must move on successful ping
#   - IBMVETH_KO srcversion must match loaded module when set
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${T1_ROUNDS:=50}"
: "${PING_RECOVER_SECS:=30}"
# Check pools+ping every N churn rounds (always check first + last).
: "${T1_CHECK_EVERY:=10}"

need_root
need_peer
save_dmesg_mark

assert_ibmveth_ko_loaded

saved_ip=$(save_iface_ipv4)
export RESTORE_IP=$saved_ip
log "saved IPv4: ${saved_ip:-none}"

log "=== T1 SQ ifdown/up churn ($T1_ROUNDS) on $IFACE ==="
ethtool_rx 1 || log "ethtool -L rx 1 returned $? (ok if already 1)"
iface_up
restore_iface_ipv4 "$saved_ip"
assert_rx_alive_after_up "T1-baseline" "$saved_ip"

for i in $(seq 1 "$T1_ROUNDS"); do
	iface_down
	if [[ "$i" -eq 1 || "$i" -eq "$T1_ROUNDS" || $((i % T1_CHECK_EVERY)) -eq 0 ]]; then
		assert_buffer_pools_down "T1-down-$i"
	fi
	iface_up
	restore_iface_ipv4 "$saved_ip"
	if [[ "$i" -eq 1 || "$i" -eq "$T1_ROUNDS" || $((i % T1_CHECK_EVERY)) -eq 0 ]]; then
		assert_rx_alive_after_up "T1-up-$i" "$saved_ip"
	fi
done
# Final recover still goes through -I IFACE + RX counter + pools.
restore_iface_ipv4 "$saved_ip"
sleep 1
ping_recover "${PING_RECOVER_SECS}"
check_no_lockup
ok "T1 SQ churn done"

log "=== T3 MQ open (rx=4) + ping flood ==="
iface_down
assert_buffer_pools_down "T3-down"
ethtool_rx 4 || ethtool_rx 2 || die "cannot set MQ rx queues"
iface_up
restore_iface_ipv4 "$saved_ip"
sleep 1
assert_rx_alive_after_up "T3-up" "$saved_ip"
ping -I "$IFACE" -f -c 200 -W 1 "$PEER" >/dev/null || \
	die "ping flood -I $IFACE failed after MQ open"
ping_recover 10
check_no_lockup

log "SMOKE PASS"
