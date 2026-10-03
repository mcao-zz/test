#!/bin/bash

# IBM Virtual Ethernet (ibmveth) net-next fixes - LPAR test script
# Covers TEST-PLAN-ibmveth-fixes.txt for the 7-patch series:
#   1 ibmveth: fix netpoll races with RX replenish
#   2 ibmveth: do not close twice after a failed reopen
#   3 ibmveth: disable the reset work before unregister in remove
#   4 ibmveth: step past bad RX correlators instead of spinning or oopsing
#   5 ibmveth: release the pool kobjects when probe fails
#   6 ibmveth: return the error when set_channels cannot add TX queues
#   7 ibmveth: wait for in-flight transmits in ibmveth_close()
#
# Kernel/module: ibmveth-fixes-7-lab (7 fixes + debug knobs). Tests 5 and 6
#   need its debug_fail_probe / debug_fail_tx_ltb knobs. Tests 1-4 were run
#   on ibmveth-fixes-4g-lab / 4-lab-before.
#
# Run on a SECOND ibmveth interface, not the one your ssh session uses.
#
# Usage: ./test-veth-fixes.sh -d env7 -t 192.168.77.2 -l 192.168.77.1 [options]

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INTERFACE="env7"
PEER_IP="192.168.77.2"
LOCAL_IP="192.168.77.1"
PREFIX=24
PEER_MAC=""
PEER_SSH=""
NETCONS_PORT=6666
TESTS="0 1 3"
ASSUME_YES=0
JUMBO=0
RESULTS_DIR="/tmp/ibmveth-fixes-test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TEST_RESULTS=()
DMESG_MARKER=0
NETCONS_CFG=""

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  -d DEVICE     ibmveth interface under test (default: $INTERFACE)
  -t PEER_IP    peer address on the same VLAN (default: $PEER_IP)
  -l LOCAL_IP   address to put on DEVICE (default: $LOCAL_IP/$PREFIX)
  -m PEER_MAC   peer MAC for netconsole (default: broadcast)
  -s USER@HOST  ssh to the peer: starts the netconsole listener and
                iperf3 server there and counts received lines
  -T "LIST"     tests to run (default: "$TESTS"; all: "0 1 2 3 4 5 6 7")
                  0 system info and config
                  1 netconsole under load and during MTU/TSO changes (patch 1)
                  2 forced open() failure on an MTU change (patch 2)
                    WARNING: on the BEFORE kernel this hangs RTNL until
                    the LPAR is restarted from the HMC
                  3 regression: ping, iperf3, MTU changes (patch 4 RX paths)
                  4 unbind/bind under traffic (patch 3)
                  5 forced probe failure: pool sysfs dirs removed (patch 5)
                  6 ethtool -L with a forced TX buffer allocation failure
                    (patch 6)
                  7 MTU and rx-csum/TSO changes under traffic (patch 7)
  -J            peer is at MTU 9000: also ping -s 8000 at MTU 9000
  -y            do not ask before test 2
  -h            show this help

Examples:
  $0 -d env7 -t 192.168.77.2 -l 192.168.77.1 -s root@lp7
  $0 -d env7 -t 192.168.77.2 -l 192.168.77.1 -T "2"     # AFTER kernel
  $0 -d env7 -t 192.168.77.2 -l 192.168.77.1 -T "0 1 2 3 4" -s root@lp7
  $0 -d env7 -t 192.168.77.2 -l 192.168.77.1 -T "7 6 5" -s root@lp7
EOF
    exit 1
}

while getopts "d:t:l:m:s:T:Jyh" opt; do
    case $opt in
        d) INTERFACE="$OPTARG" ;;
        t) PEER_IP="$OPTARG" ;;
        l) LOCAL_IP="${OPTARG%/*}"; [[ "$OPTARG" == */* ]] && PREFIX="${OPTARG#*/}" ;;
        m) PEER_MAC="$OPTARG" ;;
        s) PEER_SSH="$OPTARG" ;;
        T) TESTS="$OPTARG" ;;
        J) JUMBO=1 ;;
        y) ASSUME_YES=1 ;;
        *) usage ;;
    esac
