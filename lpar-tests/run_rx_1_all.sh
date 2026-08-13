#!/bin/bash
# run_rx_1_all.sh — MQ firmware forced to ethtool -L rx 1 (column B)
#
# NOT legacy: Pre-set max_rx must be >= 2. Still MQ PHYP + classic SQ kick.
# For true non-MQ FW use ./run_legacy_all.sh. For full MQ use ./run_mq_all.sh.
#
# Stresses J14-7b-class RX-stall risk: ifdown/up, close-under-load, soak,
# and bounce 1 ↔ mid ↔ max under inbound flood.
#
# Help: ./suite-help.sh  or  ./run_rx_1_all.sh --help  (SUITE-HELP.txt)
# Prefer lab.conf; keep peer iperf -t 0 with EXTERNAL_IPERF=1.
#
#   sudo EXTERNAL_IPERF=1 ./run_rx_1_all.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--external-iperf|-E)
			EXTERNAL_IPERF=1
			shift
			;;
		--help|-h|help)
			exec "$DIR/suite-help.sh" rx1
			;;
		EXTERNAL_IPERF=*|IBMVETH_KO=*|IFACE=*|PEER=*|DYNDBG=*|SKIP_*=*|NONINTERACTIVE=*|CHECK_HEALTH=*|ROUNDS=*|BOUNCE_ROUNDS=*|SOAK_SECS=*|T1_ROUNDS=*|MID_RX=*)
			export "${1?}"
			shift
			;;
		*)
			echo "unknown option: $1 (try --help)" >&2
			exit 1
			;;
	esac
done

# shellcheck source=env.sh
. "$DIR/env.sh"

: "${DYNDBG:=0}"
: "${EXTERNAL_IPERF:=0}"
: "${CHECK_HEALTH:=1}"
: "${ROUNDS:=30}"
: "${BOUNCE_ROUNDS:=20}"
: "${SOAK_SECS:=300}"
: "${T1_ROUNDS:=50}"
: "${MID_RX:=8}"
export CHECK_HEALTH EXTERNAL_IPERF

if [[ "$EXTERNAL_IPERF" = 1 ]]; then
	: "${RESTART_IPERF:=0}"
	: "${NONINTERACTIVE:=1}"
	: "${MIN_RX_DELTA:=100}"
	: "${RX_SAMPLE_SECS:=10}"
	: "${MIN_ACTIVE_RX_QUEUES:=1}"
	export RESTART_IPERF NONINTERACTIVE MIN_RX_DELTA RX_SAMPLE_SECS MIN_ACTIVE_RX_QUEUES
	export IPERF=0
	log "EXTERNAL_IPERF=1 — lab owns iperf"
fi

need_root
need_peer
assert_peer_on_iface

max=$(max_rx)
if [[ "$max" -lt 2 ]]; then
	die "run_rx_1_all needs MQ firmware (max_rx>=2); got max_rx=$max. For true legacy use ./run_legacy_all.sh"
fi

mid=$MID_RX
[[ "$mid" -ge "$max" ]] && mid=$((max > 1 ? max / 2 : 1))
[[ "$mid" -lt 2 ]] && mid=2

log "=== MQ+RX=1 suite on $IFACE (max_rx=$max) PEER=$PEER ==="
log "Logs under $LOGDIR  ROUNDS=$ROUNDS BOUNCE_ROUNDS=$BOUNCE_ROUNDS SOAK_SECS=$SOAK_SECS"

run() {
	local name=$1
	shift
	log "######## START $name ########"
	"$@"
	log "######## DONE  $name ########"
	health_check_after "$name"
}

force_rx1() {
	ethtool_rx 1 || die "ethtool -L rx 1 failed"
	[[ "$(current_rx)" == 1 ]] || die "Current RX=$(current_rx) want 1"
}

assert_rx1_alive() {
	local label=${1:-rx1}
	assert_rx_alive_after_up "$label" "$(save_iface_ipv4)"
}

cleanup() {
	stop_iperf_servers
}
trap cleanup EXIT

