# IBM veth Test Scripts

This directory contains test scripts for the IBM Virtual Ethernet (ibmveth) driver.

## Recommended Testing Workflow

For comprehensive validation, run tests in this order:

### Step 1: Initial Verification with Debug (Recommended)
```bash
# Reload module with debug and verify setup
sudo ./verify-mq-adapter.sh -d net0 -D -v
```
This reloads the module with dynamic debug enabled and validates the setup.

**Alternative (without module reload):**
```bash
# Quick verification without reload
./verify-mq-adapter.sh -d net0 -v
```

### Step 2: Functional Testing (Comprehensive)
```bash
# Run full functional test suite with debug
./test-veth-mq.sh -d net0 -t 10.48.34.150 -D
```
This performs dynamic testing with traffic, resizing, and module reload.

### Step 3: Post-Test Verification (Optional)
```bash
# Verify system is still healthy after tests
./verify-mq-adapter.sh -d net0 -v
```
This confirms no issues were introduced during testing.

---

## Scripts

### verify-mq-adapter.sh - Initial Setup Verification

Quick verification that multi-queue adapter is properly configured. Run this FIRST before functional testing.

**Purpose:** Validates setup correctness (non-destructive, read-only)

**Usage:**
```bash
./verify-mq-adapter.sh -d [interface] [-D] [-r] [-v] [-p]
```

**Options:**
- `-d DEVICE` - Network device to check
- `-D` - Enable debug mode (reload module with dyndbg=+p)
- `-r` - Reload module before verification (without debug)
- `-v` - Verbose output
- `-p` - Run performance checks

**Examples:**
```bash
# Recommended: Reload with debug and verify (requires sudo)
sudo ./verify-mq-adapter.sh -d net0 -D -v

# Just reload module without debug
sudo ./verify-mq-adapter.sh -d net0 -r -v

# Quick verification (no reload)
./verify-mq-adapter.sh -d net0 -v

# With performance checks
./verify-mq-adapter.sh -d net0 -v -p

# Auto-detect ibmveth device
./verify-mq-adapter.sh
```

**What it checks:**
- ✓ Device exists and uses ibmveth driver
- ✓ Multi-queue support enabled
- ✓ Queue count (max and current)
- ✓ RX queue directories exist
- ✓ IRQ assignment
- ✓ Device state (UP/DOWN)
- ✓ Queue statistics available
- ✓ Error counters
- ✓ IRQ affinity (with -p flag)

**Duration:** ~5 seconds

**When to use:**
- **With -D flag:** Before functional tests (ensures debug is enabled)
- **Without -D flag:** Quick health checks, post-installation validation
- **After tests:** Verify system is still healthy

**Why use -D flag:**
- Enables dynamic debug BEFORE any driver code runs
- Captures complete initialization sequence in dmesg
- Essential for troubleshooting initialization issues
- Recommended for comprehensive testing

---

### test-legacy-veth.sh - Legacy/Fallback Mode Test Suite

Tests single-queue fallback mode operation on firmware without multi-queue support.

**Usage:**
```bash
./test-legacy-veth.sh [-d interface] [-t test_host] [-D]
```

**Options:**
- `-d DEVICE` - Network device to test (default: net0)
- `-t HOST` - Test host for connectivity (default: 9.3.20.62)
- `-D` - Enable debug mode (modprobe with dyndbg=+p)

**Examples:**
```bash
# Basic test (no debug)
./test-legacy-veth.sh -d net0 -t 10.48.34.150

# With dynamic debug enabled during module reload
./test-legacy-veth.sh -d net0 -t 10.48.34.150 -D

# Use defaults
./test-legacy-veth.sh
```

**Tests Performed:**
1. System and driver information
2. Interface status and connectivity
3. VIO device validation
4. Fallback mode confirmation (subordinate_queue_mode=0)
5. Basic connectivity (ping)
6. Large packet test
7. Sustained traffic test
8. Parallel connections
9. Inbound traffic (RX heavy)
10. Bidirectional traffic
11. Interface resilience (down/up)
12. Module reload (with optional debug)
13. Error validation

**Debug Mode:**
When `debug_mode=on`, the script uses `modprobe ibmveth dyndbg=+p` to enable dynamic debug during module reload. This ensures all netdev_dbg() messages are visible from the moment the module loads, capturing the complete initialization sequence.

**Output:**
- Results directory: `/tmp/ibmveth-test-results/`
- Log file: `test_<interface>_<timestamp>.log`
- Statistics snapshots: Before, pre-reload, and after
- Delta reports: Changes during tests and after reload

---

### test-veth-mq.sh - Multi-Queue Test Suite (Phase 3)

Tests multi-queue operation and dynamic queue resizing.

