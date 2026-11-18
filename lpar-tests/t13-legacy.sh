#!/bin/bash
# T13 — true legacy adapter regression (non-MQ firmware, max_rx=1)
#
# Legacy means PHYP without ILLAN RX multi-queue: ethtool -l
#   Pre-set maximums: RX: 1
# That is NOT the same as "ethtool -L rx 1" on an MQ adapter
# (max_rx still 16; multi_queue=1). Do not use this script for SQ-on-MQ.
#
# Covers review-responses/LEGACY-MODE-v5.md checklist for partitions
# that stay on the classic !multi_queue open/poll/hcall path after the
# MQ series refactors (P05/P06/P09/…).
#
# Adapter-key checks:
#   L1. replenish_no_mem present in ethtool -S
#   L2. queue-0 IRQ advances under traffic (SQ path; no leftover rx0_polls)
#   L3. sysfs rx_missed_errors readable (ndo_get_stats64 hw_drop_overruns)
#   L4. no-op ethtool -L rx 1 succeeds (no-op fires before mq_fallback gate)
#   L7. adapter tx_send_failed present (leftover txN_send_failures is v8-only)
#
#   sudo IFACE=env7 PEER=192.168.100.2 ./t13-legacy.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${DOWN_UP_ROUNDS:=20}"
: "${MTU_TEST:=9000}"

need_root
need_peer
save_dmesg_mark

max=$(max_rx)
if [[ "$max" -ne 1 ]]; then
	die "not a legacy adapter: max_rx=$max (want Pre-set maximums RX: 1). This is MQ firmware — RX=1 via ethtool -L is NOT legacy. Use a non-MQ LPAR/iface (e.g. net0)."
fi

log "=== T13 true legacy (max_rx=1) on $IFACE ==="
iface_up
ping_ok
ok "ethtool -l max_rx=1 (firmware non-MQ)"

# Probe set_real: while DOWN, Current must stay 1 (not alloc MAX leak).
iface_down
sleep 1
if ip link show "$IFACE" | head -1 | grep -qE '<[^>]*UP'; then
	die "IFACE still UP after ifdown"
fi
cur=$(current_rx)
[[ "$cur" -eq 1 ]] || die "while DOWN Current RX=$cur want 1 (probe real_num)"
ok "while DOWN Current RX=1 (probe set_real)"

# MQ resize must be rejected on non-MQ FW.
if ethtool -L "$IFACE" rx 2 >"$LOGDIR/t13-L-rx2.out" 2>"$LOGDIR/t13-L-rx2.err"; then
	die "ethtool -L rx 2 succeeded on legacy FW (want reject)"
fi
if ! grep -qiE 'not supported|Operation not supported|Invalid argument|EOPNOTSUPP' \
	"$LOGDIR/t13-L-rx2.err" "$LOGDIR/t13-L-rx2.out" 2>/dev/null; then
	log "WARN: -L rx 2 failed but message not matched; see $LOGDIR/t13-L-rx2.err"
fi
ok "ethtool -L rx 2 rejected"

iface_up
sleep 1

# Lifecycle / datapath still healthy on classic SQ path (series refactors).
log "ifdown/up × $DOWN_UP_ROUNDS"
saved_ip=$(save_iface_ipv4)
for i in $(seq 1 "$DOWN_UP_ROUNDS"); do
	iface_down
	[[ "$i" -eq 1 || "$i" -eq "$DOWN_UP_ROUNDS" ]] && assert_buffer_pools_down "T13-down-$i"
	iface_up
	restore_iface_ipv4 "$saved_ip"
	[[ "$i" -eq 1 || "$i" -eq "$DOWN_UP_ROUNDS" ]] && \
		assert_rx_alive_after_up "T13-up-$i" "$saved_ip"
done
sleep 1
assert_rx_alive_after_up "T13-churn-final" "$saved_ip"
ok "ifdown/up churn × $DOWN_UP_ROUNDS"

old_mtu=$(cat /sys/class/net/"$IFACE"/mtu)
if ip link set "$IFACE" mtu "$MTU_TEST" 2>"$LOGDIR/t13-mtu.err"; then
	sleep 1
	ip link set "$IFACE" mtu "$old_mtu" || die "restore MTU failed"
	sleep 1
	ping_ok
	ok "MTU change while up"
else
	log "WARN: MTU $MTU_TEST not accepted — skip (see $LOGDIR/t13-mtu.err)"
fi

pool=
if [[ -d /sys/class/net/$IFACE/pool0 ]]; then
	pool=/sys/class/net/$IFACE/pool0
elif [[ -d /sys/class/net/$IFACE/device/pool0 ]]; then
	pool=/sys/class/net/$IFACE/device/pool0
else
	pool=$(find /sys/class/net/"$IFACE" -maxdepth 2 -type d -name 'pool0' 2>/dev/null | head -1 || true)
fi
if [[ -n "$pool" && -e "$pool/active" ]]; then
	act=$(cat "$pool/active")
	echo 0 >"$pool/active" 2>/dev/null || true
	sleep 1
	echo "$act" >"$pool/active" 2>/dev/null || echo 1 >"$pool/active"
	sleep 2
	iface_up
	ping_ok
	ok "pool0 sysfs + active bounce"
