#!/usr/bin/env bash
# ============================================================================
# 40-init-cluster.sh — bootstrap the HA control plane + join all nodes.
#
#   1. generate kube-vip static-pod manifests (VIP 10.20.0.100 on eth1, ARP)
#   2. kubeadm init on cp1 against the VIP endpoint  (kube-proxy skipped!)
#   3. join cp2/cp3 as control planes (stacked etcd -> 3-member quorum)
#   4. join w1/w2/w3 as workers
#   5. approve kubelet serving CSRs (serverTLSBootstrap=true)
#
# kube-vip note: its leader election must talk to the LOCAL apiserver
# (127.0.0.1:6443, which is in the cert SANs) — NOT the VIP, which is the very
# address kube-vip exists to create (classic chicken-and-egg deadlock). Each CP
# gets /etc/kubernetes/kube-vip.kubeconfig derived from admin.conf after
# init/join, and only THEN is the static-pod manifest placed (placing it
# earlier makes the container runtime create a directory at the missing
# hostPath, wedging the mount). Nothing during init/join needs the VIP of the
# node being added, so late placement is safe.
# Nodes stay NotReady until Cilium is installed (50-cilium.sh) — expected.
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

KUBE_VIP_IMG="ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"

# --------------------------------------------------- kube-vip manifest
place_kube_vip() {                       # place_kube_vip <node>
  local node="$1" out
  out="$GEN_DIR/kube-vip-$node.yaml"
  log "generating kube-vip manifest on $node"
  nssh "$node" "sudo ctr -n k8s.io image pull $KUBE_VIP_IMG >/dev/null && \
    sudo ctr -n k8s.io run --rm --net-host $KUBE_VIP_IMG vipgen-\$\$ \
      /kube-vip manifest pod --interface eth1 --address $API_VIP \
      --controlplane --arp --leaderElection" > "$out"
  grep -q 'kind: Pod' "$out" || die "kube-vip manifest generation failed on $node"
  # rewrite ONLY the hostPath (lowercase 'path:'): the container keeps seeing
  # /etc/kubernetes/admin.conf at its mountPath, but the host file behind it
  # is the localhost-server kubeconfig (avoids the VIP chicken-and-egg).
  sed -i "s#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/kube-vip.kubeconfig#" "$out"
  nssh "$node" "sudo mkdir -p /etc/kubernetes/manifests && sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null" < "$out"
}

install_kube_vip_kubeconfig() {          # after init/join created admin.conf
  nssh "$1" "sudo sh -c 'sed \"s#server: https://.*#server: https://127.0.0.1:6443#\" /etc/kubernetes/admin.conf > /etc/kubernetes/kube-vip.kubeconfig && chmod 600 /etc/kubernetes/kube-vip.kubeconfig'"
}

# --------------------------------------------------- render init config
K8S_VER_EXACT="$(nssh cp1 'kubeadm version -o short')"
LAN_IP="$(lan_ip || true)"
CP1_IP="$(cluster_ip cp1)"
log "kubernetes $K8S_VER_EXACT | control-plane endpoint $API_FQDN ($API_VIP) | host LAN IP ${LAN_IP:-none}"

CERT_SANS=$(
  for san in "127.0.0.1" "$API_VIP" "$API_FQDN" "$CLUSTER_HOST_IP" ${LAN_IP:+"$LAN_IP"} "$(hostname)"; do
    printf '    - "%s"\n' "$san"
  done
  for n in $CP_NODES; do
    printf '    - "%s"\n    - "%s"\n    - "%s.%s"\n' "$(cluster_ip "$n")" "$n" "$n" "$LAB_DOMAIN"
  done
)
export CP1_IP LAB_NAME K8S_VER_EXACT API_FQDN POD_CIDR SVC_CIDR CERT_SANS
render "$LAB_DIR/config/kubeadm/init-config.yaml.tpl" "$GEN_DIR/kubeadm-init.yaml" \
  CP1_IP LAB_NAME K8S_VER_EXACT API_FQDN POD_CIDR SVC_CIDR CERT_SANS

# --------------------------------------------------- pre-pull on CPs
log "pre-pulling control-plane images on cp1 cp2 cp3 (parallel) ..."
for n in $CP_NODES; do
  nssh "$n" "sudo kubeadm config images pull --kubernetes-version $K8S_VER_EXACT" \
    > "$LOG_DIR/prepull-$n.log" 2>&1 &
done
wait

# --------------------------------------------------- init cp1
if nssh cp1 "sudo test -f /etc/kubernetes/admin.conf" 2>/dev/null; then
  log "cp1 already initialized — skipping init"
else
  nscp cp1 "$GEN_DIR/kubeadm-init.yaml" /tmp/kubeadm-init.yaml
  log "kubeadm init on cp1 (this takes ~1-2 min) ..."
  nssh cp1 "sudo kubeadm init --config /tmp/kubeadm-init.yaml --upload-certs" \
    > "$LOG_DIR/kubeadm-init.log" 2>&1 || die "kubeadm init failed — see $LOG_DIR/kubeadm-init.log"
  install_kube_vip_kubeconfig cp1
  place_kube_vip cp1                   # kube-vip starts and claims the VIP
  log "cp1 initialized"
