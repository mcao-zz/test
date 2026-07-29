#!/bin/bash
# T21 / P15 — RSS hash algorithm via ethtool get_rxfh / set_rxfh
#
# Quiet (default): get/set crc32|xor, reject key/indir/toeplitz, ping.
# UNDER_RX=1: under proven inbound traffic, switch hfunc and require:
#   - bulk + MQ spread still proven
#   - error counters (invalid/no_buffer/replenish_fail) within MAX_ERR_DELTA
#   - log per-queue Δ before/after (PHYP owns indir — remapping is soft)
#
#   sudo IFACE=env9 PEER=192.168.100.2 ./t21-rss-hfunc.sh
#   sudo IFACE=env9 PEER=192.168.100.2 UNDER_RX=1 ./t21-rss-hfunc.sh
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$DIR/env.sh"

: "${UNDER_RX:=0}"
: "${T21_RX:=8}"          # geometry for under-traffic proof
: "${MAX_ERR_DELTA:=50}"  # allow small noise under switch

need_root
need_peer
save_dmesg_mark

set_hfunc_or_die() {
	local want=$1
	local tag=$2
	log "ethtool -X $IFACE hfunc $want ($tag)"
	if ! ethtool -X "$IFACE" hfunc "$want" \
		>"$LOGDIR/t21-set-${tag}.out" 2>"$LOGDIR/t21-set-${tag}.err"; then
		if grep -qi 'Cannot get RX ring count' "$LOGDIR/t21-set-${tag}.err"; then
			die "ethtool -X hfunc $want: missing get_rx_ring_count: $(tr '\n' ' ' <"$LOGDIR/t21-set-${tag}.err")"
		fi
		die "ethtool -X hfunc $want failed: $(cat "$LOGDIR/t21-set-${tag}.err")"
	fi
	got=$(current_rss_hfunc)
	[[ "$got" == "$want" ]] || die "after -X hfunc $want, ethtool -x shows '$got'"
	ok "hfunc=$want verified"
}

# Snapshot "qid delta" lines over RX_SAMPLE_SECS into a file for compare/log.
sample_queue_deltas() {
	local label=$1
	local out=$2
	local wait=${RX_SAMPLE_SECS}
	local before after q c b d

	before=$(mktemp)
	after=$(mktemp)
	snapshot_rx_queue_packets >"$before"
	sleep "$wait"
	snapshot_rx_queue_packets >"$after"

	: >"$out"
	log "=== $label: ${wait}s per-queue Δ ==="
	while read -r q c; do
		b=$(awk -v q="$q" '$1 == q { print $2; exit }' "$before")
		b=${b:-0}
		d=$((c - b))
		echo "$q $d" >>"$out"
		if [[ "$d" -gt 0 ]]; then
			log "  rx${q}_packets Δ=$d"
		fi
	done <"$after"
	rm -f "$before" "$after"
}

log "=== T21/P15 RSS hash algorithm (ethtool -x/-X) on $IFACE UNDER_RX=$UNDER_RX ==="
iface_up

max=$(max_rx)
if [[ "$max" -lt 2 ]]; then
	[[ "$UNDER_RX" = 1 ]] && die "UNDER_RX=1 requires MQ firmware (max_rx=$max)"
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

