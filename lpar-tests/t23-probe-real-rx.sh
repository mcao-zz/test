#!/bin/bash
# T23 / P10 — probe sets real_num_rx_queues to advertised default (not MAX)
#
# alloc_etherdev_mqs() sizes real_num_rx_queues to IBMVETH_MAX_RX_QUEUES.
# Probe must call netif_set_real_num_rx_queues(adapter->num_rx_queues) so
# while-down ethtool -l Current RX matches the default (1 or min(cpus,8)),
# not MAX.
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t23-probe-real-rx.sh
#   sudo IFACE=env9 PEER=... IBMVETH_KO=/path/to/ibmveth.ko ./t23-probe-real-rx.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${DYNDBG:=1}"
: "${DEFAULT_QUEUES:=8}"   # IBMVETH_DEFAULT_QUEUES

need_root
need_peer
save_dmesg_mark

log "=== T23 probe real_num_rx_queues on $IFACE ==="

saved_ip=$(save_iface_ipv4)
log "saved IPv4: ${saved_ip:-none}"

iface_up
max_before=$(max_rx)
ok "pre-reload max_rx=$max_before"

log "reload ibmveth for fresh probe (IBMVETH_KO=${IBMVETH_KO:-modprobe})..."
iface_down
sleep 1
rmmod ibmveth 2>/dev/null || log "WARN: rmmod ibmveth (may already be unloaded)"
sleep 2
if [[ "$DYNDBG" = 1 ]]; then
	load_ibmveth "+p"
else
	load_ibmveth
fi
sleep 3

ip link show "$IFACE" >/dev/null || die "netdev $IFACE missing after reload"

# Must observe Current RX while DOWN — before any open publishes a different count.
iface_down
sleep 1
if ip link show "$IFACE" | head -1 | grep -qE '<[^>]*UP'; then
	die "IFACE still UP after ifdown (cannot check probe real_num)"
fi

cur=$(current_rx)
max=$(max_rx)
cpus=$(nproc)
if [[ "$max" -le 1 ]]; then
	want=1
else
	want=$cpus
	[[ "$want" -gt "$DEFAULT_QUEUES" ]] && want=$DEFAULT_QUEUES
	[[ "$want" -lt 1 ]] && want=1
fi

log "while DOWN after probe: Current RX=$cur  max_rx=$max  want_default=$want (cpus=$cpus DEFAULT_QUEUES=$DEFAULT_QUEUES)"

[[ -n "$cur" && "$cur" -ge 1 ]] || die "Current RX empty/invalid while down ($cur)"
[[ "$cur" -le "$max" ]] || die "Current RX=$cur > max_rx=$max"

# Classic bug: left at alloc MAX while advertised default is smaller.
if [[ "$max" -gt "$want" && "$cur" -eq "$max" ]]; then
	die "Current RX=$cur equals max_rx (probe left real_num at MAX; want default $want)"
fi

[[ "$cur" -eq "$want" ]] || \
	die "Current RX=$cur while down, want probe default $want"

ok "probe Current RX=$cur matches default (not MAX=$max)"

iface_up
restore_iface_ipv4 "$saved_ip"
sleep 2
ping_ok
check_no_oops
log "T23 PASS"
