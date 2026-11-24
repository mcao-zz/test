#!/bin/bash
# T27 — link and RX mode across an RX -L reopen; TX-only -L does not reopen
#
# s2 v9 13/13: ethtool -L that changes RX on a running device closes and
# reopens it (ibmveth_reopen_with_counts), then reprograms the multicast
# filter (ibmveth_restore_rx_mode). A TX-only change keeps the live path.
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t27-reopen-rx-mode.sh
#
# Checks after each RX -L: IFF_UP and LOWER_UP still set, PROMISC/ALLMULTI
# flags kept, joined multicast address still listed, no h_multicast_ctrl
# or reopen errors, ping on IFACE works.
#
# Reopen detection uses the driver's "open/close complete" debug lines;
# the script turns them on in dynamic_debug/control when it can and puts
# the old flags back on exit. Without dynamic debug it falls back to
# subordinate IRQ counts (a reopen remaps them, so their counts restart).
#
# MC_CHECK=1 (interactive): asks you to run a multicast ping from the peer
# after the RX -L and counts ICMPv6 echo requests received on the DUT.
# That is the only check that PHYP's filter was reprogrammed; the flag
# and ip maddr checks only see the kernel's copy.
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${T27_MADDR:=01:00:5e:7f:00:01}"
: "${MC_CHECK:=0}"
: "${MC_MIN_ECHOS:=10}"

DDC=/sys/kernel/debug/dynamic_debug/control
dd_restore=
t27_cleanup() {
	ip link set "$IFACE" promisc off 2>/dev/null || true
	ip link set "$IFACE" allmulticast off 2>/dev/null || true
	ip maddr del "$T27_MADDR" dev "$IFACE" 2>/dev/null || true
	[[ -n "$dd_restore" ]] && echo "$dd_restore" >"$DDC" 2>/dev/null || true
}
trap t27_cleanup EXIT

need_root
need_peer
save_dmesg_mark

log "=== T27 link and RX mode across -L reopen on $IFACE ==="
iface_up
ping_ok

m=$(max_rx)
if [[ "$m" -lt 2 ]]; then
	log "T27 SKIP: max RX=$m (no multi-queue on this firmware/partition)"
	exit 0
fi
orig_rx=$(current_rx)
orig_tx=$(current_tx)
rx_a=2
rx_b=$(( m >= 4 ? 4 : m ))
[[ "$rx_b" -eq "$rx_a" ]] && rx_b=1

dbg=0
if [[ -w "$DDC" ]] && grep -q '\[ibmveth\]ibmveth_open .*"open complete' "$DDC"; then
	if grep -q '\[ibmveth\]ibmveth_open =_ .*"open complete' "$DDC"; then
		echo 'module ibmveth func ibmveth_open +p' >"$DDC"
		echo 'module ibmveth func ibmveth_close +p' >"$DDC"
		dd_restore='module ibmveth func ibmveth_open -p'
		dd_restore+=$'\n''module ibmveth func ibmveth_close -p'
	fi
	dbg=1
	log "open/close debug lines on (dynamic debug)"
else
	log "NOTE: no dynamic debug for ibmveth; reopen detection uses IRQ counts"
fi

# Print "irq-name count" for subordinate RX IRQs (queue 0 keeps its desc).
sub_irq_counts() {
	local vio
	vio=$(iface_vio_id)
	[[ -n "$vio" ]] || return 0
	awk -v re="^ibmveth-${vio}-rx[0-9]+$" '
		$1 ~ /^[0-9]+:/ && $NF ~ re {
			s = 0
			for (i = 2; i < NF; i++) { if ($i ~ /^[0-9]+$/) s += $i; else break }
			print $NF, s
		}' /proc/interrupts
}

link_flags() {
	ip -o link show "$IFACE" | sed -n 's/^[0-9]*: [^<]*<\([^>]*\)>.*/\1/p'
}

has_flag() {
	local f=$1
	[[ ",$(link_flags)," == *",$f,"* ]]
}

reopen_errors() {
	grep -E 'h_multicast_ctrl rc=|reopen with the old queue counts failed|failed to restore .* RX / .* TX queues' "$1" || true
}

# Do one RX -L and check everything that must survive the reopen.
rx_L_and_check() {
	local n=$1 label=$2 f errs mk
	shift 2
	mk=$(dmesg | wc -l)
	ethtool_rx "$n" || die "$label: ethtool -L rx $n failed"
	sleep 2
	dmesg_since "$mk" "$LOGDIR/t27-$label-dmesg.txt"
	assert_rx_geometry "$n"

	errs=$(reopen_errors "$LOGDIR/t27-$label-dmesg.txt")
	[[ -z "$errs" ]] || die "$label: reopen errors: $errs"
	if [[ "$dbg" = 1 ]]; then
		grep -q 'close complete' "$LOGDIR/t27-$label-dmesg.txt" && \
			grep -q 'open complete' "$LOGDIR/t27-$label-dmesg.txt" || \
			die "$label: RX -L on a running device did not close and reopen (see $LOGDIR/t27-$label-dmesg.txt)"
		ok "$label: close + open seen"
	fi

	for f in UP LOWER_UP "$@"; do
		has_flag "$f" || die "$label: link flag $f lost after RX -L (flags: $(link_flags))"
	done
	ok "$label: flags kept: $(link_flags)"

	ip maddr show dev "$IFACE" | grep -qi "$T27_MADDR" || \
		die "$label: joined multicast $T27_MADDR gone from ip maddr"
	ping_ok
}

