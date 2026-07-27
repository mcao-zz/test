#!/bin/bash
# T20 smoke — wrap verify + optional full suite monolith
# LAB_FULL=1 also runs ../test-veth-mq.sh
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer
save_dmesg_mark

log "=== T20-ish: verify-mq-adapter then optional test-veth-mq ==="
"$ROOT/verify-mq-adapter.sh" -d "$IFACE" -D -v

if [[ "${LAB_FULL:-0}" = 1 ]]; then
	"$ROOT/test-veth-mq.sh" -d "$IFACE" -t "$PEER"
fi

ping_ok
check_no_lockup
log "T20/lab-smoke PASS"
