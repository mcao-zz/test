# Series under test

Update this when the kernel tip or patch count changes.

Split after Jakub's v8 review (2026-11-17). net v2 and s1 v2 are on the
list (s1 v2 mailed 2026-11-23); s2 is not mailed yet and waits for s1.

| Field | net | series 1 | series 2 |
|-------|-----|----------|----------|
| Driver series | `[PATCH net v2 0/2]` | `[PATCH net-next v2 0/8]` SQ prep | `[PATCH net-next 0/13]` MQ enable |
| Kernel branch | `ibmveth-net-fixes-v2` | `veth-mq-s1-v2` | `veth-mq-s2-v2` |
| Patch count | 2 | 8 | 13 |
| Tip | `fa65ee7c216d` | `eefd22519ad6` | `c5955cfa0810` |
| Kernel remote | `git@github.com:mcao-zz/linux.git` | same | same |

s2 sits on `fefea210df7f` (s1 v2 plus a merge of the two net fixes,
standing in for net reaching net-next).

Lab fetch: `git fetch mingupstream` then `git reset --hard mingupstream/<branch>`
(`update-veth-mq-git-simple.sh <branch>`). Alias `veth-mq-for-testing` is
whatever the lab last pointed at — retarget it to `veth-mq-s1` for SQ
smoke, `veth-mq-s2` only after s2 is the thing under test.

## Which suite

| Tree | LPAR | QEMU |
|------|------|------|
| `ibmveth-net-fixes` | T13 lifecycle + t26 TX shrink under load; N2 needs a reset | stock QEMU: N1 in `init-s1.c` (N2 skip: hard to queue a reset) |
| `veth-mq-s1` | `./lpar-tests/run_s1_all.sh` = `run_legacy_all` minus debugfs/qstats (`SKIP_STATS=1 SKIP_T11=1 SKIP_T24=1`). Geometry is ethtool -l + /proc/interrupts, not leftover `rxN_interrupts`. **Do not** run T3 / `run_mq_all` / `-L rx 4` | stock QEMU (`notes/numa/tools/qemu`): `./run.sh up <wt-s1>; ./run.sh build s1; ./run.sh boot n4 s1`. Do not use NUMA `init.c` as pass/fail |
| `veth-mq-s2-v2` | `run_mq_all.sh` when LPAR is back (s2 notes below) | own QEMU `mqsuite=s2v9` (150/0 on `c5955cfa0810`; not LPAR evidence) |

s1 has no `buffer_pools` debugfs, no qstats, and no RSS hfunc. Skip
t12/t11/t24. t13 still runs; debugfs asserts skip when the file is
absent. t21 must stay unsupported. t26 is N1 (`ethtool -L tx` under
traffic, RX unchanged). Cover letters must not claim "Tested on
Power11" from QEMU.

s2 (v9 internally) has no `buffer_pools` debugfs, no RSS (`get/set_rxfh`)
and no `mq_fallback`. t11 and the t12 debugfs part skip unless
`EXPECT_DEBUGFS=1`; t21 expects `ethtool -x`/`-X` to be refused (not in
`run_mq_all`). Per-queue counters are qstats only (t24). The default RX
count is `min(netif_get_num_default_rss_queues(), 8)` (t23). CMO
partitions get one RX queue even on MQ firmware. An RX `-L` on a running
device closes and reopens it and restores the RX mode (t27); a TX-only
`-L` does not reopen.

## History of plan revisions

| Date | Note |
|------|------|
| 2026-07-23 | Initial plan + scripts; dropped classic-close tip patch from series |
| 2026-07-23 | Restacked hollow P9-P14 so subjects match diffs; tip tree unchanged |
| 2026-07-27 | Tip `a8dfd6177669`: qstats define move; IRQ ownership (leave queue_irq[0], open dispose unwind); P13 message why down-state RX is stashed |
| 2026-07-27 | TEST-PLAN on veth-mq-tests: added T14–T20 for v4 (geometry, stash, hcall deltas, set_channels, reload) |
| 2026-07-27 | Test plan sharpened after re-review: queue0 IRQ ownership/reopen checks, stats visibility semantics vs current geometry, explicit P14 invalid-buffer recovery expectations, stronger down-state stash and TX verification notes |
| 2026-07-29 | Tip `7e14b04f6649` P15 RSS hash algorithm (ethtool -x/-X); T21 `t21-rss-hfunc.sh` |
| 2026-07-29 | Tip `35aa5469dac5` P15 folds get_rx_ring_count (fixes ethtool -X ring-count EOPNOTSUPP); T21 hard-fails that signature |
| 2026-07-30 | Tip `7e14b04f6649` P15 commit message tightened (why + aliases + ring-count; ≤75 cols) |
| 2026-08-28 | Retarget harness at v6 squash `86afcb13035a`: drop hcall_*/rxN_packets ethtool ABI; geometry via rxN_interrupts; packet totals via sysfs ndo_get_stats64 |
| 2026-11-17 | Retarget at split: net `ibmveth-net-fixes`, s1 `veth-mq-s1`, s2 `veth-mq-s2`. LPAR down; QEMU stock for s1/legacy |
| 2026-11-17 | s2 harness: geometry via ethtool -l + /proc/interrupts; leftover v8 `rxN_interrupts` not on `-S` |
| 2026-11-24 | Retarget at v2 branches (net `fa65ee7c216d`, s1 `eefd22519ad6`, s2 13 patches `c5955cfa0810`). t11/t12 debugfs skip, t21 expects refusal, t23 v9 default, t24 device-scope totals + after-shrink check, new t27 (reopen RX mode / TX-only), t28 (failslab recovery), t29 (jumbo / pool sysfs with MQ); check_no_lockup no longer hides check_no_oops' delta |
