#!/bin/bash
# T1 + T3 smoke: SQ churn, then MQ open + ping
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer
save_dmesg_mark

log "=== T1 SQ ifdown/up churn (50) on $IFACE ==="
ethtool_rx 1 || log "ethtool -L rx 1 returned $? (ok if already 1)"
iface_up
for i in $(seq 1 50); do
	iface_down
	iface_up
done
ping_ok
check_no_lockup

log "=== T3 MQ open (rx=4) + ping flood ==="
iface_down
ethtool_rx 4 || ethtool_rx 2 || die "cannot set MQ rx queues"
iface_up
ping -f -c 200 -W 1 "$PEER" >/dev/null || die "ping flood failed after MQ open"
ping_ok
check_no_lockup

log "SMOKE PASS"
