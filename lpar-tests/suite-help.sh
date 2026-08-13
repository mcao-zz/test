#!/bin/bash
# Print suite help (run_mq_all / run_rx_1_all / run_legacy_all).
# Usage: ./suite-help.sh [mq|rx1|legacy|all]
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
HELP="$DIR/SUITE-HELP.txt"

_show() {
	if [[ ! -f "$HELP" ]]; then
		echo "missing $HELP" >&2
		exit 1
	fi
	if [[ -t 1 ]]; then
		if [[ -n "${PAGER:-}" ]]; then
			# shellcheck disable=SC2086
			$PAGER "$HELP"
		elif command -v less >/dev/null 2>&1; then
			less -FRX "$HELP"
		else
			cat "$HELP"
		fi
	else
		cat "$HELP"
	fi
}

case "${1:-all}" in
	-h|--help|help|all|mq|rx1|legacy|"")
		_show
		;;
	*)
		echo "usage: $0 [all|mq|rx1|legacy]" >&2
		exit 1
		;;
esac