fi

# --------------------------------------------------- kubeconfig -> host
mkdir -p "$HOME/.kube"
[[ -f "$HOME/.kube/config" && ! -f "$STATE_DIR/kubeconfig-installed" ]] \
  && cp "$HOME/.kube/config" "$HOME/.kube/config.bak.$(date +%s)"
nssh cp1 "sudo cat /etc/kubernetes/admin.conf" > "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
cp "$HOME/.kube/config" "$STATE_DIR/kubeconfig"
touch "$STATE_DIR/kubeconfig-installed"

log "waiting for API server via the VIP ($API_FQDN -> $API_VIP) ..."
retry 30 5 kubectl get --raw /readyz >/dev/null || die "API not reachable via VIP"
log "API is answering through kube-vip"

# --------------------------------------------------- join materials
JOIN_CMD="$(nssh cp1 'sudo kubeadm token create --ttl 2h --print-join-command')"
TOKEN="$(grep -oP '(?<=--token )\S+' <<<"$JOIN_CMD")"
CA_HASH="$(grep -oP '(?<=--discovery-token-ca-cert-hash )\S+' <<<"$JOIN_CMD")"
# Prefer the certificate key from the recent init (the kubeadm-certs secret
# lives 2h). Standalone `init phase upload-certs` is the fallback — some 1.35
# patch levels hit a kubeadm quirk there (ensure-admin with a starved client
# rate limiter), so it only runs when the init-log key is unavailable.
CERT_KEY="$(grep -oPh '(?<=--certificate-key )[0-9a-f]{64}' "$LOG_DIR/kubeadm-init.log" 2>/dev/null | head -1 || true)"
if [[ ! "$CERT_KEY" =~ ^[0-9a-f]{64}$ ]]; then
  CERT_KEY="$(nssh cp1 'sudo kubeadm certs certificate-key')"
  nssh cp1 "sudo kubeadm init phase upload-certs --upload-certs --certificate-key $CERT_KEY" \
    > "$LOG_DIR/upload-certs.log" 2>&1 || die "certs upload failed — see $LOG_DIR/upload-certs.log"
fi
[[ "$TOKEN" == *.* && "$CA_HASH" == sha256:* && "$CERT_KEY" =~ ^[0-9a-f]{64}$ ]] \
  || die "failed to derive join materials (token=$TOKEN hash=$CA_HASH certkey=${CERT_KEY:0:8}...)"
export API_FQDN TOKEN CA_HASH CERT_KEY

join_node() {                            # join_node <node> <cp|worker>
  local node="$1" kind="$2" tpl ip
  ip="$(cluster_ip "$node")"
  if nssh "$node" "sudo test -f /etc/kubernetes/kubelet.conf" 2>/dev/null; then
    log "$node already joined — skipping"; return 0
  fi
  tpl="join-worker.yaml.tpl"; [[ "$kind" == cp ]] && tpl="join-cp.yaml.tpl"
  NODE_IP="$ip" ; export NODE_IP
  render "$LAB_DIR/config/kubeadm/$tpl" "$GEN_DIR/kubeadm-join-$node.yaml" \
    API_FQDN TOKEN CA_HASH CERT_KEY NODE_IP
  nscp "$node" "$GEN_DIR/kubeadm-join-$node.yaml" /tmp/kubeadm-join.yaml
  log "joining $node ($kind) ..."
  nssh "$node" "sudo kubeadm join --config /tmp/kubeadm-join.yaml" \
    > "$LOG_DIR/join-$node.log" 2>&1 || die "join failed on $node — see $LOG_DIR/join-$node.log"
  if [[ "$kind" == cp ]]; then
    install_kube_vip_kubeconfig "$node"
    place_kube_vip "$node"
  fi
  log "$node joined"
}

# control planes sequentially (each join = an etcd member add; keep it serial)
for n in cp2 cp3; do join_node "$n" cp; done

# workers in parallel
declare -A wpids
for n in $WORKER_NODES; do
  ( join_node "$n" worker ) & wpids[$n]=$!
done
for n in $WORKER_NODES; do
  wait "${wpids[$n]}" || die "worker join failed on $n — see $LOG_DIR/join-$n.log"
done

# --------------------------------------------------- kubelet serving CSRs
log "approving kubelet serving CSRs (serverTLSBootstrap) ..."
for i in $(seq 1 18); do
  approve_kubelet_csrs
  approved=$(kubectl get csr -o json | jq '[.items[]
    | select(.spec.signerName=="kubernetes.io/kubelet-serving")
    | select(any(.status.conditions[]?; .type=="Approved"))] | length')
  [[ "$approved" -ge 6 ]] && break
  sleep 5
done
log "$approved kubelet-serving CSRs approved"

kubectl label nodes --overwrite -l '!node-role.kubernetes.io/control-plane' node-role.kubernetes.io/worker= >/dev/null 2>&1 || true

log "cluster membership:"
kubectl get nodes -o wide
echo
log "nodes are NotReady until the CNI lands — next: scripts/50-cilium.sh"
stage_done cluster
