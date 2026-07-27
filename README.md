# IBM veth / ibmveth Lab Test Scripts

Lab scripts for validating the IBM Virtual Ethernet (`ibmveth`) driver on
PowerVM / pseries: legacy single-queue and multi-queue (MQ) RX.

## Canonical run (verify → test)

<<<<<<< HEAD
Pass your interface and peer explicitly. Do not rely on script defaults
(`test-veth-mq.sh` defaults are `net0` / `9.3.20.62`).
=======
- verify that an `ibmveth` device is present and MQ-capable
- load or reload `ibmveth` with debug enabled
- install or reload an updated `ibmveth` module
- run legacy and MQ functional tests
- exercise queue resize paths
- capture logs and statistics for debugging
- reuse the same workflow across different lab setups

## Lab Setup Inputs

These scripts are meant to be reusable across different lab systems.

The main environment-specific inputs are:

- **interface/device name**
  - examples: `net0`, `env9`
- **remote test host IP**
  - example: `192.168.100.2`
- **whether debug should be enabled**
  - usually `-D` for debug-enabled reload and test runs

Do not hardcode one lab setup into your workflow. Instead, pass the
target interface and test host explicitly when running the scripts.

Examples:

```bash
./verify-mq-adapter.sh -d env9 -v
./test-veth-mq.sh -d env9 -t 192.168.100.2
./test-legacy-veth.sh -d env9 -t 192.168.100.2
```

On another setup, use different values:

```bash
./verify-mq-adapter.sh -d net0 -v
./test-veth-mq.sh -d net0 -t 10.48.34.150
./test-legacy-veth.sh -d net0 -t 10.48.34.150
```

## Recommended Testing Workflow

For most MQ validation, use this order.

## Two-LPAR Traffic Setup for MQ Testing

For stronger MQ validation, especially queue distribution and resize under
load, use two LPARs:

- **server LPAR**
  - runs `iperf3` listeners on a range of TCP ports
- **client LPAR**
  - runs many parallel `iperf3` flows toward the server LPAR
- **target/test LPAR**
  - runs the `ibmveth` test scripts while traffic is active

In some setups, the server LPAR and target/test LPAR may be the same
system. In others, you may use one LPAR as the traffic source and another
as the `ibmveth` device under test.

### Requirements for recreating the setup

You do **not** need any special switch or `ethtool` port programming just
to use `iperf3` on ports `5201-5216`.

You **do** need:

- IP connectivity between the participating LPARs
- `iperf3` installed on the traffic endpoints
- the server side listening on the chosen ports before clients start
- firewall/security policy allowing TCP ports `5201-5216` if filtering is
  enabled

### Example traffic setup

On the server side, start one `iperf3` server per port:

```bash
for port in $(seq 5201 5216); do
    iperf3 -s -p "$port" -D
done
```

On the client side, point traffic at the server IP:

```bash
export MQ_IP=192.168.100.2

for port in $(seq 5201 5216); do
    iperf3 -c "$MQ_IP" -t 300 -P 50 -l 60000 -p "$port" &
done
```

This creates many simultaneous TCP flows and is useful for driving enough
receive traffic to observe queue distribution in `ethtool -S`.

### Basic pre-checks

Before starting traffic, verify:

```bash
ip addr show dev env9
ping -c 3 192.168.100.2
```

On the server side, confirm listeners are active:

```bash
ss -ltnp | grep iperf3
```

If a firewall is enabled, allow the port range before testing.

### Using traffic with the MQ scripts

A practical workflow is:

1. verify the adapter
2. start `iperf3` listeners on the server side
3. start many client flows
4. run MQ test scripts while traffic is active
5. capture `ethtool -S` before and after queue resize operations

Example:

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
./test-veth-mq.sh -d env9 -t 192.168.100.2 -D
./rx_queue_size.sh env9
ethtool -S env9
```

If you want to exercise repeated queue-count changes while traffic is
running, `rx_queue_size.sh` and `rx_forward.sh` are the lightweight helper
scripts for that purpose.

### 1. Verify the adapter and environment
>>>>>>> 4dd4a05 (README: document MQ traffic setup and resize helpers)

```bash
# 1) Verify adapter + reload with dyndbg (preferred bring-up)
sudo ./verify-mq-adapter.sh -d env9 -D -v

