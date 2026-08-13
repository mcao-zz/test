#!/bin/bash
# Start iperf3 servers on the DUT (RX sink). Uses lab.conf / env.
#
#   sudo ./iperf-dut.sh              # start
#   sudo ./iperf-dut.sh stop         # kill listeners on configured ports
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${IPERF_PORT_FIRST:=5201}"
: "${IPERF_PORT_LAST:=5216}"

need_root
need_iperf3

cmd=${1:-start}

case "$cmd" in
	stop)
		log "stopping iperf3 (ports ${IPERF_PORT_FIRST}-${IPERF_PORT_LAST})"
		pkill iperf3 2>/dev/null || true
		sleep 1
		ok "iperf3 stop attempted"
		;;
	start|*)
		log "starting iperf3 -s on ${IFACE:-?} ports ${IPERF_PORT_FIRST}-${IPERF_PORT_LAST}"
		pkill iperf3 2>/dev/null || true
		sleep 1
		for p in $(seq "$IPERF_PORT_FIRST" "$IPERF_PORT_LAST"); do
			"$IPERF3" -s -p "$p" -D
		done
		ss -ltn | grep -E ":($(seq -s '|' "$IPERF_PORT_FIRST" "$IPERF_PORT_LAST"))\\b" || \
			warn "ss did not list expected ports — check iperf3"
		ok "DUT iperf servers up (EXTERNAL_IPERF=1 suites will not touch them)"
		log "Next: on peer run: ./iperf-peer-recipe.sh   (or copy printed commands)"
		"$DIR/iperf-peer-recipe.sh"
		;;
esac