done

mkdir -p "$RESULTS_DIR/dmesg_deltas"
LOG_FILE="$RESULTS_DIR/test_${INTERFACE}_${TIMESTAMP}.log"
SYSINFO="$RESULTS_DIR/sysinfo_${INTERFACE}_${TIMESTAMP}.txt"
REPORT="$RESULTS_DIR/report_${INTERFACE}_${TIMESTAMP}.txt"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

check_result() {
    local result=$1
    local test_name=$2
    if [ "$result" -eq 0 ]; then
        log "${GREEN}✓ PASS${NC}: $test_name"
        PASS_COUNT=$((PASS_COUNT + 1))
        TEST_RESULTS+=("PASS: $test_name")
    else
        log "${RED}✗ FAIL${NC}: $test_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        TEST_RESULTS+=("FAIL: $test_name")
    fi
}

skip_test() {
    log "${YELLOW}- SKIP${NC}: $1 ($2)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TEST_RESULTS+=("SKIP: $1 ($2)")
}

want() {
    [[ " $TESTS " == *" $1 "* ]]
}

dmesg_mark() {
    DMESG_MARKER=$(dmesg | wc -l)
}

# Saves the new dmesg lines; returns 1 if they contain an oops/WARN/BUG,
# a hung task, or one of the driver's bad-slot messages.
dmesg_check() {
    local name=$1
    local out="$RESULTS_DIR/dmesg_deltas/${name// /_}.txt"
    local now
    now=$(dmesg | wc -l)
    dmesg | tail -n $((now - DMESG_MARKER)) > "$out"
    DMESG_MARKER=$now
    if grep -qE "Oops|BUG:|WARNING:|Call Trace|blocked for more than|exceeded budget in poll|invalid RX correlator|no buffer for RX correlator" "$out"; then
        log "  ${RED}dmesg problems ($out):${NC}"
        grep -E "Oops|BUG:|WARNING:|blocked for more than|exceeded budget|RX correlator" "$out" | head -10 | sed 's/^/    /' | tee -a "$LOG_FILE"
        return 1
    fi
    return 0
}

peer_ping() {
    ping -c "${1:-5}" -W 2 -I "$INTERFACE" ${2:+-s $2} -M do "$PEER_IP" > /dev/null 2>&1 ||
        ping -c "${1:-5}" -W 2 -I "$INTERFACE" ${2:+-s $2} "$PEER_IP" > /dev/null 2>&1
}

peer_run() {
    [ -n "$PEER_SSH" ] && ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER_SSH" "$@"
}

ensure_ip() {
    ip link set dev "$INTERFACE" up 2>/dev/null
    ip addr show dev "$INTERFACE" | grep -q "inet $LOCAL_IP/" ||
        ip addr add "$LOCAL_IP/$PREFIX" dev "$INTERFACE" 2>/dev/null
}

kmsg_flood() {
    local tag=$1 n=$2 i
    for ((i = 1; i <= n; i++)); do
        echo "$tag $i" > /dev/kmsg
    done
}

# ---------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------
log "${BLUE}=== ibmveth fixes test: $INTERFACE -> $PEER_IP ($(date)) ===${NC}"
log "Tests: $TESTS   Results: $RESULTS_DIR"
log ""

if [ "$(id -u)" -ne 0 ]; then
    log "${RED}Run as root.${NC}"
    exit 1
fi
if [ ! -d "/sys/class/net/$INTERFACE" ]; then
    log "${RED}No interface $INTERFACE.${NC}"
    exit 1
fi
DRIVER=$(basename "$(readlink -f "/sys/class/net/$INTERFACE/device/driver")" 2>/dev/null)
if [ "$DRIVER" != "ibmveth" ]; then
    log "${RED}$INTERFACE uses driver '$DRIVER', not ibmveth.${NC}"
    exit 1