save_dmesg_mark
assert_ibmveth_ko_loaded

if [[ "$DYNDBG" = 1 ]]; then
	run dyndbg-load ensure_ibmveth_dyndbg
else
	log "DYNDBG=0 — skip reload (set DYNDBG=1 to force)"
fi

iface_up
force_rx1
ping_ok
ok "entered MQ+RX=1 (max_rx=$max Current=1)"

# --- S1: ifdown/up churn at RX=1 ---
if [[ "${SKIP_CHURN:-0}" != 1 ]]; then
	log "======== S1: ifdown/up ×$T1_ROUNDS at RX=1 ========"
	saved_ip=$(save_iface_ipv4)
	for i in $(seq 1 "$T1_ROUNDS"); do
		iface_down
		sleep 1
		RESTORE_IP=$saved_ip assert_rx_alive_after_up "rx1-churn-$i" "$saved_ip"
		[[ "$(current_rx)" == 1 ]] || die "after churn $i Current RX=$(current_rx) want 1"
	done
	ok "S1 churn PASS"
	health_check_after "rx1-churn"
fi

# --- S2: close under load ---
if [[ "${SKIP_CLOSE:-0}" != 1 ]]; then
	run close-rx1 env RX=1 ROUNDS="$ROUNDS" IPERF=0 "$DIR/close-under-load.sh"
	force_rx1
	assert_rx1_alive "post-close"
fi

# --- S3: soak at RX=1 ---
if [[ "${SKIP_SOAK:-0}" != 1 ]]; then
	log "======== S3: soak ${SOAK_SECS}s at RX=1 ========"
	force_rx1
	a=$(sum_rx_packets)
	sleep "$SOAK_SECS"
	b=$(sum_rx_packets)
	d=$((b - a))
	log "soak RX Δ=$d over ${SOAK_SECS}s"
	if [[ "$EXTERNAL_IPERF" = 1 ]]; then
		[[ "$d" -ge "${MIN_RX_DELTA:-100}" ]] || \
			die "soak bulk Δ=$d < MIN_RX_DELTA=${MIN_RX_DELTA:-100} (keep peer iperf -t 0)"
		ok "soak bulk RX Δ=$d"
	else
		log "EXTERNAL_IPERF=0 — soak Δ informational only (Δ=$d)"
	fi
	ping_ok
	health_check_after "rx1-soak"
fi

# --- S3b: stats at RX=1 ---
[[ "${SKIP_T10:-0}" = 1 ]] || run t10-lifetime env RX=1 "$DIR/t10-stats-lifetime.sh"
force_rx1
if [[ "$EXTERNAL_IPERF" = 1 && "${SKIP_T22:-0}" != 1 ]]; then
	run t22-coherence env UNDER_RX=1 RX=1 "$DIR/t22-stats-coherence.sh"
	force_rx1
fi

# --- S4: bounce 1 ↔ mid ↔ max under load ---
if [[ "${SKIP_BOUNCE:-0}" != 1 ]]; then
	log "======== S4: bounce 1↔${mid}↔${max} ×$BOUNCE_ROUNDS ========"
	for i in $(seq 1 "$BOUNCE_ROUNDS"); do
		log "bounce $i/$BOUNCE_ROUNDS"
		ethtool_rx 1 || die "bounce $i: -L rx 1"
		sleep 1
		ping -I "$IFACE" -c 2 -W 2 "$PEER" >/dev/null || die "bounce $i: ping at RX=1"
		ethtool_rx "$mid" || die "bounce $i: -L rx $mid"
		sleep 1
		ethtool_rx "$max" || die "bounce $i: -L rx $max"
		sleep 1
		check_no_lockup
	done
	force_rx1
	assert_rx1_alive "post-bounce"
	ok "S4 bounce PASS"
	health_check_after "rx1-bounce"
fi

check_no_lockup
check_no_oops
force_rx1
ping_ok
ok "MQ+RX=1 suite PASS on $IFACE"
log "Left Current RX=1 (max_rx=$max). Restore MQ: ethtool -L $IFACE rx $max"