# --- 1. multicast list, no promisc ---
log "--- 1. RX -L with a joined multicast address ---"
ethtool_rx "$rx_a" || die "ethtool -L rx $rx_a failed"
sleep 1
ip maddr add "$T27_MADDR" dev "$IFACE" || die "ip maddr add $T27_MADDR"
rx_L_and_check "$rx_b" mc

if [[ "$MC_CHECK" = 1 && "${NONINTERACTIVE:-0}" != 1 ]]; then
	b=$(awk '$1 == "Icmp6InEchos" { print $2 }' /proc/net/snmp6)
	cat >/dev/tty <<EOF

----------------------------------------------------------------------
On the peer, ping the IPv6 all-nodes group out of the interface on the
same VLAN as $IFACE (Linux answers it by default):

  ping -6 -c 30 -i 0.2 ff02::1%<peer-iface>

Press Enter here when it has finished.
----------------------------------------------------------------------
EOF
	tty_read "done? " _ans
	a=$(awk '$1 == "Icmp6InEchos" { print $2 }' /proc/net/snmp6)
	d=$((a - b))
	[[ "$d" -ge "$MC_MIN_ECHOS" ]] || \
		die "multicast RX after -L: Icmp6InEchos Δ=$d < $MC_MIN_ECHOS (filter not reprogrammed?)"
	ok "multicast RX after -L: Icmp6InEchos Δ=$d"
else
	log "MC_CHECK=0: skipping peer multicast ping (kernel-side checks only)"
fi

# --- 2. promisc + allmulti ---
log "--- 2. RX -L with PROMISC and ALLMULTI set ---"
ip link set "$IFACE" promisc on || die "promisc on"
ip link set "$IFACE" allmulticast on || die "allmulticast on"
rx_L_and_check "$rx_a" promisc PROMISC ALLMULTI
ip link set "$IFACE" promisc off
ip link set "$IFACE" allmulticast off
rx_L_and_check "$rx_b" promisc-off
has_flag PROMISC && die "PROMISC came back after it was cleared"
ok "PROMISC cleared stays cleared across RX -L"

# --- 3. TX-only -L keeps the live path ---
log "--- 3. TX-only -L does not reopen ---"
tx_now=$(current_tx)
tx_max=$(ethtool -l "$IFACE" 2>/dev/null | awk '
	/^Pre-set maximums:/ { p=1; next }
	/^Current hardware settings:/ { p=0 }
	p && /^[[:space:]]*TX:/ { print $2; exit }')
if [[ -z "$tx_now" || -z "$tx_max" || "$tx_max" -lt 2 ]]; then
	log "SKIP TX-only part: TX now=${tx_now:-?} max=${tx_max:-?}"
else
	tx_new=$(( tx_now > 1 ? tx_now - 1 : 2 ))
	ping -I "$IFACE" -c 5 -i 0.2 -W 2 "$PEER" >/dev/null 2>&1 || true
	sub_irq_counts >"$LOGDIR/t27-sub-before.txt"
	rx_before=$(current_rx)
	irqs_before=$(count_iface_irqs)
	mk=$(dmesg | wc -l)
	ethtool -L "$IFACE" tx "$tx_new" || die "ethtool -L tx $tx_new failed"
	sleep 1
	dmesg_since "$mk" "$LOGDIR/t27-tx-dmesg.txt"
	sub_irq_counts >"$LOGDIR/t27-sub-after.txt"

	[[ "$(current_tx)" = "$tx_new" ]] || die "TX count $(current_tx), want $tx_new"
	[[ "$(current_rx)" = "$rx_before" ]] || die "RX count changed on TX-only -L ($rx_before → $(current_rx))"
	[[ "$(count_iface_irqs)" = "$irqs_before" ]] || \
		die "IRQ lines changed on TX-only -L ($irqs_before → $(count_iface_irqs))"
	if [[ "$dbg" = 1 ]]; then
		if grep -qE 'close starting|open starting' "$LOGDIR/t27-tx-dmesg.txt"; then
			die "TX-only -L reopened the device (see $LOGDIR/t27-tx-dmesg.txt)"
		fi
		ok "TX-only -L: no close/open"
	fi
	# A reopen disposes subordinate IRQ mappings, so their counts restart.
	while read -r name before; do
		after=$(awk -v n="$name" '$1 == n { print $2 }' "$LOGDIR/t27-sub-after.txt")
		[[ -n "$after" ]] || die "TX-only -L: $name disappeared"
		[[ "$after" -ge "$before" ]] || \
			die "TX-only -L: $name count went back ($before → $after): device was reopened"
	done <"$LOGDIR/t27-sub-before.txt"
	ok "TX-only -L: RX=$rx_before, IRQ lines=$irqs_before, subordinate counts kept"
	ping_ok
	ethtool -L "$IFACE" tx "$tx_now" || die "restore TX $tx_now"
fi

ip maddr del "$T27_MADDR" dev "$IFACE" 2>/dev/null || true
[[ -n "$orig_rx" ]] && ethtool_rx "$orig_rx" || true
[[ -n "$orig_tx" ]] && ethtool -L "$IFACE" tx "$orig_tx" 2>/dev/null || true
sleep 1
ping_ok
check_no_lockup
check_no_oops
log "T27 PASS"