# 2) MQ functional suite (root needed for ethtool -L / reload paths)
sudo ./test-veth-mq.sh -d env9 -t 192.168.100.2

# 3) Optional post-test health check (no reload)
./verify-mq-adapter.sh -d env9 -v
```

On another LPAR, only change `-d` / `-t`:

```bash
sudo ./verify-mq-adapter.sh -d net0 -D -v
sudo ./test-veth-mq.sh -d net0 -t 10.48.34.150
```

### About `-D`

- On **verify**: `-D` reloads `ibmveth` with `dyndbg=+p` so init-path
  `netdev_dbg()` is visible. Prefer this as the first step.
- On **test**: `-D` reloads again with debug. Usually unnecessary if
  verify already used `-D`. Add it only when you want a fresh debug
  reload inside the test suite.

Read-only verify (no reload):

```bash
./verify-mq-adapter.sh -d env9 -v
```

### Optional legacy / SQ comparison

```bash
sudo ./test-legacy-veth.sh -d env9 -t 192.168.100.2
```

Use when firmware has no MQ bit, or you want a single-queue baseline.

---

## Lab inputs

| Input | Flag | Examples |
|-------|------|----------|
| Interface | `-d` | `env9`, `net0` |
| Peer / test host | `-t` | `192.168.100.2` |
| Debug reload | `-D` | prefer on verify |

---

## What each step does

### `verify-mq-adapter.sh`

Checks that the target device exists, uses `ibmveth`, and looks sane for
MQ testing. With `-D` / `-r`, reloads the module (optionally with
dynamic debug) before checks.

### `test-veth-mq.sh`

Main MQ suite: connectivity, multi-queue traffic, queue resize
(scale-down/up, under load), single-queue edge case, module reload,
error checks. Logs under `/tmp/ibmveth-mq-test-results/`.

### `test-legacy-veth.sh`

Classic single-queue path for fallback / comparison.

---

## Loading debug without the verify wrapper

```bash
sudo modprobe -r ibmveth
sudo modprobe ibmveth dyndbg=+p
lsmod | grep ibmveth
grep ibmveth /sys/kernel/debug/dynamic_debug/control | grep '=p' | head
dmesg | tail -n 100
```

Prefer `sudo ./verify-mq-adapter.sh -d … -D -v` in normal workflow.

---

## Other scripts

### Module install / reload

- `install-ibmveth-module.sh` — install updated `ibmveth.ko`
- `reload-ibmveth-module.sh` — reload module
- `install-and-reload-module.sh` — install + reload

### Kernel / source helpers (often LPAR-specific)

- `update-veth-mq-git-simple.sh` — module-only rebuild
- `update-veth-mq-kernel.sh` — full kernel build
- `update-veth-mq-for-testing.sh`, `kernels-set.sh` — tree/workflow helpers

Branch lists and build notes in these scripts may lag the current
net-next MQ series. For **how to run tests**, stay on this README.
See `SCRIPTS-README.md` only for build-helper details (historical).

### Debug / lab helpers

- `enable-ibmveth-debug.sh` / `disable-ibmveth-debug.sh`
- `plug-mq-adapter.sh`
<<<<<<< HEAD
=======
  - Helper for plugging/configuring an MQ adapter in the lab.

### Queue resize / traffic helpers

- `rx_queue_size.sh`
  - Simple queue resize helper for changing RX queue counts across a range
    of values.
  - Useful for manually exercising scale-down and scale-up paths while
    collecting `ethtool -l` / `ethtool -S` output.

- `rx_forward.sh`
  - Alternate queue resize helper that resets to a larger queue count
    before stepping through forward/reverse transitions.
  - Useful when you want a predictable repeated resize pattern during
    active traffic.

---

## What the MQ Test Covers

`test-veth-mq.sh` is intended to validate the main MQ receive-path
behavior, including:

- MQ capability detection
- initial queue configuration
- basic connectivity
- multi-stream traffic / RSS-style distribution
- queue scale-down
- queue scale-up
- resize under load
- single-queue edge case
- module reload
- error-path checks

Typical usage:

```bash
./test-veth-mq.sh -d env9 -t 192.168.100.2 -D
```

---

## What the Legacy Test Covers

`test-legacy-veth.sh` validates the classic single-queue path and is
useful when:

- firmware does not support MQ
- you want a fallback-mode sanity check
- you want to compare legacy behavior against MQ behavior

Typical usage:

```bash
./test-legacy-veth.sh -d env9 -t 192.168.100.2 -D
```

---

## Debug Mode

Several scripts support `-D` to enable debug mode.

When enabled, the scripts reload `ibmveth` with dynamic debug enabled so
that `netdev_dbg()` messages are visible from the start of module load.
This is useful for capturing:

- queue registration
- IRQ setup
- buffer-pool setup
- queue resize operations
- open/close sequencing

Example:

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
```
>>>>>>> 4dd4a05 (README: document MQ traffic setup and resize helpers)

