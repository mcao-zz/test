#!/bin/bash
# T20 smoke — wrap verify + optional full suite monolith
# LAB_FULL=1 also runs ../test-veth-mq.sh
# VERIFY_RELOAD=0 skips verify -D when run-all already did dyndbg load.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer
save_dmesg_mark

log "=== T20-ish: verify-mq-adapter then optional test-veth-mq ==="
if [[ "${VERIFY_RELOAD:-1}" = 1 ]]; then
	"$ROOT/verify-mq-adapter.sh" -d "$IFACE" -D -v
else
	log "VERIFY_RELOAD=0 — verify without module reload (dyndbg already on)"
	"$ROOT/verify-mq-adapter.sh" -d "$IFACE" -v
fi

if [[ "${LAB_FULL:-0}" = 1 ]]; then
	"$ROOT/test-veth-mq.sh" -d "$IFACE" -t "$PEER"
fi

ping_ok
check_no_lockup
log "T20/lab-smoke PASS"
