# IBM veth / ibmveth Lab Test Scripts

Lab scripts for validating the IBM Virtual Ethernet (`ibmveth`) driver on
PowerVM / pseries: legacy single-queue and multi-queue (MQ) RX.

Remote: `git@github.com:mcao-zz/test.git` (branch `veth-mq-tests`).

## Canonical run (verify → test)

Pass interface and peer explicitly. Do not rely on script defaults
(`test-veth-mq.sh` defaults are `net0` / `9.3.20.62`). Use a host IP
only for `-t` (no `/24`).

```bash
# 1) Verify adapter + reload with dyndbg
sudo ./verify-mq-adapter.sh -d env9 -D -v

# 2) MQ functional suite
sudo ./test-veth-mq.sh -d env9 -t 192.168.100.2

# 3) Optional post-test health check (no reload)
./verify-mq-adapter.sh -d env9 -v
```

### About `-D`

- On **verify**: `-D` reloads `ibmveth` with `dyndbg=+p`. Prefer this first.
- On **test**: `-D` reloads again. Usually unnecessary after a debug verify.

---

## Lab roles (example)

| Role | Example | Notes |
|------|---------|--------|
| DUT / target | lp19 `env9` = `192.168.100.3` | Kernel under test; run scripts here |
| Peer / traffic | lp7 = `192.168.100.2` | Same switch; generate inbound RX to DUT |

For **RX on the DUT**, `iperf3 -s` belongs on the DUT (or use client `-R`).

---

## Two-LPAR traffic (real RX / resize under load)

No special switch programming is required for `iperf3` on ports
`5201-5216`. You need IP connectivity, `iperf3` on both ends, and those
TCP ports allowed if a firewall is on.

### 1. Pre-checks

```bash
# on DUT
ip addr show dev env9
ping -c 3 192.168.100.2

# on peer
ping -c 3 192.168.100.3
```

Short pings may show warmup loss (ARP); a longer run should be ~0% loss.

### 2. Start servers on the DUT (RX sink)

```bash
# on lp19 (192.168.100.3)
for port in $(seq 5201 5216); do
    iperf3 -s -p "$port" -D
done
ss -ltnp | grep iperf3
```

### 3. Start clients on the peer (inbound to DUT)

```bash
# on lp7 (192.168.100.2)
export DUT_IP=192.168.100.3

for port in $(seq 5201 5216); do
    iperf3 -c "$DUT_IP" -t 300 -P 4 -p "$port" &
done
```

Many TCP flows help exercise PHYP RX queue selection. Watch on DUT:

```bash
watch -n1 'ethtool -S env9 | grep -E "^rx[0-9]+_packets:|^rx[0-9]+_interrupts:"'
```

### 4. Resize while traffic runs

```bash
# on DUT, while iperf is active
ethtool -S env9 > /tmp/stats_before.txt
sudo ./rx_queue_size.sh env9 2
ethtool -S env9 > /tmp/stats_after.txt
```

Or run the full suite under traffic:

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
sudo ./test-veth-mq.sh -d env9 -t 192.168.100.2
```

---

## `rx_queue_size.sh`

Cycles RX queue count on an interface (default `env9`):

1. baseline → max (from `ethtool -l`, capped at 16)
2. max → 1
3. forward ramp 2…max
4. reverse ramp (max−1)…1

After **each** step it checks:

| Check | Why |
|-------|-----|
| `ethtool -l` RX count | Published queue count |
| `ethtool -S` `rxN_packets` rows | Per-queue stats match |
| `/proc/interrupts` lines for iface | IRQ count matches RX |
| `sysfs` `queues/rx-*` | Kernel RX queue objects |
| iface `UP` | Link still usable |
| `rx_invalid` / `rx_no_buffer` / replenish fail | Error counters |
| `rx*_packets` snapshot | Distribution under iperf |
| dmesg delta | “Successfully resized…”, no Oops/BUG |
| optional `PEER` ping | Connectivity after resize |

```bash
sudo ./rx_queue_size.sh [iface] [delay_seconds]
sudo PEER=192.168.100.2 ./rx_queue_size.sh env9 2
```

Per-step logs: `/tmp/ibmveth-rx-cycle-<iface>-<timestamp>/`.  
Does **not** generate traffic — start iperf (above) first for
resize-under-load.

---

## Lab inputs

| Input | Flag / arg | Examples |
|-------|------------|----------|
| Interface | `-d` / `$1` | `env9`, `net0` |
| Peer host | `-t` | `192.168.100.2` (no CIDR) |
| Debug reload | `-D` | prefer on verify |

---

## Main scripts

| Script | Role |
|--------|------|
| `verify-mq-adapter.sh` | Adapter + optional debug reload |
| `test-veth-mq.sh` | Full MQ suite |
| `test-legacy-veth.sh` | Single-queue / fallback |

Reload in those scripts (and `lpar-tests/`) honors `IBMVETH_KO=/path/to/ibmveth.ko`
(or a build directory). Not part of `run-all.sh` — run legacy separately:

```bash
sudo IBMVETH_KO=/home/ming/ibmveth-build \
  ./test-legacy-veth.sh -d env9 -t <peer-ip> -D
