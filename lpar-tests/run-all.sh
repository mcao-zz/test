#!/bin/bash
# Ordered auto suite — maps to TEST-PLAN.txt
# Skip with SKIP_*=1  e.g. SKIP_PARALLEL=1 ./run-all.sh
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer

log "Logs under $LOGDIR"
log "IFACE=$IFACE PEER=$PEER ROOT=$ROOT"
log "See $ROOT/TEST-PLAN.txt"

run() {
	local name=$1
	shift
	log "######## START $name ########"
	"$@"
	log "######## DONE  $name ########"
}

# Bring-up / broad smoke (lab monoliths)
[[ "${SKIP_LAB:-0}" = 1 ]] || run lab-smoke "$DIR/lab-smoke.sh"

# Plan scripts
[[ "${SKIP_SMOKE:-0}" = 1 ]] || run smoke "$DIR/smoke.sh"
[[ "${SKIP_STATS:-0}" = 1 ]] || run t12-stats "$DIR/t12-stats-debugfs.sh"
[[ "${SKIP_STASH:-0}" = 1 ]] || run t8-stash "$DIR/t8-down-stash.sh"
[[ "${SKIP_CHANNELS:-0}" = 1 ]] || run t19-channels "$DIR/t19-set-channels.sh"
[[ "${SKIP_HCALL:-0}" = 1 ]] || run t16-hcall "$DIR/t16-hcall-deltas.sh"
[[ "${SKIP_T14:-0}" = 1 ]] || run t14-cycle "$DIR/t14-rx-cycle.sh"

[[ "${SKIP_CLOSE_SQ:-0}" = 1 ]] || run close-sq env RX=1 ROUNDS=15 "$DIR/close-under-load.sh"
[[ "${SKIP_CLOSE_MQ:-0}" = 1 ]] || run close-mq env RX=8 ROUNDS=15 "$DIR/close-under-load.sh"
[[ "${SKIP_L_CYCLE:-0}" = 1 ]] || run L-cycle env LOOPS=3 IPERF=0 "$DIR/ethtool-L-cycle.sh"
[[ "${SKIP_L_IPERF:-0}" = 1 ]] || run L-iperf env LOOPS=3 IPERF=1 "$DIR/ethtool-L-cycle.sh"
[[ "${SKIP_PARALLEL:-0}" = 1 ]] || run parallel env DURATION="${STRESS_SECS:-180}" "$DIR/parallel-stress.sh"

log "ALL REQUESTED TESTS PASSED — see $LOGDIR"
log "Deep-dive by patch: $ROOT/TEST-PLAN-DEEP-DIVE.txt"
