#!/bin/bash
# Interactive Kernel Management Script for RHEL/CentOS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to list all installed kernels
list_kernels() {
    echo -e "${BLUE}=== Installed Kernels ===${NC}"
    local i=1
    declare -g -A KERNEL_MAP

    cd /boot || exit 1

    # Get current running kernel
    CURRENT_KERNEL=$(uname -r)

    # Get default kernel from grub
    DEFAULT_ENTRY=$(sudo grub2-editenv list | grep saved_entry | cut -d= -f2 || echo "")

    for vmlinuz in vmlinuz-*; do
        if [[ -f "$vmlinuz" ]]; then
            VERSION=${vmlinuz#vmlinuz-}
            KERNEL_MAP[$i]=$VERSION

            # Mark current and default
            MARKERS=""
            if [[ "$VERSION" == "$CURRENT_KERNEL" ]]; then
                MARKERS="${GREEN}[RUNNING]${NC}"
            fi
            if [[ "$DEFAULT_ENTRY" == *"$VERSION"* ]]; then
                MARKERS="$MARKERS ${YELLOW}[DEFAULT]${NC}"
            fi

            echo -e "  $i) $VERSION $MARKERS"
            ((i++))
        fi
    done

    TOTAL_KERNELS=$((i-1))
    echo ""
}

# Function to set default kernel
set_default_kernel() {
    local kernel_num=$1
    local version=${KERNEL_MAP[$kernel_num]}

    if [[ -z "$version" ]]; then
        echo -e "${RED}Invalid kernel number${NC}"
        return 1
    fi

    echo -e "${YELLOW}Setting default kernel to: $version${NC}"

    # Find the grub menu entry
    local menu_entry=$(sudo grep "menuentry.*$version" /boot/grub2/grub.cfg | head -1 | sed "s/.*'\(.*\)'.*/\1/")

    if [[ -n "$menu_entry" ]]; then
        sudo grub2-set-default "$menu_entry"
        echo -e "${GREEN}Default kernel set successfully${NC}"
        echo "Run 'sudo grub2-mkconfig -o /boot/grub2/grub.cfg' to update grub config"
    else
        echo -e "${RED}Could not find grub entry for this kernel${NC}"
        return 1
    fi
}

# Function to remove a kernel
remove_kernel() {
    local kernel_num=$1
    local version=${KERNEL_MAP[$kernel_num]}

    if [[ -z "$version" ]]; then
        echo -e "${RED}Invalid kernel number${NC}"
        return 1
    fi

    # Check if it's the running kernel
    if [[ "$version" == "$(uname -r)" ]]; then
        echo -e "${RED}Cannot remove the currently running kernel!${NC}"
        return 1
    fi

    echo -e "${YELLOW}Removing kernel: $version${NC}"
    read -p "Are you sure? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo "Cancelled"
        return 0
    fi

    cd /boot || exit 1

    # Remove kernel files
    echo "Removing files..."
    sudo rm -f vmlinuz-$version
    sudo rm -f initramfs-$version.img
    sudo rm -f config-$version
    sudo rm -f System.map-$version
    sudo rm -rf /lib/modules/$version 2>/dev/null || true

    echo -e "${GREEN}Kernel removed successfully${NC}"
    echo "Updating grub configuration..."
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    echo -e "${GREEN}Done!${NC}"
}

# Function to remove all except latest
remove_all_except_latest() {
    echo -e "${YELLOW}This will remove ALL kernels except the latest one${NC}"
    read -p "Are you sure? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo "Cancelled"
        return 0
    fi

    # Find the latest kernel (first in the list)
    local latest_version=${KERNEL_MAP[1]}
    echo -e "${GREEN}Keeping: $latest_version${NC}"

    for i in $(seq 2 $TOTAL_KERNELS); do
        local version=${KERNEL_MAP[$i]}
        if [[ "$version" != "$(uname -r)" ]]; then
            echo "Removing: $version"
            cd /boot || exit 1
            sudo rm -f vmlinuz-$version
            sudo rm -f initramfs-$version.img
            sudo rm -f config-$version
            sudo rm -f System.map-$version
            sudo rm -rf /lib/modules/$version 2>/dev/null || true
        else
            echo -e "${YELLOW}Skipping running kernel: $version${NC}"
        fi
    done

    echo "Updating grub configuration..."
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    echo -e "${GREEN}Cleanup complete!${NC}"
}

# Function to reboot into a kernel
reboot_to_kernel() {
    local kernel_num=$1
    local version=${KERNEL_MAP[$kernel_num]}

    if [[ -z "$version" ]]; then
        echo -e "${RED}Invalid kernel number${NC}"
        return 1
    fi

    echo -e "${YELLOW}Setting one-time boot to: $version${NC}"

    # Find the grub menu entry
    local menu_entry=$(sudo grep "menuentry.*$version" /boot/grub2/grub.cfg | head -1 | sed "s/.*'\(.*\)'.*/\1/")

    if [[ -n "$menu_entry" ]]; then
        sudo grub2-reboot "$menu_entry"
        echo -e "${GREEN}One-time boot set${NC}"
        read -p "Reboot now? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            sudo reboot
        fi
    else
        echo -e "${RED}Could not find grub entry for this kernel${NC}"
        return 1
    fi
}

# Main menu
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║    Kernel Management Tool - RHEL 9     ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo ""

        list_kernels

        echo -e "${BLUE}Actions:${NC}"
        echo "  d <num>  - Set kernel as default"
        echo "  r <num>  - Remove kernel"
        echo "  b <num>  - Reboot into kernel (one-time)"
        echo "  c        - Remove all except latest"
        echo "  l        - Refresh list"
        echo "  q        - Quit"
        echo ""
        read -p "Enter action: " action args

        case $action in
            d)
                set_default_kernel $args
                read -p "Press Enter to continue..."
                ;;
            r)
                remove_kernel $args
                read -p "Press Enter to continue..."
                ;;
            b)
                reboot_to_kernel $args
                ;;
            c)
                remove_all_except_latest
                read -p "Press Enter to continue..."
                ;;
            l)
                continue
                ;;
            q)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid action${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    echo -e "${YELLOW}This script requires sudo privileges${NC}"
    echo "You may be prompted for your password"
fi

# Start the main menu
main_menu
