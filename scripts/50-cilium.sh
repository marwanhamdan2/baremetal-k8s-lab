#!/usr/bin/env bash
# ============================================================================
# 50-cilium.sh — install the Cilium networking stack.
#
#   1. Gateway API CRDs (must exist BEFORE Cilium starts, or the gateway
#      controller stays disabled)
#   2. Cilium via helm (values: config/cilium-values.yaml.tpl)
#   3. LB-IPAM pool + L2 announcement policy
#
# After this, nodes go Ready, CoreDNS schedules, and the cluster has a
# fully functional eBPF datapath with no kube-proxy.
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

log "installing Gateway API CRDs $GATEWAY_API_VERSION (standard channel) ..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s >/dev/null

log "installing Cilium ${CILIUM_VERSION} via helm ..."
helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm repo update cilium >/dev/null
export API_VIP POD_CIDR
render "$LAB_DIR/config/cilium-values.yaml.tpl" "$GEN_DIR/cilium-values.yaml" API_VIP POD_CIDR
helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  -f "$GEN_DIR/cilium-values.yaml" >/dev/null

log "waiting for Cilium to become healthy (can take a few minutes) ..."
cilium status --wait --wait-duration 12m

log "applying LB-IPAM pool + L2 announcement policy ..."
POOL_API="cilium.io/$(kubectl get crd ciliumloadbalancerippools.cilium.io -o jsonpath='{.spec.versions[?(@.storage==true)].name}')"
L2_API="cilium.io/$(kubectl get crd ciliuml2announcementpolicies.cilium.io -o jsonpath='{.spec.versions[?(@.storage==true)].name}')"
export LB_POOL_START LB_POOL_STOP
sed -e "s#__POOL_API__#$POOL_API#" -e "s#__L2_API__#$L2_API#" "$LAB_DIR/manifests/cilium-lbipam.yaml" \
  | envsubst '${LB_POOL_START} ${LB_POOL_STOP}' \
  | kubectl apply -f -

# CoreDNS was created before the CNI existed — bounce it onto Cilium
kubectl -n kube-system rollout restart deploy/coredns >/dev/null
kubectl -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null

log "waiting for all nodes Ready ..."
kubectl wait --for=condition=Ready node --all --timeout=8m
kubectl get nodes -o wide
stage_done cilium
