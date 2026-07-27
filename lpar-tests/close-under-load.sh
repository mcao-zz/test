#!/bin/bash
# T5/T6 — close under load. Usage:
#   PEER=1.2.3.4 RX=8 ./close-under-load.sh          # MQ
#   PEER=1.2.3.4 RX=1 ./close-under-load.sh          # SQ
# Optional: start iperf3 -s on PEER first. If IPERF=0, only ping flood.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX:=8}"
: "${ROUNDS:=20}"
: "${IPERF:=1}"
: "${DOWN_SLEEP:=1}"
: "${UP_SLEEP:=2}"

need_root
need_peer
save_dmesg_mark

log "=== Close under load: RX=$RX rounds=$ROUNDS on $IFACE ==="
iface_down
ethtool_rx "$RX" || die "ethtool -L rx $RX failed"
iface_up
ping_ok

iperf_pid=""
cleanup() {
	[[ -n "$iperf_pid" ]] && kill "$iperf_pid" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$IPERF" = 1 ]]; then
	if have_iperf3; then
		log "starting $IPERF3 -c $PEER -t 3600 -P $IPERF_PARALLEL (background)"
		"$IPERF3" -c "$PEER" -t 3600 -P "$IPERF_PARALLEL" \
			>"$LOGDIR/iperf-client.log" 2>&1 &
		iperf_pid=$!
		sleep 2
	else
		log "iperf3 not found; using ping -f only (PATH=$PATH)"
		IPERF=0
	fi
fi

if [[ "$IPERF" = 0 ]]; then
	ping -f "$PEER" >/dev/null 2>&1 &
	iperf_pid=$!
fi

for i in $(seq 1 "$ROUNDS"); do
	log "round $i/$ROUNDS: ifdown/up under traffic"
	iface_down
	sleep "$DOWN_SLEEP"
	iface_up
	sleep "$UP_SLEEP"
	check_no_lockup
done

cleanup
trap - EXIT
sleep 1
iface_up
ping_ok
check_no_lockup
log "CLOSE-UNDER-LOAD PASS (rx=$RX)"
