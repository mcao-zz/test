#!/bin/bash
# T29 — jumbo MTU and pool sysfs changes with multiple RX queues
#
# MTU change and pool sysfs writes close and reopen a running device.
# Pool sysfs edits queue 0's pools; open copies them to every queue
# (ibmveth_alloc_buffer_pools), so all queues must come back with the
# new geometry and still receive.
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t29-jumbo-mq.sh
#   sudo UNDER_RX=1 ... ./t29-jumbo-mq.sh     # also prove MQ RX under load
#
# T29_PEER_JUMBO=1: the peer side takes MTU >= T29_MTU, so a DF ping of
# that size must work (otherwise it is only a WARN).
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${T29_MTU:=9000}"
: "${T29_PEER_JUMBO:=0}"
: "${UNDER_RX:=0}"

old_mtu=
pool_path=
old_num=
t29_cleanup() {
	[[ -n "$pool_path" && -n "$old_num" ]] && echo "$old_num" >"$pool_path/num" 2>/dev/null || true
	[[ -n "$old_mtu" ]] && ip link set "$IFACE" mtu "$old_mtu" 2>/dev/null || true
}
trap t29_cleanup EXIT

need_root
need_peer
save_dmesg_mark

log "=== T29 jumbo MTU / pool sysfs with MQ on $IFACE ==="
iface_up
ping_ok

m=$(max_rx)
if [[ "$m" -lt 2 ]]; then
	log "T29 SKIP: max RX=$m (no multi-queue on this firmware/partition)"
	exit 0
fi
orig_rx=$(current_rx)
rx=$(( m >= 8 ? 8 : m ))
ethtool_rx "$rx" || die "ethtool -L rx $rx failed"
sleep 1
assert_rx_geometry "$rx"
old_mtu=$(cat "/sys/class/net/$IFACE/mtu")

alive() {
	local label=$1
	ip -o link show "$IFACE" | grep -q 'LOWER_UP' || die "$label: link not LOWER_UP"
	assert_rx_geometry "$2"
	ping_ok
	if [[ "$UNDER_RX" = 1 ]]; then
		( SKIP_SET_RX=1 prove_mq_rx_under_load "t29-$label" ) || \
			die "$label: MQ RX under load not proven"
	fi
}

# --- 1. jumbo MTU on a running MQ device ---
log "--- 1. MTU $old_mtu → $T29_MTU with RX=$rx ---"
ip link set "$IFACE" mtu "$T29_MTU" 2>"$LOGDIR/t29-mtu.err" || \
	die "MTU $T29_MTU with RX=$rx failed: $(cat "$LOGDIR/t29-mtu.err")"
sleep 2
[[ "$(cat "/sys/class/net/$IFACE/mtu")" = "$T29_MTU" ]] || die "MTU not applied"
alive jumbo "$rx"
if ping -I "$IFACE" -M "do" -s $((T29_MTU - 28)) -c 3 -W 2 "$PEER" >/dev/null 2>&1; then
	ok "DF ping of $T29_MTU bytes"
elif [[ "$T29_PEER_JUMBO" = 1 ]]; then
	die "DF ping of $T29_MTU bytes failed (T29_PEER_JUMBO=1)"
else
	warn "DF ping of $T29_MTU bytes failed (peer MTU smaller? set T29_PEER_JUMBO=1 to require it)"
fi

# --- 2. RX -L while jumbo: queues come back with jumbo pools ---
log "--- 2. RX -L 2 → $rx at MTU $T29_MTU ---"
ethtool_rx 2 || die "ethtool -L rx 2 at MTU $T29_MTU failed"
sleep 1
alive jumbo-rx2 2
ethtool_rx "$rx" || die "ethtool -L rx $rx at MTU $T29_MTU failed"
sleep 1
alive jumbo-rx$rx "$rx"

# --- 3. pool sysfs write with MQ ---
log "--- 3. pool sysfs num change with RX=$rx ---"
for d in "/sys/class/net/$IFACE/device/pool0" "/sys/class/net/$IFACE/pool0"; do
	[[ -w $d/num ]] && { pool_path=$d; break; }
done
if [[ -z "$pool_path" ]]; then
	warn "no writable pool0/num under /sys/class/net/$IFACE — skip pool sysfs part"
else
	old_num=$(cat "$pool_path/num")
	new_num=$(( old_num > 2 ? old_num / 2 : old_num + 1 ))
	echo "$new_num" >"$pool_path/num" || die "write pool0/num=$new_num failed"
	sleep 2
	[[ "$(cat "$pool_path/num")" = "$new_num" ]] || die "pool0/num not applied"
	alive pool-num "$rx"
	if echo 0 >"$pool_path/num" 2>/dev/null; then
		die "pool0/num=0 accepted"
	fi
	[[ "$(cat "$pool_path/num")" = "$new_num" ]] || die "rejected pool0/num write changed the value"
	alive pool-reject "$rx"
	echo "$old_num" >"$pool_path/num" || die "restore pool0/num=$old_num failed"
	old_num=
	sleep 2
	alive pool-restore "$rx"
	ok "pool sysfs change and restore with RX=$rx"
fi

ip link set "$IFACE" mtu "$old_mtu" || die "restore MTU $old_mtu"
old_mtu=
sleep 2
alive mtu-restore "$rx"
[[ -n "$orig_rx" ]] && ethtool_rx "$orig_rx" || true
sleep 1
ping_ok
check_no_lockup
check_no_oops
log "T29 PASS"
