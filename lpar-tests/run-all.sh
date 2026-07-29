#!/bin/bash
# Ordered suite matching the preferred lab flow:
#
#   0) Optional: reload ibmveth with dyndbg=+p (DYNDBG=1, default)
#   1) Quiet: smoke, t8, t12, t19, t21, t16
#   2) Interactive: start DUT iperf servers, prompt for lp7 clients,
#      prove bulk inbound + MQ RX spread under load
#   3) Heavy: re-prove MQ RX, t14, re-prove, close/parallel/-L with
#      MQ RX proofs between stages (lp7 clients must stay up)
#   4) Final MQ RX proof + ping
#
# Usage:
#   IFACE=env9 PEER=192.168.100.2 sudo ./run-all.sh
#   DYNDBG=1 ...              # default: reload with dyndbg=+p before tests
#   DYNDBG=0 ...              # skip initial debug reload
#   SKIP_HEAVY=1 ...          # quiet only
#   SKIP_QUIET=1 ...          # heavy only (still prompts for iperf)
#   NONINTERACTIVE=1 ...      # no prompts; inbound must already be flowing
#   SKIP_PARALLEL=1 ...       # skip hang-hunt stress
#   SKIP_RSS=1 ...            # skip quiet T21 RSS hfunc
#   SKIP_RSS_RX=1 ...         # skip heavy T21 under-traffic hash switch
#   LAB_FULL=1 ...            # also run ../test-veth-mq.sh from lab-smoke
#   MIN_RX_DELTA=10000 MIN_ACTIVE_RX_QUEUES=2 MQ_PROOF_RX=8 ...
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${DYNDBG:=1}"

need_root
need_peer

log "Logs under $LOGDIR"
log "IFACE=$IFACE PEER=$PEER ROOT=$ROOT DYNDBG=$DYNDBG"
log "MQ proof: MIN_RX_DELTA=$MIN_RX_DELTA / ${RX_SAMPLE_SECS}s, MIN_ACTIVE_RX_QUEUES=$MIN_ACTIVE_RX_QUEUES, MQ_PROOF_RX=$MQ_PROOF_RX"
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
# Phase 0 — Debug module load (dyndbg=+p) before any tests
# ------------------------------------------------------------------
if [[ "$DYNDBG" = 1 ]]; then
	log "========== PHASE 0: DYNDBG MODULE LOAD =========="
	run dyndbg-load ensure_ibmveth_dyndbg
	# Avoid a second reload in lab-smoke (verify -D); keep verbose checks.
	export VERIFY_RELOAD=0
else
	log "DYNDBG=0 — skipping initial dyndbg reload (lab-smoke may still -D)"
	export VERIFY_RELOAD="${VERIFY_RELOAD:-1}"
fi

# ------------------------------------------------------------------
# Phase 1 — Quiet (no heavy inbound required)
# ------------------------------------------------------------------
if [[ "${SKIP_QUIET:-0}" != 1 ]]; then
	log "========== PHASE 1: QUIET =========="
	[[ "${SKIP_LAB:-0}" = 1 ]] || run lab-smoke "$DIR/lab-smoke.sh"
	[[ "${SKIP_SMOKE:-0}" = 1 ]] || run smoke "$DIR/smoke.sh"
	[[ "${SKIP_STATS:-0}" = 1 ]] || run t12-stats "$DIR/t12-stats-debugfs.sh"
	[[ "${SKIP_T10:-0}" = 1 ]] || run t10-lifetime "$DIR/t10-stats-lifetime.sh"
	[[ "${SKIP_T11:-0}" = 1 ]] || run t11-debugfs "$DIR/t11-debugfs-geometry.sh"
	[[ "${SKIP_STASH:-0}" = 1 ]] || run t8-stash "$DIR/t8-down-stash.sh"
	[[ "${SKIP_T17:-0}" = 1 ]] || run t17-down-irqs "$DIR/t17-down-no-live-irqs.sh"
	[[ "${SKIP_CHANNELS:-0}" = 1 ]] || run t19-channels "$DIR/t19-set-channels.sh"
	[[ "${SKIP_RSS:-0}" = 1 ]] || run t21-rss "$DIR/t21-rss-hfunc.sh"
	[[ "${SKIP_HCALL:-0}" = 1 ]] || run t16-hcall "$DIR/t16-hcall-deltas.sh"
	[[ "${SKIP_T20:-0}" = 1 ]] || run t20-reload "$DIR/t20-reload-restore-mq.sh"
	# Quiet extras: no auto-outbound iperf (that hid the lp7 inbound gate)
	[[ "${SKIP_CLOSE_SQ:-0}" = 1 ]] || \
		run close-sq env RX=1 ROUNDS=10 IPERF=0 "$DIR/close-under-load.sh"
	[[ "${SKIP_L_CYCLE:-0}" = 1 ]] || run L-cycle env LOOPS=2 IPERF=0 "$DIR/ethtool-L-cycle.sh"
	ok "quiet phase complete"
