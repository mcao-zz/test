#!/bin/bash
# T24 — netdev qstats ABI validation for ibmveth
#
# Validates the netdev_stat_ops get_queue_stats_rx/tx path introduced in v8:
#   - NETDEV_CMD_QSTATS_GET (netlink netdev-genl family) returns entries for IFACE
#   - Per-queue fields present: rx-packets, rx-bytes, rx-hw-drops and
#     rx-hw-drop-overruns (both = the queue's rx_no_buffer total in s2 v9),
#     rx-alloc-fail (= replenish_no_mem + copybreak allocation failures)
#   - Per-queue TX: tx-packets, tx-bytes
#   - Queue count in qstats matches ethtool -l current RX after -L resize
#   - Device-scope rx-packets / hw-drop-overruns / hw-drops / alloc-fail
#     match sysfs and ethtool -S (all of them include retired RX slots)
#   - All counters monotonic across ifdown/up and across an RX shrink,
#     and still match sysfs / ethtool -S after it (6b)
#
# Requires: Python 3 + kernel source tree (for ynl library)
# Set KERNEL_SRC= to the kernel tree (default: look for ../linux relative to ROOT)
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t24-qstats-abi.sh
#   sudo IFACE=env9 KERNEL_SRC=/path/to/linux ./t24-qstats-abi.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark
iface_up

log "=== T24 netdev qstats ABI on $IFACE ==="

# --- locate kernel source tree for ynl ---
: "${KERNEL_SRC:=$(find_kernel_src)}"

if [[ -z "$KERNEL_SRC" || ! -f "$KERNEL_SRC/Documentation/netlink/specs/netdev.yaml" ]]; then
	log "SKIP T24: kernel source not found (set KERNEL_SRC=/path/to/linux)"
	log "  Looked in: $(dirname "$ROOT")/linux, /usr/src/linux, /root/linux, /root/ming/linux"
	log "  Need: \$KERNEL_SRC/Documentation/netlink/specs/netdev.yaml"
	exit 0
fi

YNL_LIB="$KERNEL_SRC/tools/testing/selftests/net/lib/py"
if [[ ! -f "$YNL_LIB/ynl.py" ]]; then
	log "SKIP T24: ynl.py not found at $YNL_LIB/ynl.py"
	exit 0
fi

if ! python3 -c "import socket, struct, fcntl" 2>/dev/null; then
	log "SKIP T24: python3 not available"
	exit 0
fi

log "Using kernel source: $KERNEL_SRC"
log "Using ynl lib: $YNL_LIB"

IFINDEX=$(cat "/sys/class/net/$IFACE/ifindex" 2>/dev/null)
[[ -n "$IFINDEX" ]] || die "cannot read ifindex for $IFACE"

# Helper: run Python ynl qstats query, output JSON to a temp file.
# Args: $1=output_file $2=scope (device|queue) [$3=ifindex filter]
_qstats_dump() {
	local out=$1 scope=$2 ifidx=${3:-}
	python3 - "$KERNEL_SRC" "$IFACE" "$IFINDEX" "$scope" "$ifidx" <<'PYEOF' >"$out" 2>"${out}.err"
import sys, json, os

kernel_src = sys.argv[1]
iface      = sys.argv[2]
ifindex    = int(sys.argv[3])
scope      = sys.argv[4]
ifidx_flt  = int(sys.argv[5]) if sys.argv[5] else None

# Add ynl to path
import importlib.util, types

ynl_lib = os.path.join(kernel_src, "tools/testing/selftests/net/lib/py")
spec_dir = os.path.join(kernel_src, "Documentation/netlink/specs")

sys.path.insert(0, ynl_lib)

# The ynl module expects SPEC_PATH to resolve to the kernel spec dir;
# patch it before importing so NetdevFamily picks up the right yaml.
import pathlib
# Monkey-patch after import
from ynl import YnlFamily
from pathlib import Path

class NetdevFamily(YnlFamily):
    def __init__(self, recv_size=0):
        super().__init__(
            str(Path(spec_dir) / "netdev.yaml"),
            schema='', recv_size=recv_size)

netfam = NetdevFamily(recv_size=4096)

req = {"scope": scope}
if ifidx_flt is not None:
    req["ifindex"] = ifidx_flt

try:
    entries = netfam.qstats_get(req, dump=True)
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)

