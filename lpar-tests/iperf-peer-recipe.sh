#!/bin/bash
# Print (and optionally run) peer-side iperf3 clients → DUT.
# Usually run ON THE PEER host, after copying lab.conf or setting env.
#
#   # on peer (after scp lab.conf or export DUT_IP):
#   ./iperf-peer-recipe.sh           # print only
#   ./iperf-peer-recipe.sh run       # start clients in background
#   ./iperf-peer-recipe.sh stop
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

_load() {
	local f=${LAB_CONF:-$DIR/lab.conf}
	if [[ -f "$f" ]]; then
		# shellcheck disable=SC1090
		set -a
		# shellcheck disable=SC1091
		. "$f"
		set +a
		echo "loaded $f"
		return 0
	fi
	if [[ -f "$DIR/lab.conf.example" && -z "${DUT_IP:-}" ]]; then
		echo "WARN: no lab.conf — defaults from lab.conf.example / env"
		set -a
		# shellcheck disable=SC1091
		. "$DIR/lab.conf.example"
		set +a
	fi
}
_load

: "${DUT_IP:=192.168.1.133}"
: "${IPERF_PORT_FIRST:=5201}"
: "${IPERF_PORT_LAST:=5216}"
: "${IPERF_PARALLEL:=4}"
: "${IPERF_TIME:=0}"
: "${IPERF3:=iperf3}"

cmd=${1:-print}

print_recipe() {
	cat <<EOF
# === peer iperf clients (inbound RX to DUT) ===
# DUT_IP=$DUT_IP  ports ${IPERF_PORT_FIRST}-${IPERF_PORT_LAST}
# IPERF_TIME=$IPERF_TIME  (0 = forever — required for long T14 / run_mq_all)
# IPERF_PARALLEL=$IPERF_PARALLEL

pkill iperf3 2>/dev/null || true
sleep 1
for p in \$(seq $IPERF_PORT_FIRST $IPERF_PORT_LAST); do
  $IPERF3 -c $DUT_IP -t $IPERF_TIME -P $IPERF_PARALLEL -p \$p &
done
jobs -l
# prove: on DUT — watch -n1 'ethtool -S \$IFACE | grep rx0_packets'
# stop later: pkill iperf3
EOF
}

case "$cmd" in
	print|"")
		print_recipe
		;;
	run)
		command -v "$IPERF3" >/dev/null || { echo "FAIL: $IPERF3 not found"; exit 1; }
		echo "starting peer clients → $DUT_IP (-t $IPERF_TIME -P $IPERF_PARALLEL)"
		pkill iperf3 2>/dev/null || true
		sleep 1
		for p in $(seq "$IPERF_PORT_FIRST" "$IPERF_PORT_LAST"); do
			"$IPERF3" -c "$DUT_IP" -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -p "$p" &
		done
		jobs -l || true
		echo "OK: clients launched"
		;;
	stop)
		pkill iperf3 2>/dev/null || true
		echo "OK: iperf3 stop attempted"
		;;
	*)
		echo "usage: $0 [print|run|stop]" >&2
		exit 1
		;;
esac
