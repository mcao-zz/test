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

1. baseline → 16 (or max supported)
2. 16 → 1
3. forward ramp 2…max
4. reverse ramp (max−1)…1

```bash
sudo ./rx_queue_size.sh [iface] [delay_seconds]
# examples:
sudo ./rx_queue_size.sh env9
sudo ./rx_queue_size.sh env9 2
```

It validates each `ethtool -L` against `ethtool -l` and stops on failure.
It does **not** generate traffic — start iperf (above) first for
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
