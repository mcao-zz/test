#!/bin/bash
# run_s1_all.sh — series 1 on true-legacy firmware (max_rx == 1)
#
# s1 is single-queue prep: no MQ open, no debugfs buffer_pools, no RSS
# hfunc. Do not run T3 / run_mq_all / ethtool -L rx 4.
#
#   sudo EXTERNAL_IPERF=1 ./run_s1_all.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

# t12 walks debugfs buffer_pools (not in s1). Other SKIP_* still work.
export SKIP_STATS="${SKIP_STATS:-1}"

exec "$DIR/run_legacy_all.sh" "$@"
