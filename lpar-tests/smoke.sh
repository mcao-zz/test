#!/bin/bash
# T1 + T3 smoke: SQ churn, then MQ open + ping
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${T1_ROUNDS:=50}"
: "${PING_RECOVER_SECS:=30}"

need_root
need_peer
save_dmesg_mark

saved_ip=$(save_iface_ipv4)
log "saved IPv4: ${saved_ip:-none}"

log "=== T1 SQ ifdown/up churn ($T1_ROUNDS) on $IFACE ==="
ethtool_rx 1 || log "ethtool -L rx 1 returned $? (ok if already 1)"
iface_up
restore_iface_ipv4 "$saved_ip"
for i in $(seq 1 "$T1_ROUNDS"); do
	iface_down
	iface_up
done
# Rapid down/up can drop addr or leave carrier settling — restore + wait.
restore_iface_ipv4 "$saved_ip"
sleep 1
ping_recover "${PING_RECOVER_SECS}"
check_no_lockup
ok "T1 SQ churn done"

log "=== T3 MQ open (rx=4) + ping flood ==="
iface_down
ethtool_rx 4 || ethtool_rx 2 || die "cannot set MQ rx queues"
iface_up
restore_iface_ipv4 "$saved_ip"
sleep 1
ping -f -c 200 -W 1 "$PEER" >/dev/null || die "ping flood failed after MQ open"
ping_recover 10
check_no_lockup

log "SMOKE PASS"
