#!/bin/bash
# Ordered suite matching the preferred lab flow:
#
#   1) Quiet: smoke, t8, t12, t19, t16
#   2) Interactive: start DUT iperf servers, prompt for lp7 clients,
#      verify inbound RX counters move
#   3) Heavy: t14-rx-cycle, close-under-load RX=8, parallel-stress
#   4) Stop iperf (if we started it); final ping
#
# Usage:
#   IFACE=env9 PEER=192.168.100.2 sudo ./run-all.sh
#   SKIP_HEAVY=1 ...          # quiet only
#   SKIP_QUIET=1 ...          # heavy only (still prompts for iperf)
#   NONINTERACTIVE=1 ...      # no prompts; inbound must already be flowing
#   SKIP_PARALLEL=1 ...       # skip hang-hunt stress
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer

log "Logs under $LOGDIR"
log "IFACE=$IFACE PEER=$PEER ROOT=$ROOT"
log "See $ROOT/TEST-PLAN.txt / TEST-PLAN-DEEP-DIVE.txt"

run() {
	local name=$1
	shift
	log "######## START $name ########"
	"$@"
	log "######## DONE  $name ########"
}

cleanup() {
	stop_iperf_servers
}
trap cleanup EXIT

# ------------------------------------------------------------------
# Phase 1 — Quiet (no heavy inbound required)
# ------------------------------------------------------------------
if [[ "${SKIP_QUIET:-0}" != 1 ]]; then
	log "========== PHASE 1: QUIET =========="
	[[ "${SKIP_LAB:-0}" = 1 ]] || run lab-smoke "$DIR/lab-smoke.sh"
	[[ "${SKIP_SMOKE:-0}" = 1 ]] || run smoke "$DIR/smoke.sh"
	[[ "${SKIP_STATS:-0}" = 1 ]] || run t12-stats "$DIR/t12-stats-debugfs.sh"
	[[ "${SKIP_STASH:-0}" = 1 ]] || run t8-stash "$DIR/t8-down-stash.sh"
	[[ "${SKIP_CHANNELS:-0}" = 1 ]] || run t19-channels "$DIR/t19-set-channels.sh"
	[[ "${SKIP_HCALL:-0}" = 1 ]] || run t16-hcall "$DIR/t16-hcall-deltas.sh"
	# Optional quiet extras
	[[ "${SKIP_CLOSE_SQ:-0}" = 1 ]] || run close-sq env RX=1 ROUNDS=10 "$DIR/close-under-load.sh"
	[[ "${SKIP_L_CYCLE:-0}" = 1 ]] || run L-cycle env LOOPS=2 IPERF=0 "$DIR/ethtool-L-cycle.sh"
	ok "quiet phase complete"
else
	log "SKIP_QUIET=1 — skipping quiet phase"
fi

# ------------------------------------------------------------------
# Phase 2 — Interactive inbound iperf gate
# ------------------------------------------------------------------
if [[ "${SKIP_HEAVY:-0}" != 1 ]]; then
	log "========== PHASE 2: INBOUND IPERF GATE =========="
	iface_up
	ping_ok
	prompt_start_inbound_iperf

	# ------------------------------------------------------------------
	# Phase 3 — Heavy under confirmed inbound RX
	# ------------------------------------------------------------------
	log "========== PHASE 3: HEAVY (under inbound RX) =========="
	[[ "${SKIP_T14:-0}" = 1 ]] || run t14-cycle "$DIR/t14-rx-cycle.sh"
	[[ "${SKIP_CLOSE_MQ:-0}" = 1 ]] || \
		run close-mq env RX=8 ROUNDS="${HEAVY_ROUNDS:-20}" IPERF=0 \
			"$DIR/close-under-load.sh"
	[[ "${SKIP_PARALLEL:-0}" = 1 ]] || \
		run parallel env DURATION="${STRESS_SECS:-300}" "$DIR/parallel-stress.sh"
	# Optional: cover-letter -L pattern under load (no outbound iperf)
	[[ "${SKIP_L_IPERF:-0}" = 1 ]] || \
		run L-under-rx env LOOPS=3 IPERF=0 "$DIR/ethtool-L-cycle.sh"
	ok "heavy phase complete"
else
	log "SKIP_HEAVY=1 — skipping inbound gate + heavy phase"
fi

# ------------------------------------------------------------------
# Phase 4 — Cleanup + final ping
# ------------------------------------------------------------------
log "========== PHASE 4: CLEANUP =========="
stop_iperf_servers
IPERF_STARTED_BY_US=0
ping_ok
check_no_lockup

log "ALL REQUESTED TESTS PASSED — see $LOGDIR"
log "Deep-dive by patch: $ROOT/TEST-PLAN-DEEP-DIVE.txt"
