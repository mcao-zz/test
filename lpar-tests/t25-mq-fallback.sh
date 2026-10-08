#!/bin/bash
# T25 — mq_fallback ABI: max_rx cap and -L rx reject path
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t25-mq-fallback.sh
#
# Tests the v8 mq_fallback gate (ibmveth_resize_rx_channels):
#
#  MQ-capable firmware (max_rx > current_rx):
#    - max_rx >= 2
#    - ethtool -L rx N (N > 1, N <= max_rx) succeeds
#    - ethtool -L rx N (N > max_rx) returns EINVAL
#
#  Non-MQ / fallback (max_rx == current_rx == 1):
#    - max_rx == 1  (get_channels caps at live count after fallback)
#    - ethtool -L rx 2 returns EOPNOTSUPP or EINVAL (blocked)
#    - ethtool -L rx 1 (no-op) succeeds (no-op path in driver)
#
# The test auto-detects which firmware state applies and validates the
# appropriate invariants. It never induces fallback — that requires
# a reload to a non-MQ-firmware LPAR.
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
save_dmesg_mark

log "=== T25 mq_fallback ABI on $IFACE ==="
iface_up

cur_rx=$(current_rx)
max_rx_val=$(max_rx)
[[ -n "$cur_rx" && "$cur_rx" -ge 1 ]] || die "current_rx not parseable"
[[ -n "$max_rx_val" && "$max_rx_val" -ge 1 ]] || die "max_rx not parseable"
log "current_rx=$cur_rx  max_rx=$max_rx_val"

# ── Invariant: max_rx is always >= current_rx (get_channels contract) ──────
[[ "$max_rx_val" -ge "$cur_rx" ]] || \
	die "max_rx=$max_rx_val < current_rx=$cur_rx — get_channels broken"
ok "max_rx ($max_rx_val) >= current_rx ($cur_rx)"

if [[ "$max_rx_val" -gt 1 ]]; then
	# ── MQ path ─────────────────────────────────────────────────────────────
	log "--- MQ firmware detected (max_rx=$max_rx_val) ---"
	ok "MQ firmware: max_rx=$max_rx_val"

	# (a) -L rx 2 must succeed (MQ available, firmware ok)
	log "MQ: ethtool -L rx 2 (expect success)"
	ethtool_rx 2 || die "MQ: ethtool -L rx 2 failed — should be allowed on MQ firmware"
	assert_rx_geometry 2
	ok "MQ: -L rx 2 accepted"

	# (b) -L rx max_rx must succeed
	if [[ "$max_rx_val" -ge 2 ]]; then
		log "MQ: ethtool -L rx $max_rx_val (max boundary, expect success)"
		ethtool_rx "$max_rx_val" || die "MQ: ethtool -L rx $max_rx_val failed at max boundary"
		assert_rx_geometry "$max_rx_val"
		ok "MQ: -L rx $max_rx_val (max boundary) accepted"
	fi

	# (c) -L rx max_rx+1 must fail (EINVAL — exceeds IBMVETH_MAX_RX_QUEUES)
	exceed=$((max_rx_val + 1))
	log "MQ: ethtool -L rx $exceed (exceeds max, expect error)"
	if ethtool -L "$IFACE" rx "$exceed" 2>/dev/null; then
		die "MQ: ethtool -L rx $exceed accepted — should fail (max_rx=$max_rx_val)"
	fi
	ok "MQ: -L rx $exceed (> max_rx) correctly rejected"

	# (d) no-op: -L rx current must succeed without any state change
	cur_now=$(current_rx)
	log "MQ: ethtool -L rx $cur_now (no-op, expect success)"
	ethtool_rx "$cur_now" || die "MQ: no-op ethtool -L rx $cur_now failed"
	got=$(current_rx)
	[[ "$got" == "$cur_now" ]] || die "MQ: no-op -L changed RX ($cur_now → $got)"
	ok "MQ: no-op -L rx $cur_now succeeded, RX unchanged"

	# Restore to 1 so the test is idempotent (low-resource baseline).
	ethtool_rx 1 || log "WARN: failed to restore RX=1 after MQ test (non-fatal)"

else
	# ── mq_fallback / non-MQ path ────────────────────────────────────────
	log "--- Non-MQ / fallback detected (max_rx=1, current_rx=$cur_rx) ---"
	[[ "$cur_rx" -eq 1 ]] || \
		die "fallback: current_rx=$cur_rx but max_rx=1 — unexpected state"
	ok "mq_fallback: max_rx=1, current_rx=1 (growth blocked)"

	# (a) -L rx 2 must fail (mq_fallback gate: EOPNOTSUPP or EINVAL)
	log "fallback: ethtool -L rx 2 (expect error)"
	err_out=$(ethtool -L "$IFACE" rx 2 2>&1 || true)
	if ethtool -L "$IFACE" rx 2 2>/dev/null; then
		die "fallback: ethtool -L rx 2 accepted — mq_fallback gate missing"
	fi
	log "fallback: -L rx 2 error: $err_out"
	ok "mq_fallback: -L rx 2 correctly blocked"

	# (b) -L rx 1 (no-op) must succeed — no-op path fires before the gate
	log "fallback: ethtool -L rx 1 (no-op, expect success)"
	ethtool_rx 1 || die "fallback: no-op ethtool -L rx 1 failed — no-op path broken"
	got=$(current_rx)
	[[ "$got" -eq 1 ]] || die "fallback: RX changed from 1 to $got on no-op -L"
	ok "mq_fallback: no-op -L rx 1 accepted, RX=1 unchanged"

	# (c) max_rx must equal current_rx (cap enforced in get_channels)
	max_recheck=$(max_rx)
	[[ "$max_recheck" -eq 1 ]] || \
		die "fallback: max_rx=$max_recheck after no-op — should remain 1"
	ok "mq_fallback: max_rx remains capped at 1"
fi

check_no_lockup
check_no_oops
log "T25 PASS"