else
	log "SKIP_QUIET=1 — skipping quiet phase"
fi

# ------------------------------------------------------------------
# Phase 2 — Interactive inbound iperf gate + MQ RX proof
# ------------------------------------------------------------------
if [[ "${SKIP_HEAVY:-0}" != 1 ]]; then
	log "========== PHASE 2: INBOUND IPERF + MQ RX PROOF =========="
	iface_up
	ping_ok
	prompt_start_inbound_iperf

	# ------------------------------------------------------------------
	# Phase 3 — Heavy under proven inbound MQ RX
	# ------------------------------------------------------------------
	log "========== PHASE 3: HEAVY (under proven inbound MQ RX) =========="

	# Explicit proof before geometry churn (gate already proved once).
	[[ "${SKIP_MQ_PROOF:-0}" = 1 ]] || \
		run mq-rx-pre "$DIR/t-mq-rx-under-load.sh" pre-heavy

	# T21 under traffic: hfunc switch + error Δ + MQ spread (P15)
	[[ "${SKIP_RSS_RX:-0}" = 1 ]] || \
		run t21-rss-under-rx env UNDER_RX=1 "$DIR/t21-rss-hfunc.sh"
	[[ "${SKIP_MQ_PROOF:-0}" = 1 ]] || \
		run mq-rx-post-t21 "$DIR/t-mq-rx-under-load.sh" post-t21-rss

	# T14 under inbound: each -L step checks error Δ, bulk RX, new-queue traffic
	[[ "${SKIP_T14:-0}" = 1 ]] || \
		run t14-cycle env UNDER_RX=1 "$DIR/t14-rx-cycle.sh"
	# T14 ends at RX=1 — restore MQ and re-prove inbound still alive + spread.
	[[ "${SKIP_MQ_PROOF:-0}" = 1 ]] || \
		run mq-rx-post-t14 "$DIR/t-mq-rx-under-load.sh" post-t14

	[[ "${SKIP_CLOSE_MQ:-0}" = 1 ]] || \
		run close-mq env RX=8 ROUNDS="${HEAVY_ROUNDS:-20}" IPERF=0 \
			"$DIR/close-under-load.sh"
	[[ "${SKIP_MQ_PROOF:-0}" = 1 ]] || \
		run mq-rx-post-close "$DIR/t-mq-rx-under-load.sh" post-close-mq

	# Parallel: outbound optional; proof relies on inbound from lp7.
	[[ "${SKIP_PARALLEL:-0}" = 1 ]] || \
		run parallel env DURATION="${STRESS_SECS:-300}" IPERF=0 \
			"$DIR/parallel-stress.sh"
	[[ "${SKIP_MQ_PROOF:-0}" = 1 ]] || \
		run mq-rx-post-parallel "$DIR/t-mq-rx-under-load.sh" post-parallel

	[[ "${SKIP_L_IPERF:-0}" = 1 ]] || \
		run L-under-rx env LOOPS=3 IPERF=0 "$DIR/ethtool-L-cycle.sh"
	[[ "${SKIP_MQ_PROOF:-0}" = 1 ]] || \
		run mq-rx-final "$DIR/t-mq-rx-under-load.sh" post-heavy-final

	ok "heavy phase complete (MQ RX under load proven)"
else
	log "SKIP_HEAVY=1 — skipping inbound gate + heavy phase"
fi

# ------------------------------------------------------------------
# Phase 4 — Cleanup + final ping
# ------------------------------------------------------------------
log "========== PHASE 4: CLEANUP =========="
stop_iperf_servers
ping_ok
check_no_lockup

log "ALL REQUESTED TESTS PASSED — see $LOGDIR"
log "Deep-dive by patch: $ROOT/TEST-PLAN-DEEP-DIVE.txt"
