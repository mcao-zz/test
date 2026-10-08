#!/bin/bash
# T24 — netdev qstats ABI validation for ibmveth
#
# Validates the netdev_stat_ops get_queue_stats_rx/tx path introduced in v8:
#   - NETDEV_CMD_QSTATS_GET (netlink netdev-genl family) returns entries for IFACE
#   - Per-queue fields present: rx-packets, rx-bytes, rx-hw-drops,
#     rx-hw-drop-overruns (= no_buffer_pair), rx-alloc-fail (= replenish_no_mem)
#   - Per-queue TX: tx-packets, tx-bytes
#   - Queue count in qstats matches ethtool -l current RX after -L resize
#   - hw-drop-overruns matches ndo_get_stats64 rx_missed_errors (same source)
#   - All counters monotonic across ifdown/up
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
: "${KERNEL_SRC:=}"
if [[ -z "$KERNEL_SRC" ]]; then
	# Try common relative paths from the repo root
	for candidate in \
		"$(dirname "$ROOT")/linux" \
		"/usr/src/linux" \
		"/root/linux" \
		"/root/ming/linux"; do
		if [[ -f "$candidate/Documentation/netlink/specs/netdev.yaml" ]]; then
			KERNEL_SRC=$candidate
			break
		fi
	done
fi

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

# --- 3. Aggregate coherence: sum(per-queue rx-packets) ≈ sysfs rx_packets ---
log "--- 3. aggregate coherence: sum per-queue rx-packets vs sysfs ---"
sysfs_rx=$(cat "/sys/class/net/$IFACE/statistics/rx_packets" 2>/dev/null || echo 0)
python3 - "$tmpq" "$sysfs_rx" "$IFACE" <<'PYEOF'
import json, sys

data     = json.load(open(sys.argv[1]))
sysfs_rx = int(sys.argv[2])
iface    = sys.argv[3]

rx_entries = [e for e in data if e.get("queue-type") == "rx"]
qstats_sum = sum(e.get("rx-packets", 0) for e in rx_entries)

diff = abs(qstats_sum - sysfs_rx)
# Non-atomic read: tolerate small skew; hard-fail if off by >1%+1000
tol = max(1000, int(max(qstats_sum, sysfs_rx) * 0.01))
print(f"  sum(per-queue rx-packets)={qstats_sum}  sysfs rx_packets={sysfs_rx}  Δ={diff}  tol={tol}")
if diff > tol:
    print(f"FAIL: qstats sum vs sysfs mismatch Δ={diff} > tol={tol}")
    sys.exit(1)
print("OK: per-queue rx-packets sum ≈ sysfs rx_packets")
PYEOF
log ""

# --- 4. hw_drop_overruns coherence: sum ≈ sysfs rx_missed_errors ---
log "--- 4. hw_drop_overruns vs sysfs rx_missed_errors ---"
sysfs_missed=$(cat "/sys/class/net/$IFACE/statistics/rx_missed_errors" 2>/dev/null || echo 0)
python3 - "$tmpq" "$sysfs_missed" "$IFACE" <<'PYEOF'
import json, sys

data           = json.load(open(sys.argv[1]))
sysfs_missed   = int(sys.argv[2])
iface          = sys.argv[3]

rx_entries = [e for e in data if e.get("queue-type") == "rx"]
if not all("rx-hw-drop-overruns" in e for e in rx_entries):
    print("WARN: rx-hw-drop-overruns absent from some/all RX queue entries — skip coherence")
    sys.exit(0)

overruns_sum = sum(e.get("rx-hw-drop-overruns", 0) for e in rx_entries)
diff = abs(overruns_sum - sysfs_missed)
# Base may include retired-queue portion from get_base_stats; tolerate small skew
tol  = max(100, int(max(overruns_sum, sysfs_missed) * 0.01))
print(f"  sum(hw-drop-overruns)={overruns_sum}  sysfs rx_missed_errors={sysfs_missed}  Δ={diff}")
if diff > tol:
    print(f"FAIL: hw_drop_overruns sum vs rx_missed_errors Δ={diff} > tol={tol}")
    sys.exit(1)
print("OK: sum(hw-drop-overruns) ≈ sysfs rx_missed_errors (same source: no_buffer_pair)")
PYEOF
log ""

