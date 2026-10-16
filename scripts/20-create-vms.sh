#!/usr/bin/env bash
# ============================================================================
# 20-create-vms.sh — provision the 6 "servers" (real KVM VMs) from the
# Ubuntu 24.04 cloud image, exactly like PXE/cloud-init provisioning in a DC:
#
#   base image (read-only backing file)
#     └── per-node qcow2 copy-on-write overlay (30G cp / 60G worker, thin)
#   + per-node cloud-init NoCloud seed ISO (identity, ssh key, static IPs)
#
# VMs: k8s-cp1..cp3 (2 vCPU/4G) and k8s-w1..w3 (4 vCPU/8G), each with
#   eth0 -> k8s-mgmt (NAT, internet)   eth1 -> k8s-cluster (routed, k8s)
# NICs get deterministic MACs so netplan matches them by MAC.
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

# ------------------------------------------------------------ ssh key
if [[ ! -f "$SSH_KEY" ]]; then
  log "generating lab SSH key $SSH_KEY"
  ssh-keygen -t ed25519 -N "" -C "k8s-lab" -f "$SSH_KEY" >/dev/null
fi
SSH_PUB="$(cat "$SSH_KEY.pub")"

# ------------------------------------------------------------ base image
IMG="$CACHE_DIR/$UBUNTU_IMG"
if [[ ! -s "$IMG" ]]; then
  log "downloading Ubuntu 24.04 cloud image ..."
  curl -fL -C - --retry 3 -o "$IMG" "$UBUNTU_IMG_URL"
fi
qemu-img info "$IMG" >/dev/null || die "downloaded image is corrupt: $IMG"

# ------------------------------------------------------------ storage pool
if ! vsh pool-info "$VM_POOL" &>/dev/null; then
  log "creating storage pool $VM_POOL -> $VM_POOL_DIR"
  vsh pool-define-as "$VM_POOL" dir --target "$VM_POOL_DIR"
  vsh pool-build "$VM_POOL"
fi
vsh pool-autostart "$VM_POOL" >/dev/null 2>&1 || true
pool_running "$VM_POOL" || vsh pool-start "$VM_POOL"

# upload base image as a volume (once)
if ! vsh vol-info --pool "$VM_POOL" base.qcow2 &>/dev/null; then
  VIRT_SIZE=$(qemu-img info --output=json "$IMG" | jq -r '."virtual-size"')
  log "uploading base image into pool ($((VIRT_SIZE / 1024 / 1024)) MiB virtual) ..."
  vsh vol-create-as "$VM_POOL" base.qcow2 "$VIRT_SIZE" --format qcow2
  vsh vol-upload --pool "$VM_POOL" base.qcow2 "$IMG"
fi

# ------------------------------------------------------------ per-node
# /etc/hosts content for every node (6-space indent for the cloud-init YAML)
ETC_HOSTS=$(
  printf '      127.0.0.1 localhost\n'
  printf '      %s %s\n' "$API_VIP" "$API_FQDN"
  for n in $ALL_NODES; do
    printf '      %s %s.%s %s\n' "$(cluster_ip "$n")" "$n" "$LAB_DOMAIN" "$n"
    printf '      %s %s-mgmt\n' "$(mgmt_ip "$n")" "$n"
  done
)
export ETC_HOSTS SSH_PUB SSH_USER LAB_DOMAIN MGMT_GW

create_vm() {
  local node="$1" vm; vm="$(vm_name "$node")"
  if vsh dominfo "$vm" &>/dev/null; then
    log "$vm already exists — skipping"
    return 0
  fi

  local disk_gb vcpus ram
  disk_gb=$(node_disk "$node"); vcpus=$(node_vcpus "$node"); ram=$(node_ram "$node")

  log "creating $vm (${vcpus} vCPU, ${ram}MiB, ${disk_gb}G disk) ..."

  # thin COW overlay on the shared base image
  vsh vol-create-as "$VM_POOL" "$node.qcow2" "${disk_gb}G" --format qcow2 \
    --backing-vol base.qcow2 --backing-vol-format qcow2

  # cloud-init seed ISO
  local d="$GEN_DIR/cloudinit-$node"; mkdir -p "$d"
  export NODE="$node"
  export MAC_MGMT="$(mac_mgmt "$node")" MAC_CLUSTER="$(mac_cluster "$node")"
  export MGMT_IP="$(mgmt_ip "$node")" CLUSTER_IP="$(cluster_ip "$node")"
  render "$LAB_DIR/config/cloud-init/user-data.tpl"      "$d/user-data"      NODE LAB_DOMAIN SSH_USER SSH_PUB ETC_HOSTS
  render "$LAB_DIR/config/cloud-init/meta-data.tpl"      "$d/meta-data"      NODE
  render "$LAB_DIR/config/cloud-init/network-config.tpl" "$d/network-config" MAC_MGMT MAC_CLUSTER MGMT_IP CLUSTER_IP MGMT_GW LAB_DOMAIN
  cloud-localds "$d/seed.iso" "$d/user-data" "$d/meta-data" -N "$d/network-config"

  vsh vol-create-as "$VM_POOL" "$node-seed.iso" "$(stat -c %s "$d/seed.iso")" --format raw
  vsh vol-upload --pool "$VM_POOL" "$node-seed.iso" "$d/seed.iso"

  lv virt-install \
    --connect qemu:///system \
    --name "$vm" \
    --memory "$ram" --vcpus "$vcpus" --cpu host-passthrough \
    --import \
    --disk "vol=$VM_POOL/$node.qcow2,bus=virtio" \
    --disk "vol=$VM_POOL/$node-seed.iso,device=cdrom" \
    --network "network=$MGMT_NET,model=virtio,mac=$MAC_MGMT" \
    --network "network=$CLUSTER_NET,model=virtio,mac=$MAC_CLUSTER" \
    --osinfo ubuntu24.04 \
    --graphics none --console pty,target.type=serial \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --noautoconsole >/dev/null
}

for n in $ALL_NODES; do create_vm "$n"; done

log "waiting for all nodes to finish first boot (cloud-init + SSH) ..."
for n in $ALL_NODES; do wait_ssh "$n"; done

log "sanity: hostname + NIC layout on each node"
for n in $ALL_NODES; do
  nssh "$n" "echo \"  \$(hostname) | eth0=\$(ip -4 -o a show eth0 | awk '{print \$4}') eth1=\$(ip -4 -o a show eth1 | awk '{print \$4}')\""
done

log "VMs up:"
vsh list --all
stage_done vms
