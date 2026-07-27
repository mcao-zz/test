#!/bin/bash
# T14 — full RX cycle with geometry checks (wraps ../rx_queue_size.sh)
#
# Under heavy/inbound phase set UNDER_RX=1 so each resize step also proves:
#   error Δ≈0, bulk RX, survivor spread, new queues get traffic on scale-up.
#
#   sudo IFACE=env9 PEER=192.168.100.2 UNDER_RX=1 ./t14-rx-cycle.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark

: "${UNDER_RX:=0}"

log "=== T14 rx_queue_size cycle on $IFACE (UNDER_RX=$UNDER_RX) ==="
export PEER UNDER_RX
export RX_SAMPLE_SECS MIN_RX_DELTA MIN_ACTIVE_RX_QUEUES
export MIN_NEW_QUEUE_DELTA="${MIN_NEW_QUEUE_DELTA:-1}"
export MAX_ERR_DELTA="${MAX_ERR_DELTA:-0}"

"$ROOT/rx_queue_size.sh" "$IFACE" "${DELAY:-2}"
check_no_lockup
check_no_oops
[[ -n "$PEER" ]] && ping_ok || log "PEER unset — skip final ping"
log "T14 PASS"