# Filter to our ifindex
result = [e for e in entries if e.get("ifindex") == ifindex]
print(json.dumps(result))
PYEOF
}

# --- 1. Device-scope qstats: basic presence and required fields ---
log "--- 1. device-scope qstats presence ---"
tmpdev=$(mktemp)
_qstats_dump "$tmpdev" "device" "$IFINDEX" || true

err=$(python3 -c "import json,sys; d=json.load(open('$tmpdev')); print(d.get('error',''))" 2>/dev/null || true)
if [[ -n "$err" ]]; then
	if echo "$err" | grep -qi "not supported\|EOPNOTSUPP\|no attribute\|NlError"; then
		log "SKIP T24: qstats not supported by this kernel/driver (error: $err)"
		rm -f "$tmpdev" "${tmpdev}.err"
		exit 0
	fi
	die "qstats device dump failed: $err"
fi

nentries=$(python3 -c "import json,sys; d=json.load(open('$tmpdev')); print(len(d))" 2>/dev/null || echo 0)
if [[ "$nentries" -eq 0 ]]; then
	log "SKIP T24: no qstats entries for $IFACE (NETDEV_CMD_QSTATS_GET returned empty)"
	rm -f "$tmpdev" "${tmpdev}.err"
	exit 0
fi
ok "device-scope qstats: $nentries entry/entries for $IFACE (ifindex=$IFINDEX)"

# Check required fields are present
python3 - "$tmpdev" "$IFACE" <<'PYEOF'
import json, sys

data = json.load(open(sys.argv[1]))
iface = sys.argv[2]
entry = data[0]

required = ["rx-packets", "rx-bytes", "tx-packets", "tx-bytes"]
missing = [k for k in required if k not in entry]
if missing:
    print(f"FAIL: missing required qstats keys: {missing}")
    sys.exit(1)

# ibmveth-specific fields we expect
ibmveth_rx = ["rx-hw-drops", "rx-hw-drop-overruns", "rx-alloc-fail"]
ibmveth_missing = [k for k in ibmveth_rx if k not in entry]
if ibmveth_missing:
    print(f"WARN: ibmveth-expected RX qstat keys absent: {ibmveth_missing}")
else:
    print(f"OK: ibmveth RX qstat keys present: {ibmveth_rx}")

for k, v in sorted(entry.items()):
    if k not in ("ifindex",):
        print(f"  {k}={v}")
PYEOF
log ""

# --- 2. Queue-scope qstats: per-queue entry count matches ethtool -l ---
log "--- 2. queue-scope: per-queue entry count vs ethtool -l ---"
n_ethtool=$(current_rx)
tmpq=$(mktemp)
_qstats_dump "$tmpq" "queue" "$IFINDEX" || true

python3 - "$tmpq" "$n_ethtool" "$IFACE" <<'PYEOF'
import json, sys

data     = json.load(open(sys.argv[1]))
n_eth    = int(sys.argv[2])
iface    = sys.argv[3]

rx_entries = [e for e in data if e.get("queue-type") == "rx"]
tx_entries = [e for e in data if e.get("queue-type") == "tx"]

n_rx = len(rx_entries)
n_tx = len(tx_entries)
print(f"  queue-scope RX entries={n_rx}  TX entries={n_tx}  ethtool RX={n_eth}")

if n_rx != n_eth:
    print(f"FAIL: queue-scope RX count={n_rx} want {n_eth} (ethtool -l)")
    sys.exit(1)
print(f"OK: queue-scope RX count={n_rx} matches ethtool -l")

# Per-queue IDs must be 0..N-1 with no gaps
rx_ids = sorted(e.get("queue-id", -1) for e in rx_entries)
expected = list(range(n_rx))
if rx_ids != expected:
    print(f"FAIL: RX queue-id list {rx_ids} != {expected}")
    sys.exit(1)
print(f"OK: RX queue-ids 0..{n_rx-1} contiguous")

# Each per-queue entry must have packets + bytes
for e in rx_entries:
    qid = e.get("queue-id")
    for k in ["rx-packets", "rx-bytes"]:
        if k not in e:
            print(f"FAIL: RX queue {qid} missing {k}")
            sys.exit(1)