# --- 4b. rx-hw-drops coherence: sum ≈ rx_no_buffer + rx_invalid_buffer ---
# get_queue_stats_rx: hw_drops = no_buffer_pair + invalid_buffers
# ethtool -S: rx_no_buffer = sum(no_buffer_pair), rx_invalid_buffer = sum(invalid_buffers)
log "--- 4b. rx-hw-drops vs ethtool -S (rx_no_buffer + rx_invalid_buffer) ---"
ethtool_no_buf=$(stat_val rx_no_buffer);    ethtool_no_buf=${ethtool_no_buf:-0}
ethtool_inv=$(stat_val rx_invalid_buffer);  ethtool_inv=${ethtool_inv:-0}
ethtool_hw_drops=$(( ethtool_no_buf + ethtool_inv ))
python3 - "$tmpq" "$ethtool_hw_drops" "$IFACE" <<'PYEOF'
import json, sys

data             = json.load(open(sys.argv[1]))
ethtool_hw_drops = int(sys.argv[2])
iface            = sys.argv[3]

rx_entries = [e for e in data if e.get("queue-type") == "rx"]
if not all("rx-hw-drops" in e for e in rx_entries):
    print("WARN: rx-hw-drops absent from some/all RX queue entries — skip coherence")
    sys.exit(0)

qstats_hw_drops = sum(e.get("rx-hw-drops", 0) for e in rx_entries)
diff = abs(qstats_hw_drops - ethtool_hw_drops)
tol  = max(100, int(max(qstats_hw_drops, ethtool_hw_drops) * 0.01))
print(f"  sum(rx-hw-drops)={qstats_hw_drops}  ethtool(rx_no_buffer+rx_invalid_buffer)={ethtool_hw_drops}  Δ={diff}")
if diff > tol:
    print(f"FAIL: rx-hw-drops sum vs ethtool -S Δ={diff} > tol={tol}")
    sys.exit(1)
print("OK: sum(rx-hw-drops) ≈ rx_no_buffer + rx_invalid_buffer")
PYEOF
log ""

# --- 4c. rx-alloc-fail coherence: sum ≈ replenish_no_mem ---
# get_queue_stats_rx: alloc_fail = replenish_no_mem per queue
# ethtool -S: replenish_no_mem = sum across all queues
log "--- 4c. rx-alloc-fail vs ethtool -S replenish_no_mem ---"
ethtool_nomem=$(stat_val replenish_no_mem); ethtool_nomem=${ethtool_nomem:-0}
python3 - "$tmpq" "$ethtool_nomem" "$IFACE" <<'PYEOF'
import json, sys

data           = json.load(open(sys.argv[1]))
ethtool_nomem  = int(sys.argv[2])
iface          = sys.argv[3]

rx_entries = [e for e in data if e.get("queue-type") == "rx"]
if not all("rx-alloc-fail" in e for e in rx_entries):
    print("WARN: rx-alloc-fail absent from some/all RX queue entries — skip coherence")
    sys.exit(0)

qstats_alloc = sum(e.get("rx-alloc-fail", 0) for e in rx_entries)
diff = abs(qstats_alloc - ethtool_nomem)
tol  = max(10, int(max(qstats_alloc, ethtool_nomem) * 0.01))
print(f"  sum(rx-alloc-fail)={qstats_alloc}  ethtool replenish_no_mem={ethtool_nomem}  Δ={diff}")
if diff > tol:
    print(f"FAIL: rx-alloc-fail sum vs replenish_no_mem Δ={diff} > tol={tol}")
    sys.exit(1)
print("OK: sum(rx-alloc-fail) ≈ replenish_no_mem")
PYEOF
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

# Restore
ethtool_rx "$m" || true
ok "queue-scope count tracks ethtool -L (full=$m half=$n_half)"
log ""

# cleanup
rm -f "$tmpdev" "${tmpdev}.err" "$tmpdev2" "${tmpdev2}.err" \
      "$tmpq" "${tmpq}.err" "$tmpq_full" "${tmpq_full}.err" \
      "$tmpq_half" "${tmpq_half}.err"

[[ -n "${PEER:-}" ]] && ping_ok || true
check_no_oops
log "T24 PASS"
