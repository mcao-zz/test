#!/bin/bash
# run_s1_all.sh — series 1 on true-legacy firmware (max_rx == 1)
#
# s1 is single-queue prep: no MQ open, no debugfs buffer_pools, no
# qstats, no RSS hfunc. Same ABI the QEMU s1 guest uses (ethtool -l,
# /proc/interrupts, sysfs rx_packets). Do not run T3 / run_mq_all /
# ethtool -L rx 4.
#
#   sudo EXTERNAL_IPERF=1 ./run_s1_all.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

# QEMU skipped T11/T12 (no buffer_pools) and T24 (no qstats). Same on LPAR.
export SKIP_STATS="${SKIP_STATS:-1}"
export SKIP_T11="${SKIP_T11:-1}"
export SKIP_T24="${SKIP_T24:-1}"

exec "$DIR/run_legacy_all.sh" "$@"
