#!/bin/bash
# Update ibmveth from git and rebuild full kernel - with branch selection

set -e

# Available branches
BRANCHES=(
    "veth-mq-s1"
    "ibmveth-net-fixes"
    "veth-mq-s2"
    "veth-mq-for-testing"
)

# If branch provided as argument, use it
if [ -n "$1" ]; then
    BRANCH="$1"
    echo "=== Using branch from argument: $BRANCH ==="
else
    # Show menu and let user choose
    echo "=== IBM veth Multi-Queue Git Update & Build (Full Kernel) ==="
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
fi

echo ""
echo "=== Setup SSH key for GitHub ==="
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/mcaozz_github

echo ""
echo "=== Fetch latest code ==="
git fetch mingupstream

echo ""
echo "=== Switching to branch: $BRANCH ==="
git reset --hard mingupstream/$BRANCH

echo ""
echo "=== Top 5 commits ==="
git log --oneline -5

echo ""
read -p "Verify commits look correct? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=== Building kernel (this will take a while) ==="
make -j$(nproc)

echo ""
echo "=== Installing modules ==="
make modules_install

echo ""
echo "=== Installing kernel ==="
make install

echo ""
echo "=== Updating grub ==="
KERNEL_VERSION=$(make kernelrelease)
grubby --set-default=/boot/vmlinuz-${KERNEL_VERSION}

echo ""
echo "=== Update complete! ==="
echo "Branch: $BRANCH"
echo "Kernel version: $KERNEL_VERSION"
echo ""
echo "Reboot to use the new kernel:"
echo "  sudo reboot"
echo ""
echo "Usage examples:"
echo "  $0                                    # Interactive menu"
echo "  $0 veth-mq-s1                        # series 1 SQ prep"
echo "  $0 ibmveth-net-fixes                 # net 0/2"
echo "  $0 veth-mq-s2                        # series 2 MQ enable"
echo "  $0 veth-mq-for-testing               # lab alias (retarget to s1/s2)"

# Made with Bob
