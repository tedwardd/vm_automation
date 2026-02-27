#!/bin/bash

set -euo pipefail

SOURCE_VM="${2:-clawd-sandbox}"
NEW_VM_NAME="$1"
DISK_DIR="/tank/kvm"

if [ -z "$NEW_VM_NAME" ]; then
    echo "Usage: $0 <new-vm-name> [source-vm-name]"
    echo ""
    echo "Examples:"
    echo "  $0 clawd-test1              # Clone clawd-sandbox to clawd-test1"
    echo "  $0 my-vm clawd-sandbox      # Clone clawd-sandbox to my-vm"
    exit 1
fi

# Check if source VM exists
if ! virsh dominfo "$SOURCE_VM" &>/dev/null; then
    echo "Error: Source VM '$SOURCE_VM' not found"
    exit 1
fi

# Check if new VM name already exists
if virsh dominfo "$NEW_VM_NAME" &>/dev/null 2>&1; then
    echo "Error: VM '$NEW_VM_NAME' already exists"
    exit 1
fi

# Check if disk file already exists
NEW_DISK="${DISK_DIR}/${NEW_VM_NAME}.qcow2"
if [ -f "$NEW_DISK" ]; then
    echo "Error: Disk file '$NEW_DISK' already exists"
    exit 1
fi

echo "Cloning VM '$SOURCE_VM' to '$NEW_VM_NAME'..."
echo "This will create: $NEW_DISK"
echo ""

# Use virt-clone to handle everything
virt-clone \
    --original "$SOURCE_VM" \
    --name "$NEW_VM_NAME" \
    --file "$NEW_DISK"

echo ""
echo "Clone complete!"
echo "New VM: $NEW_VM_NAME"
echo "Disk file: $NEW_DISK"
echo ""

# Start the VM
echo "Starting VM..."
virsh start "$NEW_VM_NAME"

# Get MAC address for the VM
MAC_ADDRESS=$(virsh domiflist "$NEW_VM_NAME" | awk 'NR>2 {print $5}' | head -n1)
NETWORK=$(virsh domiflist "$NEW_VM_NAME" | awk 'NR>2 {print $3}' | head -n1)

# Wait for IP address
echo "Waiting for IP address (MAC: $MAC_ADDRESS)..."
MAX_WAIT=120
ELAPSED=0
IP_ADDRESS=""

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Try to get IP from DHCP leases by matching MAC address
    if [ -n "$MAC_ADDRESS" ] && [ -n "$NETWORK" ]; then
        IP_ADDRESS=$(virsh net-dhcp-leases "$NETWORK" 2>/dev/null | grep -i "$MAC_ADDRESS" | awk '{print $5}' | cut -d'/' -f1)
    fi

    # If that fails, try domifaddr with lease source
    if [ -z "$IP_ADDRESS" ]; then
        IP_ADDRESS=$(virsh domifaddr "$NEW_VM_NAME" --source lease 2>/dev/null | awk 'NR>2 {print $4}' | cut -d'/' -f1 | head -n1)
    fi

    # If that fails, try qemu-agent
    if [ -z "$IP_ADDRESS" ]; then
        IP_ADDRESS=$(virsh domifaddr "$NEW_VM_NAME" --source agent 2>/dev/null | awk 'NR>2 {print $4}' | cut -d'/' -f1 | head -n1)
    fi

    if [ -n "$IP_ADDRESS" ]; then
        break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -n "."
done

echo ""
echo ""
echo "========================================="
echo "VM Name: $NEW_VM_NAME"
if [ -n "$IP_ADDRESS" ]; then
    echo "IP Address: $IP_ADDRESS"
    echo ""
    echo "SSH: ssh user@$IP_ADDRESS"
else
    echo "IP Address: Not available yet (check with: virsh domifaddr $NEW_VM_NAME)"
fi
echo "Console: virsh console $NEW_VM_NAME"
echo "========================================="
