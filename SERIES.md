# Series under test

Update this when the kernel tip or patch count changes.

| Field | Value |
|-------|-------|
| Driver series | ibmveth MQ RX v6 |
| Kernel branch | `veth-mq-v6-squash` |
| Patch count | 15 (base `805185b7c7a1`) |
| Tip subject | ibmveth: Complete set_channels down-path and mq_fallback max_rx cap |
| Kernel tree tip | `86afcb13035a` |
| Kernel remote | `git@github.com:mcao-zz/linux.git` |
| Changelog | git notes on each commit (`git log --notes 805185b7c7a1..veth-mq-v6-squash`) |
| v6 ethtool -S | no `hcall_*`; no `rxN_packets` / `txN_packets` (those are `netdev_stat_ops` / sysfs); per-queue extras are `rxN_interrupts` / `rxN_polls` / `rxN_no_buffer_drops` |
| v6 get_channels | live `rx_count`; `mq_fallback` caps `max_rx` (does not clamp `rx_count`) |
| debugfs | `buffer_pools` header column `Count` (was `Size`); column order unchanged |
| P15 RSS | `ethtool -x` / `-X hfunc murmur\|additive` via H_VIOCTL ILLAN_MULTIQUEUE_HASH; key/indir hypervisor-managed |

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