---

## Requirements

- PowerVM / pseries; MQ tests need MQ-capable PHYP
- Reachable peer for ping/iperf-style checks
- Root for module reload, interface control, `ethtool -L`

## Safety

Scripts may reload `ibmveth`, bounce interfaces, and change queue
counts. Use console or an alternate management path.

## Logs

- MQ tests: `/tmp/ibmveth-mq-test-results/` (timestamped)
- Verify: `./verify-logs/` (local; not for git)

---

## Kernel under test

Update when the series tip moves. Current net-next review work:

| Field | Value |
|-------|-------|
| Kernel remote | `git@github.com:mcao-zz/linux.git` |
| Branch | `veth-mq-upstream-netnext-v4-review` |
| Tip (as of 2026-07-27) | `a8dfd6177669` |

<<<<<<< HEAD
This test repo remote is `git@github.com:mcao-zz/test.git`
(branch `veth-mq-tests`).
=======
Use console access or an alternate management path before running
scripts that modify the active network path.

---

## Logs and Results

The test scripts create timestamped output under `/tmp`, including:

- system information
- statistics snapshots
- delta reports
- dmesg captures
- full test logs

Local verification logs under `verify-logs/` are not intended to be
tracked in git.

---

## Manual Queue Resize Under Traffic

For focused resize testing outside the full MQ suite, you can combine the
traffic setup above with the queue helper scripts.

Example sequence:

1. on the server LPAR, start `iperf3` listeners on ports `5201-5216`
2. on the client LPAR, start many parallel flows toward the server
3. on the target/test LPAR, run queue resize operations and capture stats

Example commands:

```bash
for port in $(seq 5201 5216); do
    iperf3 -s -p "$port" -D
done
```

```bash
export MQ_IP=192.168.100.2
for port in $(seq 5201 5216); do
    iperf3 -c "$MQ_IP" -t 300 -P 50 -l 60000 -p "$port" &
done
```

```bash
ethtool -S env9
./rx_queue_size.sh env9
ethtool -S env9
```

You can also use:

```bash
./rx_forward.sh env9
```

These helpers do not create traffic by themselves. They are intended to be
run while external traffic is already active.

---

## Suggested Quick Start

### MQ validation

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
./test-veth-mq.sh -d env9 -t 192.168.100.2 -D
./verify-mq-adapter.sh -d env9 -v
```

### Legacy validation

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
./test-legacy-veth.sh -d env9 -t 192.168.100.2 -D
./verify-mq-adapter.sh -d env9 -v
```

---

## Additional Documentation

- `SCRIPTS-README.md`
  - More detailed notes for build/update helper scripts.

If this repository grows, more detailed per-topic documentation can be
split out later, but this README should remain the main entry point for
running ibmveth tests.
>>>>>>> 4dd4a05 (README: document MQ traffic setup and resize helpers)