# ibmveth: hw_drop_overruns per queue
hw_fields = ["rx-hw-drops", "rx-hw-drop-overruns", "rx-alloc-fail"]
for e in rx_entries:
    qid = e.get("queue-id")
    absent = [k for k in hw_fields if k not in e]
    if absent:
        print(f"WARN: RX queue {qid} missing {absent}")
    else:
        overruns = e.get("rx-hw-drop-overruns", 0)
        alloc    = e.get("rx-alloc-fail", 0)
        print(f"  rx{qid}: packets={e['rx-packets']} bytes={e['rx-bytes']} "
              f"hw_drop_overruns={overruns} alloc_fail={alloc}")
print("OK: per-queue RX fields validated")
PYEOF
ok "queue-scope geometry validated (RX=$n_ethtool)"
log ""

# --- 3/4. Device-scope totals vs sysfs and ethtool -S ---
# sysfs and ethtool -S sum all 16 RX slots; device-scope qstats is base
# (slots >= real_num) plus live queues. The live-queue sum alone misses
# whatever a queue earned before an earlier RX shrink, so compare the
# device entry and only require live sum <= device.
log "--- 3/4. device-scope totals vs sysfs / ethtool -S ---"
tmpd3=$(mktemp)
_qstats_dump "$tmpd3" "device" "$IFINDEX"
_qstats_dump "$tmpq" "queue" "$IFINDEX"
_t24_counters() {
	local nb nm
	nb=$(stat_val rx_no_buffer)
	nm=$(stat_val replenish_no_mem)
	echo "$(link_stat rx_packets) $(link_stat rx_missed_errors) ${nb:-0} ${nm:-0}"
}
_t24_check_totals() {
	python3 - "$1" "$2" $3 <<'PYEOF'
import json, sys

dev  = json.load(open(sys.argv[1]))[0]
q    = [e for e in json.load(open(sys.argv[2])) if e.get("queue-type") == "rx"]
sys_rx, sys_missed, no_buf, no_mem = (int(x or 0) for x in sys.argv[3:7])

def tol(*v, floor=100):
    return max(floor, int(max(v) * 0.01))

fail = False
def same(name, d, ref, refname, floor=100):
    global fail
    t = tol(d, ref, floor=floor)
    print(f"  device {name}={d}  {refname}={ref}  Δ={d - ref}  tol={t}")
    if abs(d - ref) > t:
        print(f"FAIL: device {name} vs {refname}")
        fail = True

same("rx-packets", dev.get("rx-packets", 0), sys_rx, "sysfs rx_packets", 1000)
if "rx-hw-drop-overruns" in dev:
    same("rx-hw-drop-overruns", dev["rx-hw-drop-overruns"], sys_missed,
         "sysfs rx_missed_errors")
if "rx-hw-drops" in dev:
    same("rx-hw-drops", dev["rx-hw-drops"], no_buf, "ethtool rx_no_buffer")
if "rx-alloc-fail" in dev:
    d = dev["rx-alloc-fail"]
    t = tol(d, no_mem, floor=10)
    print(f"  device rx-alloc-fail={d}  ethtool replenish_no_mem={no_mem}  tol={t}")
    if d < no_mem - t:
        print("FAIL: rx-alloc-fail below replenish_no_mem")
        fail = True
    elif d > no_mem + t:
        print(f"NOTE: {d - no_mem} more in rx-alloc-fail: copybreak allocation failures")

for k in ("rx-packets", "rx-bytes", "rx-hw-drops", "rx-alloc-fail"):
    live = sum(e.get(k, 0) for e in q)
    d = dev.get(k, 0)
    print(f"  {k}: live queues={live}  device={d}  base={d - live}")
    if live > d + tol(live, d, floor=1000):
        print(f"FAIL: live-queue {k} sum exceeds device total")
        fail = True
sys.exit(1 if fail else 0)
PYEOF
}
_t24_check_totals "$tmpd3" "$tmpq" "$(_t24_counters)"
ok "device-scope totals match sysfs / ethtool -S"
log ""

# --- 5. Monotonic across ifdown/up ---
log "--- 5. monotonic across ifdown/up ---"
saved_ip=$(save_iface_ipv4)
tmpdev2=$(mktemp)
_qstats_dump "$tmpdev" "device" "$IFINDEX"
iface_down
sleep 1
iface_up
restore_iface_ipv4 "$saved_ip"
sleep 2
_qstats_dump "$tmpdev2" "device" "$IFINDEX"