else
	log "WARN: pool0 sysfs not found (check: ls /sys/class/net/$IFACE/pool*)"
fi

ip_a=$(sum_rx_packets)
ping -I "$IFACE" -c 20 -W 1 "$PEER" >/dev/null || die "ping burst -I $IFACE failed"
ip_b=$(sum_rx_packets)
d=$((ip_b - ip_a))
[[ "$d" -ge 10 ]] || die "RX counters did not advance (Δ=$d)"
ok "RX counters advance under ping (Δ=$d)"

assert_rx_geometry 1
ethtool -S "$IFACE" >"$LOGDIR/t13-stats.txt" || die "ethtool -S failed"

# ── adapter ethtool -S key smoke on legacy ───────────────────────────────
log "--- ethtool -S key checks ---"

# L1: replenish_no_mem must be present (adapter-level, always in ibmveth_stats[])
v=$(stat_val replenish_no_mem)
[[ -n "$v" ]] || die "L1: missing ethtool -S counter: replenish_no_mem"
ok "L1: replenish_no_mem=$v present in ethtool -S"

# hcall_* must be absent (dropped in v8)
if ethtool -S "$IFACE" 2>/dev/null | grep -qE '^[[:space:]]*hcall_'; then
	warn "L1: ethtool -S still has hcall_* keys (v8 dropped them — wrong .ko?)"
else
	ok "L1: hcall_* correctly absent from ethtool -S"
fi

# rx%d_packets must be absent (qstats-only per Documentation/networking/statistics.rst)
if ethtool -S "$IFACE" 2>/dev/null | grep -qE '^[[:space:]]*rx[0-9]+_packets:'; then
	warn "L1: rx%d_packets present in ethtool -S — should be qstats-only; wrong .ko?"
else
	ok "L1: rx%d_packets correctly absent from ethtool -S"
fi

# L7: adapter tx_send_failed is the summed key; leftover txN_send_failures
# is v8-only and absent on s2.
v=$(stat_val tx_send_failed)
[[ -n "$v" ]] || die "L7: missing ethtool -S counter: tx_send_failed"
ok "L7: tx_send_failed=$v present in ethtool -S"
tx_rows=$(count_tx_stat_rows)
if [[ "${tx_rows:-0}" -ge 1 ]]; then
	ok "L7: leftover tx*_send_failures rows=$tx_rows (v8 tree)"
else
	ok "L7: no leftover tx*_send_failures (s2: adapter key only)"
fi

# L2: queue-0 IRQ count must advance under traffic (SQ path).
# s2 has no rx0_polls on ethtool -S.
log "--- L2: queue-0 IRQ advance under traffic ---"
irq_before=$(snapshot_rx_queue_activity | awk '$1 == 0 { print $2; exit }')
irq_before=${irq_before:-0}
ping -I "$IFACE" -c 30 -W 1 "$PEER" >/dev/null 2>&1 || true
sleep 1
irq_after=$(snapshot_rx_queue_activity | awk '$1 == 0 { print $2; exit }')
irq_after=${irq_after:-0}
irq_delta=$((irq_after - irq_before))
log "queue0 IRQ: $irq_before → $irq_after (Δ=$irq_delta)"
[[ "$irq_delta" -ge 1 ]] || \
	die "L2: queue-0 IRQ did not advance under ping (Δ=$irq_delta) — SQ path broken"
ok "L2: queue-0 IRQ advanced under traffic (Δ=$irq_delta)"

# L3: sysfs rx_missed_errors readable (ndo_get_stats64 hw_drop_overruns proxy)
log "--- L3: sysfs rx_missed_errors ---"
sysfs_missed=$(cat "/sys/class/net/${IFACE}/statistics/rx_missed_errors" 2>/dev/null || true)
[[ -n "$sysfs_missed" ]] || \
	die "L3: /sys/class/net/$IFACE/statistics/rx_missed_errors not readable"
ok "L3: sysfs rx_missed_errors=$sysfs_missed (hw_drop_overruns proxy reachable on legacy)"

# L4: no-op ethtool -L rx 1 must succeed (no-op fires before mq_fallback gate)
log "--- L4: no-op ethtool -L rx 1 ---"
ethtool -L "$IFACE" rx 1 || die "L4: ethtool -L rx 1 (no-op) failed on legacy"
cur_after_noop=$(current_rx)
[[ "$cur_after_noop" -eq 1 ]] || \
	die "L4: RX changed from 1 to $cur_after_noop after no-op -L rx 1"
ok "L4: no-op ethtool -L rx 1 succeeded, RX=1 unchanged"

cmo=$(find /sys/bus/vio/devices -name cmo_entitled 2>/dev/null | head -1 || true)
if [[ -n "$cmo" ]]; then
	log "cmo_entitled=$(cat "$cmo") ($cmo)"
	ok "CMO entitlement readable"
elif grep -q CMO /proc/ppc64/lparcfg 2>/dev/null; then
	log "WARN: CMO in lparcfg but cmo_entitled not found"
else
	log "CMO not present — skip"
fi

check_no_oops
log "T13 PASS (true legacy max_rx=1)"