fi
SSH_CLIENT_IP=${SSH_CONNECTION:-}; SSH_CLIENT_IP=${SSH_CLIENT_IP%% *}
SSH_IFACE=$(ip route get "${SSH_CLIENT_IP:-127.0.0.1}" 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}')
if [ -n "${SSH_CONNECTION:-}" ] && [ "$SSH_IFACE" = "$INTERFACE" ]; then
    log "${RED}Your ssh session runs over $INTERFACE. Use a second interface.${NC}"
    exit 1
fi

ORIG_MTU=$(cat "/sys/class/net/$INTERFACE/mtu")
ensure_ip
if ! peer_ping 3; then
    log "${RED}Cannot ping $PEER_IP over $INTERFACE.${NC} Check that the peer has an"
    log "address in $LOCAL_IP/$PREFIX and that both adapters share a VLAN (HMC port VLAN ID)."
    exit 1
fi
log "${GREEN}✓${NC} $INTERFACE ($LOCAL_IP) reaches $PEER_IP; MTU $ORIG_MTU"
log ""

restore() {
    [ -n "$NETCONS_CFG" ] && [ -d "$NETCONS_CFG" ] && {
        echo 0 > "$NETCONS_CFG/enabled" 2>/dev/null
        rmdir "$NETCONS_CFG" 2>/dev/null
    }
    ip link set dev "$INTERFACE" mtu "$ORIG_MTU" 2>/dev/null
    ethtool -K "$INTERFACE" tso on > /dev/null 2>&1
    ethtool -K "$INTERFACE" rx on > /dev/null 2>&1
    [ -n "${ORIG_TX:-}" ] && ethtool -L "$INTERFACE" tx "$ORIG_TX" > /dev/null 2>&1
}
trap restore EXIT

# ---------------------------------------------------------------------
# Test 0: system info and config
# ---------------------------------------------------------------------
if want 0; then
    log "${BLUE}--- Test 0: system info and config ---${NC}"
    {
        echo "uname: $(uname -r)"
        grep -m1 -E '^cpu' /proc/cpuinfo
        grep -m1 -E '^model' /proc/cpuinfo
        echo "fw-version: $(tr -d '\0' < /proc/device-tree/ibm,fw-version 2>/dev/null)"
        lsmcode -A 2>/dev/null | head -5
        echo "driver: $(ethtool -i "$INTERFACE" | tr '\n' ' ')"
        echo "debug_fail_open: $( [ -e /sys/module/ibmveth/parameters/debug_fail_open ] && echo present || echo absent)"
    } > "$SYSINFO"
    CFG=""
    for f in /boot/kbuild-out/.config "/boot/config-$(uname -r)"; do
        [ -f "$f" ] && CFG="$f" && break
    done
    if [ -z "$CFG" ] && [ -f /proc/config.gz ]; then
        zcat /proc/config.gz > "$RESULTS_DIR/config" && CFG="$RESULTS_DIR/config"
    fi
    if [ -n "$CFG" ]; then
        grep -E 'CONFIG_(IBMVETH|NETCONSOLE|NETCONSOLE_DYNAMIC|NETPOLL|NET_POLL_CONTROLLER|DETECT_HUNG_TASK)=' "$CFG" >> "$SYSINFO"
    else
        echo "config: not found" >> "$SYSINFO"
    fi
    sed 's/^/  /' "$SYSINFO" | tee -a "$LOG_FILE"
    check_result 0 "Test 0: system info ($SYSINFO)"
    log ""
fi

