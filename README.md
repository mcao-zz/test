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

## Lab roles (balco example)

| Role | MQ private L2 | Legacy / public L2 |
|------|---------------|--------------------|
| DUT iface | `env9` = `192.168.1.133` | `net0` = `10.48.36.x` |
| Peer | `192.168.1.153` | `10.48.36.153` |
| Config | `lpar-tests/lab.conf` (from `lab.conf.example`) | switch profile in that file |

`PEER` must be on the **same L2 as `IFACE`**. Do not use the public peer for `env9`.

For **RX on the DUT**, run `iperf3 -s` on the DUT; peer runs `iperf3 -c $DUT_IP`.

### Lab config (`lab.conf`)

**Prefer the config file.** Put `IFACE` / `PEER` / `DUT_IP` / `IBMVETH_KO` /
iperf knobs in `lab.conf` and run suites **without** re-stating them on the
`sudo` line. That avoids accidental wrong-L2 `PEER` overrides.

```bash
cd lpar-tests
cp lab.conf.example lab.conf   # gitignored — edit IPs/paths once
# Switch MQ ↔ legacy by editing the profile in lab.conf (do not mix IPs).

sudo ./run_mq_all.sh           # uses lab.conf as-is
sudo EXTERNAL_IPERF=1 ./run_mq_all.sh   # OK: one-shot knob, not IFACE/PEER
```

Variables: `IFACE`, `PEER`, `DUT_IP`, `IBMVETH_KO`, `EXTERNAL_IPERF`,
`IPERF_PORT_FIRST`/`LAST`, `IPERF_PARALLEL`, `IPERF_TIME` (`0` = forever).

**Do not** pass `IFACE=` / `PEER=` / `DUT_IP=` / `IBMVETH_KO=` on the command
line when `lab.conf` is set — those env vars win over the file and are easy
to get wrong. Override only for a deliberate one-off (e.g. a throwaway peer).
One-shot flags such as `EXTERNAL_IPERF=1`, `T14_CYCLE=full`, `SKIP_HEAVY=1`,
`SKIP_PARALLEL=1` are fine on the `sudo` line.

---

## Two-LPAR traffic (real RX / resize under load)

Ports `5201–5216` (MQ) or a smaller range (legacy). Need IP connectivity and
`iperf3` on both ends. Use **`IPERF_TIME=0`** (forever) for `run_mq_all` /
`T14_CYCLE=full` — finite `-t 3600` often dies mid-suite.

### 1. Pre-checks

```bash
# on DUT
ip -br addr show env9          # or net0 for legacy
ping -I env9 -c 3 192.168.1.153

# on peer
ping -c 3 192.168.1.133
```

### 2. Start servers on the DUT (RX sink)

```bash
# on DUT (uses lab.conf)
cd lpar-tests
sudo ./iperf-dut.sh            # also prints peer recipe
# sudo ./iperf-dut.sh stop
```

Manual equivalent:

```bash
pkill iperf3 2>/dev/null || true
for port in $(seq 5201 5216); do
    iperf3 -s -p "$port" -D
done
ss -ltnp | grep iperf3
```

### 3. Start clients on the peer (inbound to DUT)

```bash
# on peer — copy lab.conf or set DUT_IP
export DUT_IP=192.168.1.133
# from a checkout of this repo on the peer:
./iperf-peer-recipe.sh         # print commands
./iperf-peer-recipe.sh run     # start (-t from lab.conf, default 0)
# ./iperf-peer-recipe.sh stop
```

Manual equivalent:

```bash
export DUT_IP=192.168.1.133
pkill iperf3 2>/dev/null || true
for port in $(seq 5201 5216); do
    iperf3 -c "$DUT_IP" -t 0 -P 4 -p "$port" &
done
```

Many TCP flows help PHYP RX hashing. Watch on DUT:

```bash
watch -n1 'ethtool -S env9 | grep -E "rx[0-9]+_packets"'
```

### 4. Run suites (lab owns iperf)

```bash
# DUT — lab.conf supplies IFACE/PEER/KO; do not re-pass them here
sudo EXTERNAL_IPERF=1 ./run_mq_all.sh
# EXTERNAL_IPERF can also live in lab.conf (example sets it to 1)
```

### 5. Resize while traffic runs (standalone)

```bash
sudo UNDER_RX=1 ./t14-rx-cycle.sh    # PEER from lab.conf
# or: sudo ./rx_queue_size.sh env9 2
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
(or a build directory) via **`insmod`**, then checks `srcversion` matches
`/sys/module/ibmveth/srcversion`. Do not trust bare `modprobe` on labs with
backup `.ko` copies — smoke/T1 will FAIL if the wrong module is loaded.

Smoke/T1 also gates **debugfs `buffer_pools`** (Size kept across ifdown;
Active+Available when up) and **`ping -I $IFACE`** with an RX counter Δ
(so TX-only / other-NIC routes cannot fake PASS).

**PEER must be on the same L2 as `IFACE`.** Example for lab `env9`
(`192.168.1.133`): `PEER=192.168.1.153`. Do **not** use a management /
other-NIC address (`10.48.36.x`) — bare `ping $PEER` can PASS while
`ping -I env9` fails. T14/`rx_queue_size.sh` now use `-I` every step and
fail on `WARNING:` / `ibmveth_interrupt` in the dmesg delta.

Legacy (non-MQ firmware only — `ethtool -l` max RX == 1, not `-L rx 1`):

```bash
sudo IFACE=net0 PEER=<peer-ip> ./lpar-tests/t13-legacy.sh
```

`run-all.sh` auto-runs T13 only when `max_rx==1`.

Older monolith (still useful for deep dive):

```bash
sudo IBMVETH_KO=/home/ming/ibmveth-build \
  ./test-legacy-veth.sh -d net0 -t <peer-ip> -D
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
| **Auto harness** | `lpar-tests/` | `run_mq_all.sh` (MQ), `run_rx_1_all.sh` (MQ+RX=1), `run_legacy_all.sh` (true non-MQ); `run-all.sh` → MQ wrapper |
| **Lab monoliths** | repo root | `verify-mq-adapter.sh`, `test-veth-mq.sh`, `rx_queue_size.sh` — deep/manual or wrapped |

