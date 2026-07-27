# IBM veth / ibmveth Lab Test Scripts

Lab scripts for validating the IBM Virtual Ethernet (`ibmveth`) driver on
PowerVM / pseries: legacy single-queue and multi-queue (MQ) RX.

## Canonical run (verify → test)

Pass your interface and peer explicitly. Do not rely on script defaults
(`test-veth-mq.sh` defaults are `net0` / `9.3.20.62`).

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

This test repo remote is `git@github.com:mcao-zz/test.git`
(branch `veth-mq-tests`).