# ---------------------------------------------------------------------
# Test 1: netconsole (patch 1)
# ---------------------------------------------------------------------
netcons_start() {
    local tag=$1
    if [ -d /sys/kernel/config/netconsole ] || { mount | grep -q configfs || mount -t configfs none /sys/kernel/config 2>/dev/null; [ -d /sys/kernel/config/netconsole ]; }; then
        NETCONS_CFG=/sys/kernel/config/netconsole/fixtest
        [ -d "$NETCONS_CFG" ] && { echo 0 > "$NETCONS_CFG/enabled"; rmdir "$NETCONS_CFG"; }
        mkdir "$NETCONS_CFG" || return 1
        echo "$INTERFACE" > "$NETCONS_CFG/dev_name"
        echo 6665 > "$NETCONS_CFG/local_port"
        echo "$LOCAL_IP" > "$NETCONS_CFG/local_ip"
        echo "$PEER_IP" > "$NETCONS_CFG/remote_ip"
        echo "$NETCONS_PORT" > "$NETCONS_CFG/remote_port"
        [ -n "$PEER_MAC" ] && echo "$PEER_MAC" > "$NETCONS_CFG/remote_mac"
        echo 1 > "$NETCONS_CFG/enabled" || return 1
        log "  netconsole target via configfs ($NETCONS_CFG)"
        return 0
    fi
    if modinfo netconsole > /dev/null 2>&1 && ! grep -q '^netconsole ' /proc/modules; then
        modprobe netconsole "netconsole=6665@$LOCAL_IP/$INTERFACE,$NETCONS_PORT@$PEER_IP/$PEER_MAC" || return 1
        log "  netconsole loaded as a module"
        return 0
    fi
    if grep -q "netconsole=.*$INTERFACE" /proc/cmdline; then
        log "  netconsole configured on the kernel command line"
        return 0
    fi
    return 1
}

if want 1; then
    log "${BLUE}--- Test 1: netconsole under load and during MTU/TSO changes (patch 1) ---${NC}"
    TAG="ibmveth-netcons-$TIMESTAMP"
    dmesg_mark
    if ! netcons_start "$TAG"; then
        skip_test "Test 1: netconsole" "no configfs netconsole, module or cmdline target; see the test plan"
    else
        if [ -n "$PEER_SSH" ]; then
            peer_run "pkill -f 'nc -u -l $NETCONS_PORT' ; (nohup sh -c 'nc -u -l $NETCONS_PORT > /tmp/$TAG.log' > /dev/null 2>&1 &) ; pgrep iperf3 > /dev/null || (nohup iperf3 -s -D > /dev/null 2>&1)"
            sleep 1
        else
            log "  ${YELLOW}On the peer run: nc -u -l $NETCONS_PORT | tee netcons.log ; iperf3 -s${NC}"
            log "  (or pass -s USER@HOST to let the script do it)"
            sleep 5
        fi

        IPERF_PID=""
        if command -v iperf3 > /dev/null; then
            iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -P 8 -t 120 > "$RESULTS_DIR/iperf_t1_${TIMESTAMP}.txt" 2>&1 &
            IPERF_PID=$!
        fi
        log "  printk flood under load (20000 lines + sysrq-t)"
        kmsg_flood "$TAG load" 20000
        echo t > /proc/sysrq-trigger 2>/dev/null

        log "  50 x (MTU 9000/1500, TSO off/on) with a printk flood"
        (
            for ((i = 0; i < 50; i++)); do
                ip link set dev "$INTERFACE" mtu 9000
                ip link set dev "$INTERFACE" mtu "$ORIG_MTU"
                ethtool -K "$INTERFACE" tso off > /dev/null 2>&1
                ethtool -K "$INTERFACE" tso on > /dev/null 2>&1
            done
        ) &
        LOOP_PID=$!
        kmsg_flood "$TAG reopen" 20000
        wait "$LOOP_PID"
        [ -n "$IPERF_PID" ] && wait "$IPERF_PID"
        sleep 2

        R=0
        dmesg_check "test1" || R=1
        ensure_ip
        peer_ping 5 || { log "  ${RED}no traffic over $INTERFACE afterwards${NC}"; R=1; }
        if [ -n "$PEER_SSH" ]; then
            GOT=$(peer_run "grep -c '$TAG' /tmp/$TAG.log; pkill -f 'nc -u -l $NETCONS_PORT'" 2>/dev/null | head -1)
            log "  peer received ${GOT:-0} of 40000 tagged netconsole lines (loss under load is fine)"
            [ "${GOT:-0}" -gt 0 ] || { log "  ${RED}no netconsole lines reached the peer${NC}"; R=1; }
            NETCONS_LINES=${GOT:-0}
        else
            log "  ${YELLOW}On the peer: grep -c '$TAG' netcons.log  (expect > 0)${NC}"
            NETCONS_LINES="count on peer"
        fi
        check_result $R "Test 1: netconsole (lines: $NETCONS_LINES)"
    fi
    log ""
