#!/bin/bash
# T13 — true legacy adapter regression (non-MQ firmware)
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
#   sudo IFACE=net0 PEER=192.168.100.2 ./t13-legacy.sh
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
for _ in $(seq 1 "$DOWN_UP_ROUNDS"); do
	iface_down
	iface_up
done
sleep 1
ping_ok
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

ip_a=$(ip -s link show "$IFACE" | awk '/RX:/{getline; print $1; exit}')
ping -c 20 -W 1 "$PEER" >/dev/null || die "ping burst failed"
ip_b=$(ip -s link show "$IFACE" | awk '/RX:/{getline; print $1; exit}')
d=$((ip_b - ip_a))
[[ "$d" -ge 10 ]] || die "RX counters did not advance (Δ=$d)"
ok "RX counters advance under ping (Δ=$d)"

rows=$(count_rx_stat_rows)
[[ "$rows" -eq 1 ]] || die "rx*_packets rows=$rows want 1"
ok "ethtool -S rx*_packets rows=1"
ethtool -S "$IFACE" >"$LOGDIR/t13-stats.txt" || die "ethtool -S failed"

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
