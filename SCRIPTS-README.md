# Build / update helper notes (historical)

**For running lab tests (verify → test), use [README.md](README.md).**
This file only documents the older kernel/module update helpers.

## Current series (update as tip moves)

| Field | Value |
|-------|-------|
| Kernel remote | `git@github.com:mcao-zz/linux.git` |
| Review branch | `veth-mq-s1` (see SERIES.md for net / s2) |
| Tip (2026-11-17) | `bc82f0c24742` |

Lab branch menu is `veth-mq-s1` / `ibmveth-net-fixes` / `veth-mq-s2`
(see SERIES.md). `veth-mq-for-testing` is a lab alias — point it at
the tree under test.

## Overview

Two scripts for updating and building `ibmveth` from a GitHub linux tree:

1. **update-veth-mq-git-simple.sh** — module-only build (fast)
2. **update-veth-mq-kernel.sh** — full kernel build (slow, reboot)

## Module-only build

```bash
./update-veth-mq-git-simple.sh
# or: ./update-veth-mq-git-simple.sh <branch>
```

After build, install/reload with the install/reload helpers or
`verify-mq-adapter.sh -D`, then run `test-veth-mq.sh` per README.md.

## Full kernel build

```bash
./update-veth-mq-kernel.sh
# or: ./update-veth-mq-kernel.sh <branch>
sudo reboot
```

## Prerequisites

GitHub SSH access and a linux checkout with a remote pointing at your
fork (example remote name in older docs: `mingupstream`).

## Historical branch names (pre–net-next v4 series)

These names appear in older scripts/menus; treat as archive:

- `veth-mq-phase2`
- `veth-mq-phase2-per-queue-pools`
- `veth-mq-phase3`
- `veth-mq-phase3-h-function-handling`
- `veth-mq-for-testing`

Prefer `veth-mq-upstream-netnext-v4-review` for current MQ RX work.

## See also

- [README.md](README.md) — verify → test workflow
- Scripts may still reference removed docs (`DEBUG-COMMITS-ANALYSIS.md`,
  etc.); ignore those links if the files are not in this branch.
