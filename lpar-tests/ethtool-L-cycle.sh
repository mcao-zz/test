#!/bin/bash
# T7 / T9 — ethtool -L cycling. With IPERF=1 also stresses under traffic (T9).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${LOOPS:=5}"
: "${IPERF:=0}"
: "${KEEP_UP:=1}"   # 1 = cycle while up; 0 = down/set/up each time (T8-ish)

need_root
save_dmesg_mark

log "=== ethtool -L cycle on $IFACE loops=$LOOPS keep_up=$KEEP_UP ==="
log "max RX=$(max_rx) pattern: $RX_CYCLE"
iface_up

iperf_pid=""
cleanup() { [[ -n "$iperf_pid" ]] && kill "$iperf_pid" 2>/dev/null || true; }
trap cleanup EXIT

if [[ "$IPERF" = 1 ]]; then
	need_peer
	need_iperf3
	"$IPERF3" -c "$PEER" -t 3600 -P "$IPERF_PARALLEL" \
		>"$LOGDIR/iperf-L-cycle.log" 2>&1 &
	iperf_pid=$!
	sleep 2
fi

mapfile -t RXS < <(clamp_rx_list)
[[ ${#RXS[@]} -ge 1 ]] || die "empty RX cycle list"

for ((loop = 1; loop <= LOOPS; loop++)); do
	for n in "${RXS[@]}"; do
		log "loop $loop: ethtool -L $IFACE rx $n"
		if [[ "$KEEP_UP" = 1 ]]; then
			ethtool_rx "$n" || log "WARN: -L rx $n rc=$?"
		else
			iface_down
			ethtool_rx "$n" || log "WARN: -L rx $n rc=$?"
			iface_up
		fi
		sleep "$CYCLE_SLEEP"
		check_no_lockup
	done
done

cleanup
trap - EXIT
if [[ -n "${PEER:-}" ]]; then
	ping_ok || true
fi
check_no_lockup
log "ETHTOOL-L-CYCLE PASS"
