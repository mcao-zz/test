#!/bin/bash
# T21 / P15 — RSS hash algorithm via ethtool get_rxfh / set_rxfh
#
#   ethtool -x $IFACE
#   ethtool -X $IFACE hfunc crc32|xor
#
# PHYP Murmur/Additive map to ethtool aliases crc32/xor. Key and
# indirection table stay hypervisor-managed (-EOPNOTSUPP). Ops need
# multi_queue firmware (max_rx >= 2); non-MQ firmware is T13.
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t21-rss-hfunc.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

need_root
need_peer
save_dmesg_mark

log "=== T21/P15 RSS hash algorithm (ethtool -x/-X) on $IFACE ==="
iface_up

max=$(max_rx)
if [[ "$max" -lt 2 ]]; then
	log "max_rx=$max — non-MQ firmware; expect -EOPNOTSUPP on -x/-X"
	if ethtool -x "$IFACE" >"$LOGDIR/t21-rxfh-nomq.txt" 2>"$LOGDIR/t21-rxfh-nomq.err"; then
		die "ethtool -x succeeded on non-MQ (want Operation not supported)"
	fi
	if ! grep -qiE 'not supported|Operation not supported|EOPNOTSUPP' \
		"$LOGDIR/t21-rxfh-nomq.err"; then
		log "WARN: ethtool -x stderr (review $LOGDIR/t21-rxfh-nomq.err):"
		cat "$LOGDIR/t21-rxfh-nomq.err" >&2 || true
	fi
	ok "non-MQ: get_rxfh rejected"
	ping_ok
	check_no_lockup
	check_no_oops
	log "T21 PASS (non-MQ EOPNOTSUPP)"
	exit 0
fi

# Ensure MQ is published so RX path is multi-queue (hfunc still gated on
# adapter->multi_queue from probe, but geometry asserts MQ is live).
ethtool_rx 4 || die "ethtool -L rx 4 failed"
assert_rx_geometry 4

ethtool -x "$IFACE" >"$LOGDIR/t21-rxfh-before.txt" 2>"$LOGDIR/t21-rxfh-before.err" \
	|| die "ethtool -x failed on MQ (see $LOGDIR/t21-rxfh-before.err)"
ok "ethtool -x succeeded"
explain_rss_rxfh "$LOGDIR/t21-rxfh-before.txt" "$LOGDIR/t21-rxfh-before.err"

orig=$(current_rss_hfunc)
[[ -n "$orig" ]] || die "could not parse RSS hash function from ethtool -x"
[[ "$orig" == "crc32" || "$orig" == "xor" ]] || \
	die "unexpected hfunc='$orig' (want crc32 or xor alias)"
ok "current hfunc=$orig (PHYP Murmur↔crc32 / Additive↔xor)"

# Round-trip both aliases; FW may only support one.
set_ok=0
for want in crc32 xor; do
	log "ethtool -X $IFACE hfunc $want"
	if ethtool -X "$IFACE" hfunc "$want" \
		>"$LOGDIR/t21-set-$want.out" 2>"$LOGDIR/t21-set-$want.err"; then
		got=$(current_rss_hfunc)
		[[ "$got" == "$want" ]] || die "after -X hfunc $want, ethtool -x shows '$got'"
		ok "set hfunc $want and verified"
		set_ok=$((set_ok + 1))
		ping_ok
	else
		# Missing .get_rx_ring_count → userspace never reaches set_rxfh.
		if grep -qi 'Cannot get RX ring count' "$LOGDIR/t21-set-$want.err"; then
			die "ethtool -X hfunc $want: missing get_rx_ring_count (driver bug): $(tr '\n' ' ' <"$LOGDIR/t21-set-$want.err")"
		fi
		if grep -qiE 'not supported|Operation not supported|EOPNOTSUPP' \
			"$LOGDIR/t21-set-$want.err"; then
			log "hfunc $want not supported by firmware (OK)"
		else
			die "ethtool -X hfunc $want failed unexpectedly: $(cat "$LOGDIR/t21-set-$want.err")"
		fi
	fi
done
[[ "$set_ok" -ge 1 ]] || die "neither crc32 nor xor could be set"
ok "at least one hfunc set succeeded ($set_ok)"

# Restore original if different from current
cur=$(current_rss_hfunc)
if [[ "$cur" != "$orig" ]]; then
	ethtool -X "$IFACE" hfunc "$orig" \
		|| die "failed to restore hfunc $orig"
	[[ "$(current_rss_hfunc)" == "$orig" ]] || die "restore hfunc $orig failed"
	ok "restored hfunc=$orig"
fi

# Key / indirection are hypervisor-managed (sizes 0 → ethtool rejects, or
# set_rxfh returns -EOPNOTSUPP if a request reaches the driver).
log "reject indir change (ethtool -X equal …)"
if ethtool -X "$IFACE" equal 4 \
	>"$LOGDIR/t21-equal.out" 2>"$LOGDIR/t21-equal.err"; then
	die "ethtool -X equal 4 succeeded (indir must stay hypervisor-managed)"
fi
ok "indir equal rejected: $(tr '\n' ' ' <"$LOGDIR/t21-equal.err" | head -c 120)"

log "reject hash key change (ethtool -X hkey …)"
# 40-byte zero key; may fail client-side when key_size==0, or in driver.
if ethtool -X "$IFACE" hkey 0000000000000000000000000000000000000000 \
	>"$LOGDIR/t21-hkey.out" 2>"$LOGDIR/t21-hkey.err"; then
	die "ethtool -X hkey succeeded (key must stay hypervisor-managed)"
fi
ok "hkey rejected: $(tr '\n' ' ' <"$LOGDIR/t21-hkey.err" | head -c 120)"

# Unsupported hfunc alias
log "reject unsupported hfunc (toeplitz)"
if ethtool -X "$IFACE" hfunc toeplitz \
	>"$LOGDIR/t21-toeplitz.out" 2>"$LOGDIR/t21-toeplitz.err"; then
	die "ethtool -X hfunc toeplitz succeeded (only crc32/xor aliases)"
fi
ok "toeplitz rejected"

assert_rx_geometry 4
ping_ok
check_no_lockup
check_no_oops
log "T21 PASS (RSS hfunc get/set + reject key/indir)"
