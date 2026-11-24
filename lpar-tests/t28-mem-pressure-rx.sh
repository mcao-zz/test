#!/bin/bash
# T28 — RX recovers after buffer allocation failures, under inbound load
#
# Needs bulk inbound traffic (heavy phase / EXTERNAL_IPERF).
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t28-mem-pressure-rx.sh
#
# T28_MODE=failslab (default when available): debugfs failslab, limited by
# the stack filter to allocations made from ibmveth's text, so only the
# driver's refill / copybreak allocations fail. Needs
# CONFIG_FAILSLAB + CONFIG_FAULT_INJECTION_DEBUG_FS +
# CONFIG_FAULT_INJECTION_STACKTRACE_FILTER and ibmveth as a module.
# Without that it skips. T28_MODE=stress: stress-ng --vm instead
# (system-wide, can OOM-kill iperf, may not make an atomic allocation
# fail at all; then it only checks that RX survives).
#
# Round 1 fails T28_PROB% of allocations for T28_SECS: queues keep some
# buffers, replenish_no_mem must rise, and every queue must still receive
# afterwards. T28_DRAIN=1 adds a round at 100% for T28_DRAIN_SECS, which
# can drain a queue completely. A queue whose refill posts no buffer gets
# no further interrupt (same as single queue today, stated in s2 07/13),
# so a stalled queue there is a WARN; it must come back after ifdown/up.
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${T28_MODE:=auto}"
: "${T28_PROB:=20}"
: "${T28_SECS:=30}"
: "${T28_DRAIN:=0}"
: "${T28_DRAIN_SECS:=10}"

FS=/sys/kernel/debug/failslab
inject_off() {
	[[ -w $FS/probability ]] || return 0
	echo 0 >"$FS/probability" 2>/dev/null || true
	echo 1 >"$FS/times" 2>/dev/null || true
}
stress_pid=
t28_cleanup() {
	inject_off
	[[ -n "$stress_pid" ]] && kill "$stress_pid" 2>/dev/null || true
}
trap t28_cleanup EXIT

need_root
need_peer
save_dmesg_mark

if [[ "$T28_MODE" = auto ]]; then
	if [[ -w $FS/require-start && -r /sys/module/ibmveth/sections/.text ]]; then
		T28_MODE=failslab
	else
		log "T28 SKIP: no failslab stack filter (or ibmveth built in); T28_MODE=stress to use stress-ng"
		exit 0
	fi
fi
if [[ "$T28_MODE" = stress ]] && ! command -v stress-ng >/dev/null 2>&1; then
	die "T28_MODE=stress needs stress-ng"
fi
log "=== T28 RX under allocation failures on $IFACE (mode=$T28_MODE) ==="

# Module core range from /proc/modules (name size refs deps state addr).
# ppc64 addresses do not fit bash or awk arithmetic, hence python.
mod_range() {
	python3 -c '
for l in open("/proc/modules"):
    f = l.split()
    if f[0] == "ibmveth":
        a = int(f[5], 16)
        print(a, a + int(f[1]))
'
}

inject_on() {
	local prob=$1 start end
	read -r start end < <(mod_range)
	[[ -n "$start" && "$start" -gt 0 ]] || \
		die "ibmveth address not readable in /proc/modules (kptr_restrict?)"
	echo 0 >"$FS/probability"
	echo 1 >"$FS/interval"
	echo -1 >"$FS/times"
	echo 0 >"$FS/space"
	echo 0 >"$FS/verbose"
	echo N >"$FS/task-filter"
	echo Y >"$FS/ignore-gfp-wait"
	echo 32 >"$FS/stacktrace-depth"
	echo "$start" >"$FS/require-start"
	echo "$end" >"$FS/require-end"
	echo "$prob" >"$FS/probability"
	log "failslab on: ${prob}% of atomic slab allocations from ibmveth [$start,$end)"
}

nomem() { local v; v=$(stat_val replenish_no_mem); echo "${v:-0}"; }

# Prove MQ RX without changing the RX count; returns nonzero instead of exiting.
rx_ok() {
	( SKIP_SET_RX=1 prove_mq_rx_under_load "$1" )
}

one_round() {
	local label=$1 prob=$2 secs=$3 n0 n1 saved_ip
	n0=$(nomem)
	if [[ "$T28_MODE" = failslab ]]; then
		inject_on "$prob"
	else
		stress-ng --vm "$(_nproc)" --vm-bytes 90% --vm-keep \
			--timeout "${secs}s" >"$LOGDIR/t28-$label-stress.log" 2>&1 &
		stress_pid=$!
	fi
	sleep "$secs"
	inject_off
	if [[ -n "$stress_pid" ]]; then
		wait "$stress_pid" 2>/dev/null || true
		stress_pid=
	fi
	n1=$(nomem)
	log "$label: replenish_no_mem $n0 → $n1 (Δ=$((n1 - n0)))"
	if [[ "$n1" -le "$n0" ]]; then
		[[ "$T28_MODE" = failslab ]] && \
			die "$label: no allocation failure counted (stack filter missed the refill path?)"
		warn "$label: stress-ng did not make a refill allocation fail; recovery check only"
	fi

	sleep 2
	if rx_ok "t28-$label-after"; then
		ok "$label: RX recovered on all queues without a reopen"
		return 0
	fi
	if [[ "$label" = drain ]]; then
		warn "$label: RX did not recover by itself (drained queue gets no interrupt; 07/13)"
	else
		die "$label: RX did not recover after ${prob}% failures (queues should keep buffers)"
	fi
	saved_ip=$(save_iface_ipv4)
	iface_down
	sleep 1
	iface_up
	restore_iface_ipv4 "$saved_ip"
	sleep 2
	rx_ok "t28-$label-reopen" || die "$label: RX still dead after ifdown/up"
	ok "$label: RX back after ifdown/up"
}

iface_up
ping_ok
want=$MQ_PROOF_RX
m=$(max_rx)
[[ "$want" -gt "$m" ]] && want=$m
ethtool_rx "$want" || die "ethtool -L rx $want failed"
sleep 1
assert_rx_geometry "$want"
rx_ok t28-before || die "T28 needs bulk inbound RX on $IFACE (start peer iperf first)"

one_round partial "$T28_PROB" "$T28_SECS"
if [[ "$T28_DRAIN" = 1 ]]; then
	one_round drain 100 "$T28_DRAIN_SECS"
fi

dmesg_since "$(cat "$LOGDIR/dmesg.mark")" "$LOGDIR/t28-dmesg.txt"
if grep -q 'Invalid map index' "$LOGDIR/t28-dmesg.txt"; then
	warn "driver reset messages during T28 (see $LOGDIR/t28-dmesg.txt)"
fi
ping_ok
check_no_lockup
check_no_oops
log "T28 PASS"
