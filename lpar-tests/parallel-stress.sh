#!/bin/bash
# T10 / T11 — parallel -L cycling + ifdown/up (correlator / close races)
#
# After stress: snapshot ethtool -S / IRQs / dmesg; fail if error Δ exceeds
# MAX_ERR_DELTA; require ping recovery within PING_RECOVER_SECS.
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${DURATION:=300}"   # seconds
: "${IPERF:=1}"
: "${PING_RECOVER_SECS:=30}"

need_root
need_peer
save_dmesg_mark
snap_core_errors

log "=== parallel stress ${DURATION}s on $IFACE ==="
iface_up
ethtool_rx 4 || true

mapfile -t RXS < <(clamp_rx_list)
pids=()
cleanup() {
	local p
	for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

# Worker 1: ethtool -L forever
(
	i=0
	while true; do
		n=${RXS[$((i % ${#RXS[@]}))]}
		ethtool -L "$IFACE" rx "$n" 2>/dev/null || true
		i=$((i + 1))
		sleep "$CYCLE_SLEEP"
	done
) &
pids+=($!)

# Worker 2: ifdown/up
(
	while true; do
		ip link set "$IFACE" down 2>/dev/null || true
		sleep 1
		ip link set "$IFACE" up 2>/dev/null || true
		sleep 2
	done
) &
pids+=($!)

# Worker 3: traffic
if [[ "$IPERF" = 1 ]] && have_iperf3; then
	"$IPERF3" -c "$PEER" -t "$DURATION" -P "$IPERF_PARALLEL" \
		>"$LOGDIR/iperf-parallel.log" 2>&1 &
	pids+=($!)
else
	ping -f "$PEER" >/dev/null 2>&1 &
	pids+=($!)
fi

log "workers pids=${pids[*]}; sleeping $DURATION s"
end=$((SECONDS + DURATION))
while [[ $SECONDS -lt $end ]]; do
	sleep 10
	check_no_lockup
	log "… still running ($((end - SECONDS))s left)"
done

cleanup
trap - EXIT
sleep 2
iface_up

# Artifacts
ethtool -S "$IFACE" >"$LOGDIR/parallel-ethtool-S.txt" 2>/dev/null || true
grep "${IFACE}" /proc/interrupts >"$LOGDIR/parallel-interrupts.txt" 2>/dev/null || true
dmesg_delta "$LOGDIR/parallel-dmesg.txt"
log "artifacts: $LOGDIR/parallel-{ethtool-S,interrupts,dmesg}.txt"

# Under close/resize races, transient errors can tick — bounded threshold.
: "${PARALLEL_MAX_ERR_DELTA:=1000}"
_saved_max=$MAX_ERR_DELTA
MAX_ERR_DELTA=$PARALLEL_MAX_ERR_DELTA
check_core_error_deltas "post-parallel"
MAX_ERR_DELTA=$_saved_max

ping_recover "$PING_RECOVER_SECS"
check_no_lockup

if grep -qiE 'Oops|BUG:|Call Trace|hard LOCKUP|soft lockup' "$LOGDIR/parallel-dmesg.txt"; then
	die "Oops/BUG/lockup in parallel dmesg delta"
fi
if grep -qi 'bad correlator' "$LOGDIR/parallel-dmesg.txt"; then
	log "NOTE: bad correlator messages seen (expected under stress if rate-limited)"
fi

log "PARALLEL-STRESS PASS"
