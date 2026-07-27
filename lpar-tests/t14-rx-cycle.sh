#!/bin/bash
# T14 — full RX cycle with geometry checks (wraps ../rx_queue_size.sh)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark

log "=== T14 rx_queue_size geometry cycle on $IFACE ==="
export PEER
"$ROOT/rx_queue_size.sh" "$IFACE" "${DELAY:-2}"
check_no_lockup
check_no_oops
[[ -n "$PEER" ]] && ping_ok || log "PEER unset — skip final ping"
log "T14 PASS"
