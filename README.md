# vm_automation

KVM/QEMU VM automation scripts for provisioning Ubuntu VMs with cloud-init, cloning existing VMs, and standing up Talos Linux Kubernetes clusters via Tinkerbell PXE boot.

## Repository Structure

```
vm_automation/
├── provision-vm.sh          # Provision Ubuntu VMs from ISO + cloud-init
├── clone-vm.sh              # Clone an existing VM
├── provision-talos-vms.sh   # Create bare KVM VMs for Talos/PXE boot
└── templates/
    └── vm-template.yaml     # Default Ubuntu autoinstall template (with Tailscale)
```

## Prerequisites

- KVM/libvirt (`virt-install`, `virsh`, `virt-clone`)
- `qemu-img`
- `genisoimage` (for cloud-init seed ISO generation)
- Ubuntu server ISO (default: `/tank/isos/ubuntu-24.04.3-live-server-amd64.iso`)
- VM disk storage at `/tank/kvm/` (configurable)

## Scripts

### `provision-vm.sh` — Provision a new Ubuntu VM

Provisions a KVM VM from an Ubuntu ISO using cloud-init autoinstall. Handles seed ISO generation, placeholder substitution, installation monitoring, and post-install cleanup.

```
Usage: provision-vm.sh [OPTIONS]

Required:
  -n, --name NAME           VM name

Optional:
  -c, --cloud-init PATH     Path to cloud-init YAML (default: templates/vm-template.yaml)
  -i, --iso PATH            Path to OS ISO (default: /tank/isos/ubuntu-24.04.3-live-server-amd64.iso)
  -k, --tailscale-auth-key KEY   Tailscale pre-auth key (or set TAILSCALE_AUTH_KEY env var)
  -u, --username USER       OS username (or set VM_USERNAME env var)
  -P, --password HASH       Hashed password for OS user (or set VM_PASSWORD env var)
      --gh-username USER    GitHub username for SSH key import (or set GH_USERNAME env var)
  -m, --memory MB           Memory in MB (default: 2048)
  -v, --vcpus NUM           vCPUs (default: 2)
  -d, --disk-size GB        Disk size in GB (default: 20)
  -p, --disk-path PATH      Directory for VM disk (default: /tank/kvm)
  -h, --help
```

**Examples:**

```bash
# Full provisioning with all placeholders
./provision-vm.sh -n myvm \
  -u alice \
  -P "$(openssl passwd -6 mysecretpassword)" \
  --gh-username alicegithub \
  -k tskey-auth-xxx...

# Custom resources
./provision-vm.sh -n myvm -u alice -P "$(openssl passwd -6 pass)" -m 4096 -v 4 -d 50

# Custom cloud-init template
./provision-vm.sh -n myvm -c /path/to/my-template.yaml -u alice -P "$(openssl passwd -6 pass)"

# Via environment variables
export VM_USERNAME=alice VM_PASSWORD="$(openssl passwd -6 pass)" GH_USERNAME=alicegithub
export TAILSCALE_AUTH_KEY=tskey-auth-xxx...
./provision-vm.sh -n myvm
```

**What it does:**

1. Copies the cloud-init YAML and substitutes template placeholders
2. Generates a NoCloud seed ISO (`genisoimage`)
3. Creates a qcow2 disk image
4. Runs `virt-install` with autoinstall args
5. Waits for installation to complete (VM powers off when done)
6. Ejects installer media and removes the seed ISO
7. Starts the VM and waits for an IP address

**Disk layout after provisioning:**

```
/tank/kvm/
  myvm.qcow2
  myvm-cloud-init/
    user-data        ← post-substitution copy (for reference)
    meta-data
    network-config
```

---

### `clone-vm.sh` — Clone an existing VM

Clones a running or stopped VM using `virt-clone`, starts the clone, and waits for an IP address.

```bash
./clone-vm.sh <new-vm-name> [source-vm-name]

# Examples:
./clone-vm.sh clawd-test1              # Clones clawd-sandbox (default source)
./clone-vm.sh my-vm some-other-vm
```

---

### `provision-talos-vms.sh` — Create VMs for a Talos Kubernetes cluster

Creates 3 bare KVM VMs configured for PXE/network boot, intended to be provisioned by Tinkerbell. Does not install an OS directly.

```bash
./provision-talos-vms.sh
```

Creates:
- `talos-cp-01` — control plane (MAC: `52:54:00:12:34:01`)
- `talos-worker-01` — worker (MAC: `52:54:00:12:34:02`)
- `talos-worker-02` — worker (MAC: `52:54:00:12:34:03`)

Each VM: 4GB RAM, 2 vCPUs, 50GB disk, network boot enabled, autostart on.

---

## Cloud-Init Templates

### Template Placeholder System

Templates use `${{PLACEHOLDER}}` syntax (double braces). `provision-vm.sh` performs `sed` substitution before building the seed ISO.

| Placeholder | Flag | Env var | Behavior if missing |
|---|---|---|---|
| `${{HOSTNAME}}` | `-n` | — | Required (always set to VM name) |
| `${{TAILSCALE_AUTH_KEY}}` | `-k` | `TAILSCALE_AUTH_KEY` | Warning; Tailscale skipped |
| `${{USERNAME}}` | `-u` | `VM_USERNAME` | **Error** (install would be broken) |
| `${{USER_PASSWORD}}` | `-P` | `VM_PASSWORD` | **Error** (install would be broken) |
| `${{GH_USERNAME}}` | `--gh-username` | `GH_USERNAME` | Warning; SSH key import skipped |

### `templates/vm-template.yaml` — Default Ubuntu template

Ubuntu 24.04 autoinstall config that:
- Sets hostname, username, password, and imports SSH keys from GitHub
- Installs common packages (`curl`, `git`, `jq`, `qemu-guest-agent`, etc.)
- Installs Tailscale from the official apt repo
- Installs systemd services:
  - `tailscale-setup.service` — one-shot Tailscale registration on first boot (no-op if no authkey)
  - `report-ip-to-serial.service` — writes IP to `/dev/ttyS0` for easy discovery
  - `ssh-import-keys.service` — imports SSH keys from GitHub on first boot

---

## Tailscale Integration

When a Tailscale auth key is provided (via `-k` or `$TAILSCALE_AUTH_KEY`):

1. The authkey is written to `/etc/tailscale/authkey` (mode 600, root-only) during install
2. On first boot, `tailscale-setup.service` runs `tailscale up --authkey=file:/etc/tailscale/authkey`
3. The authkey file is deleted immediately after successful registration

If no key is provided, the authkey file is never written and the service is a no-op (`ConditionPathExists=/etc/tailscale/authkey`).

---

## Common virsh Commands

```bash
# List VMs
virsh list --all

# Console access (Ctrl+] to exit)
virsh console <vm-name>

# Power management
virsh start <vm-name>
virsh shutdown <vm-name>
virsh destroy <vm-name>        # Force off

# Get IP address
virsh domifaddr <vm-name>
virsh domifaddr <vm-name> --source agent

# VNC info
virsh vncdisplay <vm-name>

# Delete VM and disk
virsh destroy <vm-name>
virsh undefine <vm-name> --remove-all-storage
```
