#!/bin/bash
# run_legacy_all.sh — true non-MQ firmware suite (max_rx == 1)
#
# Legacy = PHYP without ILLAN MQ bit. NOT "ethtool -L rx 1" on MQ FW
# (use run_rx_1_all.sh for that column).
#
# Typical lab: IFACE=net0 PEER=<public same-L2 peer>
#
#   sudo IFACE=net0 PEER=10.48.36.153 IBMVETH_KO=/home/ming/ibmveth-build \
#     EXTERNAL_IPERF=1 ./run_legacy_all.sh
#
# With EXTERNAL_IPERF=1: leave your iperf -t 0 flood alone (recommended).
# Without it: quiet-only (no harness-managed flood).
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--external-iperf|-E)
			EXTERNAL_IPERF=1
			shift
			;;
		--help|-h)
			sed -n '2,20p' "$0" | sed 's/^# \?//'
			exit 0
			;;
		EXTERNAL_IPERF=*|IBMVETH_KO=*|IFACE=*|PEER=*|DYNDBG=*|SKIP_*=*|NONINTERACTIVE=*|CHECK_HEALTH=*|DOWN_UP_ROUNDS=*|ROUNDS=*)
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

: "${DYNDBG:=1}"
: "${EXTERNAL_IPERF:=0}"
: "${CHECK_HEALTH:=1}"
: "${ROUNDS:=20}"
export CHECK_HEALTH EXTERNAL_IPERF

if [[ "$EXTERNAL_IPERF" = 1 ]]; then
	: "${RESTART_IPERF:=0}"
	: "${NONINTERACTIVE:=1}"
	: "${MIN_RX_DELTA:=100}"
	: "${RX_SAMPLE_SECS:=10}"
	: "${MIN_ACTIVE_RX_QUEUES:=1}"
	export RESTART_IPERF NONINTERACTIVE MIN_RX_DELTA RX_SAMPLE_SECS MIN_ACTIVE_RX_QUEUES
	export IPERF=0
	log "EXTERNAL_IPERF=1 — lab owns iperf; not starting/stopping servers"
fi

need_root
need_peer
assert_peer_on_iface

max=$(max_rx)
if [[ "$max" -ne 1 ]]; then
	die "run_legacy_all requires true legacy FW (max_rx==1); got max_rx=$max on $IFACE. For MQ+RX=1 use ./run_rx_1_all.sh; for full MQ use ./run_mq_all.sh"
fi

log "=== LEGACY suite on $IFACE (max_rx=1) PEER=$PEER IBMVETH_KO=${IBMVETH_KO:-modprobe} ==="
log "Logs under $LOGDIR"

run() {
	local name=$1
	shift
	log "######## START $name ########"
	"$@"
	log "######## DONE  $name ########"
	health_check_after "$name"
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
	log "DYNDBG=0 — skip initial reload"
fi

iface_up
ping_ok

# Primary ABI / lifecycle gate
run t13-legacy bash "$DIR/t13-legacy.sh"

# Stats / coherence (SQ)
[[ "${SKIP_STATS:-0}" = 1 ]] || run t12-stats "$DIR/t12-stats-debugfs.sh"
if [[ "$EXTERNAL_IPERF" = 1 ]]; then
	[[ "${SKIP_T22:-0}" = 1 ]] || \
		run t22-coherence env UNDER_RX=1 "$DIR/t22-stats-coherence.sh"
else
	[[ "${SKIP_T22:-0}" = 1 ]] || run t22-coherence "$DIR/t22-stats-coherence.sh"
fi
[[ "${SKIP_T10:-0}" = 1 ]] || run t10-lifetime env RX=1 "$DIR/t10-stats-lifetime.sh"

# Probe default must stay 1
[[ "${SKIP_T23:-0}" = 1 ]] || run t23-probe-real bash "$DIR/t23-probe-real-rx.sh"

# RSS must be unsupported on non-MQ
[[ "${SKIP_T21:-0}" = 1 ]] || run t21-rss "$DIR/t21-rss-hfunc.sh"

# Close under load at RX=1 (use lab flood if EXTERNAL_IPERF)
[[ "${SKIP_CLOSE:-0}" = 1 ]] || \
	run close-sq env RX=1 ROUNDS="$ROUNDS" IPERF=0 "$DIR/close-under-load.sh"

check_no_lockup
check_no_oops
ping_ok
ok "LEGACY suite PASS on $IFACE"
log "Done. (Skipped MQ-only: T14, L-cycle, T8/T17 stash stress, T19 multi-RX, T20 MQ restore)"