```
| `rx_queue_size.sh` | Aggressive ethtool -L cycle |

Module/kernel helpers (`install-*`, `update-veth-mq-*`, `kernels-set.sh`)
are LPAR-specific; see `SCRIPTS-README.md` (historical branch names).

Debug helpers: `enable-ibmveth-debug.sh`, `disable-ibmveth-debug.sh`,
`plug-mq-adapter.sh`.

---

## Requirements

- PowerVM / pseries; MQ tests need MQ-capable PHYP
- Reachable peer on the same L2 for real RX
- Root for module reload, interface control, `ethtool -L`
- `iperf3` on both ends for bulk RX (optional but recommended)

## Safety

Scripts may reload `ibmveth`, bounce interfaces, and change queue
counts. Prefer console or an alternate management path.

## Logs

- MQ tests: `/tmp/ibmveth-mq-test-results/`
- Verify: `./verify-logs/` (not for git)

## Kernel under test

| Field | Value |
|-------|-------|
| Kernel remote | `git@github.com:mcao-zz/linux.git` |
| Branch | `veth-mq-upstream-netnext-v4-review` |
| Tip (as of 2026-07-27) | `a8dfd6177669` |

## Validation plan

See **[TEST-PLAN.txt](TEST-PLAN.txt)** for T1–T21 and
**[TEST-PLAN-DEEP-DIVE.txt](TEST-PLAN-DEEP-DIVE.txt)** for per-patch D*
cases derived from each commit message.

### Long-term layout (combined)

| Layer | Path | Role |
|-------|------|------|
| **Auto harness** | `lpar-tests/` | Small scripts + `env.sh` + `run-all.sh` (add new T* here) |
| **Lab monoliths** | repo root | `verify-mq-adapter.sh`, `test-veth-mq.sh`, `rx_queue_size.sh` — deep/manual or wrapped |

Prefer **new automated cases in `lpar-tests/`**. Keep root scripts for bring-up and heavy one-shot suites; call them from `lpar-tests/lab-smoke.sh` / `t14-rx-cycle.sh`.

```bash
cd lpar-tests
# sudo clears exported env — pass IFACE/PEER on the command line:
sudo IFACE=env9 PEER=192.168.100.2 ./run-all.sh
# Flow: quiet → type 'yes' after starting lp7 iperf → prove bulk+MQ RX →
#       heavy with MQ RX re-proofs between stages → cleanup
# Thresholds (defaults): MIN_RX_DELTA=10000 / 5s, MIN_ACTIVE_RX_QUEUES=2, MQ_PROOF_RX=8
# Standalone MQ RX proof (iperf clients already running):
#   sudo IFACE=env9 PEER=192.168.100.2 ./t-mq-rx-under-load.sh
```

`run-all.sh` phases:

0. **Dyndbg load** (`DYNDBG=1`, default) — reload with `dyndbg=+p`
   (`modprobe`, or `insmod` when `IBMVETH_KO=` points at a `.ko` / build dir)
   before any tests; saves/restores `$IFACE` IPv4
1. **Quiet** — lab-smoke (verify `-v`; skip second `-D` reload when phase 0
   ran), smoke, t12, **t10 stats-lifetime**, **t11 debugfs geometry**, t8,
   **t17 down-no-live-irqs**, t19, **t21 RSS hfunc**, t16, **t20 reload-MQ**
   (reload again with dyndbg), SQ close / -L with `IPERF=0`
2. **Iperf + MQ RX proof** — start `iperf3 -s`, wait for `yes`, require bulk
   `rx*_packets` Δ ≥ `MIN_RX_DELTA` and ≥ `MIN_ACTIVE_RX_QUEUES` queues active
   at `MQ_PROOF_RX` (rejects ping-sized noise)
3. **Heavy** — T14 with `UNDER_RX=1` (per-step error Δ, bulk RX, new-queue
   traffic on scale-up), close-mq / parallel / -L, MQ RX re-proof after each
4. **Cleanup** — stop only iperf servers this run started; final ping

```bash
sudo IFACE=env9 PEER=192.168.100.2 ./run-all.sh
sudo IFACE=env9 PEER=192.168.100.2 IBMVETH_KO=/home/ming/ibmveth-build ./run-all.sh
sudo IFACE=env9 PEER=192.168.100.2 EXTERNAL_IPERF=1 ./run-all.sh
sudo IFACE=env9 PEER=192.168.100.2 ./run-all.sh --external-iperf
sudo IFACE=env9 PEER=192.168.100.2 CHECK_HEALTH=1 ./run-all.sh --check-health
# (vars must be on the sudo line, or pass as args — sudo drops prior exports)
sudo IFACE=env9 PEER=192.168.100.2 DYNDBG=1 ./run-all.sh          # default
sudo IFACE=env9 PEER=192.168.100.2 DYNDBG=0 ./run-all.sh          # no phase-0 reload
sudo IFACE=env9 PEER=192.168.100.2 SIMPLE_IPERF=1 ./run-all.sh    # one-port soft under-load
sudo IFACE=env9 PEER=192.168.100.2 LAB_FULL=1 ./run-all.sh        # + test-veth-mq.sh
sudo IFACE=env9 PEER=192.168.100.2 SKIP_HEAVY=1 ./run-all.sh
sudo IFACE=env9 PEER=192.168.100.2 SKIP_QUIET=1 ./run-all.sh
sudo IFACE=env9 PEER=192.168.100.2 NONINTERACTIVE=1 ./run-all.sh
sudo IFACE=env9 PEER=192.168.100.2 SKIP_PARALLEL=1 ./run-all.sh
```

Piecemeal (same `sudo VAR=...` pattern):

```bash
sudo IFACE=env9 PEER=192.168.100.2 ./smoke.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t10-stats-lifetime.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t11-debugfs-geometry.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t12-stats-debugfs.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t8-down-stash.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t17-down-no-live-irqs.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t19-set-channels.sh
sudo IFACE=env9 PEER=192.168.100.2 TX_SET=2 ./t19-set-channels.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t21-rss-hfunc.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t20-reload-restore-mq.sh
sudo IFACE=env9 PEER=192.168.100.2 ./t16-hcall-deltas.sh
sudo IFACE=env9 PEER=192.168.100.2 LAB_FULL=1 ./lab-smoke.sh
```
