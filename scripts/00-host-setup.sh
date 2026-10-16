#!/usr/bin/env bash
# ============================================================================
# 00-host-setup.sh — THE ONLY SCRIPT THAT NEEDS sudo.
#
#   sudo ./scripts/00-host-setup.sh
#
# Everything else in this lab runs as your normal user (libvirt group).
# This script is idempotent — safe to re-run.
#
# It installs/configures, on the LAPTOP ("the rack chassis"):
#   1. KVM/QEMU + libvirt + virt-manager        (hypervisor + GUI management)
#   2. Cockpit + cockpit-machines               (web management UI, LAN-reachable)
#   3. kubectl / helm / k9s / cilium / hubble   (cluster client tools)
#   4. libvirt + kvm group membership for you
#   5. IP forwarding + nftables DNAT            (LAN -> API VIP / Gateway)
#   6. /etc/hosts records for lab hostnames
# ============================================================================
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "run me with sudo: sudo $0" >&2; exit 1; }
REAL_USER="${SUDO_USER:-}"
[[ -n "$REAL_USER" && "$REAL_USER" != root ]] || { echo "run via sudo from your user account (need SUDO_USER)" >&2; exit 1; }

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/lab.env
. "$LAB_DIR/config/lab.env"

log() { printf '\e[32m[host-setup]\e[0m %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------- packages
log "installing virtualization stack + management tools (apt) ..."
apt-get update -q
apt-get install -yq \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients virtinst \
  virt-manager virt-viewer \
  cloud-image-utils genisoimage \
  cockpit cockpit-machines \
  jq curl gpg gettext-base tcpdump nftables openssl apt-transport-https

log "enabling libvirtd + cockpit ..."
systemctl enable --now libvirtd
systemctl enable --now cockpit.socket

log "adding $REAL_USER to libvirt + kvm groups ..."
usermod -aG libvirt,kvm "$REAL_USER"

# ------------------------------------------------------- kubernetes clients
if ! command -v kubectl >/dev/null; then
  log "installing kubectl ($K8S_MINOR train from pkgs.k8s.io) ..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -q
  apt-get install -yq kubectl
fi

if ! command -v helm >/dev/null; then
  log "installing helm ..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v k9s >/dev/null; then
  log "installing k9s $K9S_VERSION ..."
  curl -fsSL -o /tmp/k9s.deb "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_linux_amd64.deb"
  apt-get install -yq /tmp/k9s.deb && rm -f /tmp/k9s.deb
fi

if ! command -v cilium >/dev/null; then
  log "installing cilium CLI $CILIUM_CLI_VERSION ..."
  curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin cilium
fi

if ! command -v hubble >/dev/null; then
  log "installing hubble CLI $HUBBLE_CLI_VERSION ..."
  curl -fsSL "https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin hubble
fi

# ------------------------------------------------------------- ip forwarding
log "enabling IP forwarding (host routes the k8s-cluster network) ..."
cat > /etc/sysctl.d/99-k8slab.conf <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-k8slab.conf >/dev/null

# ------------------------------------------------- LAN exposure (nftables)
# DNAT on the laptop's LAN interface:
#   :6443 -> API server VIP     :80/:443 -> shared Gateway
# Rules live in their own table; `./labctl expose off` removes them.
LAN_IF="$(ip route show default | awk '{print $5; exit}')"
if [[ -n "$LAN_IF" ]]; then
  log "installing nftables DNAT rules on $LAN_IF (LAN -> VIP/Gateway) ..."
  # Clean up any remnants of the earlier include-based approach: we deliberately
  # do NOT hook /etc/nftables.conf — Ubuntu's default conf starts with
  # `flush ruleset`, which would nuke libvirt's rules on every service restart.
  sed -i '\#include "/etc/nftables.d/k8slab.nft"#d' /etc/nftables.conf 2>/dev/null || true
  systemctl disable --now nftables >/dev/null 2>&1 || true
  mkdir -p /etc/nftables.d
  cat > /etc/nftables.d/k8slab.nft <<EOF
#!/usr/sbin/nft -f
# k8s-lab LAN exposure — LAN clients hit the laptop IP, land on the cluster.
# Scoped to its own table; managed by k8slab-expose.service / labctl expose.
# (note: chain is named lan_dnat — "dnat" itself is a reserved nft keyword)
table inet k8slab
delete table inet k8slab
table inet k8slab {
  chain lan_dnat {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$LAN_IF" tcp dport 6443 dnat ip to ${API_VIP}:6443
    iifname "$LAN_IF" tcp dport 80   dnat ip to ${GATEWAY_IP}:80
    iifname "$LAN_IF" tcp dport 443  dnat ip to ${GATEWAY_IP}:443
  }
}
EOF
  cat > /etc/systemd/system/k8slab-expose.service <<'EOF'
[Unit]
Description=k8s-lab LAN DNAT rules (own nftables table, boot-persistent)
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/k8slab.nft
ExecStop=-/usr/sbin/nft delete table inet k8slab

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now k8slab-expose.service
  nft list table inet k8slab >/dev/null
else
  log "WARN: no default route found — skipping LAN DNAT rules"
fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "ufw is active — allowing lab ports ..."
  ufw allow 6443/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 9090/tcp
  ufw route allow to "${CLUSTER_CIDR}" || true
fi

# -------------------------------------------------- host shutdown behavior
# On host shutdown, gracefully SHUT DOWN the VMs (clean etcd stop) instead of
# the upstream default managedsave/suspend — suspended clusters wake up with
# jumped clocks, which etcd/TLS tolerate poorly. Boot-time start is handled
# by per-domain `virsh autostart` flags (see labctl autostart).
if ! grep -q '^ON_SHUTDOWN=shutdown' /etc/default/libvirt-guests 2>/dev/null; then
  log "configuring libvirt-guests: graceful VM shutdown on host shutdown ..."
  sed -i -E 's/^#?ON_SHUTDOWN=.*/ON_SHUTDOWN=shutdown/' /etc/default/libvirt-guests
  grep -q '^ON_SHUTDOWN=shutdown' /etc/default/libvirt-guests \
    || echo 'ON_SHUTDOWN=shutdown' >> /etc/default/libvirt-guests
  sed -i -E 's/^#?ON_BOOT=.*/ON_BOOT=ignore/' /etc/default/libvirt-guests
  grep -q '^ON_BOOT=ignore' /etc/default/libvirt-guests \
    || echo 'ON_BOOT=ignore' >> /etc/default/libvirt-guests
fi

# ------------------------------------------------------------ /etc/hosts
log "writing lab hostnames into /etc/hosts ..."
sed -i '/# BEGIN K8SLAB/,/# END K8SLAB/d' /etc/hosts
cat >> /etc/hosts <<EOF
# BEGIN K8SLAB (managed by scripts/00-host-setup.sh — do not edit inside block)
${API_VIP} ${API_FQDN}
${GATEWAY_IP} hello.${LAB_DOMAIN} hubble.${LAB_DOMAIN} grafana.${LAB_DOMAIN} prometheus.${LAB_DOMAIN} alertmanager.${LAB_DOMAIN} shop.${LAB_DOMAIN}
10.20.0.210 registry.${LAB_DOMAIN}
10.20.0.11 cp1.${LAB_DOMAIN} cp1
10.20.0.12 cp2.${LAB_DOMAIN} cp2
10.20.0.13 cp3.${LAB_DOMAIN} cp3
10.20.0.21 w1.${LAB_DOMAIN} w1
10.20.0.22 w2.${LAB_DOMAIN} w2
10.20.0.23 w3.${LAB_DOMAIN} w3
# END K8SLAB
EOF

log "done."
echo
echo "  Host is ready. Next (as $REAL_USER, NO sudo):   ./labctl up"
echo "  Note: virt-manager GUI needs a log-out/in to see the libvirt group;"
echo "        all lab scripts work immediately (they use sg)."
