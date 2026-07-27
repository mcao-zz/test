#!/bin/bash
# Prove multi-queue inbound RX under load (bulk Δ + spread across queues).
# Requires lp7 → DUT iperf already running (see run-all Phase 2).
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t-mq-rx-under-load.sh
#   MQ_PROOF_RX=8 MIN_RX_DELTA=10000 MIN_ACTIVE_RX_QUEUES=2 ...
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer
iface_up
ping_ok

label=${1:-mq-rx-under-load}
prove_mq_rx_under_load "$label"
log "T-MQ-RX-UNDER-LOAD PASS"
