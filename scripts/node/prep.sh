#!/usr/bin/env bash
# ============================================================================
# node/prep.sh — runs ON each VM (as root) to turn a stock Ubuntu 24.04
# server into a Kubernetes node. This is exactly what you would run on a
# bare-metal server in a real rack.
#
# Env (passed by 30-prep-nodes.sh): K8S_MINOR, PAUSE_IMAGE
#
#   1. kernel modules + sysctls required by Kubernetes/CNI
#   2. swap off (kubelet default requirement)
#   3. containerd (CRI) from Docker's apt repo — containerd 2.x, systemd cgroups
#   4. kubeadm / kubelet / kubectl from pkgs.k8s.io, version-held
# ============================================================================
set -Eeuo pipefail
: "${K8S_MINOR:?}" "${PAUSE_IMAGE:?}"

if [[ -f /var/lib/k8slab.prepped ]]; then echo "$(hostname): already prepped"; exit 0; fi
export DEBIAN_FRONTEND=noninteractive

# --- kernel prereqs -----------------------------------------------------
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# --- swap off (cloud image ships none; belt & braces) -------------------
swapoff -a
sed -ri 's/^([^#].*\sswap\s.*)$/#\1/' /etc/fstab

# --- containerd (CRI) ---------------------------------------------------
apt-get update -q
apt-get install -yq ca-certificates curl gpg apt-transport-https open-iscsi
systemctl enable --now iscsid >/dev/null 2>&1 || true   # Longhorn data path
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -yq containerd.io

# kubelet and containerd must agree on the cgroup driver: systemd (cgroup v2)
containerd config default > /etc/containerd/config.toml
sed -ri 's/(\s*SystemdCgroup\s*=\s*)false/\1true/' /etc/containerd/config.toml
# align the pause/sandbox image with what kubeadm expects (key name differs
# between containerd 1.x/2.x configs — patch whichever is present)
sed -ri "s#(sandbox_image\s*=\s*|sandbox\s*=\s*)['\"][^'\"]*pause[^'\"]*['\"]#\1'${PAUSE_IMAGE}'#" /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

# --- kubeadm / kubelet / kubectl ---------------------------------------
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -yq kubelet kubeadm kubectl cri-tools
apt-mark hold kubelet kubeadm kubectl >/dev/null

cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

systemctl enable kubelet >/dev/null 2>&1
touch /var/lib/k8slab.prepped
echo "$(hostname): node prep complete (containerd $(containerd --version | awk '{print $3}'), kubeadm $(kubeadm version -o short))"
