#!/bin/bash
set -euo pipefail

# Default values
VM_NAME=""
MEMORY="2048"
VCPUS="2"
DISK_SIZE="20"
OS_ISO="/tank/isos/ubuntu-24.04.3-live-server-amd64.iso"
CLOUD_INIT_FILE="$(dirname "$(realpath "$0")")/vm-template.yaml"
DISK_PATH="/tank/kvm"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Provision a KVM VM from an ISO with cloud-init configuration.

Required:
  -n, --name NAME           VM name

Optional:
  -c, --cloud-init PATH     Path to cloud-init/autoinstall YAML file
                            (default: vm-template.yaml in script directory)
  -i, --iso PATH            Path to OS ISO (default: /tank/isos/ubuntu-24.04.3-live-server-amd64.iso)
  -k, --tailscale-auth-key KEY
                            Tailscale pre-auth key for automatic tailnet registration
                            (can also be set via TAILSCALE_AUTH_KEY env var)
  -m, --memory MB           Memory in MB (default: 2048)
  -v, --vcpus NUM           Number of vCPUs (default: 2)
  -d, --disk-size GB        Disk size in GB (default: 20)
  -p, --disk-path PATH      Directory for VM disk (default: /tank/kvm)
  -h, --help                Show this help message

Example:
  $(basename "$0") -n myvm -i ubuntu-22.04.iso -c cloud-init.yaml -m 4096 -v 4 -d 50
  $(basename "$0") -n myvm -c vm-template.yaml -k tskey-auth-xxx...
EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -i|--iso)
            OS_ISO="$2"
            shift 2
            ;;
        -c|--cloud-init)
            CLOUD_INIT_FILE="$2"
            shift 2
            ;;
        -k|--tailscale-auth-key)
            TAILSCALE_AUTH_KEY="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -v|--vcpus)
            VCPUS="$2"
            shift 2
            ;;
        -d|--disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        -p|--disk-path)
            DISK_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[[ -z "$VM_NAME" ]] && error "VM name is required (-n)"

# Validate files exist
[[ ! -f "$OS_ISO" ]] && error "OS ISO not found: $OS_ISO"
[[ -n "$CLOUD_INIT_FILE" && ! -f "$CLOUD_INIT_FILE" ]] && error "Cloud-init file not found: $CLOUD_INIT_FILE"

# Check for required tools
for cmd in virt-install genisoimage virsh qemu-img; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd"
    fi
done

# Check if VM already exists
if virsh dominfo "$VM_NAME" &>/dev/null; then
    error "VM '$VM_NAME' already exists"
fi

log "Creating VM: $VM_NAME"
log "  Memory: ${MEMORY}MB"
log "  vCPUs: $VCPUS"
log "  Disk: ${DISK_SIZE}GB"

# Create cloud-init ISO if cloud-init file is provided
SEED_ISO_FINAL=""
if [[ -n "$CLOUD_INIT_FILE" ]]; then
    # Create temporary directory for cloud-init ISO
    TEMP_DIR=$(mktemp -d)
    CIDATA_DIR="$TEMP_DIR/cidata"
    mkdir -p "$CIDATA_DIR"

    # Copy user-data
    cp "$CLOUD_INIT_FILE" "$CIDATA_DIR/user-data"

    # Substitute ${{HOSTNAME}} and ${{TAILSCALE_AUTH_KEY}} placeholders
    sed -i "s|\\\${{HOSTNAME}}|${VM_NAME}|g" "$CIDATA_DIR/user-data"
    if [[ -z "$TAILSCALE_AUTH_KEY" ]] && grep -qF '${{TAILSCALE_AUTH_KEY}}' "$CIDATA_DIR/user-data" 2>/dev/null; then
        log "WARNING: Template contains \${{TAILSCALE_AUTH_KEY}} but no Tailscale auth key was provided."
        log "         Tailscale will not be automatically registered. Use -k or TAILSCALE_AUTH_KEY env var."
    fi
    sed -i "s|\\\${{TAILSCALE_AUTH_KEY}}|${TAILSCALE_AUTH_KEY}|g" "$CIDATA_DIR/user-data"

    # Create meta-data
    cat > "$CIDATA_DIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

    # Create network-config (optional, uses DHCP by default)
    cat > "$CIDATA_DIR/network-config" <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: true
EOF

    # Persist cloud-init source files for later reference
    CLOUD_INIT_SAVE_DIR="$DISK_PATH/${VM_NAME}-cloud-init"
    mkdir -p "$CLOUD_INIT_SAVE_DIR"
    cp "$CIDATA_DIR/user-data"      "$CLOUD_INIT_SAVE_DIR/"
    cp "$CIDATA_DIR/meta-data"      "$CLOUD_INIT_SAVE_DIR/"
    cp "$CIDATA_DIR/network-config" "$CLOUD_INIT_SAVE_DIR/"
    log "Cloud-init files saved: $CLOUD_INIT_SAVE_DIR"

    # Generate cloud-init NoCloud ISO
    SEED_ISO="$TEMP_DIR/seed.iso"
    log "Generating cloud-init seed ISO..."
    genisoimage -output "$SEED_ISO" \
        -volid cidata \
        -joliet \
        -rock \
        "$CIDATA_DIR/user-data" \
        "$CIDATA_DIR/meta-data" \
        "$CIDATA_DIR/network-config" \
        2>/dev/null

    # Copy seed ISO to permanent location
    SEED_ISO_FINAL="$DISK_PATH/${VM_NAME}-seed.iso"
    cp "$SEED_ISO" "$SEED_ISO_FINAL"
    log "Seed ISO created: $SEED_ISO_FINAL"
