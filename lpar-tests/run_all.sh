#!/bin/bash
# run_all.sh — MQ suite on IFACE, then the legacy suite on each adapter
# in LEGACY (firmware without the ILLAN MQ bit, max_rx == 1).
#
#   LEGACY="net0=10.48.36.153 net1=192.168.2.2"   iface=peer, space separated
#
# Set LEGACY in lab.conf or on the command line. Without it this is
# run_mq_all.sh. Each legacy run gets IFACE/PEER from its pair, DUT_IP
# from the interface address, its own LOGDIR ($LOGDIR/legacy-<iface>)
# and no module reload (the MQ suite already loaded it with dyndbg).
#
#   sudo ./run_all.sh
#   sudo ./run_all.sh LEGACY="net0=10.48.36.153" KERNEL_SRC=/root/ming/linux
#   sudo ./run_all.sh SKIP_MQ=1 LEGACY="net0=10.48.36.153"   legacy only
#
# Other KEY=VAL arguments are exported to both suites; --external-iperf
# goes to the MQ suite. LEGACY_EXTERNAL_IPERF=1 if the lab drives traffic
# on the legacy adapters too. A failing suite does not stop the next;
# the exit status is non-zero if any failed.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

MQ_ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--help|-h|help)
			sed -n '2,20p' "$0"
			exit 0
			;;
		--*|-E)
			MQ_ARGS+=("$1")
			;;
		*=*)
			export "${1?}"
			;;
		*)
			echo "unknown option: $1 (try --help)" >&2
			exit 1
			;;
	esac
	shift
done

conf="${LAB_CONF:-$DIR/lab.conf}"
if [[ -z "${LEGACY+x}" && -f "$conf" ]]; then
	LEGACY=$(sed -n 's/^LEGACY=//p' "$conf" | tail -1)
	LEGACY=${LEGACY#[\"\']}
	LEGACY=${LEGACY%[\"\']}
fi
: "${LEGACY:=}"
: "${LOGDIR:=/tmp/ibmveth-mq-tests}"
export LOGDIR

for pair in $LEGACY; do
	[[ "$pair" == ?*=?* ]] || { echo "LEGACY entry '$pair' is not iface=peer" >&2; exit 1; }
done

ts() { date '+%H:%M:%S'; }
results=()
rc=0

# Every adapter is checked before the long MQ suite starts, so a wrong
# LEGACY entry or an unreachable peer shows up now, not an hour later.
if [[ "${PREFLIGHT:-1}" = 1 ]]; then
	echo "[$(ts)] ===== run_all: preflight ====="
	if ! LEGACY="$LEGACY" "$DIR/preflight.sh"; then
		echo "[$(ts)] preflight failed; nothing run (PREFLIGHT=0 skips it)"
		exit 1
	fi
fi

if [[ "${SKIP_MQ:-0}" != 1 ]]; then
	echo "[$(ts)] ===== run_all: MQ suite ====="
	if "$DIR/run_mq_all.sh" "${MQ_ARGS[@]+"${MQ_ARGS[@]}"}"; then
		results+=("MQ (${IFACE:-lab.conf IFACE}): PASS")
	else
		results+=("MQ (${IFACE:-lab.conf IFACE}): FAIL")
		rc=1
	fi
fi

for pair in $LEGACY; do
	ifc=${pair%%=*}
	peer=${pair#*=}
	echo "[$(ts)] ===== run_all: legacy suite on $ifc (PEER=$peer) ====="
	if IFACE=$ifc PEER=$peer DUT_IP='' LOGDIR="$LOGDIR/legacy-$ifc" \
	   DYNDBG="${LEGACY_DYNDBG:-0}" EXTERNAL_IPERF="${LEGACY_EXTERNAL_IPERF:-0}" \
	   "$DIR/run_legacy_all.sh"; then
		results+=("legacy $ifc: PASS")
	else
		results+=("legacy $ifc: FAIL (log $LOGDIR/legacy-$ifc)")
		rc=1
	fi
done

echo "[$(ts)] ===== run_all summary ====="
for r in "${results[@]+"${results[@]}"}"; do
	echo "  $r"
done
[[ -n "$LEGACY" ]] || echo "  (no LEGACY adapters; set LEGACY=\"iface=peer ...\" to add them)"
exit "$rc"