**Usage:**
```bash
./test-veth-mq.sh [-d interface] [-t test_host] [-D]
```

**Options:**
- `-d DEVICE` - Network device to test (default: net0)
- `-t HOST` - Test host for connectivity (default: 9.3.20.62)
- `-D` - Enable debug mode (modprobe with dyndbg=+p)

**Examples:**
```bash
# Basic multi-queue test
./test-veth-mq.sh -d net0 -t 10.48.34.150

# With dynamic debug for detailed queue operations
./test-veth-mq.sh -d net0 -t 10.48.34.150 -D

# Use defaults
./test-veth-mq.sh
```

**Tests Performed:**
1. System and driver information
2. Interface status and connectivity
3. VIO device validation
4. Multi-queue capability check (subordinate_queue_mode > 0)
5. Initial queue configuration
6. Basic connectivity
7. Multi-stream traffic (RSS validation)
8. Queue resize - scale down (e.g., 16→8)
9. Queue resize - scale up (e.g., 8→16)
10. Traffic during resize (resize under load)
11. Edge case - single queue operation
12. Module reload (with optional debug)
13. Hypercall validation (multi-queue vs legacy)
14. Error validation

**Queue Resizing Tests:**
- **Scale Down:** Reduces queue count by half (e.g., 16→8→4)
- **Scale Up:** Restores original queue count (e.g., 4→8→16)
- **Under Load:** Resizes while traffic is active
- **Edge Cases:** Tests single queue and maximum queue count

**RSS Validation:**
The script runs parallel ping streams and validates that traffic is distributed across multiple RX queues, confirming proper RSS (Receive Side Scaling) operation.

**Debug Mode:**
When `debug_mode=on`, enables full debug output during:
- Module reload sequence
- Queue registration (h_register_logical_lan_queue)
- IRQ setup for all queues
- Buffer pool allocation per queue
- Queue resize operations

**Output:**
- Results directory: `/tmp/ibmveth-mq-test-results/`
- Log file: `test_<interface>_<timestamp>.log`
- Statistics snapshots: Before, after traffic, after resize, final
- Dmesg log: Kernel messages captured at key points
- Per-queue statistics: RX/TX distribution across queues

---

## Test Requirements

### Hardware/Firmware
- **Fallback Mode:** Any PowerVM firmware
- **Multi-Queue Mode:** PowerVM firmware with multi-queue veth support

### Network
- Remote test host must be reachable via ping
- Sufficient bandwidth for traffic tests
- MTU 1500 or higher recommended

### Permissions
Both scripts require sudo access for:
- Module reload (rmmod/modprobe)
- Interface control (ip link set)
- Queue configuration (ethtool -L)

---

## Understanding Debug Mode

### Why Debug Mode?

Dynamic debug messages (netdev_dbg) are crucial for understanding driver behavior but are disabled by default. The debug mode ensures these messages are visible during critical operations like module load and queue setup.

### How It Works

**Without Debug Mode (default):**
```bash
sudo rmmod ibmveth
sudo modprobe ibmveth
```
- Only pr_info() DEBUG messages visible
- netdev_dbg() messages remain hidden
- May miss initialization details

**With Debug Mode (debug_mode=on):**
```bash
sudo rmmod ibmveth
sudo modprobe ibmveth dyndbg=+p
```
- All debug messages enabled BEFORE module code runs
- Captures complete initialization sequence
- Shows queue setup, IRQ assignment, buffer allocation

### What You'll See With Debug Enabled

**Fallback Mode:**
```
ibmveth_open: open starting
ibmveth_alloc_rx_qstats: Allocated RX queue stats for 1 queues
ibmveth_alloc_filter_list: filter list @ ...
ibmveth_alloc_rx_queues: queue 0: buffer_list @ ...
ibmveth_open: RX setup complete: 1 queues, 5 buffer pools
ibmveth_alloc_tx_resources: allocated TX resources...
ibmveth_open: open complete
```

**Multi-Queue Mode:**
```
ibmveth_open: open starting
ibmveth_alloc_rx_qstats: Allocated RX queue stats for 16 queues
ibmveth_alloc_filter_list: filter list @ ...
ibmveth_alloc_rx_queues: queue 0: buffer_list @ ...
ibmveth_alloc_rx_queues: queue 1: buffer_list @ ...
[... queues 2-15 ...]
About to request IRQ 55 for queue 0
About to request IRQ 266 for queue 1
[... IRQs for queues 2-15 ...]
Queue 0 registered with handle 0x8000000000000000
Queue 1 registered with handle 0x8000000100000000
[... queues 2-15 ...]
ibmveth_open: RX setup complete: 16 queues, 80 buffer pools
ibmveth_alloc_tx_resources: allocated TX resources...
ibmveth_open: open complete
```

