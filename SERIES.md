# Series under test

Update this when the kernel tip or patch count changes.

| Field | Value |
|-------|-------|
| Driver series | ibmveth MQ RX v4 |
| Kernel branch | `veth-mq-upstream-netnext-v4-review` |
| Patch count | 15 (base `805185b7c7a1`) |
| Tip subject | ibmveth: Add RSS hash algorithm configuration support |
| Kernel tree tip | `35aa5469dac58bbdcd7f81ef12e6732d9d31641e` |
| Kernel remote | `git@github.com:mcao-zz/linux.git` |
| PHYP notes | Open enable↔post either OK (drops if early enable). Close free-lan vs free_irq either OK once masked. |
| v4 open | MQ: replenish then unmask. SQ: classic kick (poll posts then enable). |
| v4 close | mask + napi_disable + free_irq, then free_lan (v3 tip order) |
| P15 RSS | `ethtool -x` / `-X hfunc crc32|xor` via H_VIOCTL ILLAN_MULTIQUEUE_HASH; key/indir hypervisor-managed; needs `get_rx_ring_count` for `-X` |

## History of plan revisions

| Date | Note |
|------|------|
| 2026-07-23 | Initial plan + scripts; dropped classic-close tip patch from series |
| 2026-07-23 | Restacked hollow P9-P14 so subjects match diffs; tip tree unchanged |
| 2026-07-27 | Tip `a8dfd6177669`: qstats define move; IRQ ownership (leave queue_irq[0], open dispose unwind); P13 message why down-state RX is stashed |
| 2026-07-27 | TEST-PLAN on veth-mq-tests: added T14–T20 for v4 (geometry, stash, hcall deltas, set_channels, reload) |
| 2026-07-27 | Test plan sharpened after re-review: queue0 IRQ ownership/reopen checks, stats visibility semantics vs current geometry, explicit P14 invalid-buffer recovery expectations, stronger down-state stash and TX verification notes |
| 2026-07-29 | Tip `7fc556ffa0f6` P15 RSS hash algorithm (ethtool -x/-X); T21 `t21-rss-hfunc.sh` |
| 2026-07-29 | Tip `35aa5469dac5` P15 folds get_rx_ring_count (fixes ethtool -X ring-count EOPNOTSUPP); T21 hard-fails that signature |
