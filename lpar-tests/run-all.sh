#!/bin/bash
# Compatibility wrapper — full MQ suite lives in run_mq_all.sh.
#
#   sudo IFACE=env9 PEER=192.168.1.153 EXTERNAL_IPERF=1 ./run-all.sh
#   sudo IFACE=env9 PEER=... ./run_mq_all.sh          # preferred name
#   sudo IFACE=env9 PEER=... ./run_rx_1_all.sh        # MQ + ethtool -L rx 1
#   sudo IFACE=net0 PEER=... ./run_legacy_all.sh      # true non-MQ FW
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/run_mq_all.sh" "$@"