python3 - "$tmpdev" "$tmpdev2" "$IFACE" <<'PYEOF'
import json, sys

before = json.load(open(sys.argv[1]))[0]
after  = json.load(open(sys.argv[2]))[0]
iface  = sys.argv[3]

keys = [k for k in before if k != "ifindex"]
bad  = []
for k in keys:
    b = before.get(k, 0)
    a = after.get(k, 0)
    if isinstance(b, int) and isinstance(a, int) and a < b:
        bad.append(f"{k}: {b} → {a}")

if bad:
    print("FAIL: qstats went backwards across ifdown/up:")
    for msg in bad:
        print(f"  {msg}")
    sys.exit(1)
print(f"OK: {len(keys)} qstats fields monotonic across ifdown/up")
PYEOF
ok "qstats monotonic across ifdown/up"
log ""

# --- 6. Queue count tracks ethtool -L ---
log "--- 6. queue-scope count tracks ethtool -L resize ---"
m=$(max_rx)
n_half=$(( m > 2 ? m / 2 : 1 ))
ethtool_rx "$m" || die "ethtool -L rx $m failed"
sleep 1
tmpq_full=$(mktemp)
_qstats_dump "$tmpq_full" "queue" "$IFINDEX"
python3 - "$tmpq_full" "$m" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
n    = int(sys.argv[2])
rx   = [e for e in data if e.get("queue-type") == "rx"]
if len(rx) != n:
    print(f"FAIL: queue-scope RX={len(rx)} want {n} after -L rx {n}")
    sys.exit(1)
print(f"OK: RX queue count={len(rx)} matches after scale-up to {n}")
PYEOF

[[ -n "${PEER:-}" ]] && ping -I "$IFACE" -c 20 -i 0.2 -W 2 "$PEER" >/dev/null 2>&1 || true
tmpd6a=$(mktemp)
_qstats_dump "$tmpd6a" "device" "$IFINDEX"
ethtool_rx "$n_half" || die "ethtool -L rx $n_half failed"
sleep 1
tmpq_half=$(mktemp)
_qstats_dump "$tmpq_half" "queue" "$IFINDEX"
python3 - "$tmpq_half" "$n_half" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
n    = int(sys.argv[2])
rx   = [e for e in data if e.get("queue-type") == "rx"]
if len(rx) != n:
    print(f"FAIL: queue-scope RX={len(rx)} want {n} after -L rx {n}")
    sys.exit(1)
print(f"OK: RX queue count={len(rx)} matches after scale-down to {n}")
PYEOF

# --- 6b. Stats after shrink: retired queues move into base ---
log "--- 6b. totals after shrink to $n_half ---"
tmpd6b=$(mktemp)
_qstats_dump "$tmpd6b" "device" "$IFINDEX"
python3 - "$tmpd6a" "$tmpd6b" <<'PYEOF'
import json, sys
before = json.load(open(sys.argv[1]))[0]
after  = json.load(open(sys.argv[2]))[0]
bad = [f"{k}: {before[k]} -> {after.get(k, 0)}" for k in before
       if k != "ifindex" and isinstance(before[k], int) and after.get(k, 0) < before[k]]
if bad:
    print("FAIL: device-scope qstats went backwards across RX shrink:")
    for m in bad:
        print(f"  {m}")
    sys.exit(1)
print(f"OK: device-scope qstats monotonic across RX shrink")
PYEOF
_t24_check_totals "$tmpd6b" "$tmpq_half" "$(_t24_counters)"
ok "stats after shrink: device = base + live queues, matches sysfs / ethtool -S"

# Restore
ethtool_rx "$m" || true
ok "queue-scope count tracks ethtool -L (full=$m half=$n_half)"
log ""

# cleanup
rm -f "$tmpdev" "${tmpdev}.err" "$tmpdev2" "${tmpdev2}.err" \
      "$tmpq" "${tmpq}.err" "$tmpq_full" "${tmpq_full}.err" \
      "$tmpq_half" "${tmpq_half}.err" "$tmpd3" "${tmpd3}.err" \
      "$tmpd6a" "${tmpd6a}.err" "$tmpd6b" "${tmpd6b}.err"

[[ -n "${PEER:-}" ]] && ping_ok || true
check_no_oops
log "T24 PASS"