---

## Interpreting Results

### Success Criteria

**Fallback Mode:**
- ✓ subordinate_queue_mode = 0
- ✓ h_reg_lan_calls > 0 (legacy hypercall)
- ✓ h_reg_queue_calls = 0 (no multi-queue)
- ✓ All connectivity tests pass
- ✓ Zero errors in all paths

**Multi-Queue Mode:**
- ✓ subordinate_queue_mode > 0
- ✓ h_reg_queue_calls > 0 (multi-queue hypercall)
- ✓ Multiple active RX queues
- ✓ Queue resize operations succeed
- ✓ Traffic survives resize
- ✓ Zero errors in all paths

### Common Issues

**"Connection refused" during tests:**
- Check if test_host is reachable
- Verify firewall settings
- Try different test host

**"Module reload failed":**
- Check if interface is in use by other processes
- Verify sudo permissions
- Check dmesg for kernel errors

**"Queue resize failed":**
- Firmware may not support requested queue count
- Check ethtool -l output for valid range
- Verify multi-queue mode is active

---

## Example Test Runs

### Fallback Mode Test
```bash
$ ./test-veth.sh net0 10.48.34.150 on
========================================
IBM Virtual Ethernet Driver Test Suite
========================================
Interface: net0
Test Host: 10.48.34.150
Debug Mode: on
...
Tests passed: 11 / 11
✓ ALL TESTS PASSED
```

### Multi-Queue Test
```bash
$ ./test-veth-mq.sh net0 10.48.34.150 on
========================================
IBM veth Multi-Queue Test Suite (Phase 3)
========================================
Interface: net0
Test Host: 10.48.34.150
Debug Mode: on
...
Current queue count: 16
✓ PASS: Multi-queue configured (16 queues)
...
Active RX queues: 6
✓ PASS: Traffic distributed across multiple queues
...
Scaling down from 16 to 8 queues...
✓ PASS: Scale down (16→8)
...
Scaling up from 8 to 16 queues...
✓ PASS: Scale up (8→16)
...
Tests passed: 15 / 15
✓ ALL TESTS PASSED
```

---

## Troubleshooting

### Enable Debug Manually

If you need to enable debug without running the full test:

```bash
# Enable all ibmveth debug messages
echo 'module ibmveth +p' > /sys/kernel/debug/dynamic_debug/control

# Or during module load
sudo modprobe ibmveth dyndbg=+p

# Verify debug is enabled
grep ibmveth /sys/kernel/debug/dynamic_debug/control | grep '=p'
```

### Check Queue Configuration

```bash
# Show current and maximum queue counts
ethtool -l net0

# Set queue count
sudo ethtool -L net0 combined 8
```

### Monitor Real-Time

```bash
# Watch dmesg for driver messages
dmesg -w | grep ibmveth

# Monitor per-queue statistics
watch -n 1 'ethtool -S net0 | grep -E "rx[0-9]+_packets"'
```

---

## Files Generated

Both scripts create timestamped result files in their respective directories:

**Fallback Mode:** `/tmp/ibmveth-test-results/`
- `sysinfo_<interface>_<timestamp>.txt` - System information
- `stats_before_<interface>_<timestamp>.txt` - Initial statistics
- `stats_pre_reload_<interface>_<timestamp>.txt` - Before module reload
- `stats_after_<interface>_<timestamp>.txt` - After module reload
- `stats_delta_tests_<interface>_<timestamp>.txt` - Changes during tests
- `stats_delta_final_<interface>_<timestamp>.txt` - Post-reload activity
- `test_<interface>_<timestamp>.log` - Complete test log

**Multi-Queue Mode:** `/tmp/ibmveth-mq-test-results/`
- `sysinfo_<interface>_<timestamp>.txt` - System information
- `stats_before_<interface>_<timestamp>.txt` - Initial statistics
- `stats_after_traffic_<interface>_<timestamp>.txt` - After RSS test
- `stats_after_resize_<interface>_<timestamp>.txt` - After resize tests
- `stats_final_<interface>_<timestamp>.txt` - Final statistics
- `dmesg_<interface>_<timestamp>.log` - Kernel messages
- `test_<interface>_<timestamp>.log` - Complete test log

---

## Contributing

When adding new tests:
1. Follow the existing test structure
2. Use the check_result() function for pass/fail
3. Capture relevant statistics before/after
4. Update TOTAL_TESTS counter
5. Document the test in this README

---

## Related Documentation

- [Test Plan](../test-veth-mq-plan.md) - Comprehensive Phase 3 test plan
- [Project Log](../../PROJECT-LOG.md) - Development history
- [Patches](../patches/) - Patch series for upstream submission