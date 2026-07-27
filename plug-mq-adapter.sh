#!/bin/bash
#
# plug-mq-adapter.sh - Script to plug multi-queue veth adapter to LPAR
#
# Usage: ./plug-mq-adapter.sh [OPTIONS]
#
# This script automates the process of plugging a multi-queue virtual ethernet
# adapter to a PowerVM LPAR using the vioplug command.
#

set -e

# Default values
LPAR_ID=""
SLOT=""
MAC_ADDR=""
VLAN_ID=""
MANAGED_SYSTEM=""
DRY_RUN=0
VERBOSE=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print usage
usage() {
    cat << EOF
Usage: $0 -l LPAR_ID -s SLOT [OPTIONS]

Required:
  -l LPAR_ID          Logical partition ID
  -s SLOT             Virtual slot number

Optional:
  -m MAC_ADDR         MAC address (format: XX:XX:XX:XX:XX:XX)
  -v VLAN_ID          VLAN ID
  -M SYSTEM           Managed system name
  -d                  Dry run (show command without executing)
  -V                  Verbose output
  -h                  Show this help message

Examples:
  # Basic MQ adapter plug
  $0 -l 1 -s 3

  # With custom MAC address
  $0 -l 2 -s 4 -m 02:00:00:00:00:01

  # With VLAN
  $0 -l 1 -s 5 -v 100

  # Dry run to see command
  $0 -l 1 -s 3 -d

EOF
    exit 1
}

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to validate MAC address
validate_mac() {
    local mac=$1
    if [[ ! $mac =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        print_error "Invalid MAC address format: $mac"
        print_error "Expected format: XX:XX:XX:XX:XX:XX"
        exit 1
    fi
}

# Function to validate VLAN ID
validate_vlan() {
    local vlan=$1
    if [[ ! $vlan =~ ^[0-9]+$ ]] || [ "$vlan" -lt 1 ] || [ "$vlan" -gt 4094 ]; then
        print_error "Invalid VLAN ID: $vlan"
        print_error "VLAN ID must be between 1 and 4094"
        exit 1
    fi
}

# Function to check if vioplug command exists
check_vioplug() {
    if ! command -v vioplug &> /dev/null; then
        print_error "vioplug command not found"
        print_error "This script must be run on a system with FSP/HMC access"
        exit 1
    fi
}

# Function to verify LPAR exists
verify_lpar() {
    local lpar=$1
    print_info "Verifying LPAR $lpar exists..."

    # This is a placeholder - actual verification would depend on your environment
    if [ $VERBOSE -eq 1 ]; then
        print_info "LPAR verification would be performed here"
    fi
}

# Function to check if slot is available
check_slot() {
    local lpar=$1
    local slot=$2

    print_info "Checking if slot $slot is available for LPAR $lpar..."

    # This is a placeholder - actual check would query the system
    if [ $VERBOSE -eq 1 ]; then
        print_info "Slot availability check would be performed here"
    fi
}

# Function to build and execute vioplug command
plug_adapter() {
    local cmd="vioplug -plug -lp $LPAR_ID -slot $SLOT -type veth -mq"

    # Add optional parameters
    if [ -n "$MAC_ADDR" ]; then
        cmd="$cmd -mac $MAC_ADDR"
    fi

    if [ -n "$VLAN_ID" ]; then
        cmd="$cmd -vlan $VLAN_ID"
    fi

    if [ -n "$MANAGED_SYSTEM" ]; then
        cmd="$cmd -m $MANAGED_SYSTEM"
    fi

    print_info "Command to execute:"
    echo "  $cmd"
    echo

    if [ $DRY_RUN -eq 1 ]; then
        print_warn "Dry run mode - command not executed"
        return 0
    fi

    # Execute the command
    print_info "Plugging multi-queue adapter..."
    if eval "$cmd"; then
        print_info "Adapter plugged successfully!"
        return 0
    else
        print_error "Failed to plug adapter"
        return 1
    fi
}

# Function to display post-plug instructions
show_next_steps() {
    cat << EOF

${GREEN}Next Steps:${NC}
1. Power cycle the managed system:
   ${YELLOW}chsysstate -m <system> -r sys -o off${NC}
   ${YELLOW}chsysstate -m <system> -r sys -o on${NC}

2. After LPAR boots, verify the adapter:
   ${YELLOW}ip link show${NC}
   ${YELLOW}dmesg | grep ibmveth${NC}

3. Check queue registration (PHYP 1130+):
   ${YELLOW}vio -dump -lp $LPAR_ID${NC}

4. Configure queues in the LPAR:
   ${YELLOW}ethtool -l eth0${NC}
   ${YELLOW}ethtool -L eth0 rx <num_queues>${NC}

For detailed setup instructions, see:
  ../work/vethmq/docs/CLIENT-ADAPTER-MQ-SETUP.md

EOF
}

# Parse command line arguments
while getopts "l:s:m:v:M:dVh" opt; do
    case $opt in
        l) LPAR_ID="$OPTARG" ;;
        s) SLOT="$OPTARG" ;;
        m) MAC_ADDR="$OPTARG" ;;
        v) VLAN_ID="$OPTARG" ;;
        M) MANAGED_SYSTEM="$OPTARG" ;;
        d) DRY_RUN=1 ;;
        V) VERBOSE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$LPAR_ID" ] || [ -z "$SLOT" ]; then
    print_error "LPAR ID and SLOT are required"
    echo
    usage
fi

# Validate optional parameters
if [ -n "$MAC_ADDR" ]; then
    validate_mac "$MAC_ADDR"
fi

if [ -n "$VLAN_ID" ]; then
    validate_vlan "$VLAN_ID"
fi

# Main execution
print_info "Multi-Queue Adapter Setup"
print_info "========================="
echo
print_info "Configuration:"
print_info "  LPAR ID: $LPAR_ID"
print_info "  Slot: $SLOT"
[ -n "$MAC_ADDR" ] && print_info "  MAC Address: $MAC_ADDR"
[ -n "$VLAN_ID" ] && print_info "  VLAN ID: $VLAN_ID"
[ -n "$MANAGED_SYSTEM" ] && print_info "  Managed System: $MANAGED_SYSTEM"
echo

# Check prerequisites
if [ $DRY_RUN -eq 0 ]; then
    check_vioplug
fi

# Verify LPAR and slot
if [ $VERBOSE -eq 1 ]; then
    verify_lpar "$LPAR_ID"
    check_slot "$LPAR_ID" "$SLOT"
fi

# Plug the adapter
if plug_adapter; then
    echo
    show_next_steps
    exit 0
else
    exit 1
fi

# Made with Bob