fi

# ---------------------------------------------------------------------
# Test 3: regression (all patches; patch 4 RX paths)
# ---------------------------------------------------------------------
if want 3; then
    log "${BLUE}--- Test 3: regression (ping, iperf3, MTU) ---${NC}"
    dmesg_mark
    R=0
    DROP0=$(cat "/sys/class/net/$INTERFACE/statistics/rx_dropped")
    peer_ping 100 || { log "  ${RED}ping failed${NC}"; R=1; }
    if command -v iperf3 > /dev/null; then
        peer_run "pgrep iperf3 > /dev/null || iperf3 -s -D" > /dev/null 2>&1
        iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -P 8 -t 60 > "$RESULTS_DIR/iperf_t3_${TIMESTAMP}.txt" 2>&1 ||
            { log "  ${RED}iperf3 failed (is iperf3 -s running on the peer?)${NC}"; R=1; }
        grep -E "SUM.*receiver" "$RESULTS_DIR/iperf_t3_${TIMESTAMP}.txt" | tail -1 | sed 's/^/  /' | tee -a "$LOG_FILE"
    else
        log "  ${YELLOW}iperf3 not installed; traffic step skipped${NC}"
    fi
    ip link set dev "$INTERFACE" mtu 9000 || R=1
    ensure_ip
    if [ "$JUMBO" -eq 1 ]; then
        peer_ping 20 8000 || { log "  ${RED}jumbo ping failed${NC}"; R=1; }
    else
        peer_ping 20 || R=1
    fi
    ip link set dev "$INTERFACE" mtu "$ORIG_MTU" || R=1
    ensure_ip
    peer_ping 20 || R=1
    dmesg_check "test3" || R=1
    DROP1=$(cat "/sys/class/net/$INTERFACE/statistics/rx_dropped")
    log "  rx_dropped: $DROP0 -> $DROP1"
    check_result $R "Test 3: regression"
    log ""
fi

# ---------------------------------------------------------------------
# Test 4: unbind/bind under traffic (patch 3)
# ---------------------------------------------------------------------
if want 4; then
    log "${BLUE}--- Test 4: unbind/bind under traffic (patch 3) ---${NC}"
    dmesg_mark
    R=0
    UNIT=$(basename "$(readlink -f "/sys/class/net/$INTERFACE/device")")
    DRV=/sys/bus/vio/drivers/ibmveth
    IPERF_PID=""
    if command -v iperf3 > /dev/null; then
        iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -P 4 -t 30 > /dev/null 2>&1 &
        IPERF_PID=$!
        sleep 3
    fi
    log "  unbind $UNIT"
    echo "$UNIT" > "$DRV/unbind" || R=1
    [ -n "$IPERF_PID" ] && { kill "$IPERF_PID" 2>/dev/null; wait "$IPERF_PID" 2>/dev/null; }
    sleep 2
    log "  bind $UNIT"
    echo "$UNIT" > "$DRV/bind" || R=1
    for ((i = 0; i < 20; i++)); do
        NEWIF=$(ls "/sys/bus/vio/devices/$UNIT/net" 2>/dev/null | head -1)
        [ -n "$NEWIF" ] && break
        sleep 1
    done
    if [ -z "${NEWIF:-}" ]; then
        log "  ${RED}no netdev after bind${NC}"
        R=1
    else
        [ "$NEWIF" != "$INTERFACE" ] && log "  ${YELLOW}interface came back as $NEWIF${NC}" && INTERFACE=$NEWIF
        ensure_ip
        sleep 2
        peer_ping 10 || { log "  ${RED}no traffic after bind${NC}"; R=1; }
    fi
    dmesg_check "test4" || R=1
    check_result $R "Test 4: unbind/bind under traffic"
    log ""