fi

# Create VM disk
VM_DISK="$DISK_PATH/${VM_NAME}.qcow2"
log "Creating VM disk: $VM_DISK"
qemu-img create -f qcow2 "$VM_DISK" "${DISK_SIZE}G"

# Build virt-install command
VIRT_INSTALL_ARGS=(
    --name "$VM_NAME"
    --memory "$MEMORY"
    --vcpus "$VCPUS"
    --disk "path=$VM_DISK,format=qcow2"
    --os-variant detect=on,name=linux2022
    --network network=default
    --graphics vnc,listen=0.0.0.0,password=ferrari
    --console pty,target_type=serial
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0
    --noautoconsole
)

# Add cloud-init seed ISO if provided
if [[ -n "$SEED_ISO_FINAL" ]]; then
    VIRT_INSTALL_ARGS+=(--disk "path=$SEED_ISO_FINAL,device=cdrom")
fi

# Add installer location and extra args for cloud-init based installs
if [[ -n "$CLOUD_INIT_FILE" ]]; then
    VIRT_INSTALL_ARGS+=(
        --location "$OS_ISO"
        --extra-args "autoinstall ds=nocloud console=ttyS0,115200n8"
    )
else
    # For non-cloud-init installs (like Talos), boot from ISO
    VIRT_INSTALL_ARGS+=(--cdrom "$OS_ISO")
fi

# Create and start VM
log "Starting VM installation..."
virt-install "${VIRT_INSTALL_ARGS[@]}"

log "VM '$VM_NAME' created successfully!"
log ""

# Get VNC display info
VNC_DISPLAY=$(virsh vncdisplay "$VM_NAME" 2>/dev/null || echo "unavailable")
if [[ "$VNC_DISPLAY" != "unavailable" ]]; then
    VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))
    log "VNC console: $(hostname -I | awk '{print $1}'):$VNC_PORT (display $VNC_DISPLAY)"
fi

# For cloud-init based installs, wait for installation to complete
if [[ -n "$CLOUD_INIT_FILE" ]]; then
    log "Waiting for installation to complete (VM will shut down when done)..."
    while [[ "$(virsh domstate "$VM_NAME" 2>/dev/null)" == "running" ]]; do
        sleep 10
    done
    log "Installation complete. VM has shut down."

    # Remove CDROM devices (installer ISO and seed ISO)
    log "Removing installer media..."
    CDROM_TARGETS=$(virsh domblklist "$VM_NAME" --details 2>/dev/null | awk '$2 == "cdrom" {print $3}')
    for target in $CDROM_TARGETS; do
        log "  Ejecting CDROM: $target"
        virsh change-media "$VM_NAME" "$target" --eject 2>/dev/null || true
    done

    # Remove the seed ISO file if it was created
    if [[ -n "$SEED_ISO_FINAL" && -f "$SEED_ISO_FINAL" ]]; then
        log "Removing seed ISO: $SEED_ISO_FINAL"
        rm -f "$SEED_ISO_FINAL"
    fi

    # Start the VM from installed disk
    log "Starting VM '$VM_NAME' from installed disk..."
    virsh start "$VM_NAME"
else
    # For non-cloud-init installs (like Talos), the VM is already running
    log "VM is running. For Talos Linux, use 'talosctl' to configure the node."
fi

# Wait for IP address
log "Waiting for VM to obtain IP address..."
VM_IP=""
for i in {1..60}; do
    # Check if VM is still running
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$VM_STATE" != "running" ]]; then
        log "Warning: VM is no longer running (state: $VM_STATE)"
        break
    fi
    VM_IP=$(virsh domifaddr "$VM_NAME" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -1) || true
    if [[ -n "$VM_IP" ]]; then
        break
    fi
    # Fallback to lease source if agent didn't work
    VM_IP=$(virsh domifaddr "$VM_NAME" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -1) || true
    if [[ -n "$VM_IP" ]]; then
        break
    fi
    sleep 2
done

log ""
if [[ -n "$VM_IP" ]]; then
    log "VM '$VM_NAME' is ready!"
    log "IP Address: $VM_IP"
    log "SSH command: ssh $VM_IP"
else
    log "Warning: Could not determine IP address"
    log "Try: virsh domifaddr $VM_NAME"
fi

log ""
log "Useful commands:"
log "  Console:  virsh console $VM_NAME"
log "  Stop:     virsh shutdown $VM_NAME"
log "  Delete:   virsh destroy $VM_NAME && virsh undefine $VM_NAME --remove-all-storage"
