#!/bin/bash

# provision-talos-vms.sh
# Creates 3 bare KVM VMs for Talos Linux provisioning via Tinkerbell PXE boot

set -euo pipefail

# Configuration
STORAGE_PATH="/tank/kvm"
NETWORK="default"
MEMORY=4096  # 4GB RAM per node
VCPUS=2
DISK_SIZE=50  # 50GB per node

# VM names and configuration
declare -a VM_NAMES=("talos-cp-01" "talos-worker-01" "talos-worker-02")
declare -A VM_MACS=(
    ["talos-cp-01"]="52:54:00:12:34:01"
    ["talos-worker-01"]="52:54:00:12:34:02"
    ["talos-worker-02"]="52:54:00:12:34:03"
)

echo "=== Talos Linux VM Provisioning ==="
echo "Creating 3 VMs for Talos Kubernetes cluster"
echo ""

for VM_NAME in "${VM_NAMES[@]}"; do
    MAC=${VM_MACS[$VM_NAME]}
    DISK_PATH="${STORAGE_PATH}/${VM_NAME}.qcow2"

    echo "Creating VM: $VM_NAME"
    echo "  MAC: $MAC"
    echo "  Disk: $DISK_PATH"
    echo "  Memory: ${MEMORY}MB"
    echo "  vCPUs: $VCPUS"

    # Check if VM already exists
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "  ⚠️  VM $VM_NAME already exists"
        read -p "  Delete and recreate? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            virsh destroy "$VM_NAME" 2>/dev/null || true
            virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
        else
            echo "  Skipping $VM_NAME"
            continue
        fi
    fi

    # Create disk
    echo "  Creating disk..."
    qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

    # Create VM with PXE boot enabled
    echo "  Creating VM definition..."
    virt-install \
        --name "$VM_NAME" \
        --memory $MEMORY \
        --vcpus $VCPUS \
        --disk path="$DISK_PATH",format=qcow2,bus=virtio \
        --network network=$NETWORK,mac="$MAC",model=virtio \
        --boot network,hd,menu=on \
        --os-variant generic \
        --graphics vnc,password=ferrari \
        --noautoconsole \
        --import

    # Enable autostart
    virsh autostart "$VM_NAME"

    echo "  ✓ VM $VM_NAME created successfully"
    echo ""
done

echo "=== VM Creation Complete ==="
echo ""
echo "VMs created:"
for VM_NAME in "${VM_NAMES[@]}"; do
    MAC=${VM_MACS[$VM_NAME]}
    echo "  - $VM_NAME (MAC: $MAC)"
done
echo ""
echo "Next steps:"
echo "1. Run ansible playbook to configure Tinkerbell:"
echo "   cd ansible && ansible-playbook provision-talos-cluster.yml"
echo "2. Start the VMs to begin PXE boot:"
echo "   virsh start talos-cp-01"
echo "   virsh start talos-worker-01"
echo "   virsh start talos-worker-02"
echo ""
echo "Monitor with:"
echo "  virsh console <vm-name>"
echo "  virsh list --all"