fi

# ---------------------------------------------------------------------
# Test 7: MTU and offload changes under traffic (patch 7)
# ---------------------------------------------------------------------
if want 7; then
    log "${BLUE}--- Test 7: MTU and rx-csum/TSO changes under traffic (patch 7) ---${NC}"
    dmesg_mark
    R=0
    LOAD_PID=""
    if command -v iperf3 > /dev/null; then
        peer_run "pgrep iperf3 > /dev/null || iperf3 -s -D" > /dev/null 2>&1
        iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -P 8 -t 300 > /dev/null 2>&1 &
        LOAD_PID=$!
    else
        log "  ${YELLOW}iperf3 not installed; using ping -f${NC}"
        ping -f -I "$INTERFACE" "$PEER_IP" > /dev/null 2>&1 &
        LOAD_PID=$!
    fi
    sleep 3
    N=20
    log "  $N rounds of: mtu 9000/$ORIG_MTU, rx off/on, tso off/on"
    for ((i = 1; i <= N; i++)); do
        ip link set dev "$INTERFACE" mtu 9000 || R=1
        ip link set dev "$INTERFACE" mtu "$ORIG_MTU" || R=1
        ethtool -K "$INTERFACE" rx off > /dev/null 2>&1
        ethtool -K "$INTERFACE" rx on > /dev/null 2>&1
        ethtool -K "$INTERFACE" tso off > /dev/null 2>&1
        ethtool -K "$INTERFACE" tso on > /dev/null 2>&1
    done
    kill "$LOAD_PID" 2>/dev/null; wait "$LOAD_PID" 2>/dev/null
    ensure_ip
    sleep 2
    peer_ping 10 || { log "  ${RED}no traffic after the changes${NC}"; R=1; }
    dmesg_check "test7" || R=1
    check_result $R "Test 7: MTU and rx-csum/TSO changes under traffic"
    log ""
fi

# ---------------------------------------------------------------------
# Test 6: ethtool -L with a forced TX buffer allocation failure (patch 6)
# ---------------------------------------------------------------------
tx_now() {
    ethtool -l "$INTERFACE" 2>/dev/null |
        awk -v want="$1" '$0 ~ want {c=1} c && /^TX:/ {print $2; exit}'
}
if want 6; then
    log "${BLUE}--- Test 6: ethtool -L with a forced TX buffer allocation failure (patch 6) ---${NC}"
    KNOB=/sys/module/ibmveth/parameters/debug_fail_tx_ltb
    ensure_ip
    ORIG_TX=$(tx_now "Current hardware")
    MAX_TX=$(tx_now "Pre-set maximums")
    GOAL=$(( ${MAX_TX:-1} < 8 ? ${MAX_TX:-1} : 8 ))
    if [ ! -w "$KNOB" ]; then
        skip_test "Test 6: ethtool -L allocation failure" "no $KNOB; build a *-lab branch"
    elif [ "$GOAL" -lt 2 ]; then
        skip_test "Test 6: ethtool -L allocation failure" "only $MAX_TX TX queue(s)"
    else
        dmesg_mark
        R=0
        log "  TX queues: current $ORIG_TX, max $MAX_TX"
        ethtool -L "$INTERFACE" tx 1 || R=1
        echo 1 > "$KNOB"
        if ethtool -L "$INTERFACE" tx "$GOAL" 2> "$RESULTS_DIR/t6.err"; then
            log "  ${RED}ethtool -L tx $GOAL returned success although the allocation failed (the bug)${NC}"
            R=1
        else
            log "  ethtool -L tx $GOAL failed as expected: $(tr '\n' ' ' < "$RESULTS_DIR/t6.err")"
        fi
        echo 0 > "$KNOB"
        CUR=$(tx_now "Current hardware")
        log "  TX queues after the failed change: $CUR (expect 1)"
        [ "$CUR" = 1 ] || R=1
        ethtool -L "$INTERFACE" tx "$GOAL" || { log "  ${RED}ethtool -L tx $GOAL failed without the knob${NC}"; R=1; }
        CUR=$(tx_now "Current hardware")
        log "  TX queues after a normal change: $CUR (expect $GOAL)"
        [ "$CUR" = "$GOAL" ] || R=1
        peer_ping 10 || { log "  ${RED}no traffic${NC}"; R=1; }
        ethtool -L "$INTERFACE" tx "$ORIG_TX" || R=1
        dmesg_check "test6" || R=1
        check_result $R "Test 6: ethtool -L returns the allocation error"
    fi
    log ""
