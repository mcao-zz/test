# IBM veth Multi-Queue Build Scripts

## Overview

Two scripts for updating and building IBM veth multi-queue driver from GitHub:

1. **update-veth-mq-git-simple.sh** - Module-only build (fast, ~1 minute)
2. **update-veth-mq-kernel.sh** - Full kernel build (slow, ~30 minutes)

## Available Branches

1. `veth-mq-phase2` - Initial multi-queue implementation (64 commits)
2. `veth-mq-phase2-per-queue-pools` - Per-queue buffer pools (7 commits)
3. `veth-mq-phase3` - Ethtool resize support (6 commits)
4. `veth-mq-phase3-h-function-handling` - H_FUNCTION error handling (6 commits)
5. `veth-mq-for-testing` - Clean version for FVT testing (72 commits, no debug flooding)

## Script 1: Module-Only Build (Recommended for Development)

### Features
- Fast build (~1 minute)
- Only rebuilds ibmveth.ko module
- No kernel reboot required
- Perfect for iterative development

### Usage

```bash
# Interactive menu
./update-veth-mq-git-simple.sh

# Direct to specific branch
./update-veth-mq-git-simple.sh veth-mq-for-testing
```

### After Build

```bash
# Unload old module
rmmod ibmveth

# Load new module
insmod drivers/net/ethernet/ibm/ibmveth.ko num_queues=16

# Or use modprobe (if installed)
modprobe ibmveth num_queues=16
```

## Script 2: Full Kernel Build (For Testing/Production)

### Features
- Full kernel build (~30 minutes)
- Installs kernel and modules
- Updates grub
- Requires reboot

### Usage

```bash
# Interactive menu
./update-veth-mq-kernel.sh

# Direct to specific branch
./update-veth-mq-kernel.sh veth-mq-for-testing
```

### After Build

```bash
# Reboot to new kernel
sudo reboot

# After reboot, verify
uname -r
modprobe ibmveth num_queues=16
```

## Prerequisites

### SSH Key Setup

Both scripts require GitHub SSH access:

```bash
# Generate key (if not exists)
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/mcaozz_github

# Add to GitHub
cat ~/.ssh/mcaozz_github.pub
# Copy and add to GitHub Settings > SSH Keys

# Test connection
ssh -T git@github.com
```

### Git Remote Setup

```bash
cd /root/ming/net-next/linux

# Add remote (if not exists)
git remote add mingupstream git@github.com:yourusername/linux.git

# Verify
git remote -v
```

## Branch Comparison

### veth-mq-phase2 (64 commits)
- Initial multi-queue implementation
- Shared buffer pools
- Basic functionality

### veth-mq-phase2-per-queue-pools (71 commits)
- Phase 2 + per-queue buffer pools
- Better performance
- Reduced lock contention

### veth-mq-phase3 (77 commits)
- Phase 2 + per-queue pools + ethtool resize
- Dynamic queue scaling
- `ethtool -L` support

### veth-mq-phase3-h-function-handling (83 commits)
- Phase 3 + H_FUNCTION error handling
- Fallback to legacy mode
- Better firmware compatibility

### veth-mq-for-testing (72 commits) ⭐ RECOMMENDED
- Phase 3 + H_FUNCTION handling
- **Debug flooding removed** (commit 37a418d4b956 reverted)
- Clean dmesg for FVT testing
- Production-ready

## Common Issues

### Issue: "fatal: git checkout: --detach does not take a path argument"

**Cause:** Wrong git command syntax

**Fix:** Scripts now use `git reset --hard` instead of `git checkout --detach`

### Issue: Branch not found on GitHub

**Cause:** Branch not pushed to GitHub yet

**Fix:**
```bash
# On build system
cd /Volumes/LinuxKernel/linux
git checkout veth-mq-for-testing
git push -u origin veth-mq-for-testing
```

### Issue: Debug flooding in dmesg

**Cause:** Running old branch (veth-mq-phase2-debug or similar)

**Fix:** Use `veth-mq-for-testing` branch

## Testing Workflow

### 1. Development (Module Build)

```bash
# Make code changes
vim drivers/net/ethernet/ibm/ibmveth.c

# Quick rebuild
./update-veth-mq-git-simple.sh veth-mq-for-testing

# Test
rmmod ibmveth
insmod drivers/net/ethernet/ibm/ibmveth.ko num_queues=16
```

### 2. Testing (Full Kernel)

```bash
# Build full kernel
./update-veth-mq-kernel.sh veth-mq-for-testing

# Reboot
sudo reboot

# Test after reboot
modprobe ibmveth num_queues=16
ethtool -l env8
```

## Script Maintenance

### Adding New Branch

Edit both scripts and add to `BRANCHES` array:

```bash
BRANCHES=(
    "veth-mq-phase2"
    "veth-mq-phase2-per-queue-pools"
    "veth-mq-phase3"
    "veth-mq-phase3-h-function-handling"
    "veth-mq-for-testing"
    "your-new-branch"  # Add here
)
```

### Changing Default Branch

Change first element in `BRANCHES` array:

```bash
BRANCHES=(
    "veth-mq-for-testing"  # This becomes default
    "veth-mq-phase2"
    # ...
)
```

## Files

- `update-veth-mq-git-simple.sh` - Module-only build script
- `update-veth-mq-kernel.sh` - Full kernel build script
- `SCRIPTS-README.md` - This file

## See Also

- `DEBUG-COMMITS-ANALYSIS.md` - Analysis of debug commits
- `FOR-TESTING-BRANCH-SUMMARY.md` - Testing branch documentation
- `TRUNK-ADAPTER-CORRECT-CONFIG.md` - Trunk adapter setup guide