#!/bin/bash
# preflight.sh — check every adapter run_all.sh would test, before any
# test runs: the MQ adapter (IFACE/PEER from lab.conf) and each LEGACY
# "iface=peer" pair. Per adapter: exists, driver ibmveth, up, IPv4
# (= DUT_IP if set), PEER answers ping -I, max RX (>= 2 for MQ, 1 for
# legacy), RX IRQ lines match current RX, ethtool -S readable, iperf3
# for the MQ heavy phase. Exit status = number of failed checks.
#
#   sudo ./preflight.sh
#   sudo ./preflight.sh LEGACY="net0=10.48.36.153" EXPECT_KERNEL=9cd8827b0107
#   sudo ./preflight.sh SKIP_MQ=1 LEGACY="net0=10.48.36.153"
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

for a in "$@"; do
	case "$a" in
		--help|-h|help) sed -n '2,13p' "$0"; exit 0 ;;
		*=*) export "${a?}" ;;
		*) echo "unknown option: $a (try --help)" >&2; exit 1 ;;
	esac
done

# shellcheck source=env.sh
. "$DIR/env.sh"
need_root

fails=0
summary=()
if [[ "${SKIP_MQ:-0}" != 1 ]]; then
	if preflight_adapter mq; then
		summary+=("MQ     $IFACE: ready")
	else
		n=$?; fails=$((fails + n)); summary+=("MQ     $IFACE: $n failed")
	fi
fi
for pair in ${LEGACY:-}; do
	ifc=${pair%%=*}
	peer=${pair#*=}
	if [[ "$pair" != ?*=?* ]]; then
		summary+=("legacy '$pair': not iface=peer")
		fails=$((fails + 1))
		continue
	fi
	if (IFACE=$ifc PEER=$peer DUT_IP='' && preflight_adapter legacy); then
		summary+=("legacy $ifc: ready")
	else
		n=$?; fails=$((fails + n)); summary+=("legacy $ifc: $n failed")
	fi
done

log "===== preflight summary ====="
for s in "${summary[@]+"${summary[@]}"}"; do
	log "  $s"
done
[[ -n "${LEGACY:-}" ]] || log "  (no LEGACY adapters)"
exit "$fails"