Prefer **new automated cases in `lpar-tests/`**. Keep root scripts for bring-up and heavy one-shot suites; call them from `lpar-tests/lab-smoke.sh` / `t14-rx-cycle.sh`.

```bash
cd lpar-tests
# Prefer lab.conf for IFACE/PEER/DUT_IP/IBMVETH_KO (do not override on CLI).
# Switch MQ ↔ legacy by editing the profile in lab.conf, then:

sudo ./run_mq_all.sh          # Full MQ; run-all.sh is a compat alias
sudo ./run_rx_1_all.sh        # MQ FW forced to ethtool -L rx 1 (not legacy)
sudo ./run_legacy_all.sh      # True legacy FW (max_rx==1)

# One-shot knobs only — not IFACE/PEER:
sudo EXTERNAL_IPERF=1 T14_CYCLE=full ./run_mq_all.sh
```

`run_mq_all.sh` phases (same as former `run-all.sh`):

0. **Dyndbg load** (`DYNDBG=1`, default) — reload with `dyndbg=+p`
   (`modprobe`, or `insmod` when `IBMVETH_KO=` points at a `.ko` / build dir)
   before any tests; saves/restores `$IFACE` IPv4
1. **Quiet / functional** — lab-smoke, smoke, t12, t22, t10, t11, t8, t17,
   t19, t21, t16, t20. With `EXTERNAL_IPERF=1`, also runs t22/`t21` under RX
   here and skips phase-1 close-sq / L-cycle (heavy covers them).
2. **Iperf + MQ RX proof** — start `iperf3 -s`, wait for `yes` (or soft gate
   under `EXTERNAL_IPERF`), require bulk + MQ spread
3. **Heavy** — T14 `UNDER_RX` (`T14_CYCLE=quick` default), close-mq / parallel
   / L-under-rx, MQ re-proof after churn. With `EXTERNAL_IPERF=1`, skips
   mq-rx-pre / t22-rx / t21-rx (already done in phase 1 + gate).
4. **Cleanup** — stop only iperf servers this run started; final ping

```bash
# MQ suite knobs (IFACE/PEER/KO from lab.conf — do not re-pass them)
sudo ./run_mq_all.sh
sudo EXTERNAL_IPERF=1 ./run_mq_all.sh
sudo ./run_mq_all.sh --external-iperf
sudo CHECK_HEALTH=0 ./run_mq_all.sh
sudo DYNDBG=0 ./run_mq_all.sh
sudo T14_CYCLE=full EXTERNAL_IPERF=1 ./run_mq_all.sh
sudo SKIP_HEAVY=1 ./run_mq_all.sh
sudo SKIP_PARALLEL=1 ./run_mq_all.sh          # skip 300s hang-hunt (parallel-stress)
sudo STRESS_SECS=120 ./run_mq_all.sh          # shorten parallel-stress (default 300)
# MQ+RX=1 / legacy: ./run_rx_1_all.sh  ./run_legacy_all.sh
```

Common one-shot knobs (full list in `run_mq_all.sh` header; no man page):

| Knob | Effect |
|------|--------|
| `SKIP_PARALLEL=1` | Skip `parallel-stress.sh` (`-L` + ifdown/up hang hunt) |
| `STRESS_SECS=N` | Duration for that stress (default 300) |
| `SKIP_HEAVY=1` | Quiet/functional only — no inbound gate + heavy phase |
| `SKIP_QUIET=1` | Heavy only |
| `T14_CYCLE=quick\|full` | Short vs exhaustive T14 under load |
| `EXTERNAL_IPERF=1` | Lab owns iperf; harness does not start/stop/restart it |
| `CHECK_HEALTH=0` | Disable post-test mem/softnet/adapter health ALERTs |

Help page (suites + knobs; no separate man(1) install):

```bash
cd lpar-tests
./suite-help.sh                 # or: ./run_mq_all.sh --help
./run_legacy_all.sh --help
./run_rx_1_all.sh --help
# full text: SUITE-HELP.txt
```

Piecemeal (same: config in `lab.conf`, only one-shot knobs on CLI):

```bash
sudo ./smoke.sh
sudo ./t10-stats-lifetime.sh
sudo ./t11-debugfs-geometry.sh
sudo ./t12-stats-debugfs.sh
sudo ./t22-stats-coherence.sh
sudo UNDER_RX=1 ./t22-stats-coherence.sh
sudo ./t8-down-stash.sh
sudo ./t17-down-no-live-irqs.sh
sudo ./t19-set-channels.sh
sudo TX_SET=2 ./t19-set-channels.sh
sudo ./t21-rss-hfunc.sh
sudo ./t20-reload-restore-mq.sh
sudo ./t16-hcall-deltas.sh
sudo LAB_FULL=1 ./lab-smoke.sh
```