fi

# ---------------------------------------------------------------------
# Test 5: forced probe failure leaves no pool kobjects (patch 5)
# ---------------------------------------------------------------------
if want 5; then
    log "${BLUE}--- Test 5: forced probe failure, then rebind (patch 5) ---${NC}"
    KNOB=/sys/module/ibmveth/parameters/debug_fail_probe
    if [ ! -w "$KNOB" ]; then
        skip_test "Test 5: forced probe failure" "no $KNOB; build a *-lab branch"
    else
        dmesg_mark
        R=0
        UNIT=$(basename "$(readlink -f "/sys/class/net/$INTERFACE/device")")
        DRV=/sys/bus/vio/drivers/ibmveth
        DEVDIR=/sys/bus/vio/devices/$UNIT
        log "  unbind $UNIT"
        echo "$UNIT" > "$DRV/unbind" || R=1
        sleep 1
        log "  bind $UNIT with debug_fail_probe=1 (probe must fail)"
        echo 1 > "$KNOB"
        echo "$UNIT" > "$DRV/bind" 2>/dev/null
        echo 0 > "$KNOB"
        sleep 1
        if ls "$DEVDIR/net" > /dev/null 2>&1; then
            log "  ${RED}a netdev exists: the forced failure did not take effect${NC}"
            R=1
        fi
        if [ -d "$DEVDIR/pool0" ]; then
            log "  ${RED}pool0..pool4 are still in sysfs after the failed probe (the bug).${NC}"
            log "  ${RED}Not reading them: their memory was freed.${NC}"
            R=1
        else
            log "  no pool%d directories left after the failed probe"
        fi
        log "  bind $UNIT again"
        echo "$UNIT" > "$DRV/bind" || R=1
        NEWIF=""
        for ((i = 0; i < 20; i++)); do
            NEWIF=$(ls "$DEVDIR/net" 2>/dev/null | head -1)
            [ -n "$NEWIF" ] && break
            sleep 1
        done
        if [ -z "$NEWIF" ]; then
            log "  ${RED}no netdev after the second bind${NC}"
            R=1
        else
            [ "$NEWIF" != "$INTERFACE" ] && log "  ${YELLOW}interface came back as $NEWIF${NC}" && INTERFACE=$NEWIF
            if [ -r "$DEVDIR/pool0/num" ]; then
                log "  pool0/num after rebind: $(cat "$DEVDIR/pool0/num")"
            else
                log "  ${RED}pool0 missing after rebind${NC}"
                R=1
            fi
            ensure_ip
            sleep 2
            peer_ping 10 || { log "  ${RED}no traffic after rebind${NC}"; R=1; }
        fi
        if dmesg | tail -n $(( $(dmesg | wc -l) - DMESG_MARKER )) | grep -q "duplicate filename"; then
            log "  ${RED}sysfs reported a duplicate pool directory on rebind (the bug)${NC}"
            R=1
        fi
        dmesg_check "test5" || R=1
        check_result $R "Test 5: forced probe failure removes pool kobjects"
        [ "$R" -ne 0 ] && log "  ${YELLOW}Stale pool kobjects may remain; reboot before further tests.${NC}"
    fi
    log ""