# ------------------------------------------------------------------
# UNDER_RX=1 — hash switch under inbound MQ traffic
# ------------------------------------------------------------------
if [[ "$UNDER_RX" = 1 ]]; then
	ethtool_rx "$T21_RX" || die "ethtool -L rx $T21_RX failed"
	assert_rx_geometry "$T21_RX"
	explain_rss_rxfh

	orig=$(current_rss_hfunc)
	[[ "$orig" == "crc32" || "$orig" == "xor" ]] || \
		die "unexpected hfunc='$orig' (want crc32 or xor)"
	ok "starting hfunc=$orig under traffic"

	# Pick the other alias if possible; else re-set same (still validates path).
	other=xor
	[[ "$orig" == "xor" ]] && other=crc32

	prove_mq_rx_under_load "t21-before-switch"
	sample_queue_deltas "t21-before-$orig" "$LOGDIR/t21-qdelta-before.txt"
	snap_core_errors

	if ethtool -X "$IFACE" hfunc "$other" \
		>"$LOGDIR/t21-under-other.out" 2>"$LOGDIR/t21-under-other.err"; then
		[[ "$(current_rss_hfunc)" == "$other" ]] || die "switch to $other not visible"
		ok "switched $orig → $other under traffic"
		switched=1
	else
		if grep -qi 'Cannot get RX ring count' "$LOGDIR/t21-under-other.err"; then
			die "under traffic: missing get_rx_ring_count"
		fi
		if grep -qiE 'not supported|Operation not supported|EOPNOTSUPP' \
			"$LOGDIR/t21-under-other.err"; then
			log "WARN: hfunc $other not supported by FW — re-applying $orig under traffic"
			set_hfunc_or_die "$orig" "under-same"
			switched=0
		else
			die "ethtool -X hfunc $other failed: $(cat "$LOGDIR/t21-under-other.err")"
		fi
	fi

	sleep 2
	check_core_error_deltas "t21-post-switch"
	prove_mq_rx_under_load "t21-after-switch"
	sample_queue_deltas "t21-after-$(current_rss_hfunc)" "$LOGDIR/t21-qdelta-after.txt"

	log "NOTE: PHYP owns indirection — queue Δ shift after hfunc change is"
	log "      informative, not a hard pass/fail. Expect no error storm + MQ spread."
	if [[ -f "$LOGDIR/t21-qdelta-before.txt" && -f "$LOGDIR/t21-qdelta-after.txt" ]]; then
		if cmp -s "$LOGDIR/t21-qdelta-before.txt" "$LOGDIR/t21-qdelta-after.txt"; then
			log "queue Δ pattern unchanged after hfunc switch (OK — flows may hash same)"
		else
			ok "queue Δ pattern changed after hfunc switch (hasher/remap effect)"
		fi
	fi

	if [[ "${switched:-0}" = 1 ]]; then
		set_hfunc_or_die "$orig" "under-restore"
		prove_mq_rx_under_load "t21-restored"
		check_core_error_deltas "t21-post-restore"
	fi

	ping_ok
	check_no_lockup
	check_no_oops
	log "T21 PASS (RSS hfunc under traffic: no error storm, MQ spread held)"
	exit 0
fi

# ------------------------------------------------------------------
# Quiet path — get/set + rejects (no iperf required)
# ------------------------------------------------------------------
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

cur=$(current_rss_hfunc)
if [[ "$cur" != "$orig" ]]; then
	set_hfunc_or_die "$orig" "quiet-restore"
fi

log "reject indir change (ethtool -X equal …)"
if ethtool -X "$IFACE" equal 4 \
	>"$LOGDIR/t21-equal.out" 2>"$LOGDIR/t21-equal.err"; then
	die "ethtool -X equal 4 succeeded (indir must stay hypervisor-managed)"
fi
ok "indir equal rejected: $(tr '\n' ' ' <"$LOGDIR/t21-equal.err" | head -c 120)"

log "reject hash key change (ethtool -X hkey …)"
if ethtool -X "$IFACE" hkey 0000000000000000000000000000000000000000 \
	>"$LOGDIR/t21-hkey.out" 2>"$LOGDIR/t21-hkey.err"; then
	die "ethtool -X hkey succeeded (key must stay hypervisor-managed)"
fi
ok "hkey rejected: $(tr '\n' ' ' <"$LOGDIR/t21-hkey.err" | head -c 120)"

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
log "TIP: UNDER_RX=1 ./t21-rss-hfunc.sh  # after lp7 inbound — drops + MQ spread"
