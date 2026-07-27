#!/bin/bash
# T17 — down-state -L must not create live subordinate IRQs (P13)
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t17-down-no-live-irqs.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${RX_UP:=8}"
: "${RX_STASH:=2}"

need_root
need_peer
save_dmesg_mark

log "=== T17 down-state -L must not create live IRQs on $IFACE ==="

iface_up
ethtool_rx "$RX_UP" || die "ethtool -L rx $RX_UP failed"
assert_rx_geometry "$RX_UP"
grep "${IFACE}" /proc/interrupts >"$LOGDIR/t17-irqs-up.txt" || true
irqs_up=$(count_iface_irqs)
ok "UP irqs=$irqs_up"

iface_down
sleep 1
irqs_down_before=$(count_iface_irqs)
grep "${IFACE}" /proc/interrupts >"$LOGDIR/t17-irqs-down-before.txt" || true
log "DOWN before -L: irqs=$irqs_down_before"

save_dmesg_mark
ethtool_rx "$RX_STASH" || die "ethtool -L rx $RX_STASH while down failed"
sleep 1
irqs_down_after=$(count_iface_irqs)
grep "${IFACE}" /proc/interrupts >"$LOGDIR/t17-irqs-down-after.txt" || true
dmesg_delta "$LOGDIR/t17-stash-dmesg.txt"

log "DOWN after -L rx $RX_STASH: irqs=$irqs_down_after"
# Stash must not publish live MQ IRQs while closed
if [[ "$irqs_down_after" -gt "$irqs_down_before" ]]; then
	die "IRQ lines grew while DOWN ($irqs_down_before → $irqs_down_after) — live IRQs created on stash?"
fi
# Must not already look like the stashed MQ geometry while still down
if [[ "$irqs_down_after" -eq "$RX_STASH" && "$RX_STASH" -gt 1 && "$irqs_down_before" -lt "$RX_STASH" ]]; then
	die "while DOWN, IRQ count already equals stash RX=$RX_STASH (expected apply-on-open only)"
fi
ok "no new live IRQ lines while DOWN after stash -L"

reg=$(grep -cE "Registered queue|Successfully resized" "$LOGDIR/t17-stash-dmesg.txt" || true)
if [[ "${reg:-0}" -gt 0 ]]; then
	log "WARN: $reg resize/register lines while down (review $LOGDIR/t17-stash-dmesg.txt)"
fi

iface_up
sleep 2
assert_rx_geometry "$RX_STASH"
grep "${IFACE}" /proc/interrupts >"$LOGDIR/t17-irqs-reup.txt" || true
ok "after reopen: IRQ geometry is $RX_STASH"

ping_ok
check_no_lockup
check_no_oops
log "T17 PASS"
