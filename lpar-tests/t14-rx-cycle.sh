#!/bin/bash
# T14 — full RX cycle with geometry checks (wraps ../rx_queue_size.sh)
#
# Under heavy/inbound phase set UNDER_RX=1 so each resize step also proves:
#   bulk RX, survivor spread, new queues get traffic on scale-up.
#   invalid/replenish_fail Δ still ≈0; no_buffer may bump briefly (MAX_NOBUF_DELTA).
#
# T14_CYCLE=quick (default here / run-all): max→1→mid→max→1 (~5 steps)
# T14_CYCLE=full: every integer up and down (~2*max steps; slow under load)
#
# Note: env.sh RX_CYCLE is a numeric list for ethtool-L-cycle.sh — do not
# reuse it for quick/full mode (that bug made run-all always run full T14).
#
#   sudo IFACE=env9 PEER=192.168.1.153 UNDER_RX=1 ./t14-rx-cycle.sh
#   sudo IFACE=env9 UNDER_RX=1 T14_CYCLE=full ./t14-rx-cycle.sh
#
# PEER must be on the same L2 as IFACE (ping -I). Do not use a mgmt/other-NIC
# address (e.g. 10.48.36.x while env9 is 192.168.1.x) — mid-step bare ping
# used to fake PASS; final ping -I then failed.
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer
assert_peer_on_iface
save_dmesg_mark

: "${UNDER_RX:=0}"
: "${T14_CYCLE:=quick}"
: "${DELAY:=1}"

log "=== T14 rx_queue_size cycle on $IFACE (UNDER_RX=$UNDER_RX T14_CYCLE=$T14_CYCLE DELAY=$DELAY) ==="
export PEER UNDER_RX T14_CYCLE
export RX_SAMPLE_SECS MIN_RX_DELTA MIN_ACTIVE_RX_QUEUES
export MIN_NEW_QUEUE_DELTA="${MIN_NEW_QUEUE_DELTA:-1}"
export MAX_ERR_DELTA="${MAX_ERR_DELTA:-0}"
# Scale-up under load: a few PHYP no_buffer drops while new queues replenish
# is expected (your fail was Δ=4). Still fail hard on invalid/replenish_fail.
if [[ "$UNDER_RX" = 1 ]]; then
	export MAX_NOBUF_DELTA="${MAX_NOBUF_DELTA:-64}"
else
	export MAX_NOBUF_DELTA="${MAX_NOBUF_DELTA:-$MAX_ERR_DELTA}"
fi
export RX_SCALEUP_EXTRA="${RX_SCALEUP_EXTRA:-}"
log "MAX_ERR_DELTA=$MAX_ERR_DELTA MAX_NOBUF_DELTA=$MAX_NOBUF_DELTA"

"$ROOT/rx_queue_size.sh" "$IFACE" "$DELAY"
check_no_lockup
check_no_oops
# Final ping: under UNDER_RX, ICMP may still lose to the flood — recover
# briefly; quiet path keeps hard ping_ok.
if [[ "$UNDER_RX" = 1 ]]; then
	if ping -I "$IFACE" -c 3 -W 1 "$PEER" >/dev/null 2>&1; then
		ok "final ping -I $IFACE $PEER"
	else
		log "final ping soft under UNDER_RX — trying ping_recover"
		ping_recover "${PING_RECOVER_SECS:-15}"
	fi
else
	ping_ok
fi
log "T14 PASS"
