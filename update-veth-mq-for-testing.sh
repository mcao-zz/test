#!/bin/bash
# Update ibmveth from git and rebuild - with branch selection

set -e

# Default kernel tree location (can be overridden with KERNEL_TREE env var)
KERNEL_TREE="${KERNEL_TREE:-/root/ming/net-next}"

# Available branches
BRANCHES=(
    "veth-mq-v2.0-dev"
    "veth-mq-for-testing"
    "veth-mq-phase3"
    "veth-mq-phase3-h-function-handling"
    "veth-mq-phase2"
    "veth-mq-phase2-per-queue-pools"
)

# Parse command line arguments
FULL_KERNEL=false
BRANCH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --full-kernel|-f)
            FULL_KERNEL=true
            shift
            ;;
        --tree|-t)
            KERNEL_TREE="$2"
            shift 2
            ;;
        *)
            BRANCH="$1"
            shift
            ;;
    esac
done

# If branch not provided, show menu
if [ -z "$BRANCH" ]; then
    echo "=== IBM veth Multi-Queue Git Update & Build ==="
    echo ""
    echo "Available branches:"
    for i in "${!BRANCHES[@]}"; do
        printf "%d) %s\n" $((i+1)) "${BRANCHES[$i]}"
    done
    echo ""
    read -p "Select branch number (or press Enter for default '${BRANCHES[0]}'): " BRANCH_NUM

    if [ -z "$BRANCH_NUM" ]; then
        BRANCH="${BRANCHES[0]}"
        echo "Using default: $BRANCH"
    elif [ "$BRANCH_NUM" -ge 1 ] && [ "$BRANCH_NUM" -le "${#BRANCHES[@]}" ]; then
        BRANCH="${BRANCHES[$((BRANCH_NUM-1))]}"
        echo "Selected: $BRANCH"
    else
        echo "Invalid selection. Exiting."
        exit 1
    fi
else
    echo "=== Using branch: $BRANCH ==="
fi

# Verify kernel tree exists
if [ ! -d "$KERNEL_TREE" ]; then
    echo "Error: Kernel tree not found at $KERNEL_TREE"
    echo "Set KERNEL_TREE environment variable or use --tree option"
    exit 1
fi

echo ""
echo "=== Kernel tree: $KERNEL_TREE ==="
cd "$KERNEL_TREE"

echo ""
echo "=== Setup SSH key for GitHub ==="
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/mcaozz_github

echo ""
echo "=== Fetch latest code ==="
git fetch mingupstream

echo ""
echo "=== Switching to branch: $BRANCH ==="
git checkout mingupstream/$BRANCH --detach

echo ""
echo "=== Top 5 commits ==="
git log --oneline -5

if [ "$FULL_KERNEL" = true ]; then
    echo ""
    echo "=== Building full kernel ==="
    make -j$(nproc)

    echo ""
    echo "=== Installing modules ==="
    make modules_install

    echo ""
    echo "=== Installing kernel ==="
    make install

    echo ""
    echo "=== Full kernel update complete! ==="
    echo "Kernel tree: $KERNEL_TREE"
    echo "Branch: $BRANCH"
    echo "Kernel version: $(make kernelversion)"
    echo ""
    echo "Reboot to use the new kernel."
else
    echo ""
    echo "=== Building ibmveth module only ==="
    make M=drivers/net/ethernet/ibm -j$(nproc)

    echo ""
    echo "=== Installing ibmveth module ==="
    make M=drivers/net/ethernet/ibm modules_install

    echo ""
    echo "=== Module update complete! ==="
    echo "Kernel tree: $KERNEL_TREE"
    echo "Branch: $BRANCH"
    echo "Module: drivers/net/ethernet/ibm/ibmveth.ko"
    echo ""
    echo "To reload the module:"
    echo "  # Without debug"
    echo "  sudo rmmod ibmveth"
    echo "  sudo modprobe ibmveth"
    echo ""
    echo "  # With dynamic debug enabled"
    echo "  sudo rmmod ibmveth"
    echo "  sudo modprobe ibmveth dyndbg=+pflmt"
    echo ""
    echo "  # Or enable debug after loading"
    echo "  echo 'module ibmveth +pflmt' | sudo tee /sys/kernel/debug/dynamic_debug/control"
    echo ""
    echo "Or reboot to use the new module."
fi

# Made with Bob
