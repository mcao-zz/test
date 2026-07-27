# IBM veth / ibmveth Lab Test Scripts

This repository contains lab scripts for validating the IBM Virtual
Ethernet (`ibmveth`) driver, including both legacy single-queue behavior
and multi-queue (MQ) receive support.

The scripts are intended for PowerVM / pseries lab environments where
you may need to:

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

### 1. Verify the adapter and environment

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
```

This is the recommended first step. It reloads the module with dynamic
debug enabled and validates that the target device is configured
correctly for testing.

If you only want a quick read-only check without reload:

```bash
./verify-mq-adapter.sh -d env9 -v
```

### 2. Run the MQ functional test suite

```bash
./test-veth-mq.sh -d env9 -t 192.168.100.2 -D
```

This exercises:

- connectivity
- multi-queue operation
- traffic distribution across queues
- queue resize paths
- module reload behavior
- error checks

### 3. Optionally run legacy/single-queue comparison

```bash
./test-legacy-veth.sh -d env9 -t 192.168.100.2 -D
```

Use this when you want to compare MQ behavior against the classic
single-queue path or validate fallback behavior on firmware without MQ
support.

### 4. Re-verify after testing

```bash
./verify-mq-adapter.sh -d env9 -v
```

This is useful as a post-test health check.

---

## Loading the Module with Debug Enabled

If you want full initialization-path debug logs, enable dynamic debug at
module load time rather than after the module is already loaded.

Recommended direct commands:

```bash
sudo modprobe -r ibmveth
sudo modprobe ibmveth dyndbg=+p
```

Then verify:

```bash
lsmod | grep ibmveth
grep ibmveth /sys/kernel/debug/dynamic_debug/control | grep '=p' | head
dmesg | tail -n 100
```

In normal test workflow, the easiest way to do this is:

```bash
sudo ./verify-mq-adapter.sh -d env9 -D -v
```

The `-D` option is intended to reload the module with debug enabled
before verification, so it is usually the preferred entry point.

---

## Main Scripts

### Verification

- `verify-mq-adapter.sh`
  - Verifies that the target device exists, uses the `ibmveth` driver,
    and is configured appropriately for MQ testing.
  - Can optionally reload the module and enable dynamic debug.

### Functional tests

- `test-veth-mq.sh`
  - Main multi-queue test suite.
  - Covers queue setup, traffic distribution, queue resize, and reload
    behavior.

- `test-legacy-veth.sh`
  - Legacy/single-queue validation flow.
  - Useful for fallback-mode testing and comparison against MQ behavior.

### Module install / reload helpers

- `install-ibmveth-module.sh`
  - Installs an updated `ibmveth` module for testing.

- `reload-ibmveth-module.sh`
  - Reloads the `ibmveth` module.

- `install-and-reload-module.sh`
  - Combined install + reload helper.

### Kernel / source update helpers

- `update-veth-mq-for-testing.sh`
  - Updates the veth MQ test tree/workflow.

- `update-veth-mq-git-simple.sh`
  - Faster git/module-oriented update helper.

- `update-veth-mq-kernel.sh`
  - Full kernel update/build helper.

- `kernels-set.sh`
  - Helper for selecting or managing kernel/test setup state.

### Debug / environment helpers

- `enable-ibmveth-debug.sh`
  - Enables extra ibmveth debug settings.

- `disable-ibmveth-debug.sh`
  - Disables extra ibmveth debug settings.

- `plug-mq-adapter.sh`
  - Helper for plugging/configuring an MQ adapter in the lab.

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

---

## Requirements

### Hardware / firmware

- PowerVM / pseries environment
- For MQ testing: firmware with ibmveth multi-queue support

### Network

- reachable remote test host for connectivity/traffic checks
- sufficient bandwidth for traffic tests

### Permissions

Many scripts require root privileges for operations such as:

- module reload
- interface control
- queue configuration via `ethtool -L`

---

## Safety Notes

Some scripts may:

- reload the `ibmveth` module
- bring interfaces down/up
- change queue counts
- disrupt active network connectivity

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