fi

# ---------------------------------------------------------------------
# Test 2: forced open() failure (patch 2) - last, it can hang RTNL
# ---------------------------------------------------------------------
if want 2; then
    log "${BLUE}--- Test 2: forced open() failure on an MTU change (patch 2) ---${NC}"
    KNOB=/sys/module/ibmveth/parameters/debug_fail_open
    if [ ! -w "$KNOB" ]; then
        skip_test "Test 2: forced open() failure" "no $KNOB; build a *-lab branch"
    else
        if [ "$ASSUME_YES" -ne 1 ]; then
            log "  ${YELLOW}On the BEFORE kernel this hangs RTNL: all ip/ethtool commands block"
            log "  and only an LPAR restart from the HMC recovers. Keep the HMC console open.${NC}"
            read -r -p "  Continue? (yes/no): " ANS
            [ "$ANS" = "yes" ] || { skip_test "Test 2: forced open() failure" "not confirmed"; TESTS=""; }
        fi
    fi
    if [ -w "$KNOB" ] && want 2; then
        dmesg_mark
        R=0
        echo 1 > "$KNOB"
        if ip link set dev "$INTERFACE" mtu 9000 2> "$RESULTS_DIR/t2_mtu.err"; then
            log "  ${RED}MTU change did not fail; debug knob not effective${NC}"
            R=1
        else
            log "  MTU change failed as forced: $(cat "$RESULTS_DIR/t2_mtu.err")"
        fi
        ip -br link show dev "$INTERFACE" | sed 's/^/  /' | tee -a "$LOG_FILE"

        log "  ip link set dev $INTERFACE down (30 s limit)"
        ip link set dev "$INTERFACE" down &
        DOWN_PID=$!
        for ((i = 0; i < 30; i++)); do
            kill -0 "$DOWN_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$DOWN_PID" 2>/dev/null; then
            log "  ${RED}'ip link set down' is still blocked after 30 s: the double-close hang.${NC}"
            log "  ${RED}RTNL is held; restart the LPAR from the HMC.${NC}"
            log "  Wait ~2 min for the hung-task report, then save it:"
            log "    dmesg | grep -A30 'blocked for more than' > $RESULTS_DIR/t2_hung_task.txt"
            check_result 1 "Test 2: forced open() failure (hang reproduced; expected on BEFORE)"
            trap - EXIT
            TESTS=""
        else
            wait "$DOWN_PID" || R=1
            log "  down returned"
            echo 0 > "$KNOB"
            ip link set dev "$INTERFACE" up || { log "  ${RED}up failed${NC}"; R=1; }
            ensure_ip
            sleep 2
            peer_ping 10 || { log "  ${RED}no traffic after recovery${NC}"; R=1; }
            log "  MTU after recovery: $(cat "/sys/class/net/$INTERFACE/mtu")"
            dmesg_check "test2" || R=1
            check_result $R "Test 2: forced open() failure (down returns, up recovers)"
        fi
    fi
    log ""
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
{
    echo "ibmveth fixes LPAR test report ($(date))"
    echo "interface $INTERFACE  peer $PEER_IP  kernel $(uname -r)"
    echo
    [ -f "$SYSINFO" ] && cat "$SYSINFO" && echo
    for r in "${TEST_RESULTS[@]}"; do echo "$r"; done
} > "$REPORT"

log "${BLUE}=== Summary ===${NC}"
for r in "${TEST_RESULTS[@]}"; do
    log "  $r"
done
log ""
log "  Passed: $PASS_COUNT  Failed: $FAIL_COUNT  Skipped: $SKIP_COUNT"
log "  Report to send back: $REPORT"
log "  Full log: $LOG_FILE   dmesg deltas: $RESULTS_DIR/dmesg_deltas/"

[ "$FAIL_COUNT" -eq 0 ]
